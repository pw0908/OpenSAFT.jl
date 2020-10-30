## Standard pressure solver
function get_volume(model::Cubic, p, T, z=[1.]; phase = "unknown")
    z = create_z(model, z)
    components = model.components

    N = length(p)

    ub = [Inf]
    lb = [log10(sum(z[i]*z[j]*model.params.b[union(i,j)] for i in model.components for j in model.components))]

    if phase == "unknown" || phase == "liquid"
        x0 = [log10(sum(z[i]*z[j]*model.params.b[union(i,j)] for i in model.components for j in model.components)/0.8)]
    elseif phase == "vapour"
        x0 = [log10(sum(z[i]*z[j]*model.params.b[union(i,j)] for i in model.components for j in model.components)/1e-2)]
    elseif phase == "supercritical"
        x0 = [log10(sum(z[i]*z[j]*model.params.b[union(i,j)] for i in model.components for j in model.components)/0.5)]
    end

    Vol = []
    if phase == "unknown"
        for i in 1:N
            f(v) = eos(model, z, 10^v[1], T[i]) + 10^v[1]*p[i]
            (f_best,v_best) = Solvers.tunneling(f,lb,ub,x0)
            append!(Vol,10^v_best[1])
        end
    else
        opt_min = NLopt.Opt(:LD_MMA, length(ub))
        opt_min.lower_bounds = lb
        opt_min.upper_bounds = ub
        opt_min.xtol_rel     = 1e-8
        for i in 1:N
            f(v)   = eos(model, z, 10^v[1], T[i]) + 10^v[1]*p[i]
            obj_f0 = x -> f(x)
            obj_f  = (x,g) -> Solvers.NLopt_obj(obj_f0,x,g)
            opt_min.min_objective =  obj_f
            (f_min,v_min) = NLopt.optimize(opt_min, x0)
            append!(Vol, 10^v_min[1])
        end
    end
    return Vol
end


## Pure saturation conditions solver
function get_sat_pure(model::Cubic, T)
    components = model.components
    v0    = [log10(model.params.b[components[1]]/0.9),
             log10(model.params.b[components[1]]/1e-3)]
    v_l   = []
    v_v   = []
    P_sat = []
    for i in 1:length(T)
        f! = (F,x) -> Obj_Sat(model, F, T[i], 10^x[1], 10^x[2])
        j! = (J,x) -> Jac_Sat(model, J, T[i], 10^x[1], 10^x[2])
        r  =nlsolve(f!,j!,v0)
        append!(v_l,10^r.zero[1])
        append!(v_v,10^r.zero[2])
        append!(P_sat,get_pressure(model,v_v[i],T[i]))
        v0 = r.zero
    end
    return (P_sat, v_l, v_v)
end

function Obj_Sat(model::Cubic, F, T, v_l, v_v)
    components = model.components[1]
    fun(x) = eos(model, create_z(model, [x[1]]), x[2], T)
    df(x)  = ForwardDiff.gradient(fun,x)
    df_l = df([1,v_l[1]])
    df_v = df([1,v_v[1]])
    F[1] = (df_l[2]-df_v[2])*model.params.b[components]^2/model.params.a[components]*27
    F[2] = (df_l[1]-df_v[1])*27*model.params.b[components]/8/model.params.a[components]
end

function Jac_Sat(model::Cubic, J, T, v_l, v_v)
    components = model.components[1]
    fun(x) = eos(model, create_z(model, [x[1]]), x[2], T)
    d2f(x) = ForwardDiff.hessian(fun,x)
    d2f_l = d2f([1,v_l[1]])
    d2f_v = d2f([1,v_v[1]])
    J[1,1] =  v_l[1]*d2f_l[2,2]*model.params.b[components]^2*log(10)/model.params.a[components]*27
    J[1,2] = -v_v[1]*d2f_v[2,2]*model.params.b[components]^2*log(10)/model.params.a[components]*27
    J[2,1] =  v_l[1]*d2f_l[1,2]*log(10)*27*model.params.b[components]/8/model.params.a[components]
    J[2,2] = -v_v[1]*d2f_v[1,2]*log(10)*27*model.params.b[components]/8/model.params.a[components]
end

function get_enthalpy_vap(model::Cubic, T)
    (P_sat,v_l,v_v) = get_sat_pure(model,T)
    fun(x) = eos(model, create_z(model,[1.0]), x[1], x[2])
    df(x)  = ForwardDiff.gradient(fun,x)
    H_vap = []
    for i in 1:length(T)
        H_l = fun([v_l[i],T[i]])-df([v_l[i],T[i]])[2]*T[i]-df([v_l[i],T[i]])[1]*v_l[i]
        H_v = fun([v_v[i],T[i]])-df([v_v[i],T[i]])[2]*T[i]-df([v_v[i],T[i]])[1]*v_v[i]
        append!(H_vap,H_v-H_l)
    end
    return H_vap
end
## Pure critical point solver
function get_crit_pure(model::Cubic; units = false, output=[u"K", u"Pa", u"m^3"])
    components = model.components
    f! = (F,x) -> Obj_Crit(model, F, x[1]*model.params.a[model.components[1]]/model.params.b[model.components[1]]/8.314*8/27, 10^x[2])
    # j! = (J,x) -> Jac_Crit(J,eos,model,x[1]*model.params.epsilon[(1, 1)],10^x[2])
    x0 = [1, log10(model.params.b[components[1]]/0.3)]
    r  = nlsolve(f!,x0)
    T_c = r.zero[1]*model.params.a[model.components[1]]/model.params.b[model.components[1]]/8.314*8/27
    v_c = 10^r.zero[2]
    p_c = get_pressure(model, v_c, T_c)
    if units
        return (uconvert(output[1], T_c*u"K"), uconvert(output[2], p_c*u"Pa"), uconvert(output[2], v_c*u"m^3"))
    else
        return (T_c, p_c, v_c)
    end
end

function Obj_Crit(model::Cubic, F, T_c, v_c)
    fun(x)  = eos(model, create_z(model, [1]), x[1], T_c)
    df(x)   = ForwardDiff.derivative(fun,x)
    d2f(x)  = ForwardDiff.derivative(df,x)
    d3f(x)  = ForwardDiff.derivative(d2f,x)
    F[1] = d2f(v_c)
    F[2] = d3f(v_c)
end