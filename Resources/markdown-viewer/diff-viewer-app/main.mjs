var go = { exports: {} }, wu = {};
var Fd;
function Wh() {
  if (Fd) return wu;
  Fd = 1;
  var A = /* @__PURE__ */ Symbol.for("react.transitional.element"), J = /* @__PURE__ */ Symbol.for("react.fragment");
  function st(b, Bt, wt) {
    var kt = null;
    if (wt !== void 0 && (kt = "" + wt), Bt.key !== void 0 && (kt = "" + Bt.key), "key" in Bt) {
      wt = {};
      for (var Pt in Bt)
        Pt !== "key" && (wt[Pt] = Bt[Pt]);
    } else wt = Bt;
    return Bt = wt.ref, {
      $$typeof: A,
      type: b,
      key: kt,
      ref: Bt !== void 0 ? Bt : null,
      props: wt
    };
  }
  return wu.Fragment = J, wu.jsx = st, wu.jsxs = st, wu;
}
var Wd;
function $h() {
  return Wd || (Wd = 1, go.exports = Wh()), go.exports;
}
var tt = $h(), vo = { exports: {} }, Yu = {}, po = { exports: {} }, bo = {};
var $d;
function Ih() {
  return $d || ($d = 1, (function(A) {
    function J(m, D) {
      var Y = m.length;
      m.push(D);
      t: for (; 0 < Y; ) {
        var Q = Y - 1 >>> 1, K = m[Q];
        if (0 < Bt(K, D))
          m[Q] = D, m[Y] = K, Y = Q;
        else break t;
      }
    }
    function st(m) {
      return m.length === 0 ? null : m[0];
    }
    function b(m) {
      if (m.length === 0) return null;
      var D = m[0], Y = m.pop();
      if (Y !== D) {
        m[0] = Y;
        t: for (var Q = 0, K = m.length, r = K >>> 1; Q < r; ) {
          var M = 2 * (Q + 1) - 1, B = m[M], H = M + 1, k = m[H];
          if (0 > Bt(B, Y))
            H < K && 0 > Bt(k, B) ? (m[Q] = k, m[H] = Y, Q = H) : (m[Q] = B, m[M] = Y, Q = M);
          else if (H < K && 0 > Bt(k, Y))
            m[Q] = k, m[H] = Y, Q = H;
          else break t;
        }
      }
      return D;
    }
    function Bt(m, D) {
      var Y = m.sortIndex - D.sortIndex;
      return Y !== 0 ? Y : m.id - D.id;
    }
    if (A.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var wt = performance;
      A.unstable_now = function() {
        return wt.now();
      };
    } else {
      var kt = Date, Pt = kt.now();
      A.unstable_now = function() {
        return kt.now() - Pt;
      };
    }
    var C = [], _ = [], lt = 1, L = null, Et = 3, Xt = !1, fe = !1, te = !1, Ye = !1, vt = typeof setTimeout == "function" ? setTimeout : null, Ge = typeof clearTimeout == "function" ? clearTimeout : null, Rt = typeof setImmediate < "u" ? setImmediate : null;
    function Ft(m) {
      for (var D = st(_); D !== null; ) {
        if (D.callback === null) b(_);
        else if (D.startTime <= m)
          b(_), D.sortIndex = D.expirationTime, J(C, D);
        else break;
        D = st(_);
      }
    }
    function ce(m) {
      if (te = !1, Ft(m), !fe)
        if (st(C) !== null)
          fe = !0, Nt || (Nt = !0, ee());
        else {
          var D = st(_);
          D !== null && G(ce, D.startTime - m);
        }
    }
    var Nt = !1, et = -1, Ut = 5, De = -1;
    function xe() {
      return Ye ? !0 : !(A.unstable_now() - De < Ut);
    }
    function oe() {
      if (Ye = !1, Nt) {
        var m = A.unstable_now();
        De = m;
        var D = !0;
        try {
          t: {
            fe = !1, te && (te = !1, Ge(et), et = -1), Xt = !0;
            var Y = Et;
            try {
              e: {
                for (Ft(m), L = st(C); L !== null && !(L.expirationTime > m && xe()); ) {
                  var Q = L.callback;
                  if (typeof Q == "function") {
                    L.callback = null, Et = L.priorityLevel;
                    var K = Q(
                      L.expirationTime <= m
                    );
                    if (m = A.unstable_now(), typeof K == "function") {
                      L.callback = K, Ft(m), D = !0;
                      break e;
                    }
                    L === st(C) && b(C), Ft(m);
                  } else b(C);
                  L = st(C);
                }
                if (L !== null) D = !0;
                else {
                  var r = st(_);
                  r !== null && G(
                    ce,
                    r.startTime - m
                  ), D = !1;
                }
              }
              break t;
            } finally {
              L = null, Et = Y, Xt = !1;
            }
            D = void 0;
          }
        } finally {
          D ? ee() : Nt = !1;
        }
      }
    }
    var ee;
    if (typeof Rt == "function")
      ee = function() {
        Rt(oe);
      };
    else if (typeof MessageChannel < "u") {
      var al = new MessageChannel(), Le = al.port2;
      al.port1.onmessage = oe, ee = function() {
        Le.postMessage(null);
      };
    } else
      ee = function() {
        vt(oe, 0);
      };
    function G(m, D) {
      et = vt(function() {
        m(A.unstable_now());
      }, D);
    }
    A.unstable_IdlePriority = 5, A.unstable_ImmediatePriority = 1, A.unstable_LowPriority = 4, A.unstable_NormalPriority = 3, A.unstable_Profiling = null, A.unstable_UserBlockingPriority = 2, A.unstable_cancelCallback = function(m) {
      m.callback = null;
    }, A.unstable_forceFrameRate = function(m) {
      0 > m || 125 < m ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : Ut = 0 < m ? Math.floor(1e3 / m) : 5;
    }, A.unstable_getCurrentPriorityLevel = function() {
      return Et;
    }, A.unstable_next = function(m) {
      switch (Et) {
        case 1:
        case 2:
        case 3:
          var D = 3;
          break;
        default:
          D = Et;
      }
      var Y = Et;
      Et = D;
      try {
        return m();
      } finally {
        Et = Y;
      }
    }, A.unstable_requestPaint = function() {
      Ye = !0;
    }, A.unstable_runWithPriority = function(m, D) {
      switch (m) {
        case 1:
        case 2:
        case 3:
        case 4:
        case 5:
          break;
        default:
          m = 3;
      }
      var Y = Et;
      Et = m;
      try {
        return D();
      } finally {
        Et = Y;
      }
    }, A.unstable_scheduleCallback = function(m, D, Y) {
      var Q = A.unstable_now();
      switch (typeof Y == "object" && Y !== null ? (Y = Y.delay, Y = typeof Y == "number" && 0 < Y ? Q + Y : Q) : Y = Q, m) {
        case 1:
          var K = -1;
          break;
        case 2:
          K = 250;
          break;
        case 5:
          K = 1073741823;
          break;
        case 4:
          K = 1e4;
          break;
        default:
          K = 5e3;
      }
      return K = Y + K, m = {
        id: lt++,
        callback: D,
        priorityLevel: m,
        startTime: Y,
        expirationTime: K,
        sortIndex: -1
      }, Y > Q ? (m.sortIndex = Y, J(_, m), st(C) === null && m === st(_) && (te ? (Ge(et), et = -1) : te = !0, G(ce, Y - Q))) : (m.sortIndex = K, J(C, m), fe || Xt || (fe = !0, Nt || (Nt = !0, ee()))), m;
    }, A.unstable_shouldYield = xe, A.unstable_wrapCallback = function(m) {
      var D = Et;
      return function() {
        var Y = Et;
        Et = D;
        try {
          return m.apply(this, arguments);
        } finally {
          Et = Y;
        }
      };
    };
  })(bo)), bo;
}
var Id;
function Ph() {
  return Id || (Id = 1, po.exports = Ih()), po.exports;
}
var So = { exports: {} }, F = {};
var Pd;
function t0() {
  if (Pd) return F;
  Pd = 1;
  var A = /* @__PURE__ */ Symbol.for("react.transitional.element"), J = /* @__PURE__ */ Symbol.for("react.portal"), st = /* @__PURE__ */ Symbol.for("react.fragment"), b = /* @__PURE__ */ Symbol.for("react.strict_mode"), Bt = /* @__PURE__ */ Symbol.for("react.profiler"), wt = /* @__PURE__ */ Symbol.for("react.consumer"), kt = /* @__PURE__ */ Symbol.for("react.context"), Pt = /* @__PURE__ */ Symbol.for("react.forward_ref"), C = /* @__PURE__ */ Symbol.for("react.suspense"), _ = /* @__PURE__ */ Symbol.for("react.memo"), lt = /* @__PURE__ */ Symbol.for("react.lazy"), L = /* @__PURE__ */ Symbol.for("react.activity"), Et = Symbol.iterator;
  function Xt(r) {
    return r === null || typeof r != "object" ? null : (r = Et && r[Et] || r["@@iterator"], typeof r == "function" ? r : null);
  }
  var fe = {
    isMounted: function() {
      return !1;
    },
    enqueueForceUpdate: function() {
    },
    enqueueReplaceState: function() {
    },
    enqueueSetState: function() {
    }
  }, te = Object.assign, Ye = {};
  function vt(r, M, B) {
    this.props = r, this.context = M, this.refs = Ye, this.updater = B || fe;
  }
  vt.prototype.isReactComponent = {}, vt.prototype.setState = function(r, M) {
    if (typeof r != "object" && typeof r != "function" && r != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, r, M, "setState");
  }, vt.prototype.forceUpdate = function(r) {
    this.updater.enqueueForceUpdate(this, r, "forceUpdate");
  };
  function Ge() {
  }
  Ge.prototype = vt.prototype;
  function Rt(r, M, B) {
    this.props = r, this.context = M, this.refs = Ye, this.updater = B || fe;
  }
  var Ft = Rt.prototype = new Ge();
  Ft.constructor = Rt, te(Ft, vt.prototype), Ft.isPureReactComponent = !0;
  var ce = Array.isArray;
  function Nt() {
  }
  var et = { H: null, A: null, T: null, S: null }, Ut = Object.prototype.hasOwnProperty;
  function De(r, M, B) {
    var H = B.ref;
    return {
      $$typeof: A,
      type: r,
      key: M,
      ref: H !== void 0 ? H : null,
      props: B
    };
  }
  function xe(r, M) {
    return De(r.type, M, r.props);
  }
  function oe(r) {
    return typeof r == "object" && r !== null && r.$$typeof === A;
  }
  function ee(r) {
    var M = { "=": "=0", ":": "=2" };
    return "$" + r.replace(/[=:]/g, function(B) {
      return M[B];
    });
  }
  var al = /\/+/g;
  function Le(r, M) {
    return typeof r == "object" && r !== null && r.key != null ? ee("" + r.key) : M.toString(36);
  }
  function G(r) {
    switch (r.status) {
      case "fulfilled":
        return r.value;
      case "rejected":
        throw r.reason;
      default:
        switch (typeof r.status == "string" ? r.then(Nt, Nt) : (r.status = "pending", r.then(
          function(M) {
            r.status === "pending" && (r.status = "fulfilled", r.value = M);
          },
          function(M) {
            r.status === "pending" && (r.status = "rejected", r.reason = M);
          }
        )), r.status) {
          case "fulfilled":
            return r.value;
          case "rejected":
            throw r.reason;
        }
    }
    throw r;
  }
  function m(r, M, B, H, k) {
    var W = typeof r;
    (W === "undefined" || W === "boolean") && (r = null);
    var ct = !1;
    if (r === null) ct = !0;
    else
      switch (W) {
        case "bigint":
        case "string":
        case "number":
          ct = !0;
          break;
        case "object":
          switch (r.$$typeof) {
            case A:
            case J:
              ct = !0;
              break;
            case lt:
              return ct = r._init, m(
                ct(r._payload),
                M,
                B,
                H,
                k
              );
          }
      }
    if (ct)
      return k = k(r), ct = H === "" ? "." + Le(r, 0) : H, ce(k) ? (B = "", ct != null && (B = ct.replace(al, "$&/") + "/"), m(k, M, B, "", function(yl) {
        return yl;
      })) : k != null && (oe(k) && (k = xe(
        k,
        B + (k.key == null || r && r.key === k.key ? "" : ("" + k.key).replace(
          al,
          "$&/"
        ) + "/") + ct
      )), M.push(k)), 1;
    ct = 0;
    var $t = H === "" ? "." : H + ":";
    if (ce(r))
      for (var pt = 0; pt < r.length; pt++)
        H = r[pt], W = $t + Le(H, pt), ct += m(
          H,
          M,
          B,
          W,
          k
        );
    else if (pt = Xt(r), typeof pt == "function")
      for (r = pt.call(r), pt = 0; !(H = r.next()).done; )
        H = H.value, W = $t + Le(H, pt++), ct += m(
          H,
          M,
          B,
          W,
          k
        );
    else if (W === "object") {
      if (typeof r.then == "function")
        return m(
          G(r),
          M,
          B,
          H,
          k
        );
      throw M = String(r), Error(
        "Objects are not valid as a React child (found: " + (M === "[object Object]" ? "object with keys {" + Object.keys(r).join(", ") + "}" : M) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return ct;
  }
  function D(r, M, B) {
    if (r == null) return r;
    var H = [], k = 0;
    return m(r, H, "", "", function(W) {
      return M.call(B, W, k++);
    }), H;
  }
  function Y(r) {
    if (r._status === -1) {
      var M = r._result;
      M = M(), M.then(
        function(B) {
          (r._status === 0 || r._status === -1) && (r._status = 1, r._result = B);
        },
        function(B) {
          (r._status === 0 || r._status === -1) && (r._status = 2, r._result = B);
        }
      ), r._status === -1 && (r._status = 0, r._result = M);
    }
    if (r._status === 1) return r._result.default;
    throw r._result;
  }
  var Q = typeof reportError == "function" ? reportError : function(r) {
    if (typeof window == "object" && typeof window.ErrorEvent == "function") {
      var M = new window.ErrorEvent("error", {
        bubbles: !0,
        cancelable: !0,
        message: typeof r == "object" && r !== null && typeof r.message == "string" ? String(r.message) : String(r),
        error: r
      });
      if (!window.dispatchEvent(M)) return;
    } else if (typeof process == "object" && typeof process.emit == "function") {
      process.emit("uncaughtException", r);
      return;
    }
    console.error(r);
  }, K = {
    map: D,
    forEach: function(r, M, B) {
      D(
        r,
        function() {
          M.apply(this, arguments);
        },
        B
      );
    },
    count: function(r) {
      var M = 0;
      return D(r, function() {
        M++;
      }), M;
    },
    toArray: function(r) {
      return D(r, function(M) {
        return M;
      }) || [];
    },
    only: function(r) {
      if (!oe(r))
        throw Error(
          "React.Children.only expected to receive a single React element child."
        );
      return r;
    }
  };
  return F.Activity = L, F.Children = K, F.Component = vt, F.Fragment = st, F.Profiler = Bt, F.PureComponent = Rt, F.StrictMode = b, F.Suspense = C, F.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = et, F.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(r) {
      return et.H.useMemoCache(r);
    }
  }, F.cache = function(r) {
    return function() {
      return r.apply(null, arguments);
    };
  }, F.cacheSignal = function() {
    return null;
  }, F.cloneElement = function(r, M, B) {
    if (r == null)
      throw Error(
        "The argument must be a React element, but you passed " + r + "."
      );
    var H = te({}, r.props), k = r.key;
    if (M != null)
      for (W in M.key !== void 0 && (k = "" + M.key), M)
        !Ut.call(M, W) || W === "key" || W === "__self" || W === "__source" || W === "ref" && M.ref === void 0 || (H[W] = M[W]);
    var W = arguments.length - 2;
    if (W === 1) H.children = B;
    else if (1 < W) {
      for (var ct = Array(W), $t = 0; $t < W; $t++)
        ct[$t] = arguments[$t + 2];
      H.children = ct;
    }
    return De(r.type, k, H);
  }, F.createContext = function(r) {
    return r = {
      $$typeof: kt,
      _currentValue: r,
      _currentValue2: r,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, r.Provider = r, r.Consumer = {
      $$typeof: wt,
      _context: r
    }, r;
  }, F.createElement = function(r, M, B) {
    var H, k = {}, W = null;
    if (M != null)
      for (H in M.key !== void 0 && (W = "" + M.key), M)
        Ut.call(M, H) && H !== "key" && H !== "__self" && H !== "__source" && (k[H] = M[H]);
    var ct = arguments.length - 2;
    if (ct === 1) k.children = B;
    else if (1 < ct) {
      for (var $t = Array(ct), pt = 0; pt < ct; pt++)
        $t[pt] = arguments[pt + 2];
      k.children = $t;
    }
    if (r && r.defaultProps)
      for (H in ct = r.defaultProps, ct)
        k[H] === void 0 && (k[H] = ct[H]);
    return De(r, W, k);
  }, F.createRef = function() {
    return { current: null };
  }, F.forwardRef = function(r) {
    return { $$typeof: Pt, render: r };
  }, F.isValidElement = oe, F.lazy = function(r) {
    return {
      $$typeof: lt,
      _payload: { _status: -1, _result: r },
      _init: Y
    };
  }, F.memo = function(r, M) {
    return {
      $$typeof: _,
      type: r,
      compare: M === void 0 ? null : M
    };
  }, F.startTransition = function(r) {
    var M = et.T, B = {};
    et.T = B;
    try {
      var H = r(), k = et.S;
      k !== null && k(B, H), typeof H == "object" && H !== null && typeof H.then == "function" && H.then(Nt, Q);
    } catch (W) {
      Q(W);
    } finally {
      M !== null && B.types !== null && (M.types = B.types), et.T = M;
    }
  }, F.unstable_useCacheRefresh = function() {
    return et.H.useCacheRefresh();
  }, F.use = function(r) {
    return et.H.use(r);
  }, F.useActionState = function(r, M, B) {
    return et.H.useActionState(r, M, B);
  }, F.useCallback = function(r, M) {
    return et.H.useCallback(r, M);
  }, F.useContext = function(r) {
    return et.H.useContext(r);
  }, F.useDebugValue = function() {
  }, F.useDeferredValue = function(r, M) {
    return et.H.useDeferredValue(r, M);
  }, F.useEffect = function(r, M) {
    return et.H.useEffect(r, M);
  }, F.useEffectEvent = function(r) {
    return et.H.useEffectEvent(r);
  }, F.useId = function() {
    return et.H.useId();
  }, F.useImperativeHandle = function(r, M, B) {
    return et.H.useImperativeHandle(r, M, B);
  }, F.useInsertionEffect = function(r, M) {
    return et.H.useInsertionEffect(r, M);
  }, F.useLayoutEffect = function(r, M) {
    return et.H.useLayoutEffect(r, M);
  }, F.useMemo = function(r, M) {
    return et.H.useMemo(r, M);
  }, F.useOptimistic = function(r, M) {
    return et.H.useOptimistic(r, M);
  }, F.useReducer = function(r, M, B) {
    return et.H.useReducer(r, M, B);
  }, F.useRef = function(r) {
    return et.H.useRef(r);
  }, F.useState = function(r) {
    return et.H.useState(r);
  }, F.useSyncExternalStore = function(r, M, B) {
    return et.H.useSyncExternalStore(
      r,
      M,
      B
    );
  }, F.useTransition = function() {
    return et.H.useTransition();
  }, F.version = "19.2.3", F;
}
var tm;
function To() {
  return tm || (tm = 1, So.exports = t0()), So.exports;
}
var xo = { exports: {} }, he = {};
var em;
function e0() {
  if (em) return he;
  em = 1;
  var A = To();
  function J(C) {
    var _ = "https://react.dev/errors/" + C;
    if (1 < arguments.length) {
      _ += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var lt = 2; lt < arguments.length; lt++)
        _ += "&args[]=" + encodeURIComponent(arguments[lt]);
    }
    return "Minified React error #" + C + "; visit " + _ + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function st() {
  }
  var b = {
    d: {
      f: st,
      r: function() {
        throw Error(J(522));
      },
      D: st,
      C: st,
      L: st,
      m: st,
      X: st,
      S: st,
      M: st
    },
    p: 0,
    findDOMNode: null
  }, Bt = /* @__PURE__ */ Symbol.for("react.portal");
  function wt(C, _, lt) {
    var L = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: Bt,
      key: L == null ? null : "" + L,
      children: C,
      containerInfo: _,
      implementation: lt
    };
  }
  var kt = A.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function Pt(C, _) {
    if (C === "font") return "";
    if (typeof _ == "string")
      return _ === "use-credentials" ? _ : "";
  }
  return he.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = b, he.createPortal = function(C, _) {
    var lt = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!_ || _.nodeType !== 1 && _.nodeType !== 9 && _.nodeType !== 11)
      throw Error(J(299));
    return wt(C, _, null, lt);
  }, he.flushSync = function(C) {
    var _ = kt.T, lt = b.p;
    try {
      if (kt.T = null, b.p = 2, C) return C();
    } finally {
      kt.T = _, b.p = lt, b.d.f();
    }
  }, he.preconnect = function(C, _) {
    typeof C == "string" && (_ ? (_ = _.crossOrigin, _ = typeof _ == "string" ? _ === "use-credentials" ? _ : "" : void 0) : _ = null, b.d.C(C, _));
  }, he.prefetchDNS = function(C) {
    typeof C == "string" && b.d.D(C);
  }, he.preinit = function(C, _) {
    if (typeof C == "string" && _ && typeof _.as == "string") {
      var lt = _.as, L = Pt(lt, _.crossOrigin), Et = typeof _.integrity == "string" ? _.integrity : void 0, Xt = typeof _.fetchPriority == "string" ? _.fetchPriority : void 0;
      lt === "style" ? b.d.S(
        C,
        typeof _.precedence == "string" ? _.precedence : void 0,
        {
          crossOrigin: L,
          integrity: Et,
          fetchPriority: Xt
        }
      ) : lt === "script" && b.d.X(C, {
        crossOrigin: L,
        integrity: Et,
        fetchPriority: Xt,
        nonce: typeof _.nonce == "string" ? _.nonce : void 0
      });
    }
  }, he.preinitModule = function(C, _) {
    if (typeof C == "string")
      if (typeof _ == "object" && _ !== null) {
        if (_.as == null || _.as === "script") {
          var lt = Pt(
            _.as,
            _.crossOrigin
          );
          b.d.M(C, {
            crossOrigin: lt,
            integrity: typeof _.integrity == "string" ? _.integrity : void 0,
            nonce: typeof _.nonce == "string" ? _.nonce : void 0
          });
        }
      } else _ == null && b.d.M(C);
  }, he.preload = function(C, _) {
    if (typeof C == "string" && typeof _ == "object" && _ !== null && typeof _.as == "string") {
      var lt = _.as, L = Pt(lt, _.crossOrigin);
      b.d.L(C, lt, {
        crossOrigin: L,
        integrity: typeof _.integrity == "string" ? _.integrity : void 0,
        nonce: typeof _.nonce == "string" ? _.nonce : void 0,
        type: typeof _.type == "string" ? _.type : void 0,
        fetchPriority: typeof _.fetchPriority == "string" ? _.fetchPriority : void 0,
        referrerPolicy: typeof _.referrerPolicy == "string" ? _.referrerPolicy : void 0,
        imageSrcSet: typeof _.imageSrcSet == "string" ? _.imageSrcSet : void 0,
        imageSizes: typeof _.imageSizes == "string" ? _.imageSizes : void 0,
        media: typeof _.media == "string" ? _.media : void 0
      });
    }
  }, he.preloadModule = function(C, _) {
    if (typeof C == "string")
      if (_) {
        var lt = Pt(_.as, _.crossOrigin);
        b.d.m(C, {
          as: typeof _.as == "string" && _.as !== "script" ? _.as : void 0,
          crossOrigin: lt,
          integrity: typeof _.integrity == "string" ? _.integrity : void 0
        });
      } else b.d.m(C);
  }, he.requestFormReset = function(C) {
    b.d.r(C);
  }, he.unstable_batchedUpdates = function(C, _) {
    return C(_);
  }, he.useFormState = function(C, _, lt) {
    return kt.H.useFormState(C, _, lt);
  }, he.useFormStatus = function() {
    return kt.H.useHostTransitionStatus();
  }, he.version = "19.2.3", he;
}
var lm;
function l0() {
  if (lm) return xo.exports;
  lm = 1;
  function A() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(A);
      } catch (J) {
        console.error(J);
      }
  }
  return A(), xo.exports = e0(), xo.exports;
}
var am;
function a0() {
  if (am) return Yu;
  am = 1;
  var A = Ph(), J = To(), st = l0();
  function b(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function Bt(t) {
    return !(!t || t.nodeType !== 1 && t.nodeType !== 9 && t.nodeType !== 11);
  }
  function wt(t) {
    var e = t, l = t;
    if (t.alternate) for (; e.return; ) e = e.return;
    else {
      t = e;
      do
        e = t, (e.flags & 4098) !== 0 && (l = e.return), t = e.return;
      while (t);
    }
    return e.tag === 3 ? l : null;
  }
  function kt(t) {
    if (t.tag === 13) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function Pt(t) {
    if (t.tag === 31) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function C(t) {
    if (wt(t) !== t)
      throw Error(b(188));
  }
  function _(t) {
    var e = t.alternate;
    if (!e) {
      if (e = wt(t), e === null) throw Error(b(188));
      return e !== t ? null : t;
    }
    for (var l = t, a = e; ; ) {
      var n = l.return;
      if (n === null) break;
      var u = n.alternate;
      if (u === null) {
        if (a = n.return, a !== null) {
          l = a;
          continue;
        }
        break;
      }
      if (n.child === u.child) {
        for (u = n.child; u; ) {
          if (u === l) return C(n), t;
          if (u === a) return C(n), e;
          u = u.sibling;
        }
        throw Error(b(188));
      }
      if (l.return !== a.return) l = n, a = u;
      else {
        for (var i = !1, f = n.child; f; ) {
          if (f === l) {
            i = !0, l = n, a = u;
            break;
          }
          if (f === a) {
            i = !0, a = n, l = u;
            break;
          }
          f = f.sibling;
        }
        if (!i) {
          for (f = u.child; f; ) {
            if (f === l) {
              i = !0, l = u, a = n;
              break;
            }
            if (f === a) {
              i = !0, a = u, l = n;
              break;
            }
            f = f.sibling;
          }
          if (!i) throw Error(b(189));
        }
      }
      if (l.alternate !== a) throw Error(b(190));
    }
    if (l.tag !== 3) throw Error(b(188));
    return l.stateNode.current === l ? t : e;
  }
  function lt(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t;
    for (t = t.child; t !== null; ) {
      if (e = lt(t), e !== null) return e;
      t = t.sibling;
    }
    return null;
  }
  var L = Object.assign, Et = /* @__PURE__ */ Symbol.for("react.element"), Xt = /* @__PURE__ */ Symbol.for("react.transitional.element"), fe = /* @__PURE__ */ Symbol.for("react.portal"), te = /* @__PURE__ */ Symbol.for("react.fragment"), Ye = /* @__PURE__ */ Symbol.for("react.strict_mode"), vt = /* @__PURE__ */ Symbol.for("react.profiler"), Ge = /* @__PURE__ */ Symbol.for("react.consumer"), Rt = /* @__PURE__ */ Symbol.for("react.context"), Ft = /* @__PURE__ */ Symbol.for("react.forward_ref"), ce = /* @__PURE__ */ Symbol.for("react.suspense"), Nt = /* @__PURE__ */ Symbol.for("react.suspense_list"), et = /* @__PURE__ */ Symbol.for("react.memo"), Ut = /* @__PURE__ */ Symbol.for("react.lazy"), De = /* @__PURE__ */ Symbol.for("react.activity"), xe = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), oe = Symbol.iterator;
  function ee(t) {
    return t === null || typeof t != "object" ? null : (t = oe && t[oe] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var al = /* @__PURE__ */ Symbol.for("react.client.reference");
  function Le(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === al ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case te:
        return "Fragment";
      case vt:
        return "Profiler";
      case Ye:
        return "StrictMode";
      case ce:
        return "Suspense";
      case Nt:
        return "SuspenseList";
      case De:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case fe:
          return "Portal";
        case Rt:
          return t.displayName || "Context";
        case Ge:
          return (t._context.displayName || "Context") + ".Consumer";
        case Ft:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case et:
          return e = t.displayName || null, e !== null ? e : Le(t.type) || "Memo";
        case Ut:
          e = t._payload, t = t._init;
          try {
            return Le(t(e));
          } catch {
          }
      }
    return null;
  }
  var G = Array.isArray, m = J.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, D = st.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, Y = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, Q = [], K = -1;
  function r(t) {
    return { current: t };
  }
  function M(t) {
    0 > K || (t.current = Q[K], Q[K] = null, K--);
  }
  function B(t, e) {
    K++, Q[K] = t.current, t.current = e;
  }
  var H = r(null), k = r(null), W = r(null), ct = r(null);
  function $t(t, e) {
    switch (B(W, e), B(k, t), B(H, null), e.nodeType) {
      case 9:
      case 11:
        t = (t = e.documentElement) && (t = t.namespaceURI) ? pd(t) : 0;
        break;
      default:
        if (t = e.tagName, e = e.namespaceURI)
          e = pd(e), t = bd(e, t);
        else
          switch (t) {
            case "svg":
              t = 1;
              break;
            case "math":
              t = 2;
              break;
            default:
              t = 0;
          }
    }
    M(H), B(H, t);
  }
  function pt() {
    M(H), M(k), M(W);
  }
  function yl(t) {
    t.memoizedState !== null && B(ct, t);
    var e = H.current, l = bd(e, t.type);
    e !== l && (B(k, t), B(H, l));
  }
  function Xe(t) {
    k.current === t && (M(H), M(k)), ct.current === t && (M(ct), Nu._currentValue = Y);
  }
  var nl, jn;
  function gl(t) {
    if (nl === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        nl = e && e[1] || "", jn = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + nl + t + jn;
  }
  var Oe = !1;
  function wn(t, e) {
    if (!t || Oe) return "";
    Oe = !0;
    var l = Error.prepareStackTrace;
    Error.prepareStackTrace = void 0;
    try {
      var a = {
        DetermineComponentFrameRoot: function() {
          try {
            if (e) {
              var E = function() {
                throw Error();
              };
              if (Object.defineProperty(E.prototype, "props", {
                set: function() {
                  throw Error();
                }
              }), typeof Reflect == "object" && Reflect.construct) {
                try {
                  Reflect.construct(E, []);
                } catch (S) {
                  var p = S;
                }
                Reflect.construct(t, [], E);
              } else {
                try {
                  E.call();
                } catch (S) {
                  p = S;
                }
                t.call(E.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (S) {
                p = S;
              }
              (E = t()) && typeof E.catch == "function" && E.catch(function() {
              });
            }
          } catch (S) {
            if (S && p && typeof S.stack == "string")
              return [S.stack, p.stack];
          }
          return [null, null];
        }
      };
      a.DetermineComponentFrameRoot.displayName = "DetermineComponentFrameRoot";
      var n = Object.getOwnPropertyDescriptor(
        a.DetermineComponentFrameRoot,
        "name"
      );
      n && n.configurable && Object.defineProperty(
        a.DetermineComponentFrameRoot,
        "name",
        { value: "DetermineComponentFrameRoot" }
      );
      var u = a.DetermineComponentFrameRoot(), i = u[0], f = u[1];
      if (i && f) {
        var s = i.split(`
`), v = f.split(`
`);
        for (n = a = 0; a < s.length && !s[a].includes("DetermineComponentFrameRoot"); )
          a++;
        for (; n < v.length && !v[n].includes(
          "DetermineComponentFrameRoot"
        ); )
          n++;
        if (a === s.length || n === v.length)
          for (a = s.length - 1, n = v.length - 1; 1 <= a && 0 <= n && s[a] !== v[n]; )
            n--;
        for (; 1 <= a && 0 <= n; a--, n--)
          if (s[a] !== v[n]) {
            if (a !== 1 || n !== 1)
              do
                if (a--, n--, 0 > n || s[a] !== v[n]) {
                  var x = `
` + s[a].replace(" at new ", " at ");
                  return t.displayName && x.includes("<anonymous>") && (x = x.replace("<anonymous>", t.displayName)), x;
                }
              while (1 <= a && 0 <= n);
            break;
          }
      }
    } finally {
      Oe = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? gl(l) : "";
  }
  function df(t, e) {
    switch (t.tag) {
      case 26:
      case 27:
      case 5:
        return gl(t.type);
      case 16:
        return gl("Lazy");
      case 13:
        return t.child !== e && e !== null ? gl("Suspense Fallback") : gl("Suspense");
      case 19:
        return gl("SuspenseList");
      case 0:
      case 15:
        return wn(t.type, !1);
      case 11:
        return wn(t.type.render, !1);
      case 1:
        return wn(t.type, !0);
      case 31:
        return gl("Activity");
      default:
        return "";
    }
  }
  function Gu(t) {
    try {
      var e = "", l = null;
      do
        e += df(t, l), l = t, t = t.return;
      while (t);
      return e;
    } catch (a) {
      return `
Error generating stack: ` + a.message + `
` + a.stack;
    }
  }
  var Yn = Object.prototype.hasOwnProperty, Gn = A.unstable_scheduleCallback, Sa = A.unstable_cancelCallback, Ln = A.unstable_shouldYield, Lu = A.unstable_requestPaint, le = A.unstable_now, Xu = A.unstable_getCurrentPriorityLevel, Qu = A.unstable_ImmediatePriority, $a = A.unstable_UserBlockingPriority, xa = A.unstable_NormalPriority, mf = A.unstable_LowPriority, Vu = A.unstable_IdlePriority, hf = A.log, Zu = A.unstable_setDisableYieldValue, Ta = null, ye = null;
  function ul(t) {
    if (typeof hf == "function" && Zu(t), ye && typeof ye.setStrictMode == "function")
      try {
        ye.setStrictMode(Ta, t);
      } catch {
      }
  }
  var ge = Math.clz32 ? Math.clz32 : Ku, yf = Math.log, za = Math.LN2;
  function Ku(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (yf(t) / za | 0) | 0;
  }
  var vl = 256, Ia = 262144, pl = 4194304;
  function bl(t) {
    var e = t & 42;
    if (e !== 0) return e;
    switch (t & -t) {
      case 1:
        return 1;
      case 2:
        return 2;
      case 4:
        return 4;
      case 8:
        return 8;
      case 16:
        return 16;
      case 32:
        return 32;
      case 64:
        return 64;
      case 128:
        return 128;
      case 256:
      case 512:
      case 1024:
      case 2048:
      case 4096:
      case 8192:
      case 16384:
      case 32768:
      case 65536:
      case 131072:
        return t & 261888;
      case 262144:
      case 524288:
      case 1048576:
      case 2097152:
        return t & 3932160;
      case 4194304:
      case 8388608:
      case 16777216:
      case 33554432:
        return t & 62914560;
      case 67108864:
        return 67108864;
      case 134217728:
        return 134217728;
      case 268435456:
        return 268435456;
      case 536870912:
        return 536870912;
      case 1073741824:
        return 0;
      default:
        return t;
    }
  }
  function Pa(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, u = t.suspendedLanes, i = t.pingedLanes;
    t = t.warmLanes;
    var f = a & 134217727;
    return f !== 0 ? (a = f & ~u, a !== 0 ? n = bl(a) : (i &= f, i !== 0 ? n = bl(i) : l || (l = f & ~t, l !== 0 && (n = bl(l))))) : (f = a & ~u, f !== 0 ? n = bl(f) : i !== 0 ? n = bl(i) : l || (l = a & ~t, l !== 0 && (n = bl(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & u) === 0 && (u = n & -n, l = e & -e, u >= l || u === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function Xl(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function Ju(t, e) {
    switch (t) {
      case 1:
      case 2:
      case 4:
      case 8:
      case 64:
        return e + 250;
      case 16:
      case 32:
      case 128:
      case 256:
      case 512:
      case 1024:
      case 2048:
      case 4096:
      case 8192:
      case 16384:
      case 32768:
      case 65536:
      case 131072:
      case 262144:
      case 524288:
      case 1048576:
      case 2097152:
        return e + 5e3;
      case 4194304:
      case 8388608:
      case 16777216:
      case 33554432:
        return -1;
      case 67108864:
      case 134217728:
      case 268435456:
      case 536870912:
      case 1073741824:
        return -1;
      default:
        return -1;
    }
  }
  function ku() {
    var t = pl;
    return pl <<= 1, (pl & 62914560) === 0 && (pl = 4194304), t;
  }
  function Ie(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function Ql(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function gf(t, e, l, a, n, u) {
    var i = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var f = t.entanglements, s = t.expirationTimes, v = t.hiddenUpdates;
    for (l = i & ~l; 0 < l; ) {
      var x = 31 - ge(l), E = 1 << x;
      f[x] = 0, s[x] = -1;
      var p = v[x];
      if (p !== null)
        for (v[x] = null, x = 0; x < p.length; x++) {
          var S = p[x];
          S !== null && (S.lane &= -536870913);
        }
      l &= ~E;
    }
    a !== 0 && Ma(t, a, 0), u !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= u & ~(i & ~e));
  }
  function Ma(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - ge(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function Xn(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - ge(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function Fu(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : se(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function se(t) {
    switch (t) {
      case 2:
        t = 1;
        break;
      case 8:
        t = 4;
        break;
      case 32:
        t = 16;
        break;
      case 256:
      case 512:
      case 1024:
      case 2048:
      case 4096:
      case 8192:
      case 16384:
      case 32768:
      case 65536:
      case 131072:
      case 262144:
      case 524288:
      case 1048576:
      case 2097152:
      case 4194304:
      case 8388608:
      case 16777216:
      case 33554432:
        t = 128;
        break;
      case 268435456:
        t = 134217728;
        break;
      default:
        t = 0;
    }
    return t;
  }
  function Ea(t) {
    return t &= -t, 2 < t ? 8 < t ? (t & 134217727) !== 0 ? 32 : 268435456 : 8 : 2;
  }
  function tn() {
    var t = D.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Xd(t.type));
  }
  function Wu(t, e) {
    var l = D.p;
    try {
      return D.p = t, e();
    } finally {
      D.p = l;
    }
  }
  var il = Math.random().toString(36).slice(2), Qt = "__reactFiber$" + il, re = "__reactProps$" + il, Sl = "__reactContainer$" + il, en = "__reactEvents$" + il, vf = "__reactListeners$" + il, pf = "__reactHandles$" + il, $u = "__reactResources$" + il, Aa = "__reactMarker$" + il;
  function Qn(t) {
    delete t[Qt], delete t[re], delete t[en], delete t[vf], delete t[pf];
  }
  function xl(t) {
    var e = t[Qt];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[Sl] || l[Qt]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Ad(t); t !== null; ) {
            if (l = t[Qt]) return l;
            t = Ad(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function fl(t) {
    if (t = t[Qt] || t[Sl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function Tl(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(b(33));
  }
  function Vl(t) {
    var e = t[$u];
    return e || (e = t[$u] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function Yt(t) {
    t[Aa] = !0;
  }
  var _a = /* @__PURE__ */ new Set(), Vn = {};
  function cl(t, e) {
    Zl(t, e), Zl(t + "Capture", e);
  }
  function Zl(t, e) {
    for (Vn[t] = e, t = 0; t < e.length; t++)
      _a.add(e[t]);
  }
  var Iu = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), Pu = {}, Zn = {};
  function bf(t) {
    return Yn.call(Zn, t) ? !0 : Yn.call(Pu, t) ? !1 : Iu.test(t) ? Zn[t] = !0 : (Pu[t] = !0, !1);
  }
  function ln(t, e, l) {
    if (bf(e))
      if (l === null) t.removeAttribute(e);
      else {
        switch (typeof l) {
          case "undefined":
          case "function":
          case "symbol":
            t.removeAttribute(e);
            return;
          case "boolean":
            var a = e.toLowerCase().slice(0, 5);
            if (a !== "data-" && a !== "aria-") {
              t.removeAttribute(e);
              return;
            }
        }
        t.setAttribute(e, "" + l);
      }
  }
  function Kl(t, e, l) {
    if (l === null) t.removeAttribute(e);
    else {
      switch (typeof l) {
        case "undefined":
        case "function":
        case "symbol":
        case "boolean":
          t.removeAttribute(e);
          return;
      }
      t.setAttribute(e, "" + l);
    }
  }
  function Pe(t, e, l, a) {
    if (a === null) t.removeAttribute(l);
    else {
      switch (typeof a) {
        case "undefined":
        case "function":
        case "symbol":
        case "boolean":
          t.removeAttribute(l);
          return;
      }
      t.setAttributeNS(e, l, "" + a);
    }
  }
  function ve(t) {
    switch (typeof t) {
      case "bigint":
      case "boolean":
      case "number":
      case "string":
      case "undefined":
        return t;
      case "object":
        return t;
      default:
        return "";
    }
  }
  function ti(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function Da(t, e, l) {
    var a = Object.getOwnPropertyDescriptor(
      t.constructor.prototype,
      e
    );
    if (!t.hasOwnProperty(e) && typeof a < "u" && typeof a.get == "function" && typeof a.set == "function") {
      var n = a.get, u = a.set;
      return Object.defineProperty(t, e, {
        configurable: !0,
        get: function() {
          return n.call(this);
        },
        set: function(i) {
          l = "" + i, u.call(this, i);
        }
      }), Object.defineProperty(t, e, {
        enumerable: a.enumerable
      }), {
        getValue: function() {
          return l;
        },
        setValue: function(i) {
          l = "" + i;
        },
        stopTracking: function() {
          t._valueTracker = null, delete t[e];
        }
      };
    }
  }
  function Kn(t) {
    if (!t._valueTracker) {
      var e = ti(t) ? "checked" : "value";
      t._valueTracker = Da(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function ei(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = ti(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function Oa(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var Ua = /[\n"\\]/g;
  function Te(t) {
    return t.replace(
      Ua,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function pe(t, e, l, a, n, u, i, f) {
    t.name = "", i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" ? t.type = i : t.removeAttribute("type"), e != null ? i === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + ve(e)) : t.value !== "" + ve(e) && (t.value = "" + ve(e)) : i !== "submit" && i !== "reset" || t.removeAttribute("value"), e != null ? Jn(t, i, ve(e)) : l != null ? Jn(t, i, ve(l)) : a != null && t.removeAttribute("value"), n == null && u != null && (t.defaultChecked = !!u), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), f != null && typeof f != "function" && typeof f != "symbol" && typeof f != "boolean" ? t.name = "" + ve(f) : t.removeAttribute("name");
  }
  function Ca(t, e, l, a, n, u, i, f) {
    if (u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.type = u), e != null || l != null) {
      if (!(u !== "submit" && u !== "reset" || e != null)) {
        Kn(t);
        return;
      }
      l = l != null ? "" + ve(l) : "", e = e != null ? "" + ve(e) : l, f || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = f ? t.checked : !!a, t.defaultChecked = !!a, i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.name = i), Kn(t);
  }
  function Jn(t, e, l) {
    e === "number" && Oa(t.ownerDocument) === t || t.defaultValue === "" + l || (t.defaultValue = "" + l);
  }
  function Jl(t, e, l, a) {
    if (t = t.options, e) {
      e = {};
      for (var n = 0; n < l.length; n++)
        e["$" + l[n]] = !0;
      for (l = 0; l < t.length; l++)
        n = e.hasOwnProperty("$" + t[l].value), t[l].selected !== n && (t[l].selected = n), n && a && (t[l].defaultSelected = !0);
    } else {
      for (l = "" + ve(l), e = null, n = 0; n < t.length; n++) {
        if (t[n].value === l) {
          t[n].selected = !0, a && (t[n].defaultSelected = !0);
          return;
        }
        e !== null || t[n].disabled || (e = t[n]);
      }
      e !== null && (e.selected = !0);
    }
  }
  function c(t, e, l) {
    if (e != null && (e = "" + ve(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + ve(l) : "";
  }
  function o(t, e, l, a) {
    if (e == null) {
      if (a != null) {
        if (l != null) throw Error(b(92));
        if (G(a)) {
          if (1 < a.length) throw Error(b(93));
          a = a[0];
        }
        l = a;
      }
      l == null && (l = ""), e = l;
    }
    l = ve(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), Kn(t);
  }
  function y(t, e) {
    if (e) {
      var l = t.firstChild;
      if (l && l === t.lastChild && l.nodeType === 3) {
        l.nodeValue = e;
        return;
      }
    }
    t.textContent = e;
  }
  var O = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function q(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || O.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function R(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(b(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && q(t, n, a);
    } else
      for (var u in e)
        e.hasOwnProperty(u) && q(t, u, e[u]);
  }
  function N(t) {
    if (t.indexOf("-") === -1) return !1;
    switch (t) {
      case "annotation-xml":
      case "color-profile":
      case "font-face":
      case "font-face-src":
      case "font-face-uri":
      case "font-face-format":
      case "font-face-name":
      case "missing-glyph":
        return !1;
      default:
        return !0;
    }
  }
  var rt = /* @__PURE__ */ new Map([
    ["acceptCharset", "accept-charset"],
    ["htmlFor", "for"],
    ["httpEquiv", "http-equiv"],
    ["crossOrigin", "crossorigin"],
    ["accentHeight", "accent-height"],
    ["alignmentBaseline", "alignment-baseline"],
    ["arabicForm", "arabic-form"],
    ["baselineShift", "baseline-shift"],
    ["capHeight", "cap-height"],
    ["clipPath", "clip-path"],
    ["clipRule", "clip-rule"],
    ["colorInterpolation", "color-interpolation"],
    ["colorInterpolationFilters", "color-interpolation-filters"],
    ["colorProfile", "color-profile"],
    ["colorRendering", "color-rendering"],
    ["dominantBaseline", "dominant-baseline"],
    ["enableBackground", "enable-background"],
    ["fillOpacity", "fill-opacity"],
    ["fillRule", "fill-rule"],
    ["floodColor", "flood-color"],
    ["floodOpacity", "flood-opacity"],
    ["fontFamily", "font-family"],
    ["fontSize", "font-size"],
    ["fontSizeAdjust", "font-size-adjust"],
    ["fontStretch", "font-stretch"],
    ["fontStyle", "font-style"],
    ["fontVariant", "font-variant"],
    ["fontWeight", "font-weight"],
    ["glyphName", "glyph-name"],
    ["glyphOrientationHorizontal", "glyph-orientation-horizontal"],
    ["glyphOrientationVertical", "glyph-orientation-vertical"],
    ["horizAdvX", "horiz-adv-x"],
    ["horizOriginX", "horiz-origin-x"],
    ["imageRendering", "image-rendering"],
    ["letterSpacing", "letter-spacing"],
    ["lightingColor", "lighting-color"],
    ["markerEnd", "marker-end"],
    ["markerMid", "marker-mid"],
    ["markerStart", "marker-start"],
    ["overlinePosition", "overline-position"],
    ["overlineThickness", "overline-thickness"],
    ["paintOrder", "paint-order"],
    ["panose-1", "panose-1"],
    ["pointerEvents", "pointer-events"],
    ["renderingIntent", "rendering-intent"],
    ["shapeRendering", "shape-rendering"],
    ["stopColor", "stop-color"],
    ["stopOpacity", "stop-opacity"],
    ["strikethroughPosition", "strikethrough-position"],
    ["strikethroughThickness", "strikethrough-thickness"],
    ["strokeDasharray", "stroke-dasharray"],
    ["strokeDashoffset", "stroke-dashoffset"],
    ["strokeLinecap", "stroke-linecap"],
    ["strokeLinejoin", "stroke-linejoin"],
    ["strokeMiterlimit", "stroke-miterlimit"],
    ["strokeOpacity", "stroke-opacity"],
    ["strokeWidth", "stroke-width"],
    ["textAnchor", "text-anchor"],
    ["textDecoration", "text-decoration"],
    ["textRendering", "text-rendering"],
    ["transformOrigin", "transform-origin"],
    ["underlinePosition", "underline-position"],
    ["underlineThickness", "underline-thickness"],
    ["unicodeBidi", "unicode-bidi"],
    ["unicodeRange", "unicode-range"],
    ["unitsPerEm", "units-per-em"],
    ["vAlphabetic", "v-alphabetic"],
    ["vHanging", "v-hanging"],
    ["vIdeographic", "v-ideographic"],
    ["vMathematical", "v-mathematical"],
    ["vectorEffect", "vector-effect"],
    ["vertAdvY", "vert-adv-y"],
    ["vertOriginX", "vert-origin-x"],
    ["vertOriginY", "vert-origin-y"],
    ["wordSpacing", "word-spacing"],
    ["writingMode", "writing-mode"],
    ["xmlnsXlink", "xmlns:xlink"],
    ["xHeight", "x-height"]
  ]), At = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function ot(t) {
    return At.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function de() {
  }
  var kn = null;
  function Fn(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var kl = null, zl = null;
  function li(t) {
    var e = fl(t);
    if (e && (t = e.stateNode)) {
      var l = t[re] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if (pe(
            t,
            l.value,
            l.defaultValue,
            l.defaultValue,
            l.checked,
            l.defaultChecked,
            l.type,
            l.name
          ), e = l.name, l.type === "radio" && e != null) {
            for (l = t; l.parentNode; ) l = l.parentNode;
            for (l = l.querySelectorAll(
              'input[name="' + Te(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[re] || null;
                if (!n) throw Error(b(90));
                pe(
                  a,
                  n.value,
                  n.defaultValue,
                  n.defaultValue,
                  n.checked,
                  n.defaultChecked,
                  n.type,
                  n.name
                );
              }
            }
            for (e = 0; e < l.length; e++)
              a = l[e], a.form === t.form && ei(a);
          }
          break t;
        case "textarea":
          c(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && Jl(t, !!l.multiple, e, !1);
      }
    }
  }
  var an = !1;
  function ai(t, e, l) {
    if (an) return t(e, l);
    an = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (an = !1, (kl !== null || zl !== null) && (Xi(), kl && (e = kl, t = zl, zl = kl = null, li(e), t)))
        for (e = 0; e < t.length; e++) li(t[e]);
    }
  }
  function Ml(t, e) {
    var l = t.stateNode;
    if (l === null) return null;
    var a = l[re] || null;
    if (a === null) return null;
    l = a[e];
    t: switch (e) {
      case "onClick":
      case "onClickCapture":
      case "onDoubleClick":
      case "onDoubleClickCapture":
      case "onMouseDown":
      case "onMouseDownCapture":
      case "onMouseMove":
      case "onMouseMoveCapture":
      case "onMouseUp":
      case "onMouseUpCapture":
      case "onMouseEnter":
        (a = !a.disabled) || (t = t.type, a = !(t === "button" || t === "input" || t === "select" || t === "textarea")), t = !a;
        break t;
      default:
        t = !1;
    }
    if (t) return null;
    if (l && typeof l != "function")
      throw Error(
        b(231, e, typeof l)
      );
    return l;
  }
  var Ue = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), Wn = !1;
  if (Ue)
    try {
      var Fl = {};
      Object.defineProperty(Fl, "passive", {
        get: function() {
          Wn = !0;
        }
      }), window.addEventListener("test", Fl, Fl), window.removeEventListener("test", Fl, Fl);
    } catch {
      Wn = !1;
    }
  var Qe = null, Ba = null, ol = null;
  function $n() {
    if (ol) return ol;
    var t, e = Ba, l = e.length, a, n = "value" in Qe ? Qe.value : Qe.textContent, u = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var i = l - t;
    for (a = 1; a <= i && e[l - a] === n[u - a]; a++) ;
    return ol = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function nn(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function Ra() {
    return !0;
  }
  function In() {
    return !1;
  }
  function me(t) {
    function e(l, a, n, u, i) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = u, this.target = i, this.currentTarget = null;
      for (var f in t)
        t.hasOwnProperty(f) && (l = t[f], this[f] = l ? l(u) : u[f]);
      return this.isDefaultPrevented = (u.defaultPrevented != null ? u.defaultPrevented : u.returnValue === !1) ? Ra : In, this.isPropagationStopped = In, this;
    }
    return L(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = Ra);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = Ra);
      },
      persist: function() {
      },
      isPersistent: Ra
    }), e;
  }
  var sl = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, El = me(sl), Wl = L({}, sl, { view: 0, detail: 0 }), Sf = me(Wl), Pn, un, Na, $l = L({}, Wl, {
    screenX: 0,
    screenY: 0,
    clientX: 0,
    clientY: 0,
    pageX: 0,
    pageY: 0,
    ctrlKey: 0,
    shiftKey: 0,
    altKey: 0,
    metaKey: 0,
    getModifierState: tu,
    button: 0,
    buttons: 0,
    relatedTarget: function(t) {
      return t.relatedTarget === void 0 ? t.fromElement === t.srcElement ? t.toElement : t.fromElement : t.relatedTarget;
    },
    movementX: function(t) {
      return "movementX" in t ? t.movementX : (t !== Na && (Na && t.type === "mousemove" ? (Pn = t.screenX - Na.screenX, un = t.screenY - Na.screenY) : un = Pn = 0, Na = t), Pn);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : un;
    }
  }), Al = me($l), ni = L({}, $l, { dataTransfer: 0 }), ui = me(ni), fn = L({}, Wl, { relatedTarget: 0 }), T = me(fn), U = L({}, sl, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), Z = me(U), $ = L({}, sl, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), dt = me($), mt = L({}, sl, { data: 0 }), Ht = me(mt), be = {
    Esc: "Escape",
    Spacebar: " ",
    Left: "ArrowLeft",
    Up: "ArrowUp",
    Right: "ArrowRight",
    Down: "ArrowDown",
    Del: "Delete",
    Win: "OS",
    Menu: "ContextMenu",
    Apps: "ContextMenu",
    Scroll: "ScrollLock",
    MozPrintableKey: "Unidentified"
  }, Ha = {
    8: "Backspace",
    9: "Tab",
    12: "Clear",
    13: "Enter",
    16: "Shift",
    17: "Control",
    18: "Alt",
    19: "Pause",
    20: "CapsLock",
    27: "Escape",
    32: " ",
    33: "PageUp",
    34: "PageDown",
    35: "End",
    36: "Home",
    37: "ArrowLeft",
    38: "ArrowUp",
    39: "ArrowRight",
    40: "ArrowDown",
    45: "Insert",
    46: "Delete",
    112: "F1",
    113: "F2",
    114: "F3",
    115: "F4",
    116: "F5",
    117: "F6",
    118: "F7",
    119: "F8",
    120: "F9",
    121: "F10",
    122: "F11",
    123: "F12",
    144: "NumLock",
    145: "ScrollLock",
    224: "Meta"
  }, Ce = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function ii(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = Ce[t]) ? !!e[t] : !1;
  }
  function tu() {
    return ii;
  }
  var fm = L({}, Wl, {
    key: function(t) {
      if (t.key) {
        var e = be[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = nn(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? Ha[t.keyCode] || "Unidentified" : "";
    },
    code: 0,
    location: 0,
    ctrlKey: 0,
    shiftKey: 0,
    altKey: 0,
    metaKey: 0,
    repeat: 0,
    locale: 0,
    getModifierState: tu,
    charCode: function(t) {
      return t.type === "keypress" ? nn(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? nn(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), cm = me(fm), om = L({}, $l, {
    pointerId: 0,
    width: 0,
    height: 0,
    pressure: 0,
    tangentialPressure: 0,
    tiltX: 0,
    tiltY: 0,
    twist: 0,
    pointerType: 0,
    isPrimary: 0
  }), zo = me(om), sm = L({}, Wl, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: tu
  }), rm = me(sm), dm = L({}, sl, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), mm = me(dm), hm = L({}, $l, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), ym = me(hm), gm = L({}, sl, {
    newState: 0,
    oldState: 0
  }), vm = me(gm), pm = [9, 13, 27, 32], xf = Ue && "CompositionEvent" in window, eu = null;
  Ue && "documentMode" in document && (eu = document.documentMode);
  var bm = Ue && "TextEvent" in window && !eu, Mo = Ue && (!xf || eu && 8 < eu && 11 >= eu), Eo = " ", Ao = !1;
  function _o(t, e) {
    switch (t) {
      case "keyup":
        return pm.indexOf(e.keyCode) !== -1;
      case "keydown":
        return e.keyCode !== 229;
      case "keypress":
      case "mousedown":
      case "focusout":
        return !0;
      default:
        return !1;
    }
  }
  function Do(t) {
    return t = t.detail, typeof t == "object" && "data" in t ? t.data : null;
  }
  var cn = !1;
  function Sm(t, e) {
    switch (t) {
      case "compositionend":
        return Do(e);
      case "keypress":
        return e.which !== 32 ? null : (Ao = !0, Eo);
      case "textInput":
        return t = e.data, t === Eo && Ao ? null : t;
      default:
        return null;
    }
  }
  function xm(t, e) {
    if (cn)
      return t === "compositionend" || !xf && _o(t, e) ? (t = $n(), ol = Ba = Qe = null, cn = !1, t) : null;
    switch (t) {
      case "paste":
        return null;
      case "keypress":
        if (!(e.ctrlKey || e.altKey || e.metaKey) || e.ctrlKey && e.altKey) {
          if (e.char && 1 < e.char.length)
            return e.char;
          if (e.which) return String.fromCharCode(e.which);
        }
        return null;
      case "compositionend":
        return Mo && e.locale !== "ko" ? null : e.data;
      default:
        return null;
    }
  }
  var Tm = {
    color: !0,
    date: !0,
    datetime: !0,
    "datetime-local": !0,
    email: !0,
    month: !0,
    number: !0,
    password: !0,
    range: !0,
    search: !0,
    tel: !0,
    text: !0,
    time: !0,
    url: !0,
    week: !0
  };
  function Oo(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e === "input" ? !!Tm[t.type] : e === "textarea";
  }
  function Uo(t, e, l, a) {
    kl ? zl ? zl.push(a) : zl = [a] : kl = a, e = Fi(e, "onChange"), 0 < e.length && (l = new El(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var lu = null, au = null;
  function zm(t) {
    dd(t, 0);
  }
  function fi(t) {
    var e = Tl(t);
    if (ei(e)) return t;
  }
  function Co(t, e) {
    if (t === "change") return e;
  }
  var Bo = !1;
  if (Ue) {
    var Tf;
    if (Ue) {
      var zf = "oninput" in document;
      if (!zf) {
        var Ro = document.createElement("div");
        Ro.setAttribute("oninput", "return;"), zf = typeof Ro.oninput == "function";
      }
      Tf = zf;
    } else Tf = !1;
    Bo = Tf && (!document.documentMode || 9 < document.documentMode);
  }
  function No() {
    lu && (lu.detachEvent("onpropertychange", Ho), au = lu = null);
  }
  function Ho(t) {
    if (t.propertyName === "value" && fi(au)) {
      var e = [];
      Uo(
        e,
        au,
        t,
        Fn(t)
      ), ai(zm, e);
    }
  }
  function Mm(t, e, l) {
    t === "focusin" ? (No(), lu = e, au = l, lu.attachEvent("onpropertychange", Ho)) : t === "focusout" && No();
  }
  function Em(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return fi(au);
  }
  function Am(t, e) {
    if (t === "click") return fi(e);
  }
  function _m(t, e) {
    if (t === "input" || t === "change")
      return fi(e);
  }
  function Dm(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var Be = typeof Object.is == "function" ? Object.is : Dm;
  function nu(t, e) {
    if (Be(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!Yn.call(e, n) || !Be(t[n], e[n]))
        return !1;
    }
    return !0;
  }
  function qo(t) {
    for (; t && t.firstChild; ) t = t.firstChild;
    return t;
  }
  function jo(t, e) {
    var l = qo(t);
    t = 0;
    for (var a; l; ) {
      if (l.nodeType === 3) {
        if (a = t + l.textContent.length, t <= e && a >= e)
          return { node: l, offset: e - t };
        t = a;
      }
      t: {
        for (; l; ) {
          if (l.nextSibling) {
            l = l.nextSibling;
            break t;
          }
          l = l.parentNode;
        }
        l = void 0;
      }
      l = qo(l);
    }
  }
  function wo(t, e) {
    return t && e ? t === e ? !0 : t && t.nodeType === 3 ? !1 : e && e.nodeType === 3 ? wo(t, e.parentNode) : "contains" in t ? t.contains(e) : t.compareDocumentPosition ? !!(t.compareDocumentPosition(e) & 16) : !1 : !1;
  }
  function Yo(t) {
    t = t != null && t.ownerDocument != null && t.ownerDocument.defaultView != null ? t.ownerDocument.defaultView : window;
    for (var e = Oa(t.document); e instanceof t.HTMLIFrameElement; ) {
      try {
        var l = typeof e.contentWindow.location.href == "string";
      } catch {
        l = !1;
      }
      if (l) t = e.contentWindow;
      else break;
      e = Oa(t.document);
    }
    return e;
  }
  function Mf(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var Om = Ue && "documentMode" in document && 11 >= document.documentMode, on = null, Ef = null, uu = null, Af = !1;
  function Go(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Af || on == null || on !== Oa(a) || (a = on, "selectionStart" in a && Mf(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), uu && nu(uu, a) || (uu = a, a = Fi(Ef, "onSelect"), 0 < a.length && (e = new El(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = on)));
  }
  function qa(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var sn = {
    animationend: qa("Animation", "AnimationEnd"),
    animationiteration: qa("Animation", "AnimationIteration"),
    animationstart: qa("Animation", "AnimationStart"),
    transitionrun: qa("Transition", "TransitionRun"),
    transitionstart: qa("Transition", "TransitionStart"),
    transitioncancel: qa("Transition", "TransitionCancel"),
    transitionend: qa("Transition", "TransitionEnd")
  }, _f = {}, Lo = {};
  Ue && (Lo = document.createElement("div").style, "AnimationEvent" in window || (delete sn.animationend.animation, delete sn.animationiteration.animation, delete sn.animationstart.animation), "TransitionEvent" in window || delete sn.transitionend.transition);
  function ja(t) {
    if (_f[t]) return _f[t];
    if (!sn[t]) return t;
    var e = sn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Lo)
        return _f[t] = e[l];
    return t;
  }
  var Xo = ja("animationend"), Qo = ja("animationiteration"), Vo = ja("animationstart"), Um = ja("transitionrun"), Cm = ja("transitionstart"), Bm = ja("transitioncancel"), Zo = ja("transitionend"), Ko = /* @__PURE__ */ new Map(), Df = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Df.push("scrollEnd");
  function tl(t, e) {
    Ko.set(t, e), cl(e, [t]);
  }
  var ci = typeof reportError == "function" ? reportError : function(t) {
    if (typeof window == "object" && typeof window.ErrorEvent == "function") {
      var e = new window.ErrorEvent("error", {
        bubbles: !0,
        cancelable: !0,
        message: typeof t == "object" && t !== null && typeof t.message == "string" ? String(t.message) : String(t),
        error: t
      });
      if (!window.dispatchEvent(e)) return;
    } else if (typeof process == "object" && typeof process.emit == "function") {
      process.emit("uncaughtException", t);
      return;
    }
    console.error(t);
  }, Ve = [], rn = 0, Of = 0;
  function oi() {
    for (var t = rn, e = Of = rn = 0; e < t; ) {
      var l = Ve[e];
      Ve[e++] = null;
      var a = Ve[e];
      Ve[e++] = null;
      var n = Ve[e];
      Ve[e++] = null;
      var u = Ve[e];
      if (Ve[e++] = null, a !== null && n !== null) {
        var i = a.pending;
        i === null ? n.next = n : (n.next = i.next, i.next = n), a.pending = n;
      }
      u !== 0 && Jo(l, n, u);
    }
  }
  function si(t, e, l, a) {
    Ve[rn++] = t, Ve[rn++] = e, Ve[rn++] = l, Ve[rn++] = a, Of |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Uf(t, e, l, a) {
    return si(t, e, l, a), ri(t);
  }
  function wa(t, e) {
    return si(t, null, null, e), ri(t);
  }
  function Jo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, u = t.return; u !== null; )
      u.childLanes |= l, a = u.alternate, a !== null && (a.childLanes |= l), u.tag === 22 && (t = u.stateNode, t === null || t._visibility & 1 || (n = !0)), t = u, u = u.return;
    return t.tag === 3 ? (u = t.stateNode, n && e !== null && (n = 31 - ge(l), t = u.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), u) : null;
  }
  function ri(t) {
    if (50 < _u)
      throw _u = 0, Yc = null, Error(b(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var dn = {};
  function Rm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function Re(t, e, l, a) {
    return new Rm(t, e, l, a);
  }
  function Cf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function _l(t, e) {
    var l = t.alternate;
    return l === null ? (l = Re(
      t.tag,
      e,
      t.key,
      t.mode
    ), l.elementType = t.elementType, l.type = t.type, l.stateNode = t.stateNode, l.alternate = t, t.alternate = l) : (l.pendingProps = e, l.type = t.type, l.flags = 0, l.subtreeFlags = 0, l.deletions = null), l.flags = t.flags & 65011712, l.childLanes = t.childLanes, l.lanes = t.lanes, l.child = t.child, l.memoizedProps = t.memoizedProps, l.memoizedState = t.memoizedState, l.updateQueue = t.updateQueue, e = t.dependencies, l.dependencies = e === null ? null : { lanes: e.lanes, firstContext: e.firstContext }, l.sibling = t.sibling, l.index = t.index, l.ref = t.ref, l.refCleanup = t.refCleanup, l;
  }
  function ko(t, e) {
    t.flags &= 65011714;
    var l = t.alternate;
    return l === null ? (t.childLanes = 0, t.lanes = e, t.child = null, t.subtreeFlags = 0, t.memoizedProps = null, t.memoizedState = null, t.updateQueue = null, t.dependencies = null, t.stateNode = null) : (t.childLanes = l.childLanes, t.lanes = l.lanes, t.child = l.child, t.subtreeFlags = 0, t.deletions = null, t.memoizedProps = l.memoizedProps, t.memoizedState = l.memoizedState, t.updateQueue = l.updateQueue, t.type = l.type, e = l.dependencies, t.dependencies = e === null ? null : {
      lanes: e.lanes,
      firstContext: e.firstContext
    }), t;
  }
  function di(t, e, l, a, n, u) {
    var i = 0;
    if (a = t, typeof t == "function") Cf(t) && (i = 1);
    else if (typeof t == "string")
      i = wh(
        t,
        l,
        H.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case De:
          return t = Re(31, l, e, n), t.elementType = De, t.lanes = u, t;
        case te:
          return Ya(l.children, n, u, e);
        case Ye:
          i = 8, n |= 24;
          break;
        case vt:
          return t = Re(12, l, e, n | 2), t.elementType = vt, t.lanes = u, t;
        case ce:
          return t = Re(13, l, e, n), t.elementType = ce, t.lanes = u, t;
        case Nt:
          return t = Re(19, l, e, n), t.elementType = Nt, t.lanes = u, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case Rt:
                i = 10;
                break t;
              case Ge:
                i = 9;
                break t;
              case Ft:
                i = 11;
                break t;
              case et:
                i = 14;
                break t;
              case Ut:
                i = 16, a = null;
                break t;
            }
          i = 29, l = Error(
            b(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = Re(i, l, e, n), e.elementType = t, e.type = a, e.lanes = u, e;
  }
  function Ya(t, e, l, a) {
    return t = Re(7, t, a, e), t.lanes = l, t;
  }
  function Bf(t, e, l) {
    return t = Re(6, t, null, e), t.lanes = l, t;
  }
  function Fo(t) {
    var e = Re(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function Rf(t, e, l) {
    return e = Re(
      4,
      t.children !== null ? t.children : [],
      t.key,
      e
    ), e.lanes = l, e.stateNode = {
      containerInfo: t.containerInfo,
      pendingChildren: null,
      implementation: t.implementation
    }, e;
  }
  var Wo = /* @__PURE__ */ new WeakMap();
  function Ze(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = Wo.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Gu(e)
      }, Wo.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Gu(e)
    };
  }
  var mn = [], hn = 0, mi = null, iu = 0, Ke = [], Je = 0, Il = null, rl = 1, dl = "";
  function Dl(t, e) {
    mn[hn++] = iu, mn[hn++] = mi, mi = t, iu = e;
  }
  function $o(t, e, l) {
    Ke[Je++] = rl, Ke[Je++] = dl, Ke[Je++] = Il, Il = t;
    var a = rl;
    t = dl;
    var n = 32 - ge(a) - 1;
    a &= ~(1 << n), l += 1;
    var u = 32 - ge(e) + n;
    if (30 < u) {
      var i = n - n % 5;
      u = (a & (1 << i) - 1).toString(32), a >>= i, n -= i, rl = 1 << 32 - ge(e) + n | l << n | a, dl = u + t;
    } else
      rl = 1 << u | l << n | a, dl = t;
  }
  function Nf(t) {
    t.return !== null && (Dl(t, 1), $o(t, 1, 0));
  }
  function Hf(t) {
    for (; t === mi; )
      mi = mn[--hn], mn[hn] = null, iu = mn[--hn], mn[hn] = null;
    for (; t === Il; )
      Il = Ke[--Je], Ke[Je] = null, dl = Ke[--Je], Ke[Je] = null, rl = Ke[--Je], Ke[Je] = null;
  }
  function Io(t, e) {
    Ke[Je++] = rl, Ke[Je++] = dl, Ke[Je++] = Il, rl = e.id, dl = e.overflow, Il = t;
  }
  var ae = null, _t = null, ft = !1, Pl = null, ke = !1, qf = Error(b(519));
  function ta(t) {
    var e = Error(
      b(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw fu(Ze(e, t)), qf;
  }
  function Po(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[Qt] = t, e[re] = a, l) {
      case "dialog":
        nt("cancel", e), nt("close", e);
        break;
      case "iframe":
      case "object":
      case "embed":
        nt("load", e);
        break;
      case "video":
      case "audio":
        for (l = 0; l < Ou.length; l++)
          nt(Ou[l], e);
        break;
      case "source":
        nt("error", e);
        break;
      case "img":
      case "image":
      case "link":
        nt("error", e), nt("load", e);
        break;
      case "details":
        nt("toggle", e);
        break;
      case "input":
        nt("invalid", e), Ca(
          e,
          a.value,
          a.defaultValue,
          a.checked,
          a.defaultChecked,
          a.type,
          a.name,
          !0
        );
        break;
      case "select":
        nt("invalid", e);
        break;
      case "textarea":
        nt("invalid", e), o(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || gd(e.textContent, l) ? (a.popover != null && (nt("beforetoggle", e), nt("toggle", e)), a.onScroll != null && nt("scroll", e), a.onScrollEnd != null && nt("scrollend", e), a.onClick != null && (e.onclick = de), e = !0) : e = !1, e || ta(t, !0);
  }
  function ts(t) {
    for (ae = t.return; ae; )
      switch (ae.tag) {
        case 5:
        case 31:
        case 13:
          ke = !1;
          return;
        case 27:
        case 3:
          ke = !0;
          return;
        default:
          ae = ae.return;
      }
  }
  function yn(t) {
    if (t !== ae) return !1;
    if (!ft) return ts(t), ft = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || to(t.type, t.memoizedProps)), l = !l), l && _t && ta(t), ts(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(b(317));
      _t = Ed(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(b(317));
      _t = Ed(t);
    } else
      e === 27 ? (e = _t, ha(t.type) ? (t = uo, uo = null, _t = t) : _t = e) : _t = ae ? We(t.stateNode.nextSibling) : null;
    return !0;
  }
  function Ga() {
    _t = ae = null, ft = !1;
  }
  function jf() {
    var t = Pl;
    return t !== null && (Ae === null ? Ae = t : Ae.push.apply(
      Ae,
      t
    ), Pl = null), t;
  }
  function fu(t) {
    Pl === null ? Pl = [t] : Pl.push(t);
  }
  var wf = r(null), La = null, Ol = null;
  function ea(t, e, l) {
    B(wf, e._currentValue), e._currentValue = l;
  }
  function Ul(t) {
    t._currentValue = wf.current, M(wf);
  }
  function Yf(t, e, l) {
    for (; t !== null; ) {
      var a = t.alternate;
      if ((t.childLanes & e) !== e ? (t.childLanes |= e, a !== null && (a.childLanes |= e)) : a !== null && (a.childLanes & e) !== e && (a.childLanes |= e), t === l) break;
      t = t.return;
    }
  }
  function Gf(t, e, l, a) {
    var n = t.child;
    for (n !== null && (n.return = t); n !== null; ) {
      var u = n.dependencies;
      if (u !== null) {
        var i = n.child;
        u = u.firstContext;
        t: for (; u !== null; ) {
          var f = u;
          u = n;
          for (var s = 0; s < e.length; s++)
            if (f.context === e[s]) {
              u.lanes |= l, f = u.alternate, f !== null && (f.lanes |= l), Yf(
                u.return,
                l,
                t
              ), a || (i = null);
              break t;
            }
          u = f.next;
        }
      } else if (n.tag === 18) {
        if (i = n.return, i === null) throw Error(b(341));
        i.lanes |= l, u = i.alternate, u !== null && (u.lanes |= l), Yf(i, l, t), i = null;
      } else i = n.child;
      if (i !== null) i.return = n;
      else
        for (i = n; i !== null; ) {
          if (i === t) {
            i = null;
            break;
          }
          if (n = i.sibling, n !== null) {
            n.return = i.return, i = n;
            break;
          }
          i = i.return;
        }
      n = i;
    }
  }
  function gn(t, e, l, a) {
    t = null;
    for (var n = e, u = !1; n !== null; ) {
      if (!u) {
        if ((n.flags & 524288) !== 0) u = !0;
        else if ((n.flags & 262144) !== 0) break;
      }
      if (n.tag === 10) {
        var i = n.alternate;
        if (i === null) throw Error(b(387));
        if (i = i.memoizedProps, i !== null) {
          var f = n.type;
          Be(n.pendingProps.value, i.value) || (t !== null ? t.push(f) : t = [f]);
        }
      } else if (n === ct.current) {
        if (i = n.alternate, i === null) throw Error(b(387));
        i.memoizedState.memoizedState !== n.memoizedState.memoizedState && (t !== null ? t.push(Nu) : t = [Nu]);
      }
      n = n.return;
    }
    t !== null && Gf(
      e,
      t,
      l,
      a
    ), e.flags |= 262144;
  }
  function hi(t) {
    for (t = t.firstContext; t !== null; ) {
      if (!Be(
        t.context._currentValue,
        t.memoizedValue
      ))
        return !0;
      t = t.next;
    }
    return !1;
  }
  function Xa(t) {
    La = t, Ol = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function ne(t) {
    return es(La, t);
  }
  function yi(t, e) {
    return La === null && Xa(t), es(t, e);
  }
  function es(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Ol === null) {
      if (t === null) throw Error(b(308));
      Ol = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else Ol = Ol.next = e;
    return l;
  }
  var Nm = typeof AbortController < "u" ? AbortController : function() {
    var t = [], e = this.signal = {
      aborted: !1,
      addEventListener: function(l, a) {
        t.push(a);
      }
    };
    this.abort = function() {
      e.aborted = !0, t.forEach(function(l) {
        return l();
      });
    };
  }, Hm = A.unstable_scheduleCallback, qm = A.unstable_NormalPriority, Vt = {
    $$typeof: Rt,
    Consumer: null,
    Provider: null,
    _currentValue: null,
    _currentValue2: null,
    _threadCount: 0
  };
  function Lf() {
    return {
      controller: new Nm(),
      data: /* @__PURE__ */ new Map(),
      refCount: 0
    };
  }
  function cu(t) {
    t.refCount--, t.refCount === 0 && Hm(qm, function() {
      t.controller.abort();
    });
  }
  var ou = null, Xf = 0, vn = 0, pn = null;
  function jm(t, e) {
    if (ou === null) {
      var l = ou = [];
      Xf = 0, vn = Zc(), pn = {
        status: "pending",
        value: void 0,
        then: function(a) {
          l.push(a);
        }
      };
    }
    return Xf++, e.then(ls, ls), e;
  }
  function ls() {
    if (--Xf === 0 && ou !== null) {
      pn !== null && (pn.status = "fulfilled");
      var t = ou;
      ou = null, vn = 0, pn = null;
      for (var e = 0; e < t.length; e++) (0, t[e])();
    }
  }
  function wm(t, e) {
    var l = [], a = {
      status: "pending",
      value: null,
      reason: null,
      then: function(n) {
        l.push(n);
      }
    };
    return t.then(
      function() {
        a.status = "fulfilled", a.value = e;
        for (var n = 0; n < l.length; n++) (0, l[n])(e);
      },
      function(n) {
        for (a.status = "rejected", a.reason = n, n = 0; n < l.length; n++)
          (0, l[n])(void 0);
      }
    ), a;
  }
  var as = m.S;
  m.S = function(t, e) {
    Gr = le(), typeof e == "object" && e !== null && typeof e.then == "function" && jm(t, e), as !== null && as(t, e);
  };
  var Qa = r(null);
  function Qf() {
    var t = Qa.current;
    return t !== null ? t : Mt.pooledCache;
  }
  function gi(t, e) {
    e === null ? B(Qa, Qa.current) : B(Qa, e.pool);
  }
  function ns() {
    var t = Qf();
    return t === null ? null : { parent: Vt._currentValue, pool: t };
  }
  var bn = Error(b(460)), Vf = Error(b(474)), vi = Error(b(542)), pi = { then: function() {
  } };
  function us(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function is(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(de, de), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, cs(t), t;
      default:
        if (typeof e.status == "string") e.then(de, de);
        else {
          if (t = Mt, t !== null && 100 < t.shellSuspendCounter)
            throw Error(b(482));
          t = e, t.status = "pending", t.then(
            function(a) {
              if (e.status === "pending") {
                var n = e;
                n.status = "fulfilled", n.value = a;
              }
            },
            function(a) {
              if (e.status === "pending") {
                var n = e;
                n.status = "rejected", n.reason = a;
              }
            }
          );
        }
        switch (e.status) {
          case "fulfilled":
            return e.value;
          case "rejected":
            throw t = e.reason, cs(t), t;
        }
        throw Za = e, bn;
    }
  }
  function Va(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (Za = l, bn) : l;
    }
  }
  var Za = null;
  function fs() {
    if (Za === null) throw Error(b(459));
    var t = Za;
    return Za = null, t;
  }
  function cs(t) {
    if (t === bn || t === vi)
      throw Error(b(483));
  }
  var Sn = null, su = 0;
  function bi(t) {
    var e = su;
    return su += 1, Sn === null && (Sn = []), is(Sn, t, e);
  }
  function ru(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function Si(t, e) {
    throw e.$$typeof === Et ? Error(b(525)) : (t = Object.prototype.toString.call(e), Error(
      b(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function os(t) {
    function e(h, d) {
      if (t) {
        var g = h.deletions;
        g === null ? (h.deletions = [d], h.flags |= 16) : g.push(d);
      }
    }
    function l(h, d) {
      if (!t) return null;
      for (; d !== null; )
        e(h, d), d = d.sibling;
      return null;
    }
    function a(h) {
      for (var d = /* @__PURE__ */ new Map(); h !== null; )
        h.key !== null ? d.set(h.key, h) : d.set(h.index, h), h = h.sibling;
      return d;
    }
    function n(h, d) {
      return h = _l(h, d), h.index = 0, h.sibling = null, h;
    }
    function u(h, d, g) {
      return h.index = g, t ? (g = h.alternate, g !== null ? (g = g.index, g < d ? (h.flags |= 67108866, d) : g) : (h.flags |= 67108866, d)) : (h.flags |= 1048576, d);
    }
    function i(h) {
      return t && h.alternate === null && (h.flags |= 67108866), h;
    }
    function f(h, d, g, z) {
      return d === null || d.tag !== 6 ? (d = Bf(g, h.mode, z), d.return = h, d) : (d = n(d, g), d.return = h, d);
    }
    function s(h, d, g, z) {
      var X = g.type;
      return X === te ? x(
        h,
        d,
        g.props.children,
        z,
        g.key
      ) : d !== null && (d.elementType === X || typeof X == "object" && X !== null && X.$$typeof === Ut && Va(X) === d.type) ? (d = n(d, g.props), ru(d, g), d.return = h, d) : (d = di(
        g.type,
        g.key,
        g.props,
        null,
        h.mode,
        z
      ), ru(d, g), d.return = h, d);
    }
    function v(h, d, g, z) {
      return d === null || d.tag !== 4 || d.stateNode.containerInfo !== g.containerInfo || d.stateNode.implementation !== g.implementation ? (d = Rf(g, h.mode, z), d.return = h, d) : (d = n(d, g.children || []), d.return = h, d);
    }
    function x(h, d, g, z, X) {
      return d === null || d.tag !== 7 ? (d = Ya(
        g,
        h.mode,
        z,
        X
      ), d.return = h, d) : (d = n(d, g), d.return = h, d);
    }
    function E(h, d, g) {
      if (typeof d == "string" && d !== "" || typeof d == "number" || typeof d == "bigint")
        return d = Bf(
          "" + d,
          h.mode,
          g
        ), d.return = h, d;
      if (typeof d == "object" && d !== null) {
        switch (d.$$typeof) {
          case Xt:
            return g = di(
              d.type,
              d.key,
              d.props,
              null,
              h.mode,
              g
            ), ru(g, d), g.return = h, g;
          case fe:
            return d = Rf(
              d,
              h.mode,
              g
            ), d.return = h, d;
          case Ut:
            return d = Va(d), E(h, d, g);
        }
        if (G(d) || ee(d))
          return d = Ya(
            d,
            h.mode,
            g,
            null
          ), d.return = h, d;
        if (typeof d.then == "function")
          return E(h, bi(d), g);
        if (d.$$typeof === Rt)
          return E(
            h,
            yi(h, d),
            g
          );
        Si(h, d);
      }
      return null;
    }
    function p(h, d, g, z) {
      var X = d !== null ? d.key : null;
      if (typeof g == "string" && g !== "" || typeof g == "number" || typeof g == "bigint")
        return X !== null ? null : f(h, d, "" + g, z);
      if (typeof g == "object" && g !== null) {
        switch (g.$$typeof) {
          case Xt:
            return g.key === X ? s(h, d, g, z) : null;
          case fe:
            return g.key === X ? v(h, d, g, z) : null;
          case Ut:
            return g = Va(g), p(h, d, g, z);
        }
        if (G(g) || ee(g))
          return X !== null ? null : x(h, d, g, z, null);
        if (typeof g.then == "function")
          return p(
            h,
            d,
            bi(g),
            z
          );
        if (g.$$typeof === Rt)
          return p(
            h,
            d,
            yi(h, g),
            z
          );
        Si(h, g);
      }
      return null;
    }
    function S(h, d, g, z, X) {
      if (typeof z == "string" && z !== "" || typeof z == "number" || typeof z == "bigint")
        return h = h.get(g) || null, f(d, h, "" + z, X);
      if (typeof z == "object" && z !== null) {
        switch (z.$$typeof) {
          case Xt:
            return h = h.get(
              z.key === null ? g : z.key
            ) || null, s(d, h, z, X);
          case fe:
            return h = h.get(
              z.key === null ? g : z.key
            ) || null, v(d, h, z, X);
          case Ut:
            return z = Va(z), S(
              h,
              d,
              g,
              z,
              X
            );
        }
        if (G(z) || ee(z))
          return h = h.get(g) || null, x(d, h, z, X, null);
        if (typeof z.then == "function")
          return S(
            h,
            d,
            g,
            bi(z),
            X
          );
        if (z.$$typeof === Rt)
          return S(
            h,
            d,
            g,
            yi(d, z),
            X
          );
        Si(d, z);
      }
      return null;
    }
    function j(h, d, g, z) {
      for (var X = null, ht = null, w = d, P = d = 0, it = null; w !== null && P < g.length; P++) {
        w.index > P ? (it = w, w = null) : it = w.sibling;
        var yt = p(
          h,
          w,
          g[P],
          z
        );
        if (yt === null) {
          w === null && (w = it);
          break;
        }
        t && w && yt.alternate === null && e(h, w), d = u(yt, d, P), ht === null ? X = yt : ht.sibling = yt, ht = yt, w = it;
      }
      if (P === g.length)
        return l(h, w), ft && Dl(h, P), X;
      if (w === null) {
        for (; P < g.length; P++)
          w = E(h, g[P], z), w !== null && (d = u(
            w,
            d,
            P
          ), ht === null ? X = w : ht.sibling = w, ht = w);
        return ft && Dl(h, P), X;
      }
      for (w = a(w); P < g.length; P++)
        it = S(
          w,
          h,
          P,
          g[P],
          z
        ), it !== null && (t && it.alternate !== null && w.delete(
          it.key === null ? P : it.key
        ), d = u(
          it,
          d,
          P
        ), ht === null ? X = it : ht.sibling = it, ht = it);
      return t && w.forEach(function(ba) {
        return e(h, ba);
      }), ft && Dl(h, P), X;
    }
    function V(h, d, g, z) {
      if (g == null) throw Error(b(151));
      for (var X = null, ht = null, w = d, P = d = 0, it = null, yt = g.next(); w !== null && !yt.done; P++, yt = g.next()) {
        w.index > P ? (it = w, w = null) : it = w.sibling;
        var ba = p(h, w, yt.value, z);
        if (ba === null) {
          w === null && (w = it);
          break;
        }
        t && w && ba.alternate === null && e(h, w), d = u(ba, d, P), ht === null ? X = ba : ht.sibling = ba, ht = ba, w = it;
      }
      if (yt.done)
        return l(h, w), ft && Dl(h, P), X;
      if (w === null) {
        for (; !yt.done; P++, yt = g.next())
          yt = E(h, yt.value, z), yt !== null && (d = u(yt, d, P), ht === null ? X = yt : ht.sibling = yt, ht = yt);
        return ft && Dl(h, P), X;
      }
      for (w = a(w); !yt.done; P++, yt = g.next())
        yt = S(w, h, P, yt.value, z), yt !== null && (t && yt.alternate !== null && w.delete(yt.key === null ? P : yt.key), d = u(yt, d, P), ht === null ? X = yt : ht.sibling = yt, ht = yt);
      return t && w.forEach(function(Fh) {
        return e(h, Fh);
      }), ft && Dl(h, P), X;
    }
    function zt(h, d, g, z) {
      if (typeof g == "object" && g !== null && g.type === te && g.key === null && (g = g.props.children), typeof g == "object" && g !== null) {
        switch (g.$$typeof) {
          case Xt:
            t: {
              for (var X = g.key; d !== null; ) {
                if (d.key === X) {
                  if (X = g.type, X === te) {
                    if (d.tag === 7) {
                      l(
                        h,
                        d.sibling
                      ), z = n(
                        d,
                        g.props.children
                      ), z.return = h, h = z;
                      break t;
                    }
                  } else if (d.elementType === X || typeof X == "object" && X !== null && X.$$typeof === Ut && Va(X) === d.type) {
                    l(
                      h,
                      d.sibling
                    ), z = n(d, g.props), ru(z, g), z.return = h, h = z;
                    break t;
                  }
                  l(h, d);
                  break;
                } else e(h, d);
                d = d.sibling;
              }
              g.type === te ? (z = Ya(
                g.props.children,
                h.mode,
                z,
                g.key
              ), z.return = h, h = z) : (z = di(
                g.type,
                g.key,
                g.props,
                null,
                h.mode,
                z
              ), ru(z, g), z.return = h, h = z);
            }
            return i(h);
          case fe:
            t: {
              for (X = g.key; d !== null; ) {
                if (d.key === X)
                  if (d.tag === 4 && d.stateNode.containerInfo === g.containerInfo && d.stateNode.implementation === g.implementation) {
                    l(
                      h,
                      d.sibling
                    ), z = n(d, g.children || []), z.return = h, h = z;
                    break t;
                  } else {
                    l(h, d);
                    break;
                  }
                else e(h, d);
                d = d.sibling;
              }
              z = Rf(g, h.mode, z), z.return = h, h = z;
            }
            return i(h);
          case Ut:
            return g = Va(g), zt(
              h,
              d,
              g,
              z
            );
        }
        if (G(g))
          return j(
            h,
            d,
            g,
            z
          );
        if (ee(g)) {
          if (X = ee(g), typeof X != "function") throw Error(b(150));
          return g = X.call(g), V(
            h,
            d,
            g,
            z
          );
        }
        if (typeof g.then == "function")
          return zt(
            h,
            d,
            bi(g),
            z
          );
        if (g.$$typeof === Rt)
          return zt(
            h,
            d,
            yi(h, g),
            z
          );
        Si(h, g);
      }
      return typeof g == "string" && g !== "" || typeof g == "number" || typeof g == "bigint" ? (g = "" + g, d !== null && d.tag === 6 ? (l(h, d.sibling), z = n(d, g), z.return = h, h = z) : (l(h, d), z = Bf(g, h.mode, z), z.return = h, h = z), i(h)) : l(h, d);
    }
    return function(h, d, g, z) {
      try {
        su = 0;
        var X = zt(
          h,
          d,
          g,
          z
        );
        return Sn = null, X;
      } catch (w) {
        if (w === bn || w === vi) throw w;
        var ht = Re(29, w, null, h.mode);
        return ht.lanes = z, ht.return = h, ht;
      }
    };
  }
  var Ka = os(!0), ss = os(!1), la = !1;
  function Zf(t) {
    t.updateQueue = {
      baseState: t.memoizedState,
      firstBaseUpdate: null,
      lastBaseUpdate: null,
      shared: { pending: null, lanes: 0, hiddenCallbacks: null },
      callbacks: null
    };
  }
  function Kf(t, e) {
    t = t.updateQueue, e.updateQueue === t && (e.updateQueue = {
      baseState: t.baseState,
      firstBaseUpdate: t.firstBaseUpdate,
      lastBaseUpdate: t.lastBaseUpdate,
      shared: t.shared,
      callbacks: null
    });
  }
  function aa(t) {
    return { lane: t, tag: 0, payload: null, callback: null, next: null };
  }
  function na(t, e, l) {
    var a = t.updateQueue;
    if (a === null) return null;
    if (a = a.shared, (gt & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = ri(t), Jo(t, null, l), e;
    }
    return si(t, a, e, l), ri(t);
  }
  function du(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Xn(t, l);
    }
  }
  function Jf(t, e) {
    var l = t.updateQueue, a = t.alternate;
    if (a !== null && (a = a.updateQueue, l === a)) {
      var n = null, u = null;
      if (l = l.firstBaseUpdate, l !== null) {
        do {
          var i = {
            lane: l.lane,
            tag: l.tag,
            payload: l.payload,
            callback: null,
            next: null
          };
          u === null ? n = u = i : u = u.next = i, l = l.next;
        } while (l !== null);
        u === null ? n = u = e : u = u.next = e;
      } else n = u = e;
      l = {
        baseState: a.baseState,
        firstBaseUpdate: n,
        lastBaseUpdate: u,
        shared: a.shared,
        callbacks: a.callbacks
      }, t.updateQueue = l;
      return;
    }
    t = l.lastBaseUpdate, t === null ? l.firstBaseUpdate = e : t.next = e, l.lastBaseUpdate = e;
  }
  var kf = !1;
  function mu() {
    if (kf) {
      var t = pn;
      if (t !== null) throw t;
    }
  }
  function hu(t, e, l, a) {
    kf = !1;
    var n = t.updateQueue;
    la = !1;
    var u = n.firstBaseUpdate, i = n.lastBaseUpdate, f = n.shared.pending;
    if (f !== null) {
      n.shared.pending = null;
      var s = f, v = s.next;
      s.next = null, i === null ? u = v : i.next = v, i = s;
      var x = t.alternate;
      x !== null && (x = x.updateQueue, f = x.lastBaseUpdate, f !== i && (f === null ? x.firstBaseUpdate = v : f.next = v, x.lastBaseUpdate = s));
    }
    if (u !== null) {
      var E = n.baseState;
      i = 0, x = v = s = null, f = u;
      do {
        var p = f.lane & -536870913, S = p !== f.lane;
        if (S ? (ut & p) === p : (a & p) === p) {
          p !== 0 && p === vn && (kf = !0), x !== null && (x = x.next = {
            lane: 0,
            tag: f.tag,
            payload: f.payload,
            callback: null,
            next: null
          });
          t: {
            var j = t, V = f;
            p = e;
            var zt = l;
            switch (V.tag) {
              case 1:
                if (j = V.payload, typeof j == "function") {
                  E = j.call(zt, E, p);
                  break t;
                }
                E = j;
                break t;
              case 3:
                j.flags = j.flags & -65537 | 128;
              case 0:
                if (j = V.payload, p = typeof j == "function" ? j.call(zt, E, p) : j, p == null) break t;
                E = L({}, E, p);
                break t;
              case 2:
                la = !0;
            }
          }
          p = f.callback, p !== null && (t.flags |= 64, S && (t.flags |= 8192), S = n.callbacks, S === null ? n.callbacks = [p] : S.push(p));
        } else
          S = {
            lane: p,
            tag: f.tag,
            payload: f.payload,
            callback: f.callback,
            next: null
          }, x === null ? (v = x = S, s = E) : x = x.next = S, i |= p;
        if (f = f.next, f === null) {
          if (f = n.shared.pending, f === null)
            break;
          S = f, f = S.next, S.next = null, n.lastBaseUpdate = S, n.shared.pending = null;
        }
      } while (!0);
      x === null && (s = E), n.baseState = s, n.firstBaseUpdate = v, n.lastBaseUpdate = x, u === null && (n.shared.lanes = 0), oa |= i, t.lanes = i, t.memoizedState = E;
    }
  }
  function rs(t, e) {
    if (typeof t != "function")
      throw Error(b(191, t));
    t.call(e);
  }
  function ds(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        rs(l[t], e);
  }
  var xn = r(null), xi = r(0);
  function ms(t, e) {
    t = Yl, B(xi, t), B(xn, e), Yl = t | e.baseLanes;
  }
  function Ff() {
    B(xi, Yl), B(xn, xn.current);
  }
  function Wf() {
    Yl = xi.current, M(xn), M(xi);
  }
  var Ne = r(null), Fe = null;
  function ua(t) {
    var e = t.alternate;
    B(Gt, Gt.current & 1), B(Ne, t), Fe === null && (e === null || xn.current !== null || e.memoizedState !== null) && (Fe = t);
  }
  function $f(t) {
    B(Gt, Gt.current), B(Ne, t), Fe === null && (Fe = t);
  }
  function hs(t) {
    t.tag === 22 ? (B(Gt, Gt.current), B(Ne, t), Fe === null && (Fe = t)) : ia();
  }
  function ia() {
    B(Gt, Gt.current), B(Ne, Ne.current);
  }
  function He(t) {
    M(Ne), Fe === t && (Fe = null), M(Gt);
  }
  var Gt = r(0);
  function Ti(t) {
    for (var e = t; e !== null; ) {
      if (e.tag === 13) {
        var l = e.memoizedState;
        if (l !== null && (l = l.dehydrated, l === null || ao(l) || no(l)))
          return e;
      } else if (e.tag === 19 && (e.memoizedProps.revealOrder === "forwards" || e.memoizedProps.revealOrder === "backwards" || e.memoizedProps.revealOrder === "unstable_legacy-backwards" || e.memoizedProps.revealOrder === "together")) {
        if ((e.flags & 128) !== 0) return e;
      } else if (e.child !== null) {
        e.child.return = e, e = e.child;
        continue;
      }
      if (e === t) break;
      for (; e.sibling === null; ) {
        if (e.return === null || e.return === t) return null;
        e = e.return;
      }
      e.sibling.return = e.return, e = e.sibling;
    }
    return null;
  }
  var Cl = 0, I = null, xt = null, Zt = null, zi = !1, Tn = !1, Ja = !1, Mi = 0, yu = 0, zn = null, Ym = 0;
  function qt() {
    throw Error(b(321));
  }
  function If(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!Be(t[l], e[l])) return !1;
    return !0;
  }
  function Pf(t, e, l, a, n, u) {
    return Cl = u, I = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, m.H = t === null || t.memoizedState === null ? $s : hc, Ja = !1, u = l(a, n), Ja = !1, Tn && (u = gs(
      e,
      l,
      a,
      n
    )), ys(t), u;
  }
  function ys(t) {
    m.H = pu;
    var e = xt !== null && xt.next !== null;
    if (Cl = 0, Zt = xt = I = null, zi = !1, yu = 0, zn = null, e) throw Error(b(300));
    t === null || Kt || (t = t.dependencies, t !== null && hi(t) && (Kt = !0));
  }
  function gs(t, e, l, a) {
    I = t;
    var n = 0;
    do {
      if (Tn && (zn = null), yu = 0, Tn = !1, 25 <= n) throw Error(b(301));
      if (n += 1, Zt = xt = null, t.updateQueue != null) {
        var u = t.updateQueue;
        u.lastEffect = null, u.events = null, u.stores = null, u.memoCache != null && (u.memoCache.index = 0);
      }
      m.H = Is, u = e(l, a);
    } while (Tn);
    return u;
  }
  function Gm() {
    var t = m.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? gu(e) : e, t = t.useState()[0], (xt !== null ? xt.memoizedState : null) !== t && (I.flags |= 1024), e;
  }
  function tc() {
    var t = Mi !== 0;
    return Mi = 0, t;
  }
  function ec(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function lc(t) {
    if (zi) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      zi = !1;
    }
    Cl = 0, Zt = xt = I = null, Tn = !1, yu = Mi = 0, zn = null;
  }
  function Se() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return Zt === null ? I.memoizedState = Zt = t : Zt = Zt.next = t, Zt;
  }
  function Lt() {
    if (xt === null) {
      var t = I.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = xt.next;
    var e = Zt === null ? I.memoizedState : Zt.next;
    if (e !== null)
      Zt = e, xt = t;
    else {
      if (t === null)
        throw I.alternate === null ? Error(b(467)) : Error(b(310));
      xt = t, t = {
        memoizedState: xt.memoizedState,
        baseState: xt.baseState,
        baseQueue: xt.baseQueue,
        queue: xt.queue,
        next: null
      }, Zt === null ? I.memoizedState = Zt = t : Zt = Zt.next = t;
    }
    return Zt;
  }
  function Ei() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function gu(t) {
    var e = yu;
    return yu += 1, zn === null && (zn = []), t = is(zn, t, e), e = I, (Zt === null ? e.memoizedState : Zt.next) === null && (e = e.alternate, m.H = e === null || e.memoizedState === null ? $s : hc), t;
  }
  function Ai(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return gu(t);
      if (t.$$typeof === Rt) return ne(t);
    }
    throw Error(b(438, String(t)));
  }
  function ac(t) {
    var e = null, l = I.updateQueue;
    if (l !== null && (e = l.memoCache), e == null) {
      var a = I.alternate;
      a !== null && (a = a.updateQueue, a !== null && (a = a.memoCache, a != null && (e = {
        data: a.data.map(function(n) {
          return n.slice();
        }),
        index: 0
      })));
    }
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Ei(), I.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = xe;
    return e.index++, l;
  }
  function Bl(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function _i(t) {
    var e = Lt();
    return nc(e, xt, t);
  }
  function nc(t, e, l) {
    var a = t.queue;
    if (a === null) throw Error(b(311));
    a.lastRenderedReducer = l;
    var n = t.baseQueue, u = a.pending;
    if (u !== null) {
      if (n !== null) {
        var i = n.next;
        n.next = u.next, u.next = i;
      }
      e.baseQueue = n = u, a.pending = null;
    }
    if (u = t.baseState, n === null) t.memoizedState = u;
    else {
      e = n.next;
      var f = i = null, s = null, v = e, x = !1;
      do {
        var E = v.lane & -536870913;
        if (E !== v.lane ? (ut & E) === E : (Cl & E) === E) {
          var p = v.revertLane;
          if (p === 0)
            s !== null && (s = s.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: v.action,
              hasEagerState: v.hasEagerState,
              eagerState: v.eagerState,
              next: null
            }), E === vn && (x = !0);
          else if ((Cl & p) === p) {
            v = v.next, p === vn && (x = !0);
            continue;
          } else
            E = {
              lane: 0,
              revertLane: v.revertLane,
              gesture: null,
              action: v.action,
              hasEagerState: v.hasEagerState,
              eagerState: v.eagerState,
              next: null
            }, s === null ? (f = s = E, i = u) : s = s.next = E, I.lanes |= p, oa |= p;
          E = v.action, Ja && l(u, E), u = v.hasEagerState ? v.eagerState : l(u, E);
        } else
          p = {
            lane: E,
            revertLane: v.revertLane,
            gesture: v.gesture,
            action: v.action,
            hasEagerState: v.hasEagerState,
            eagerState: v.eagerState,
            next: null
          }, s === null ? (f = s = p, i = u) : s = s.next = p, I.lanes |= E, oa |= E;
        v = v.next;
      } while (v !== null && v !== e);
      if (s === null ? i = u : s.next = f, !Be(u, t.memoizedState) && (Kt = !0, x && (l = pn, l !== null)))
        throw l;
      t.memoizedState = u, t.baseState = i, t.baseQueue = s, a.lastRenderedState = u;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function uc(t) {
    var e = Lt(), l = e.queue;
    if (l === null) throw Error(b(311));
    l.lastRenderedReducer = t;
    var a = l.dispatch, n = l.pending, u = e.memoizedState;
    if (n !== null) {
      l.pending = null;
      var i = n = n.next;
      do
        u = t(u, i.action), i = i.next;
      while (i !== n);
      Be(u, e.memoizedState) || (Kt = !0), e.memoizedState = u, e.baseQueue === null && (e.baseState = u), l.lastRenderedState = u;
    }
    return [u, a];
  }
  function vs(t, e, l) {
    var a = I, n = Lt(), u = ft;
    if (u) {
      if (l === void 0) throw Error(b(407));
      l = l();
    } else l = e();
    var i = !Be(
      (xt || n).memoizedState,
      l
    );
    if (i && (n.memoizedState = l, Kt = !0), n = n.queue, cc(Ss.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || i || Zt !== null && Zt.memoizedState.tag & 1) {
      if (a.flags |= 2048, Mn(
        9,
        { destroy: void 0 },
        bs.bind(
          null,
          a,
          n,
          l,
          e
        ),
        null
      ), Mt === null) throw Error(b(349));
      u || (Cl & 127) !== 0 || ps(a, e, l);
    }
    return l;
  }
  function ps(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = I.updateQueue, e === null ? (e = Ei(), I.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
  }
  function bs(t, e, l, a) {
    e.value = l, e.getSnapshot = a, xs(e) && Ts(t);
  }
  function Ss(t, e, l) {
    return l(function() {
      xs(e) && Ts(t);
    });
  }
  function xs(t) {
    var e = t.getSnapshot;
    t = t.value;
    try {
      var l = e();
      return !Be(t, l);
    } catch {
      return !0;
    }
  }
  function Ts(t) {
    var e = wa(t, 2);
    e !== null && _e(e, t, 2);
  }
  function ic(t) {
    var e = Se();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Ja) {
        ul(!0);
        try {
          l();
        } finally {
          ul(!1);
        }
      }
    }
    return e.memoizedState = e.baseState = t, e.queue = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Bl,
      lastRenderedState: t
    }, e;
  }
  function zs(t, e, l, a) {
    return t.baseState = l, nc(
      t,
      xt,
      typeof a == "function" ? a : Bl
    );
  }
  function Lm(t, e, l, a, n) {
    if (Ui(t)) throw Error(b(485));
    if (t = e.action, t !== null) {
      var u = {
        payload: n,
        action: t,
        next: null,
        isTransition: !0,
        status: "pending",
        value: null,
        reason: null,
        listeners: [],
        then: function(i) {
          u.listeners.push(i);
        }
      };
      m.T !== null ? l(!0) : u.isTransition = !1, a(u), l = e.pending, l === null ? (u.next = e.pending = u, Ms(e, u)) : (u.next = l.next, e.pending = l.next = u);
    }
  }
  function Ms(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var u = m.T, i = {};
      m.T = i;
      try {
        var f = l(n, a), s = m.S;
        s !== null && s(i, f), Es(t, e, f);
      } catch (v) {
        fc(t, e, v);
      } finally {
        u !== null && i.types !== null && (u.types = i.types), m.T = u;
      }
    } else
      try {
        u = l(n, a), Es(t, e, u);
      } catch (v) {
        fc(t, e, v);
      }
  }
  function Es(t, e, l) {
    l !== null && typeof l == "object" && typeof l.then == "function" ? l.then(
      function(a) {
        As(t, e, a);
      },
      function(a) {
        return fc(t, e, a);
      }
    ) : As(t, e, l);
  }
  function As(t, e, l) {
    e.status = "fulfilled", e.value = l, _s(e), t.state = l, e = t.pending, e !== null && (l = e.next, l === e ? t.pending = null : (l = l.next, e.next = l, Ms(t, l)));
  }
  function fc(t, e, l) {
    var a = t.pending;
    if (t.pending = null, a !== null) {
      a = a.next;
      do
        e.status = "rejected", e.reason = l, _s(e), e = e.next;
      while (e !== a);
    }
    t.action = null;
  }
  function _s(t) {
    t = t.listeners;
    for (var e = 0; e < t.length; e++) (0, t[e])();
  }
  function Ds(t, e) {
    return e;
  }
  function Os(t, e) {
    if (ft) {
      var l = Mt.formState;
      if (l !== null) {
        t: {
          var a = I;
          if (ft) {
            if (_t) {
              e: {
                for (var n = _t, u = ke; n.nodeType !== 8; ) {
                  if (!u) {
                    n = null;
                    break e;
                  }
                  if (n = We(
                    n.nextSibling
                  ), n === null) {
                    n = null;
                    break e;
                  }
                }
                u = n.data, n = u === "F!" || u === "F" ? n : null;
              }
              if (n) {
                _t = We(
                  n.nextSibling
                ), a = n.data === "F!";
                break t;
              }
            }
            ta(a);
          }
          a = !1;
        }
        a && (e = l[0]);
      }
    }
    return l = Se(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Ds,
      lastRenderedState: e
    }, l.queue = a, l = ks.bind(
      null,
      I,
      a
    ), a.dispatch = l, a = ic(!1), u = mc.bind(
      null,
      I,
      !1,
      a.queue
    ), a = Se(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = Lm.bind(
      null,
      I,
      n,
      u,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Us(t) {
    var e = Lt();
    return Cs(e, xt, t);
  }
  function Cs(t, e, l) {
    if (e = nc(
      t,
      e,
      Ds
    )[0], t = _i(Bl)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = gu(e);
      } catch (i) {
        throw i === bn ? vi : i;
      }
    else a = e;
    e = Lt();
    var n = e.queue, u = n.dispatch;
    return l !== e.memoizedState && (I.flags |= 2048, Mn(
      9,
      { destroy: void 0 },
      Xm.bind(null, n, l),
      null
    )), [a, u, t];
  }
  function Xm(t, e) {
    t.action = e;
  }
  function Bs(t) {
    var e = Lt(), l = xt;
    if (l !== null)
      return Cs(e, l, t);
    Lt(), e = e.memoizedState, l = Lt();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function Mn(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = I.updateQueue, e === null && (e = Ei(), I.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Rs() {
    return Lt().memoizedState;
  }
  function Di(t, e, l, a) {
    var n = Se();
    I.flags |= t, n.memoizedState = Mn(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Oi(t, e, l, a) {
    var n = Lt();
    a = a === void 0 ? null : a;
    var u = n.memoizedState.inst;
    xt !== null && a !== null && If(a, xt.memoizedState.deps) ? n.memoizedState = Mn(e, u, l, a) : (I.flags |= t, n.memoizedState = Mn(
      1 | e,
      u,
      l,
      a
    ));
  }
  function Ns(t, e) {
    Di(8390656, 8, t, e);
  }
  function cc(t, e) {
    Oi(2048, 8, t, e);
  }
  function Qm(t) {
    I.flags |= 4;
    var e = I.updateQueue;
    if (e === null)
      e = Ei(), I.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function Hs(t) {
    var e = Lt().memoizedState;
    return Qm({ ref: e, nextImpl: t }), function() {
      if ((gt & 2) !== 0) throw Error(b(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function qs(t, e) {
    return Oi(4, 2, t, e);
  }
  function js(t, e) {
    return Oi(4, 4, t, e);
  }
  function ws(t, e) {
    if (typeof e == "function") {
      t = t();
      var l = e(t);
      return function() {
        typeof l == "function" ? l() : e(null);
      };
    }
    if (e != null)
      return t = t(), e.current = t, function() {
        e.current = null;
      };
  }
  function Ys(t, e, l) {
    l = l != null ? l.concat([t]) : null, Oi(4, 4, ws.bind(null, e, t), l);
  }
  function oc() {
  }
  function Gs(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && If(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Ls(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && If(e, a[1]))
      return a[0];
    if (a = t(), Ja) {
      ul(!0);
      try {
        t();
      } finally {
        ul(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function sc(t, e, l) {
    return l === void 0 || (Cl & 1073741824) !== 0 && (ut & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Xr(), I.lanes |= t, oa |= t, l);
  }
  function Xs(t, e, l, a) {
    return Be(l, e) ? l : xn.current !== null ? (t = sc(t, l, a), Be(t, e) || (Kt = !0), t) : (Cl & 42) === 0 || (Cl & 1073741824) !== 0 && (ut & 261930) === 0 ? (Kt = !0, t.memoizedState = l) : (t = Xr(), I.lanes |= t, oa |= t, e);
  }
  function Qs(t, e, l, a, n) {
    var u = D.p;
    D.p = u !== 0 && 8 > u ? u : 8;
    var i = m.T, f = {};
    m.T = f, mc(t, !1, e, l);
    try {
      var s = n(), v = m.S;
      if (v !== null && v(f, s), s !== null && typeof s == "object" && typeof s.then == "function") {
        var x = wm(
          s,
          a
        );
        vu(
          t,
          e,
          x,
          we(t)
        );
      } else
        vu(
          t,
          e,
          a,
          we(t)
        );
    } catch (E) {
      vu(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: E },
        we()
      );
    } finally {
      D.p = u, i !== null && f.types !== null && (i.types = f.types), m.T = i;
    }
  }
  function Vm() {
  }
  function rc(t, e, l, a) {
    if (t.tag !== 5) throw Error(b(476));
    var n = Vs(t).queue;
    Qs(
      t,
      n,
      e,
      Y,
      l === null ? Vm : function() {
        return Zs(t), l(a);
      }
    );
  }
  function Vs(t) {
    var e = t.memoizedState;
    if (e !== null) return e;
    e = {
      memoizedState: Y,
      baseState: Y,
      baseQueue: null,
      queue: {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: Bl,
        lastRenderedState: Y
      },
      next: null
    };
    var l = {};
    return e.next = {
      memoizedState: l,
      baseState: l,
      baseQueue: null,
      queue: {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: Bl,
        lastRenderedState: l
      },
      next: null
    }, t.memoizedState = e, t = t.alternate, t !== null && (t.memoizedState = e), e;
  }
  function Zs(t) {
    var e = Vs(t);
    e.next === null && (e = t.alternate.memoizedState), vu(
      t,
      e.next.queue,
      {},
      we()
    );
  }
  function dc() {
    return ne(Nu);
  }
  function Ks() {
    return Lt().memoizedState;
  }
  function Js() {
    return Lt().memoizedState;
  }
  function Zm(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = we();
          t = aa(l);
          var a = na(e, t, l);
          a !== null && (_e(a, e, l), du(a, e, l)), e = { cache: Lf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function Km(t, e, l) {
    var a = we();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Ui(t) ? Fs(e, l) : (l = Uf(t, e, l, a), l !== null && (_e(l, t, a), Ws(l, e, a)));
  }
  function ks(t, e, l) {
    var a = we();
    vu(t, e, l, a);
  }
  function vu(t, e, l, a) {
    var n = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    };
    if (Ui(t)) Fs(e, n);
    else {
      var u = t.alternate;
      if (t.lanes === 0 && (u === null || u.lanes === 0) && (u = e.lastRenderedReducer, u !== null))
        try {
          var i = e.lastRenderedState, f = u(i, l);
          if (n.hasEagerState = !0, n.eagerState = f, Be(f, i))
            return si(t, e, n, 0), Mt === null && oi(), !1;
        } catch {
        }
      if (l = Uf(t, e, n, a), l !== null)
        return _e(l, t, a), Ws(l, e, a), !0;
    }
    return !1;
  }
  function mc(t, e, l, a) {
    if (a = {
      lane: 2,
      revertLane: Zc(),
      gesture: null,
      action: a,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Ui(t)) {
      if (e) throw Error(b(479));
    } else
      e = Uf(
        t,
        l,
        a,
        2
      ), e !== null && _e(e, t, 2);
  }
  function Ui(t) {
    var e = t.alternate;
    return t === I || e !== null && e === I;
  }
  function Fs(t, e) {
    Tn = zi = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function Ws(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Xn(t, l);
    }
  }
  var pu = {
    readContext: ne,
    use: Ai,
    useCallback: qt,
    useContext: qt,
    useEffect: qt,
    useImperativeHandle: qt,
    useLayoutEffect: qt,
    useInsertionEffect: qt,
    useMemo: qt,
    useReducer: qt,
    useRef: qt,
    useState: qt,
    useDebugValue: qt,
    useDeferredValue: qt,
    useTransition: qt,
    useSyncExternalStore: qt,
    useId: qt,
    useHostTransitionStatus: qt,
    useFormState: qt,
    useActionState: qt,
    useOptimistic: qt,
    useMemoCache: qt,
    useCacheRefresh: qt
  };
  pu.useEffectEvent = qt;
  var $s = {
    readContext: ne,
    use: Ai,
    useCallback: function(t, e) {
      return Se().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: ne,
    useEffect: Ns,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, Di(
        4194308,
        4,
        ws.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return Di(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      Di(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = Se();
      e = e === void 0 ? null : e;
      var a = t();
      if (Ja) {
        ul(!0);
        try {
          t();
        } finally {
          ul(!1);
        }
      }
      return l.memoizedState = [a, e], a;
    },
    useReducer: function(t, e, l) {
      var a = Se();
      if (l !== void 0) {
        var n = l(e);
        if (Ja) {
          ul(!0);
          try {
            l(e);
          } finally {
            ul(!1);
          }
        }
      } else n = e;
      return a.memoizedState = a.baseState = n, t = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: t,
        lastRenderedState: n
      }, a.queue = t, t = t.dispatch = Km.bind(
        null,
        I,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = Se();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = ic(t);
      var e = t.queue, l = ks.bind(null, I, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Se();
      return sc(l, t, e);
    },
    useTransition: function() {
      var t = ic(!1);
      return t = Qs.bind(
        null,
        I,
        t.queue,
        !0,
        !1
      ), Se().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = I, n = Se();
      if (ft) {
        if (l === void 0)
          throw Error(b(407));
        l = l();
      } else {
        if (l = e(), Mt === null)
          throw Error(b(349));
        (ut & 127) !== 0 || ps(a, e, l);
      }
      n.memoizedState = l;
      var u = { value: l, getSnapshot: e };
      return n.queue = u, Ns(Ss.bind(null, a, u, t), [
        t
      ]), a.flags |= 2048, Mn(
        9,
        { destroy: void 0 },
        bs.bind(
          null,
          a,
          u,
          l,
          e
        ),
        null
      ), l;
    },
    useId: function() {
      var t = Se(), e = Mt.identifierPrefix;
      if (ft) {
        var l = dl, a = rl;
        l = (a & ~(1 << 32 - ge(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = Mi++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Ym++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: dc,
    useFormState: Os,
    useActionState: Os,
    useOptimistic: function(t) {
      var e = Se();
      e.memoizedState = e.baseState = t;
      var l = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: null,
        lastRenderedState: null
      };
      return e.queue = l, e = mc.bind(
        null,
        I,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: ac,
    useCacheRefresh: function() {
      return Se().memoizedState = Zm.bind(
        null,
        I
      );
    },
    useEffectEvent: function(t) {
      var e = Se(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((gt & 2) !== 0)
          throw Error(b(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, hc = {
    readContext: ne,
    use: Ai,
    useCallback: Gs,
    useContext: ne,
    useEffect: cc,
    useImperativeHandle: Ys,
    useInsertionEffect: qs,
    useLayoutEffect: js,
    useMemo: Ls,
    useReducer: _i,
    useRef: Rs,
    useState: function() {
      return _i(Bl);
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return Xs(
        l,
        xt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = _i(Bl)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : gu(t),
        e
      ];
    },
    useSyncExternalStore: vs,
    useId: Ks,
    useHostTransitionStatus: dc,
    useFormState: Us,
    useActionState: Us,
    useOptimistic: function(t, e) {
      var l = Lt();
      return zs(l, xt, t, e);
    },
    useMemoCache: ac,
    useCacheRefresh: Js
  };
  hc.useEffectEvent = Hs;
  var Is = {
    readContext: ne,
    use: Ai,
    useCallback: Gs,
    useContext: ne,
    useEffect: cc,
    useImperativeHandle: Ys,
    useInsertionEffect: qs,
    useLayoutEffect: js,
    useMemo: Ls,
    useReducer: uc,
    useRef: Rs,
    useState: function() {
      return uc(Bl);
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return xt === null ? sc(l, t, e) : Xs(
        l,
        xt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = uc(Bl)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : gu(t),
        e
      ];
    },
    useSyncExternalStore: vs,
    useId: Ks,
    useHostTransitionStatus: dc,
    useFormState: Bs,
    useActionState: Bs,
    useOptimistic: function(t, e) {
      var l = Lt();
      return xt !== null ? zs(l, xt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ac,
    useCacheRefresh: Js
  };
  Is.useEffectEvent = Hs;
  function yc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : L({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var gc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = we(), n = aa(a);
      n.payload = e, l != null && (n.callback = l), e = na(t, n, a), e !== null && (_e(e, t, a), du(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = we(), n = aa(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = na(t, n, a), e !== null && (_e(e, t, a), du(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = we(), a = aa(l);
      a.tag = 2, e != null && (a.callback = e), e = na(t, a, l), e !== null && (_e(e, t, l), du(e, t, l));
    }
  };
  function Ps(t, e, l, a, n, u, i) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, u, i) : e.prototype && e.prototype.isPureReactComponent ? !nu(l, a) || !nu(n, u) : !0;
  }
  function tr(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && gc.enqueueReplaceState(e, e.state, null);
  }
  function ka(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = L({}, l));
      for (var n in t)
        l[n] === void 0 && (l[n] = t[n]);
    }
    return l;
  }
  function er(t) {
    ci(t);
  }
  function lr(t) {
    console.error(t);
  }
  function ar(t) {
    ci(t);
  }
  function Ci(t, e) {
    try {
      var l = t.onUncaughtError;
      l(e.value, { componentStack: e.stack });
    } catch (a) {
      setTimeout(function() {
        throw a;
      });
    }
  }
  function nr(t, e, l) {
    try {
      var a = t.onCaughtError;
      a(l.value, {
        componentStack: l.stack,
        errorBoundary: e.tag === 1 ? e.stateNode : null
      });
    } catch (n) {
      setTimeout(function() {
        throw n;
      });
    }
  }
  function vc(t, e, l) {
    return l = aa(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Ci(t, e);
    }, l;
  }
  function ur(t) {
    return t = aa(t), t.tag = 3, t;
  }
  function ir(t, e, l, a) {
    var n = l.type.getDerivedStateFromError;
    if (typeof n == "function") {
      var u = a.value;
      t.payload = function() {
        return n(u);
      }, t.callback = function() {
        nr(e, l, a);
      };
    }
    var i = l.stateNode;
    i !== null && typeof i.componentDidCatch == "function" && (t.callback = function() {
      nr(e, l, a), typeof n != "function" && (sa === null ? sa = /* @__PURE__ */ new Set([this]) : sa.add(this));
      var f = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: f !== null ? f : ""
      });
    });
  }
  function Jm(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && gn(
        e,
        l,
        n,
        !0
      ), l = Ne.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return Fe === null ? Qi() : l.alternate === null && jt === 0 && (jt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === pi ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Xc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === pi ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Xc(t, a, n)), !1;
        }
        throw Error(b(435, l.tag));
      }
      return Xc(t, a, n), Qi(), !1;
    }
    if (ft)
      return e = Ne.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== qf && (t = Error(b(422), { cause: a }), fu(Ze(t, l)))) : (a !== qf && (e = Error(b(423), {
        cause: a
      }), fu(
        Ze(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ze(a, l), n = vc(
        t.stateNode,
        a,
        n
      ), Jf(t, n), jt !== 4 && (jt = 2)), !1;
    var u = Error(b(520), { cause: a });
    if (u = Ze(u, l), Au === null ? Au = [u] : Au.push(u), jt !== 4 && (jt = 2), e === null) return !0;
    a = Ze(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = vc(l.stateNode, a, t), Jf(l, t), !1;
        case 1:
          if (e = l.type, u = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || u !== null && typeof u.componentDidCatch == "function" && (sa === null || !sa.has(u))))
            return l.flags |= 65536, n &= -n, l.lanes |= n, n = ur(n), ir(
              n,
              t,
              l,
              a
            ), Jf(l, n), !1;
      }
      l = l.return;
    } while (l !== null);
    return !1;
  }
  var pc = Error(b(461)), Kt = !1;
  function ue(t, e, l, a) {
    e.child = t === null ? ss(e, null, l, a) : Ka(
      e,
      t.child,
      l,
      a
    );
  }
  function fr(t, e, l, a, n) {
    l = l.render;
    var u = e.ref;
    if ("ref" in a) {
      var i = {};
      for (var f in a)
        f !== "ref" && (i[f] = a[f]);
    } else i = a;
    return Xa(e), a = Pf(
      t,
      e,
      l,
      i,
      u,
      n
    ), f = tc(), t !== null && !Kt ? (ec(t, e, n), Rl(t, e, n)) : (ft && f && Nf(e), e.flags |= 1, ue(t, e, a, n), e.child);
  }
  function cr(t, e, l, a, n) {
    if (t === null) {
      var u = l.type;
      return typeof u == "function" && !Cf(u) && u.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = u, or(
        t,
        e,
        u,
        a,
        n
      )) : (t = di(
        l.type,
        null,
        a,
        e,
        e.mode,
        n
      ), t.ref = e.ref, t.return = e, e.child = t);
    }
    if (u = t.child, !Ac(t, n)) {
      var i = u.memoizedProps;
      if (l = l.compare, l = l !== null ? l : nu, l(i, a) && t.ref === e.ref)
        return Rl(t, e, n);
    }
    return e.flags |= 1, t = _l(u, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function or(t, e, l, a, n) {
    if (t !== null) {
      var u = t.memoizedProps;
      if (nu(u, a) && t.ref === e.ref)
        if (Kt = !1, e.pendingProps = a = u, Ac(t, n))
          (t.flags & 131072) !== 0 && (Kt = !0);
        else
          return e.lanes = t.lanes, Rl(t, e, n);
    }
    return bc(
      t,
      e,
      l,
      a,
      n
    );
  }
  function sr(t, e, l, a) {
    var n = a.children, u = t !== null ? t.memoizedState : null;
    if (t === null && e.stateNode === null && (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), a.mode === "hidden") {
      if ((e.flags & 128) !== 0) {
        if (u = u !== null ? u.baseLanes | l : l, t !== null) {
          for (a = e.child = t.child, n = 0; a !== null; )
            n = n | a.lanes | a.childLanes, a = a.sibling;
          a = n & ~u;
        } else a = 0, e.child = null;
        return rr(
          t,
          e,
          u,
          l,
          a
        );
      }
      if ((l & 536870912) !== 0)
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && gi(
          e,
          u !== null ? u.cachePool : null
        ), u !== null ? ms(e, u) : Ff(), hs(e);
      else
        return a = e.lanes = 536870912, rr(
          t,
          e,
          u !== null ? u.baseLanes | l : l,
          l,
          a
        );
    } else
      u !== null ? (gi(e, u.cachePool), ms(e, u), ia(), e.memoizedState = null) : (t !== null && gi(e, null), Ff(), ia());
    return ue(t, e, n, l), e.child;
  }
  function bu(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function rr(t, e, l, a, n) {
    var u = Qf();
    return u = u === null ? null : { parent: Vt._currentValue, pool: u }, e.memoizedState = {
      baseLanes: l,
      cachePool: u
    }, t !== null && gi(e, null), Ff(), hs(e), t !== null && gn(t, e, a, !0), e.childLanes = n, null;
  }
  function Bi(t, e) {
    return e = Ni(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function dr(t, e, l) {
    return Ka(e, t.child, null, l), t = Bi(e, e.pendingProps), t.flags |= 2, He(e), e.memoizedState = null, t;
  }
  function km(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (ft) {
        if (a.mode === "hidden")
          return t = Bi(e, a), e.lanes = 536870912, bu(null, t);
        if ($f(e), (t = _t) ? (t = Md(
          t,
          ke
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Il !== null ? { id: rl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ae = e, _t = null)) : t = null, t === null) throw ta(e);
        return e.lanes = 536870912, null;
      }
      return Bi(e, a);
    }
    var u = t.memoizedState;
    if (u !== null) {
      var i = u.dehydrated;
      if ($f(e), n)
        if (e.flags & 256)
          e.flags &= -257, e = dr(
            t,
            e,
            l
          );
        else if (e.memoizedState !== null)
          e.child = t.child, e.flags |= 128, e = null;
        else throw Error(b(558));
      else if (Kt || gn(t, e, l, !1), n = (l & t.childLanes) !== 0, Kt || n) {
        if (a = Mt, a !== null && (i = Fu(a, l), i !== 0 && i !== u.retryLane))
          throw u.retryLane = i, wa(t, i), _e(a, t, i), pc;
        Qi(), e = dr(
          t,
          e,
          l
        );
      } else
        t = u.treeContext, _t = We(i.nextSibling), ae = e, ft = !0, Pl = null, ke = !1, t !== null && Io(e, t), e = Bi(e, a), e.flags |= 4096;
      return e;
    }
    return t = _l(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Ri(t, e) {
    var l = e.ref;
    if (l === null)
      t !== null && t.ref !== null && (e.flags |= 4194816);
    else {
      if (typeof l != "function" && typeof l != "object")
        throw Error(b(284));
      (t === null || t.ref !== l) && (e.flags |= 4194816);
    }
  }
  function bc(t, e, l, a, n) {
    return Xa(e), l = Pf(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = tc(), t !== null && !Kt ? (ec(t, e, n), Rl(t, e, n)) : (ft && a && Nf(e), e.flags |= 1, ue(t, e, l, n), e.child);
  }
  function mr(t, e, l, a, n, u) {
    return Xa(e), e.updateQueue = null, l = gs(
      e,
      a,
      l,
      n
    ), ys(t), a = tc(), t !== null && !Kt ? (ec(t, e, u), Rl(t, e, u)) : (ft && a && Nf(e), e.flags |= 1, ue(t, e, l, u), e.child);
  }
  function hr(t, e, l, a, n) {
    if (Xa(e), e.stateNode === null) {
      var u = dn, i = l.contextType;
      typeof i == "object" && i !== null && (u = ne(i)), u = new l(a, u), e.memoizedState = u.state !== null && u.state !== void 0 ? u.state : null, u.updater = gc, e.stateNode = u, u._reactInternals = e, u = e.stateNode, u.props = a, u.state = e.memoizedState, u.refs = {}, Zf(e), i = l.contextType, u.context = typeof i == "object" && i !== null ? ne(i) : dn, u.state = e.memoizedState, i = l.getDerivedStateFromProps, typeof i == "function" && (yc(
        e,
        l,
        i,
        a
      ), u.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof u.getSnapshotBeforeUpdate == "function" || typeof u.UNSAFE_componentWillMount != "function" && typeof u.componentWillMount != "function" || (i = u.state, typeof u.componentWillMount == "function" && u.componentWillMount(), typeof u.UNSAFE_componentWillMount == "function" && u.UNSAFE_componentWillMount(), i !== u.state && gc.enqueueReplaceState(u, u.state, null), hu(e, a, u, n), mu(), u.state = e.memoizedState), typeof u.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      u = e.stateNode;
      var f = e.memoizedProps, s = ka(l, f);
      u.props = s;
      var v = u.context, x = l.contextType;
      i = dn, typeof x == "object" && x !== null && (i = ne(x));
      var E = l.getDerivedStateFromProps;
      x = typeof E == "function" || typeof u.getSnapshotBeforeUpdate == "function", f = e.pendingProps !== f, x || typeof u.UNSAFE_componentWillReceiveProps != "function" && typeof u.componentWillReceiveProps != "function" || (f || v !== i) && tr(
        e,
        u,
        a,
        i
      ), la = !1;
      var p = e.memoizedState;
      u.state = p, hu(e, a, u, n), mu(), v = e.memoizedState, f || p !== v || la ? (typeof E == "function" && (yc(
        e,
        l,
        E,
        a
      ), v = e.memoizedState), (s = la || Ps(
        e,
        l,
        s,
        a,
        p,
        v,
        i
      )) ? (x || typeof u.UNSAFE_componentWillMount != "function" && typeof u.componentWillMount != "function" || (typeof u.componentWillMount == "function" && u.componentWillMount(), typeof u.UNSAFE_componentWillMount == "function" && u.UNSAFE_componentWillMount()), typeof u.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof u.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = v), u.props = a, u.state = v, u.context = i, a = s) : (typeof u.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      u = e.stateNode, Kf(t, e), i = e.memoizedProps, x = ka(l, i), u.props = x, E = e.pendingProps, p = u.context, v = l.contextType, s = dn, typeof v == "object" && v !== null && (s = ne(v)), f = l.getDerivedStateFromProps, (v = typeof f == "function" || typeof u.getSnapshotBeforeUpdate == "function") || typeof u.UNSAFE_componentWillReceiveProps != "function" && typeof u.componentWillReceiveProps != "function" || (i !== E || p !== s) && tr(
        e,
        u,
        a,
        s
      ), la = !1, p = e.memoizedState, u.state = p, hu(e, a, u, n), mu();
      var S = e.memoizedState;
      i !== E || p !== S || la || t !== null && t.dependencies !== null && hi(t.dependencies) ? (typeof f == "function" && (yc(
        e,
        l,
        f,
        a
      ), S = e.memoizedState), (x = la || Ps(
        e,
        l,
        x,
        a,
        p,
        S,
        s
      ) || t !== null && t.dependencies !== null && hi(t.dependencies)) ? (v || typeof u.UNSAFE_componentWillUpdate != "function" && typeof u.componentWillUpdate != "function" || (typeof u.componentWillUpdate == "function" && u.componentWillUpdate(a, S, s), typeof u.UNSAFE_componentWillUpdate == "function" && u.UNSAFE_componentWillUpdate(
        a,
        S,
        s
      )), typeof u.componentDidUpdate == "function" && (e.flags |= 4), typeof u.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof u.componentDidUpdate != "function" || i === t.memoizedProps && p === t.memoizedState || (e.flags |= 4), typeof u.getSnapshotBeforeUpdate != "function" || i === t.memoizedProps && p === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = S), u.props = a, u.state = S, u.context = s, a = x) : (typeof u.componentDidUpdate != "function" || i === t.memoizedProps && p === t.memoizedState || (e.flags |= 4), typeof u.getSnapshotBeforeUpdate != "function" || i === t.memoizedProps && p === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return u = a, Ri(t, e), a = (e.flags & 128) !== 0, u || a ? (u = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : u.render(), e.flags |= 1, t !== null && a ? (e.child = Ka(
      e,
      t.child,
      null,
      n
    ), e.child = Ka(
      e,
      null,
      l,
      n
    )) : ue(t, e, l, n), e.memoizedState = u.state, t = e.child) : t = Rl(
      t,
      e,
      n
    ), t;
  }
  function yr(t, e, l, a) {
    return Ga(), e.flags |= 256, ue(t, e, l, a), e.child;
  }
  var Sc = {
    dehydrated: null,
    treeContext: null,
    retryLane: 0,
    hydrationErrors: null
  };
  function xc(t) {
    return { baseLanes: t, cachePool: ns() };
  }
  function Tc(t, e, l) {
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= je), t;
  }
  function gr(t, e, l) {
    var a = e.pendingProps, n = !1, u = (e.flags & 128) !== 0, i;
    if ((i = u) || (i = t !== null && t.memoizedState === null ? !1 : (Gt.current & 2) !== 0), i && (n = !0, e.flags &= -129), i = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (ft) {
        if (n ? ua(e) : ia(), (t = _t) ? (t = Md(
          t,
          ke
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Il !== null ? { id: rl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ae = e, _t = null)) : t = null, t === null) throw ta(e);
        return no(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var f = a.children;
      return a = a.fallback, n ? (ia(), n = e.mode, f = Ni(
        { mode: "hidden", children: f },
        n
      ), a = Ya(
        a,
        n,
        l,
        null
      ), f.return = e, a.return = e, f.sibling = a, e.child = f, a = e.child, a.memoizedState = xc(l), a.childLanes = Tc(
        t,
        i,
        l
      ), e.memoizedState = Sc, bu(null, a)) : (ua(e), zc(e, f));
    }
    var s = t.memoizedState;
    if (s !== null && (f = s.dehydrated, f !== null)) {
      if (u)
        e.flags & 256 ? (ua(e), e.flags &= -257, e = Mc(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (ia(), e.child = t.child, e.flags |= 128, e = null) : (ia(), f = a.fallback, n = e.mode, a = Ni(
          { mode: "visible", children: a.children },
          n
        ), f = Ya(
          f,
          n,
          l,
          null
        ), f.flags |= 2, a.return = e, f.return = e, a.sibling = f, e.child = a, Ka(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = xc(l), a.childLanes = Tc(
          t,
          i,
          l
        ), e.memoizedState = Sc, e = bu(null, a));
      else if (ua(e), no(f)) {
        if (i = f.nextSibling && f.nextSibling.dataset, i) var v = i.dgst;
        i = v, a = Error(b(419)), a.stack = "", a.digest = i, fu({ value: a, source: null, stack: null }), e = Mc(
          t,
          e,
          l
        );
      } else if (Kt || gn(t, e, l, !1), i = (l & t.childLanes) !== 0, Kt || i) {
        if (i = Mt, i !== null && (a = Fu(i, l), a !== 0 && a !== s.retryLane))
          throw s.retryLane = a, wa(t, a), _e(i, t, a), pc;
        ao(f) || Qi(), e = Mc(
          t,
          e,
          l
        );
      } else
        ao(f) ? (e.flags |= 192, e.child = t.child, e = null) : (t = s.treeContext, _t = We(
          f.nextSibling
        ), ae = e, ft = !0, Pl = null, ke = !1, t !== null && Io(e, t), e = zc(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (ia(), f = a.fallback, n = e.mode, s = t.child, v = s.sibling, a = _l(s, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = s.subtreeFlags & 65011712, v !== null ? f = _l(
      v,
      f
    ) : (f = Ya(
      f,
      n,
      l,
      null
    ), f.flags |= 2), f.return = e, a.return = e, a.sibling = f, e.child = a, bu(null, a), a = e.child, f = t.child.memoizedState, f === null ? f = xc(l) : (n = f.cachePool, n !== null ? (s = Vt._currentValue, n = n.parent !== s ? { parent: s, pool: s } : n) : n = ns(), f = {
      baseLanes: f.baseLanes | l,
      cachePool: n
    }), a.memoizedState = f, a.childLanes = Tc(
      t,
      i,
      l
    ), e.memoizedState = Sc, bu(t.child, a)) : (ua(e), l = t.child, t = l.sibling, l = _l(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (i = e.deletions, i === null ? (e.deletions = [t], e.flags |= 16) : i.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function zc(t, e) {
    return e = Ni(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Ni(t, e) {
    return t = Re(22, t, null, e), t.lanes = 0, t;
  }
  function Mc(t, e, l) {
    return Ka(e, t.child, null, l), t = zc(
      e,
      e.pendingProps.children
    ), t.flags |= 2, e.memoizedState = null, t;
  }
  function vr(t, e, l) {
    t.lanes |= e;
    var a = t.alternate;
    a !== null && (a.lanes |= e), Yf(t.return, e, l);
  }
  function Ec(t, e, l, a, n, u) {
    var i = t.memoizedState;
    i === null ? t.memoizedState = {
      isBackwards: e,
      rendering: null,
      renderingStartTime: 0,
      last: a,
      tail: l,
      tailMode: n,
      treeForkCount: u
    } : (i.isBackwards = e, i.rendering = null, i.renderingStartTime = 0, i.last = a, i.tail = l, i.tailMode = n, i.treeForkCount = u);
  }
  function pr(t, e, l) {
    var a = e.pendingProps, n = a.revealOrder, u = a.tail;
    a = a.children;
    var i = Gt.current, f = (i & 2) !== 0;
    if (f ? (i = i & 1 | 2, e.flags |= 128) : i &= 1, B(Gt, i), ue(t, e, a, l), a = ft ? iu : 0, !f && t !== null && (t.flags & 128) !== 0)
      t: for (t = e.child; t !== null; ) {
        if (t.tag === 13)
          t.memoizedState !== null && vr(t, l, e);
        else if (t.tag === 19)
          vr(t, l, e);
        else if (t.child !== null) {
          t.child.return = t, t = t.child;
          continue;
        }
        if (t === e) break t;
        for (; t.sibling === null; ) {
          if (t.return === null || t.return === e)
            break t;
          t = t.return;
        }
        t.sibling.return = t.return, t = t.sibling;
      }
    switch (n) {
      case "forwards":
        for (l = e.child, n = null; l !== null; )
          t = l.alternate, t !== null && Ti(t) === null && (n = l), l = l.sibling;
        l = n, l === null ? (n = e.child, e.child = null) : (n = l.sibling, l.sibling = null), Ec(
          e,
          !1,
          n,
          l,
          u,
          a
        );
        break;
      case "backwards":
      case "unstable_legacy-backwards":
        for (l = null, n = e.child, e.child = null; n !== null; ) {
          if (t = n.alternate, t !== null && Ti(t) === null) {
            e.child = n;
            break;
          }
          t = n.sibling, n.sibling = l, l = n, n = t;
        }
        Ec(
          e,
          !0,
          l,
          null,
          u,
          a
        );
        break;
      case "together":
        Ec(
          e,
          !1,
          null,
          null,
          void 0,
          a
        );
        break;
      default:
        e.memoizedState = null;
    }
    return e.child;
  }
  function Rl(t, e, l) {
    if (t !== null && (e.dependencies = t.dependencies), oa |= e.lanes, (l & e.childLanes) === 0)
      if (t !== null) {
        if (gn(
          t,
          e,
          l,
          !1
        ), (l & e.childLanes) === 0)
          return null;
      } else return null;
    if (t !== null && e.child !== t.child)
      throw Error(b(153));
    if (e.child !== null) {
      for (t = e.child, l = _l(t, t.pendingProps), e.child = l, l.return = e; t.sibling !== null; )
        t = t.sibling, l = l.sibling = _l(t, t.pendingProps), l.return = e;
      l.sibling = null;
    }
    return e.child;
  }
  function Ac(t, e) {
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && hi(t)));
  }
  function Fm(t, e, l) {
    switch (e.tag) {
      case 3:
        $t(e, e.stateNode.containerInfo), ea(e, Vt, t.memoizedState.cache), Ga();
        break;
      case 27:
      case 5:
        yl(e);
        break;
      case 4:
        $t(e, e.stateNode.containerInfo);
        break;
      case 10:
        ea(
          e,
          e.type,
          e.memoizedProps.value
        );
        break;
      case 31:
        if (e.memoizedState !== null)
          return e.flags |= 128, $f(e), null;
        break;
      case 13:
        var a = e.memoizedState;
        if (a !== null)
          return a.dehydrated !== null ? (ua(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? gr(t, e, l) : (ua(e), t = Rl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        ua(e);
        break;
      case 19:
        var n = (t.flags & 128) !== 0;
        if (a = (l & e.childLanes) !== 0, a || (gn(
          t,
          e,
          l,
          !1
        ), a = (l & e.childLanes) !== 0), n) {
          if (a)
            return pr(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), B(Gt, Gt.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, sr(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        ea(e, Vt, t.memoizedState.cache);
    }
    return Rl(t, e, l);
  }
  function br(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        Kt = !0;
      else {
        if (!Ac(t, l) && (e.flags & 128) === 0)
          return Kt = !1, Fm(
            t,
            e,
            l
          );
        Kt = (t.flags & 131072) !== 0;
      }
    else
      Kt = !1, ft && (e.flags & 1048576) !== 0 && $o(e, iu, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = Va(e.elementType), e.type = t, typeof t == "function")
            Cf(t) ? (a = ka(t, a), e.tag = 1, e = hr(
              null,
              e,
              t,
              a,
              l
            )) : (e.tag = 0, e = bc(
              null,
              e,
              t,
              a,
              l
            ));
          else {
            if (t != null) {
              var n = t.$$typeof;
              if (n === Ft) {
                e.tag = 11, e = fr(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === et) {
                e.tag = 14, e = cr(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              }
            }
            throw e = Le(t) || t, Error(b(306, e, ""));
          }
        }
        return e;
      case 0:
        return bc(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 1:
        return a = e.type, n = ka(
          a,
          e.pendingProps
        ), hr(
          t,
          e,
          a,
          n,
          l
        );
      case 3:
        t: {
          if ($t(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(b(387));
          a = e.pendingProps;
          var u = e.memoizedState;
          n = u.element, Kf(t, e), hu(e, a, null, l);
          var i = e.memoizedState;
          if (a = i.cache, ea(e, Vt, a), a !== u.cache && Gf(
            e,
            [Vt],
            l,
            !0
          ), mu(), a = i.element, u.isDehydrated)
            if (u = {
              element: a,
              isDehydrated: !1,
              cache: i.cache
            }, e.updateQueue.baseState = u, e.memoizedState = u, e.flags & 256) {
              e = yr(
                t,
                e,
                a,
                l
              );
              break t;
            } else if (a !== n) {
              n = Ze(
                Error(b(424)),
                e
              ), fu(n), e = yr(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, _t = We(t.firstChild), ae = e, ft = !0, Pl = null, ke = !0, l = ss(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (Ga(), a === n) {
              e = Rl(
                t,
                e,
                l
              );
              break t;
            }
            ue(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Ri(t, e), t === null ? (l = Ud(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : ft || (l = e.type, t = e.pendingProps, a = Wi(
          W.current
        ).createElement(l), a[Qt] = e, a[re] = t, ie(a, l, t), Yt(a), e.stateNode = a) : e.memoizedState = Ud(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return yl(e), t === null && ft && (a = e.stateNode = _d(
          e.type,
          e.pendingProps,
          W.current
        ), ae = e, ke = !0, n = _t, ha(e.type) ? (uo = n, _t = We(a.firstChild)) : _t = n), ue(
          t,
          e,
          e.pendingProps.children,
          l
        ), Ri(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && ft && ((n = a = _t) && (a = Eh(
          a,
          e.type,
          e.pendingProps,
          ke
        ), a !== null ? (e.stateNode = a, ae = e, _t = We(a.firstChild), ke = !1, n = !0) : n = !1), n || ta(e)), yl(e), n = e.type, u = e.pendingProps, i = t !== null ? t.memoizedProps : null, a = u.children, to(n, u) ? a = null : i !== null && to(n, i) && (e.flags |= 32), e.memoizedState !== null && (n = Pf(
          t,
          e,
          Gm,
          null,
          null,
          l
        ), Nu._currentValue = n), Ri(t, e), ue(t, e, a, l), e.child;
      case 6:
        return t === null && ft && ((t = l = _t) && (l = Ah(
          l,
          e.pendingProps,
          ke
        ), l !== null ? (e.stateNode = l, ae = e, _t = null, t = !0) : t = !1), t || ta(e)), null;
      case 13:
        return gr(t, e, l);
      case 4:
        return $t(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = Ka(
          e,
          null,
          a,
          l
        ) : ue(t, e, a, l), e.child;
      case 11:
        return fr(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return ue(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return ue(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return ue(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, ea(e, e.type, a.value), ue(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, Xa(e), n = ne(n), a = a(n), e.flags |= 1, ue(t, e, a, l), e.child;
      case 14:
        return cr(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 15:
        return or(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 19:
        return pr(t, e, l);
      case 31:
        return km(t, e, l);
      case 22:
        return sr(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return Xa(e), a = ne(Vt), t === null ? (n = Qf(), n === null && (n = Mt, u = Lf(), n.pooledCache = u, u.refCount++, u !== null && (n.pooledCacheLanes |= l), n = u), e.memoizedState = { parent: a, cache: n }, Zf(e), ea(e, Vt, n)) : ((t.lanes & l) !== 0 && (Kf(t, e), hu(e, null, null, l), mu()), n = t.memoizedState, u = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), ea(e, Vt, a)) : (a = u.cache, ea(e, Vt, a), a !== n.cache && Gf(
          e,
          [Vt],
          l,
          !0
        ))), ue(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 29:
        throw e.pendingProps;
    }
    throw Error(b(156, e.tag));
  }
  function Nl(t) {
    t.flags |= 4;
  }
  function _c(t, e, l, a, n) {
    if ((e = (t.mode & 32) !== 0) && (e = !1), e) {
      if (t.flags |= 16777216, (n & 335544128) === n)
        if (t.stateNode.complete) t.flags |= 8192;
        else if (Kr()) t.flags |= 8192;
        else
          throw Za = pi, Vf;
    } else t.flags &= -16777217;
  }
  function Sr(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !Hd(e))
      if (Kr()) t.flags |= 8192;
      else
        throw Za = pi, Vf;
  }
  function Hi(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? ku() : 536870912, t.lanes |= e, Dn |= e);
  }
  function Su(t, e) {
    if (!ft)
      switch (t.tailMode) {
        case "hidden":
          e = t.tail;
          for (var l = null; e !== null; )
            e.alternate !== null && (l = e), e = e.sibling;
          l === null ? t.tail = null : l.sibling = null;
          break;
        case "collapsed":
          l = t.tail;
          for (var a = null; l !== null; )
            l.alternate !== null && (a = l), l = l.sibling;
          a === null ? e || t.tail === null ? t.tail = null : t.tail.sibling = null : a.sibling = null;
      }
  }
  function Dt(t) {
    var e = t.alternate !== null && t.alternate.child === t.child, l = 0, a = 0;
    if (e)
      for (var n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags & 65011712, a |= n.flags & 65011712, n.return = t, n = n.sibling;
    else
      for (n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags, a |= n.flags, n.return = t, n = n.sibling;
    return t.subtreeFlags |= a, t.childLanes = l, e;
  }
  function Wm(t, e, l) {
    var a = e.pendingProps;
    switch (Hf(e), e.tag) {
      case 16:
      case 15:
      case 0:
      case 11:
      case 7:
      case 8:
      case 12:
      case 9:
      case 14:
        return Dt(e), null;
      case 1:
        return Dt(e), null;
      case 3:
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), Ul(Vt), pt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (yn(e) ? Nl(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, jf())), Dt(e), null;
      case 26:
        var n = e.type, u = e.memoizedState;
        return t === null ? (Nl(e), u !== null ? (Dt(e), Sr(e, u)) : (Dt(e), _c(
          e,
          n,
          null,
          a,
          l
        ))) : u ? u !== t.memoizedState ? (Nl(e), Dt(e), Sr(e, u)) : (Dt(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Nl(e), Dt(e), _c(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if (Xe(e), l = W.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Nl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(b(166));
            return Dt(e), null;
          }
          t = H.current, yn(e) ? Po(e) : (t = _d(n, a, l), e.stateNode = t, Nl(e));
        }
        return Dt(e), null;
      case 5:
        if (Xe(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Nl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(b(166));
            return Dt(e), null;
          }
          if (u = H.current, yn(e))
            Po(e);
          else {
            var i = Wi(
              W.current
            );
            switch (u) {
              case 1:
                u = i.createElementNS(
                  "http://www.w3.org/2000/svg",
                  n
                );
                break;
              case 2:
                u = i.createElementNS(
                  "http://www.w3.org/1998/Math/MathML",
                  n
                );
                break;
              default:
                switch (n) {
                  case "svg":
                    u = i.createElementNS(
                      "http://www.w3.org/2000/svg",
                      n
                    );
                    break;
                  case "math":
                    u = i.createElementNS(
                      "http://www.w3.org/1998/Math/MathML",
                      n
                    );
                    break;
                  case "script":
                    u = i.createElement("div"), u.innerHTML = "<script><\/script>", u = u.removeChild(
                      u.firstChild
                    );
                    break;
                  case "select":
                    u = typeof a.is == "string" ? i.createElement("select", {
                      is: a.is
                    }) : i.createElement("select"), a.multiple ? u.multiple = !0 : a.size && (u.size = a.size);
                    break;
                  default:
                    u = typeof a.is == "string" ? i.createElement(n, { is: a.is }) : i.createElement(n);
                }
            }
            u[Qt] = e, u[re] = a;
            t: for (i = e.child; i !== null; ) {
              if (i.tag === 5 || i.tag === 6)
                u.appendChild(i.stateNode);
              else if (i.tag !== 4 && i.tag !== 27 && i.child !== null) {
                i.child.return = i, i = i.child;
                continue;
              }
              if (i === e) break t;
              for (; i.sibling === null; ) {
                if (i.return === null || i.return === e)
                  break t;
                i = i.return;
              }
              i.sibling.return = i.return, i = i.sibling;
            }
            e.stateNode = u;
            t: switch (ie(u, n, a), n) {
              case "button":
              case "input":
              case "select":
              case "textarea":
                a = !!a.autoFocus;
                break t;
              case "img":
                a = !0;
                break t;
              default:
                a = !1;
            }
            a && Nl(e);
          }
        }
        return Dt(e), _c(
          e,
          e.type,
          t === null ? null : t.memoizedProps,
          e.pendingProps,
          l
        ), null;
      case 6:
        if (t && e.stateNode != null)
          t.memoizedProps !== a && Nl(e);
        else {
          if (typeof a != "string" && e.stateNode === null)
            throw Error(b(166));
          if (t = W.current, yn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = ae, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[Qt] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || gd(t.nodeValue, l)), t || ta(e, !0);
          } else
            t = Wi(t).createTextNode(
              a
            ), t[Qt] = e, e.stateNode = t;
        }
        return Dt(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = yn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(b(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(b(557));
              t[Qt] = e;
            } else
              Ga(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Dt(e), t = !1;
          } else
            l = jf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (He(e), e) : (He(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(b(558));
        }
        return Dt(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = yn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(b(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(b(317));
              n[Qt] = e;
            } else
              Ga(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Dt(e), n = !1;
          } else
            n = jf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (He(e), e) : (He(e), null);
        }
        return He(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), u = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (u = a.memoizedState.cachePool.pool), u !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Hi(e, e.updateQueue), Dt(e), null);
      case 4:
        return pt(), t === null && Fc(e.stateNode.containerInfo), Dt(e), null;
      case 10:
        return Ul(e.type), Dt(e), null;
      case 19:
        if (M(Gt), a = e.memoizedState, a === null) return Dt(e), null;
        if (n = (e.flags & 128) !== 0, u = a.rendering, u === null)
          if (n) Su(a, !1);
          else {
            if (jt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (u = Ti(t), u !== null) {
                  for (e.flags |= 128, Su(a, !1), t = u.updateQueue, e.updateQueue = t, Hi(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    ko(l, t), l = l.sibling;
                  return B(
                    Gt,
                    Gt.current & 1 | 2
                  ), ft && Dl(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && le() > Gi && (e.flags |= 128, n = !0, Su(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = Ti(u), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Hi(e, t), Su(a, !0), a.tail === null && a.tailMode === "hidden" && !u.alternate && !ft)
                return Dt(e), null;
            } else
              2 * le() - a.renderingStartTime > Gi && l !== 536870912 && (e.flags |= 128, n = !0, Su(a, !1), e.lanes = 4194304);
          a.isBackwards ? (u.sibling = e.child, e.child = u) : (t = a.last, t !== null ? t.sibling = u : e.child = u, a.last = u);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = le(), t.sibling = null, l = Gt.current, B(
          Gt,
          n ? l & 1 | 2 : l & 1
        ), ft && Dl(e, a.treeForkCount), t) : (Dt(e), null);
      case 22:
      case 23:
        return He(e), Wf(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Dt(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Dt(e), l = e.updateQueue, l !== null && Hi(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && M(Qa), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), Ul(Vt), Dt(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(b(156, e.tag));
  }
  function $m(t, e) {
    switch (Hf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return Ul(Vt), pt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return Xe(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (He(e), e.alternate === null)
            throw Error(b(340));
          Ga();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (He(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(b(340));
          Ga();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return M(Gt), null;
      case 4:
        return pt(), null;
      case 10:
        return Ul(e.type), null;
      case 22:
      case 23:
        return He(e), Wf(), t !== null && M(Qa), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return Ul(Vt), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function xr(t, e) {
    switch (Hf(e), e.tag) {
      case 3:
        Ul(Vt), pt();
        break;
      case 26:
      case 27:
      case 5:
        Xe(e);
        break;
      case 4:
        pt();
        break;
      case 31:
        e.memoizedState !== null && He(e);
        break;
      case 13:
        He(e);
        break;
      case 19:
        M(Gt);
        break;
      case 10:
        Ul(e.type);
        break;
      case 22:
      case 23:
        He(e), Wf(), t !== null && M(Qa);
        break;
      case 24:
        Ul(Vt);
    }
  }
  function xu(t, e) {
    try {
      var l = e.updateQueue, a = l !== null ? l.lastEffect : null;
      if (a !== null) {
        var n = a.next;
        l = n;
        do {
          if ((l.tag & t) === t) {
            a = void 0;
            var u = l.create, i = l.inst;
            a = u(), i.destroy = a;
          }
          l = l.next;
        } while (l !== n);
      }
    } catch (f) {
      St(e, e.return, f);
    }
  }
  function fa(t, e, l) {
    try {
      var a = e.updateQueue, n = a !== null ? a.lastEffect : null;
      if (n !== null) {
        var u = n.next;
        a = u;
        do {
          if ((a.tag & t) === t) {
            var i = a.inst, f = i.destroy;
            if (f !== void 0) {
              i.destroy = void 0, n = e;
              var s = l, v = f;
              try {
                v();
              } catch (x) {
                St(
                  n,
                  s,
                  x
                );
              }
            }
          }
          a = a.next;
        } while (a !== u);
      }
    } catch (x) {
      St(e, e.return, x);
    }
  }
  function Tr(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        ds(e, l);
      } catch (a) {
        St(t, t.return, a);
      }
    }
  }
  function zr(t, e, l) {
    l.props = ka(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      St(t, e, a);
    }
  }
  function Tu(t, e) {
    try {
      var l = t.ref;
      if (l !== null) {
        switch (t.tag) {
          case 26:
          case 27:
          case 5:
            var a = t.stateNode;
            break;
          case 30:
            a = t.stateNode;
            break;
          default:
            a = t.stateNode;
        }
        typeof l == "function" ? t.refCleanup = l(a) : l.current = a;
      }
    } catch (n) {
      St(t, e, n);
    }
  }
  function ml(t, e) {
    var l = t.ref, a = t.refCleanup;
    if (l !== null)
      if (typeof a == "function")
        try {
          a();
        } catch (n) {
          St(t, e, n);
        } finally {
          t.refCleanup = null, t = t.alternate, t != null && (t.refCleanup = null);
        }
      else if (typeof l == "function")
        try {
          l(null);
        } catch (n) {
          St(t, e, n);
        }
      else l.current = null;
  }
  function Mr(t) {
    var e = t.type, l = t.memoizedProps, a = t.stateNode;
    try {
      t: switch (e) {
        case "button":
        case "input":
        case "select":
        case "textarea":
          l.autoFocus && a.focus();
          break t;
        case "img":
          l.src ? a.src = l.src : l.srcSet && (a.srcset = l.srcSet);
      }
    } catch (n) {
      St(t, t.return, n);
    }
  }
  function Dc(t, e, l) {
    try {
      var a = t.stateNode;
      bh(a, t.type, l, e), a[re] = e;
    } catch (n) {
      St(t, t.return, n);
    }
  }
  function Er(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && ha(t.type) || t.tag === 4;
  }
  function Oc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || Er(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && ha(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Uc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = de));
    else if (a !== 4 && (a === 27 && ha(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Uc(t, e, l), t = t.sibling; t !== null; )
        Uc(t, e, l), t = t.sibling;
  }
  function qi(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && ha(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (qi(t, e, l), t = t.sibling; t !== null; )
        qi(t, e, l), t = t.sibling;
  }
  function Ar(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      ie(e, a, l), e[Qt] = t, e[re] = l;
    } catch (u) {
      St(t, t.return, u);
    }
  }
  var Hl = !1, Jt = !1, Cc = !1, _r = typeof WeakSet == "function" ? WeakSet : Set, It = null;
  function Im(t, e) {
    if (t = t.containerInfo, Ic = af, t = Yo(t), Mf(t)) {
      if ("selectionStart" in t)
        var l = {
          start: t.selectionStart,
          end: t.selectionEnd
        };
      else
        t: {
          l = (l = t.ownerDocument) && l.defaultView || window;
          var a = l.getSelection && l.getSelection();
          if (a && a.rangeCount !== 0) {
            l = a.anchorNode;
            var n = a.anchorOffset, u = a.focusNode;
            a = a.focusOffset;
            try {
              l.nodeType, u.nodeType;
            } catch {
              l = null;
              break t;
            }
            var i = 0, f = -1, s = -1, v = 0, x = 0, E = t, p = null;
            e: for (; ; ) {
              for (var S; E !== l || n !== 0 && E.nodeType !== 3 || (f = i + n), E !== u || a !== 0 && E.nodeType !== 3 || (s = i + a), E.nodeType === 3 && (i += E.nodeValue.length), (S = E.firstChild) !== null; )
                p = E, E = S;
              for (; ; ) {
                if (E === t) break e;
                if (p === l && ++v === n && (f = i), p === u && ++x === a && (s = i), (S = E.nextSibling) !== null) break;
                E = p, p = E.parentNode;
              }
              E = S;
            }
            l = f === -1 || s === -1 ? null : { start: f, end: s };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (Pc = { focusedElem: t, selectionRange: l }, af = !1, It = e; It !== null; )
      if (e = It, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, It = t;
      else
        for (; It !== null; ) {
          switch (e = It, u = e.alternate, t = e.flags, e.tag) {
            case 0:
              if ((t & 4) !== 0 && (t = e.updateQueue, t = t !== null ? t.events : null, t !== null))
                for (l = 0; l < t.length; l++)
                  n = t[l], n.ref.impl = n.nextImpl;
              break;
            case 11:
            case 15:
              break;
            case 1:
              if ((t & 1024) !== 0 && u !== null) {
                t = void 0, l = e, n = u.memoizedProps, u = u.memoizedState, a = l.stateNode;
                try {
                  var j = ka(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    j,
                    u
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch (V) {
                  St(
                    l,
                    l.return,
                    V
                  );
                }
              }
              break;
            case 3:
              if ((t & 1024) !== 0) {
                if (t = e.stateNode.containerInfo, l = t.nodeType, l === 9)
                  lo(t);
                else if (l === 1)
                  switch (t.nodeName) {
                    case "HEAD":
                    case "HTML":
                    case "BODY":
                      lo(t);
                      break;
                    default:
                      t.textContent = "";
                  }
              }
              break;
            case 5:
            case 26:
            case 27:
            case 6:
            case 4:
            case 17:
              break;
            default:
              if ((t & 1024) !== 0) throw Error(b(163));
          }
          if (t = e.sibling, t !== null) {
            t.return = e.return, It = t;
            break;
          }
          It = e.return;
        }
  }
  function Dr(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        jl(t, l), a & 4 && xu(5, l);
        break;
      case 1:
        if (jl(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (i) {
              St(l, l.return, i);
            }
          else {
            var n = ka(
              l.type,
              e.memoizedProps
            );
            e = e.memoizedState;
            try {
              t.componentDidUpdate(
                n,
                e,
                t.__reactInternalSnapshotBeforeUpdate
              );
            } catch (i) {
              St(
                l,
                l.return,
                i
              );
            }
          }
        a & 64 && Tr(l), a & 512 && Tu(l, l.return);
        break;
      case 3:
        if (jl(t, l), a & 64 && (t = l.updateQueue, t !== null)) {
          if (e = null, l.child !== null)
            switch (l.child.tag) {
              case 27:
              case 5:
                e = l.child.stateNode;
                break;
              case 1:
                e = l.child.stateNode;
            }
          try {
            ds(t, e);
          } catch (i) {
            St(l, l.return, i);
          }
        }
        break;
      case 27:
        e === null && a & 4 && Ar(l);
      case 26:
      case 5:
        jl(t, l), e === null && a & 4 && Mr(l), a & 512 && Tu(l, l.return);
        break;
      case 12:
        jl(t, l);
        break;
      case 31:
        jl(t, l), a & 4 && Cr(t, l);
        break;
      case 13:
        jl(t, l), a & 4 && Br(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = fh.bind(
          null,
          l
        ), _h(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Hl, !a) {
          e = e !== null && e.memoizedState !== null || Jt, n = Hl;
          var u = Jt;
          Hl = a, (Jt = e) && !u ? wl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : jl(t, l), Hl = n, Jt = u;
        }
        break;
      case 30:
        break;
      default:
        jl(t, l);
    }
  }
  function Or(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Or(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && Qn(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Ct = null, ze = !1;
  function ql(t, e, l) {
    for (l = l.child; l !== null; )
      Ur(t, e, l), l = l.sibling;
  }
  function Ur(t, e, l) {
    if (ye && typeof ye.onCommitFiberUnmount == "function")
      try {
        ye.onCommitFiberUnmount(Ta, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        Jt || ml(l, e), ql(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        Jt || ml(l, e);
        var a = Ct, n = ze;
        ha(l.type) && (Ct = l.stateNode, ze = !1), ql(
          t,
          e,
          l
        ), Cu(l.stateNode), Ct = a, ze = n;
        break;
      case 5:
        Jt || ml(l, e);
      case 6:
        if (a = Ct, n = ze, Ct = null, ql(
          t,
          e,
          l
        ), Ct = a, ze = n, Ct !== null)
          if (ze)
            try {
              (Ct.nodeType === 9 ? Ct.body : Ct.nodeName === "HTML" ? Ct.ownerDocument.body : Ct).removeChild(l.stateNode);
            } catch (u) {
              St(
                l,
                e,
                u
              );
            }
          else
            try {
              Ct.removeChild(l.stateNode);
            } catch (u) {
              St(
                l,
                e,
                u
              );
            }
        break;
      case 18:
        Ct !== null && (ze ? (t = Ct, Td(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), qn(t)) : Td(Ct, l.stateNode));
        break;
      case 4:
        a = Ct, n = ze, Ct = l.stateNode.containerInfo, ze = !0, ql(
          t,
          e,
          l
        ), Ct = a, ze = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        fa(2, l, e), Jt || fa(4, l, e), ql(
          t,
          e,
          l
        );
        break;
      case 1:
        Jt || (ml(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && zr(
          l,
          e,
          a
        )), ql(
          t,
          e,
          l
        );
        break;
      case 21:
        ql(
          t,
          e,
          l
        );
        break;
      case 22:
        Jt = (a = Jt) || l.memoizedState !== null, ql(
          t,
          e,
          l
        ), Jt = a;
        break;
      default:
        ql(
          t,
          e,
          l
        );
    }
  }
  function Cr(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null))) {
      t = t.dehydrated;
      try {
        qn(t);
      } catch (l) {
        St(e, e.return, l);
      }
    }
  }
  function Br(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        qn(t);
      } catch (l) {
        St(e, e.return, l);
      }
  }
  function Pm(t) {
    switch (t.tag) {
      case 31:
      case 13:
      case 19:
        var e = t.stateNode;
        return e === null && (e = t.stateNode = new _r()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new _r()), e;
      default:
        throw Error(b(435, t.tag));
    }
  }
  function ji(t, e) {
    var l = Pm(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = ch.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function Me(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], u = t, i = e, f = i;
        t: for (; f !== null; ) {
          switch (f.tag) {
            case 27:
              if (ha(f.type)) {
                Ct = f.stateNode, ze = !1;
                break t;
              }
              break;
            case 5:
              Ct = f.stateNode, ze = !1;
              break t;
            case 3:
            case 4:
              Ct = f.stateNode.containerInfo, ze = !0;
              break t;
          }
          f = f.return;
        }
        if (Ct === null) throw Error(b(160));
        Ur(u, i, n), Ct = null, ze = !1, u = n.alternate, u !== null && (u.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Rr(e, t), e = e.sibling;
  }
  var el = null;
  function Rr(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Me(e, t), Ee(t), a & 4 && (fa(3, t, t.return), xu(3, t), fa(5, t, t.return));
        break;
      case 1:
        Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), a & 64 && Hl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = el;
        if (Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), a & 4) {
          var u = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      u = n.getElementsByTagName("title")[0], (!u || u[Aa] || u[Qt] || u.namespaceURI === "http://www.w3.org/2000/svg" || u.hasAttribute("itemprop")) && (u = n.createElement(a), n.head.insertBefore(
                        u,
                        n.querySelector("head > title")
                      )), ie(u, a, l), u[Qt] = t, Yt(u), a = u;
                      break t;
                    case "link":
                      var i = Rd(
                        "link",
                        "href",
                        n
                      ).get(a + (l.href || ""));
                      if (i) {
                        for (var f = 0; f < i.length; f++)
                          if (u = i[f], u.getAttribute("href") === (l.href == null || l.href === "" ? null : l.href) && u.getAttribute("rel") === (l.rel == null ? null : l.rel) && u.getAttribute("title") === (l.title == null ? null : l.title) && u.getAttribute("crossorigin") === (l.crossOrigin == null ? null : l.crossOrigin)) {
                            i.splice(f, 1);
                            break e;
                          }
                      }
                      u = n.createElement(a), ie(u, a, l), n.head.appendChild(u);
                      break;
                    case "meta":
                      if (i = Rd(
                        "meta",
                        "content",
                        n
                      ).get(a + (l.content || ""))) {
                        for (f = 0; f < i.length; f++)
                          if (u = i[f], u.getAttribute("content") === (l.content == null ? null : "" + l.content) && u.getAttribute("name") === (l.name == null ? null : l.name) && u.getAttribute("property") === (l.property == null ? null : l.property) && u.getAttribute("http-equiv") === (l.httpEquiv == null ? null : l.httpEquiv) && u.getAttribute("charset") === (l.charSet == null ? null : l.charSet)) {
                            i.splice(f, 1);
                            break e;
                          }
                      }
                      u = n.createElement(a), ie(u, a, l), n.head.appendChild(u);
                      break;
                    default:
                      throw Error(b(468, a));
                  }
                  u[Qt] = t, Yt(u), a = u;
                }
                t.stateNode = a;
              } else
                Nd(
                  n,
                  t.type,
                  t.stateNode
                );
            else
              t.stateNode = Bd(
                n,
                a,
                t.memoizedProps
              );
          else
            u !== a ? (u === null ? l.stateNode !== null && (l = l.stateNode, l.parentNode.removeChild(l)) : u.count--, a === null ? Nd(
              n,
              t.type,
              t.stateNode
            ) : Bd(
              n,
              a,
              t.memoizedProps
            )) : a === null && t.stateNode !== null && Dc(
              t,
              t.memoizedProps,
              l.memoizedProps
            );
        }
        break;
      case 27:
        Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), l !== null && a & 4 && Dc(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            y(n, "");
          } catch (j) {
            St(t, t.return, j);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Dc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Cc = !0);
        break;
      case 6:
        if (Me(e, t), Ee(t), a & 4) {
          if (t.stateNode === null)
            throw Error(b(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (j) {
            St(t, t.return, j);
          }
        }
        break;
      case 3:
        if (Pi = null, n = el, el = $i(e.containerInfo), Me(e, t), el = n, Ee(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            qn(e.containerInfo);
          } catch (j) {
            St(t, t.return, j);
          }
        Cc && (Cc = !1, Nr(t));
        break;
      case 4:
        a = el, el = $i(
          t.stateNode.containerInfo
        ), Me(e, t), Ee(t), el = a;
        break;
      case 12:
        Me(e, t), Ee(t);
        break;
      case 31:
        Me(e, t), Ee(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, ji(t, a)));
        break;
      case 13:
        Me(e, t), Ee(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Yi = le()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, ji(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var s = l !== null && l.memoizedState !== null, v = Hl, x = Jt;
        if (Hl = v || n, Jt = x || s, Me(e, t), Jt = x, Hl = v, Ee(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || s || Hl || Jt || Fa(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                s = l = e;
                try {
                  if (u = s.stateNode, n)
                    i = u.style, typeof i.setProperty == "function" ? i.setProperty("display", "none", "important") : i.display = "none";
                  else {
                    f = s.stateNode;
                    var E = s.memoizedProps.style, p = E != null && E.hasOwnProperty("display") ? E.display : null;
                    f.style.display = p == null || typeof p == "boolean" ? "" : ("" + p).trim();
                  }
                } catch (j) {
                  St(s, s.return, j);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                s = e;
                try {
                  s.stateNode.nodeValue = n ? "" : s.memoizedProps;
                } catch (j) {
                  St(s, s.return, j);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                s = e;
                try {
                  var S = s.stateNode;
                  n ? zd(S, !0) : zd(s.stateNode, !1);
                } catch (j) {
                  St(s, s.return, j);
                }
              }
            } else if ((e.tag !== 22 && e.tag !== 23 || e.memoizedState === null || e === t) && e.child !== null) {
              e.child.return = e, e = e.child;
              continue;
            }
            if (e === t) break t;
            for (; e.sibling === null; ) {
              if (e.return === null || e.return === t) break t;
              l === e && (l = null), e = e.return;
            }
            l === e && (l = null), e.sibling.return = e.return, e = e.sibling;
          }
        a & 4 && (a = t.updateQueue, a !== null && (l = a.retryQueue, l !== null && (a.retryQueue = null, ji(t, l))));
        break;
      case 19:
        Me(e, t), Ee(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, ji(t, a)));
        break;
      case 30:
        break;
      case 21:
        break;
      default:
        Me(e, t), Ee(t);
    }
  }
  function Ee(t) {
    var e = t.flags;
    if (e & 2) {
      try {
        for (var l, a = t.return; a !== null; ) {
          if (Er(a)) {
            l = a;
            break;
          }
          a = a.return;
        }
        if (l == null) throw Error(b(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, u = Oc(t);
            qi(t, u, n);
            break;
          case 5:
            var i = l.stateNode;
            l.flags & 32 && (y(i, ""), l.flags &= -33);
            var f = Oc(t);
            qi(t, f, i);
            break;
          case 3:
          case 4:
            var s = l.stateNode.containerInfo, v = Oc(t);
            Uc(
              t,
              v,
              s
            );
            break;
          default:
            throw Error(b(161));
        }
      } catch (x) {
        St(t, t.return, x);
      }
      t.flags &= -3;
    }
    e & 4096 && (t.flags &= -4097);
  }
  function Nr(t) {
    if (t.subtreeFlags & 1024)
      for (t = t.child; t !== null; ) {
        var e = t;
        Nr(e), e.tag === 5 && e.flags & 1024 && e.stateNode.reset(), t = t.sibling;
      }
  }
  function jl(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        Dr(t, e.alternate, e), e = e.sibling;
  }
  function Fa(t) {
    for (t = t.child; t !== null; ) {
      var e = t;
      switch (e.tag) {
        case 0:
        case 11:
        case 14:
        case 15:
          fa(4, e, e.return), Fa(e);
          break;
        case 1:
          ml(e, e.return);
          var l = e.stateNode;
          typeof l.componentWillUnmount == "function" && zr(
            e,
            e.return,
            l
          ), Fa(e);
          break;
        case 27:
          Cu(e.stateNode);
        case 26:
        case 5:
          ml(e, e.return), Fa(e);
          break;
        case 22:
          e.memoizedState === null && Fa(e);
          break;
        case 30:
          Fa(e);
          break;
        default:
          Fa(e);
      }
      t = t.sibling;
    }
  }
  function wl(t, e, l) {
    for (l = l && (e.subtreeFlags & 8772) !== 0, e = e.child; e !== null; ) {
      var a = e.alternate, n = t, u = e, i = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          wl(
            n,
            u,
            l
          ), xu(4, u);
          break;
        case 1:
          if (wl(
            n,
            u,
            l
          ), a = u, n = a.stateNode, typeof n.componentDidMount == "function")
            try {
              n.componentDidMount();
            } catch (v) {
              St(a, a.return, v);
            }
          if (a = u, n = a.updateQueue, n !== null) {
            var f = a.stateNode;
            try {
              var s = n.shared.hiddenCallbacks;
              if (s !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < s.length; n++)
                  rs(s[n], f);
            } catch (v) {
              St(a, a.return, v);
            }
          }
          l && i & 64 && Tr(u), Tu(u, u.return);
          break;
        case 27:
          Ar(u);
        case 26:
        case 5:
          wl(
            n,
            u,
            l
          ), l && a === null && i & 4 && Mr(u), Tu(u, u.return);
          break;
        case 12:
          wl(
            n,
            u,
            l
          );
          break;
        case 31:
          wl(
            n,
            u,
            l
          ), l && i & 4 && Cr(n, u);
          break;
        case 13:
          wl(
            n,
            u,
            l
          ), l && i & 4 && Br(n, u);
          break;
        case 22:
          u.memoizedState === null && wl(
            n,
            u,
            l
          ), Tu(u, u.return);
          break;
        case 30:
          break;
        default:
          wl(
            n,
            u,
            l
          );
      }
      e = e.sibling;
    }
  }
  function Bc(t, e) {
    var l = null;
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && cu(l));
  }
  function Rc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && cu(t));
  }
  function ll(t, e, l, a) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; )
        Hr(
          t,
          e,
          l,
          a
        ), e = e.sibling;
  }
  function Hr(t, e, l, a) {
    var n = e.flags;
    switch (e.tag) {
      case 0:
      case 11:
      case 15:
        ll(
          t,
          e,
          l,
          a
        ), n & 2048 && xu(9, e);
        break;
      case 1:
        ll(
          t,
          e,
          l,
          a
        );
        break;
      case 3:
        ll(
          t,
          e,
          l,
          a
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && cu(t)));
        break;
      case 12:
        if (n & 2048) {
          ll(
            t,
            e,
            l,
            a
          ), t = e.stateNode;
          try {
            var u = e.memoizedProps, i = u.id, f = u.onPostCommit;
            typeof f == "function" && f(
              i,
              e.alternate === null ? "mount" : "update",
              t.passiveEffectDuration,
              -0
            );
          } catch (s) {
            St(e, e.return, s);
          }
        } else
          ll(
            t,
            e,
            l,
            a
          );
        break;
      case 31:
        ll(
          t,
          e,
          l,
          a
        );
        break;
      case 13:
        ll(
          t,
          e,
          l,
          a
        );
        break;
      case 23:
        break;
      case 22:
        u = e.stateNode, i = e.alternate, e.memoizedState !== null ? u._visibility & 2 ? ll(
          t,
          e,
          l,
          a
        ) : zu(t, e) : u._visibility & 2 ? ll(
          t,
          e,
          l,
          a
        ) : (u._visibility |= 2, En(
          t,
          e,
          l,
          a,
          (e.subtreeFlags & 10256) !== 0 || !1
        )), n & 2048 && Bc(i, e);
        break;
      case 24:
        ll(
          t,
          e,
          l,
          a
        ), n & 2048 && Rc(e.alternate, e);
        break;
      default:
        ll(
          t,
          e,
          l,
          a
        );
    }
  }
  function En(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var u = t, i = e, f = l, s = a, v = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          En(
            u,
            i,
            f,
            s,
            n
          ), xu(8, i);
          break;
        case 23:
          break;
        case 22:
          var x = i.stateNode;
          i.memoizedState !== null ? x._visibility & 2 ? En(
            u,
            i,
            f,
            s,
            n
          ) : zu(
            u,
            i
          ) : (x._visibility |= 2, En(
            u,
            i,
            f,
            s,
            n
          )), n && v & 2048 && Bc(
            i.alternate,
            i
          );
          break;
        case 24:
          En(
            u,
            i,
            f,
            s,
            n
          ), n && v & 2048 && Rc(i.alternate, i);
          break;
        default:
          En(
            u,
            i,
            f,
            s,
            n
          );
      }
      e = e.sibling;
    }
  }
  function zu(t, e) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; ) {
        var l = t, a = e, n = a.flags;
        switch (a.tag) {
          case 22:
            zu(l, a), n & 2048 && Bc(
              a.alternate,
              a
            );
            break;
          case 24:
            zu(l, a), n & 2048 && Rc(a.alternate, a);
            break;
          default:
            zu(l, a);
        }
        e = e.sibling;
      }
  }
  var Mu = 8192;
  function An(t, e, l) {
    if (t.subtreeFlags & Mu)
      for (t = t.child; t !== null; )
        qr(
          t,
          e,
          l
        ), t = t.sibling;
  }
  function qr(t, e, l) {
    switch (t.tag) {
      case 26:
        An(
          t,
          e,
          l
        ), t.flags & Mu && t.memoizedState !== null && Yh(
          l,
          el,
          t.memoizedState,
          t.memoizedProps
        );
        break;
      case 5:
        An(
          t,
          e,
          l
        );
        break;
      case 3:
      case 4:
        var a = el;
        el = $i(t.stateNode.containerInfo), An(
          t,
          e,
          l
        ), el = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = Mu, Mu = 16777216, An(
          t,
          e,
          l
        ), Mu = a) : An(
          t,
          e,
          l
        ));
        break;
      default:
        An(
          t,
          e,
          l
        );
    }
  }
  function jr(t) {
    var e = t.alternate;
    if (e !== null && (t = e.child, t !== null)) {
      e.child = null;
      do
        e = t.sibling, t.sibling = null, t = e;
      while (t !== null);
    }
  }
  function Eu(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          It = a, Yr(
            a,
            t
          );
        }
      jr(t);
    }
    if (t.subtreeFlags & 10256)
      for (t = t.child; t !== null; )
        wr(t), t = t.sibling;
  }
  function wr(t) {
    switch (t.tag) {
      case 0:
      case 11:
      case 15:
        Eu(t), t.flags & 2048 && fa(9, t, t.return);
        break;
      case 3:
        Eu(t);
        break;
      case 12:
        Eu(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, wi(t)) : Eu(t);
        break;
      default:
        Eu(t);
    }
  }
  function wi(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          It = a, Yr(
            a,
            t
          );
        }
      jr(t);
    }
    for (t = t.child; t !== null; ) {
      switch (e = t, e.tag) {
        case 0:
        case 11:
        case 15:
          fa(8, e, e.return), wi(e);
          break;
        case 22:
          l = e.stateNode, l._visibility & 2 && (l._visibility &= -3, wi(e));
          break;
        default:
          wi(e);
      }
      t = t.sibling;
    }
  }
  function Yr(t, e) {
    for (; It !== null; ) {
      var l = It;
      switch (l.tag) {
        case 0:
        case 11:
        case 15:
          fa(8, l, e);
          break;
        case 23:
        case 22:
          if (l.memoizedState !== null && l.memoizedState.cachePool !== null) {
            var a = l.memoizedState.cachePool.pool;
            a != null && a.refCount++;
          }
          break;
        case 24:
          cu(l.memoizedState.cache);
      }
      if (a = l.child, a !== null) a.return = l, It = a;
      else
        t: for (l = t; It !== null; ) {
          a = It;
          var n = a.sibling, u = a.return;
          if (Or(a), a === l) {
            It = null;
            break t;
          }
          if (n !== null) {
            n.return = u, It = n;
            break t;
          }
          It = u;
        }
    }
  }
  var th = {
    getCacheForType: function(t) {
      var e = ne(Vt), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return ne(Vt).controller.signal;
    }
  }, eh = typeof WeakMap == "function" ? WeakMap : Map, gt = 0, Mt = null, at = null, ut = 0, bt = 0, qe = null, ca = !1, _n = !1, Nc = !1, Yl = 0, jt = 0, oa = 0, Wa = 0, Hc = 0, je = 0, Dn = 0, Au = null, Ae = null, qc = !1, Yi = 0, Gr = 0, Gi = 1 / 0, Li = null, sa = null, Wt = 0, ra = null, On = null, Gl = 0, jc = 0, wc = null, Lr = null, _u = 0, Yc = null;
  function we() {
    return (gt & 2) !== 0 && ut !== 0 ? ut & -ut : m.T !== null ? Zc() : tn();
  }
  function Xr() {
    if (je === 0)
      if ((ut & 536870912) === 0 || ft) {
        var t = Ia;
        Ia <<= 1, (Ia & 3932160) === 0 && (Ia = 262144), je = t;
      } else je = 536870912;
    return t = Ne.current, t !== null && (t.flags |= 32), je;
  }
  function _e(t, e, l) {
    (t === Mt && (bt === 2 || bt === 9) || t.cancelPendingCommit !== null) && (Un(t, 0), da(
      t,
      ut,
      je,
      !1
    )), Ql(t, l), ((gt & 2) === 0 || t !== Mt) && (t === Mt && ((gt & 2) === 0 && (Wa |= l), jt === 4 && da(
      t,
      ut,
      je,
      !1
    )), hl(t));
  }
  function Qr(t, e, l) {
    if ((gt & 6) !== 0) throw Error(b(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Xl(t, e), n = a ? nh(t, e) : Lc(t, e, !0), u = a;
    do {
      if (n === 0) {
        _n && !a && da(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, u && !lh(l)) {
          n = Lc(t, e, !1), u = !1;
          continue;
        }
        if (n === 2) {
          if (u = e, t.errorRecoveryDisabledLanes & u)
            var i = 0;
          else
            i = t.pendingLanes & -536870913, i = i !== 0 ? i : i & 536870912 ? 536870912 : 0;
          if (i !== 0) {
            e = i;
            t: {
              var f = t;
              n = Au;
              var s = f.current.memoizedState.isDehydrated;
              if (s && (Un(f, i).flags |= 256), i = Lc(
                f,
                i,
                !1
              ), i !== 2) {
                if (Nc && !s) {
                  f.errorRecoveryDisabledLanes |= u, Wa |= u, n = 4;
                  break t;
                }
                u = Ae, Ae = n, u !== null && (Ae === null ? Ae = u : Ae.push.apply(
                  Ae,
                  u
                ));
              }
              n = i;
            }
            if (u = !1, n !== 2) continue;
          }
        }
        if (n === 1) {
          Un(t, 0), da(t, e, 0, !0);
          break;
        }
        t: {
          switch (a = t, u = n, u) {
            case 0:
            case 1:
              throw Error(b(345));
            case 4:
              if ((e & 4194048) !== e) break;
            case 6:
              da(
                a,
                e,
                je,
                !ca
              );
              break t;
            case 2:
              Ae = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(b(329));
          }
          if ((e & 62914560) === e && (n = Yi + 300 - le(), 10 < n)) {
            if (da(
              a,
              e,
              je,
              !ca
            ), Pa(a, 0, !0) !== 0) break t;
            Gl = e, a.timeoutHandle = Sd(
              Vr.bind(
                null,
                a,
                l,
                Ae,
                Li,
                qc,
                e,
                je,
                Wa,
                Dn,
                ca,
                u,
                "Throttled",
                -0,
                0
              ),
              n
            );
            break t;
          }
          Vr(
            a,
            l,
            Ae,
            Li,
            qc,
            e,
            je,
            Wa,
            Dn,
            ca,
            u,
            null,
            -0,
            0
          );
        }
      }
      break;
    } while (!0);
    hl(t);
  }
  function Vr(t, e, l, a, n, u, i, f, s, v, x, E, p, S) {
    if (t.timeoutHandle = -1, E = e.subtreeFlags, E & 8192 || (E & 16785408) === 16785408) {
      E = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: de
      }, qr(
        e,
        u,
        E
      );
      var j = (u & 62914560) === u ? Yi - le() : (u & 4194048) === u ? Gr - le() : 0;
      if (j = Gh(
        E,
        j
      ), j !== null) {
        Gl = u, t.cancelPendingCommit = j(
          Ir.bind(
            null,
            t,
            e,
            u,
            l,
            a,
            n,
            i,
            f,
            s,
            x,
            E,
            null,
            p,
            S
          )
        ), da(t, u, i, !v);
        return;
      }
    }
    Ir(
      t,
      e,
      u,
      l,
      a,
      n,
      i,
      f,
      s
    );
  }
  function lh(t) {
    for (var e = t; ; ) {
      var l = e.tag;
      if ((l === 0 || l === 11 || l === 15) && e.flags & 16384 && (l = e.updateQueue, l !== null && (l = l.stores, l !== null)))
        for (var a = 0; a < l.length; a++) {
          var n = l[a], u = n.getSnapshot;
          n = n.value;
          try {
            if (!Be(u(), n)) return !1;
          } catch {
            return !1;
          }
        }
      if (l = e.child, e.subtreeFlags & 16384 && l !== null)
        l.return = e, e = l;
      else {
        if (e === t) break;
        for (; e.sibling === null; ) {
          if (e.return === null || e.return === t) return !0;
          e = e.return;
        }
        e.sibling.return = e.return, e = e.sibling;
      }
    }
    return !0;
  }
  function da(t, e, l, a) {
    e &= ~Hc, e &= ~Wa, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var u = 31 - ge(n), i = 1 << u;
      a[u] = -1, n &= ~i;
    }
    l !== 0 && Ma(t, l, e);
  }
  function Xi() {
    return (gt & 6) === 0 ? (Du(0), !1) : !0;
  }
  function Gc() {
    if (at !== null) {
      if (bt === 0)
        var t = at.return;
      else
        t = at, Ol = La = null, lc(t), Sn = null, su = 0, t = at;
      for (; t !== null; )
        xr(t.alternate, t), t = t.return;
      at = null;
    }
  }
  function Un(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Th(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), Gl = 0, Gc(), Mt = t, at = l = _l(t.current, null), ut = e, bt = 0, qe = null, ca = !1, _n = Xl(t, e), Nc = !1, Dn = je = Hc = Wa = oa = jt = 0, Ae = Au = null, qc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - ge(a), u = 1 << n;
        e |= t[n], a &= ~u;
      }
    return Yl = e, oi(), l;
  }
  function Zr(t, e) {
    I = null, m.H = pu, e === bn || e === vi ? (e = fs(), bt = 3) : e === Vf ? (e = fs(), bt = 4) : bt = e === pc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, qe = e, at === null && (jt = 1, Ci(
      t,
      Ze(e, t.current)
    ));
  }
  function Kr() {
    var t = Ne.current;
    return t === null ? !0 : (ut & 4194048) === ut ? Fe === null : (ut & 62914560) === ut || (ut & 536870912) !== 0 ? t === Fe : !1;
  }
  function Jr() {
    var t = m.H;
    return m.H = pu, t === null ? pu : t;
  }
  function kr() {
    var t = m.A;
    return m.A = th, t;
  }
  function Qi() {
    jt = 4, ca || (ut & 4194048) !== ut && Ne.current !== null || (_n = !0), (oa & 134217727) === 0 && (Wa & 134217727) === 0 || Mt === null || da(
      Mt,
      ut,
      je,
      !1
    );
  }
  function Lc(t, e, l) {
    var a = gt;
    gt |= 2;
    var n = Jr(), u = kr();
    (Mt !== t || ut !== e) && (Li = null, Un(t, e)), e = !1;
    var i = jt;
    t: do
      try {
        if (bt !== 0 && at !== null) {
          var f = at, s = qe;
          switch (bt) {
            case 8:
              Gc(), i = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              Ne.current === null && (e = !0);
              var v = bt;
              if (bt = 0, qe = null, Cn(t, f, s, v), l && _n) {
                i = 0;
                break t;
              }
              break;
            default:
              v = bt, bt = 0, qe = null, Cn(t, f, s, v);
          }
        }
        ah(), i = jt;
        break;
      } catch (x) {
        Zr(t, x);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Ol = La = null, gt = a, m.H = n, m.A = u, at === null && (Mt = null, ut = 0, oi()), i;
  }
  function ah() {
    for (; at !== null; ) Fr(at);
  }
  function nh(t, e) {
    var l = gt;
    gt |= 2;
    var a = Jr(), n = kr();
    Mt !== t || ut !== e ? (Li = null, Gi = le() + 500, Un(t, e)) : _n = Xl(
      t,
      e
    );
    t: do
      try {
        if (bt !== 0 && at !== null) {
          e = at;
          var u = qe;
          e: switch (bt) {
            case 1:
              bt = 0, qe = null, Cn(t, e, u, 1);
              break;
            case 2:
            case 9:
              if (us(u)) {
                bt = 0, qe = null, Wr(e);
                break;
              }
              e = function() {
                bt !== 2 && bt !== 9 || Mt !== t || (bt = 7), hl(t);
              }, u.then(e, e);
              break t;
            case 3:
              bt = 7;
              break t;
            case 4:
              bt = 5;
              break t;
            case 7:
              us(u) ? (bt = 0, qe = null, Wr(e)) : (bt = 0, qe = null, Cn(t, e, u, 7));
              break;
            case 5:
              var i = null;
              switch (at.tag) {
                case 26:
                  i = at.memoizedState;
                case 5:
                case 27:
                  var f = at;
                  if (i ? Hd(i) : f.stateNode.complete) {
                    bt = 0, qe = null;
                    var s = f.sibling;
                    if (s !== null) at = s;
                    else {
                      var v = f.return;
                      v !== null ? (at = v, Vi(v)) : at = null;
                    }
                    break e;
                  }
              }
              bt = 0, qe = null, Cn(t, e, u, 5);
              break;
            case 6:
              bt = 0, qe = null, Cn(t, e, u, 6);
              break;
            case 8:
              Gc(), jt = 6;
              break t;
            default:
              throw Error(b(462));
          }
        }
        uh();
        break;
      } catch (x) {
        Zr(t, x);
      }
    while (!0);
    return Ol = La = null, m.H = a, m.A = n, gt = l, at !== null ? 0 : (Mt = null, ut = 0, oi(), jt);
  }
  function uh() {
    for (; at !== null && !Ln(); )
      Fr(at);
  }
  function Fr(t) {
    var e = br(t.alternate, t, Yl);
    t.memoizedProps = t.pendingProps, e === null ? Vi(t) : at = e;
  }
  function Wr(t) {
    var e = t, l = e.alternate;
    switch (e.tag) {
      case 15:
      case 0:
        e = mr(
          l,
          e,
          e.pendingProps,
          e.type,
          void 0,
          ut
        );
        break;
      case 11:
        e = mr(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          ut
        );
        break;
      case 5:
        lc(e);
      default:
        xr(l, e), e = at = ko(e, Yl), e = br(l, e, Yl);
    }
    t.memoizedProps = t.pendingProps, e === null ? Vi(t) : at = e;
  }
  function Cn(t, e, l, a) {
    Ol = La = null, lc(e), Sn = null, su = 0;
    var n = e.return;
    try {
      if (Jm(
        t,
        n,
        e,
        l,
        ut
      )) {
        jt = 1, Ci(
          t,
          Ze(l, t.current)
        ), at = null;
        return;
      }
    } catch (u) {
      if (n !== null) throw at = n, u;
      jt = 1, Ci(
        t,
        Ze(l, t.current)
      ), at = null;
      return;
    }
    e.flags & 32768 ? (ft || a === 1 ? t = !0 : _n || (ut & 536870912) !== 0 ? t = !1 : (ca = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = Ne.current, a !== null && a.tag === 13 && (a.flags |= 16384))), $r(e, t)) : Vi(e);
  }
  function Vi(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        $r(
          e,
          ca
        );
        return;
      }
      t = e.return;
      var l = Wm(
        e.alternate,
        e,
        Yl
      );
      if (l !== null) {
        at = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        at = e;
        return;
      }
      at = e = t;
    } while (e !== null);
    jt === 0 && (jt = 5);
  }
  function $r(t, e) {
    do {
      var l = $m(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, at = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        at = t;
        return;
      }
      at = t = l;
    } while (t !== null);
    jt = 6, at = null;
  }
  function Ir(t, e, l, a, n, u, i, f, s) {
    t.cancelPendingCommit = null;
    do
      Zi();
    while (Wt !== 0);
    if ((gt & 6) !== 0) throw Error(b(327));
    if (e !== null) {
      if (e === t.current) throw Error(b(177));
      if (u = e.lanes | e.childLanes, u |= Of, gf(
        t,
        l,
        u,
        i,
        f,
        s
      ), t === Mt && (at = Mt = null, ut = 0), On = e, ra = t, Gl = l, jc = u, wc = n, Lr = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, oh(xa, function() {
        return ad(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = m.T, m.T = null, n = D.p, D.p = 2, i = gt, gt |= 4;
        try {
          Im(t, e, l);
        } finally {
          gt = i, D.p = n, m.T = a;
        }
      }
      Wt = 1, Pr(), td(), ed();
    }
  }
  function Pr() {
    if (Wt === 1) {
      Wt = 0;
      var t = ra, e = On, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = m.T, m.T = null;
        var a = D.p;
        D.p = 2;
        var n = gt;
        gt |= 4;
        try {
          Rr(e, t);
          var u = Pc, i = Yo(t.containerInfo), f = u.focusedElem, s = u.selectionRange;
          if (i !== f && f && f.ownerDocument && wo(
            f.ownerDocument.documentElement,
            f
          )) {
            if (s !== null && Mf(f)) {
              var v = s.start, x = s.end;
              if (x === void 0 && (x = v), "selectionStart" in f)
                f.selectionStart = v, f.selectionEnd = Math.min(
                  x,
                  f.value.length
                );
              else {
                var E = f.ownerDocument || document, p = E && E.defaultView || window;
                if (p.getSelection) {
                  var S = p.getSelection(), j = f.textContent.length, V = Math.min(s.start, j), zt = s.end === void 0 ? V : Math.min(s.end, j);
                  !S.extend && V > zt && (i = zt, zt = V, V = i);
                  var h = jo(
                    f,
                    V
                  ), d = jo(
                    f,
                    zt
                  );
                  if (h && d && (S.rangeCount !== 1 || S.anchorNode !== h.node || S.anchorOffset !== h.offset || S.focusNode !== d.node || S.focusOffset !== d.offset)) {
                    var g = E.createRange();
                    g.setStart(h.node, h.offset), S.removeAllRanges(), V > zt ? (S.addRange(g), S.extend(d.node, d.offset)) : (g.setEnd(d.node, d.offset), S.addRange(g));
                  }
                }
              }
            }
            for (E = [], S = f; S = S.parentNode; )
              S.nodeType === 1 && E.push({
                element: S,
                left: S.scrollLeft,
                top: S.scrollTop
              });
            for (typeof f.focus == "function" && f.focus(), f = 0; f < E.length; f++) {
              var z = E[f];
              z.element.scrollLeft = z.left, z.element.scrollTop = z.top;
            }
          }
          af = !!Ic, Pc = Ic = null;
        } finally {
          gt = n, D.p = a, m.T = l;
        }
      }
      t.current = e, Wt = 2;
    }
  }
  function td() {
    if (Wt === 2) {
      Wt = 0;
      var t = ra, e = On, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = m.T, m.T = null;
        var a = D.p;
        D.p = 2;
        var n = gt;
        gt |= 4;
        try {
          Dr(t, e.alternate, e);
        } finally {
          gt = n, D.p = a, m.T = l;
        }
      }
      Wt = 3;
    }
  }
  function ed() {
    if (Wt === 4 || Wt === 3) {
      Wt = 0, Lu();
      var t = ra, e = On, l = Gl, a = Lr;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? Wt = 5 : (Wt = 0, On = ra = null, ld(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (sa = null), Ea(l), e = e.stateNode, ye && typeof ye.onCommitFiberRoot == "function")
        try {
          ye.onCommitFiberRoot(
            Ta,
            e,
            void 0,
            (e.current.flags & 128) === 128
          );
        } catch {
        }
      if (a !== null) {
        e = m.T, n = D.p, D.p = 2, m.T = null;
        try {
          for (var u = t.onRecoverableError, i = 0; i < a.length; i++) {
            var f = a[i];
            u(f.value, {
              componentStack: f.stack
            });
          }
        } finally {
          m.T = e, D.p = n;
        }
      }
      (Gl & 3) !== 0 && Zi(), hl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Yc ? _u++ : (_u = 0, Yc = t) : _u = 0, Du(0);
    }
  }
  function ld(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, cu(e)));
  }
  function Zi() {
    return Pr(), td(), ed(), ad();
  }
  function ad() {
    if (Wt !== 5) return !1;
    var t = ra, e = jc;
    jc = 0;
    var l = Ea(Gl), a = m.T, n = D.p;
    try {
      D.p = 32 > l ? 32 : l, m.T = null, l = wc, wc = null;
      var u = ra, i = Gl;
      if (Wt = 0, On = ra = null, Gl = 0, (gt & 6) !== 0) throw Error(b(331));
      var f = gt;
      if (gt |= 4, wr(u.current), Hr(
        u,
        u.current,
        i,
        l
      ), gt = f, Du(0, !1), ye && typeof ye.onPostCommitFiberRoot == "function")
        try {
          ye.onPostCommitFiberRoot(Ta, u);
        } catch {
        }
      return !0;
    } finally {
      D.p = n, m.T = a, ld(t, e);
    }
  }
  function nd(t, e, l) {
    e = Ze(l, e), e = vc(t.stateNode, e, 2), t = na(t, e, 2), t !== null && (Ql(t, 2), hl(t));
  }
  function St(t, e, l) {
    if (t.tag === 3)
      nd(t, t, l);
    else
      for (; e !== null; ) {
        if (e.tag === 3) {
          nd(
            e,
            t,
            l
          );
          break;
        } else if (e.tag === 1) {
          var a = e.stateNode;
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (sa === null || !sa.has(a))) {
            t = Ze(l, t), l = ur(2), a = na(e, l, 2), a !== null && (ir(
              l,
              a,
              e,
              t
            ), Ql(a, 2), hl(a));
            break;
          }
        }
        e = e.return;
      }
  }
  function Xc(t, e, l) {
    var a = t.pingCache;
    if (a === null) {
      a = t.pingCache = new eh();
      var n = /* @__PURE__ */ new Set();
      a.set(e, n);
    } else
      n = a.get(e), n === void 0 && (n = /* @__PURE__ */ new Set(), a.set(e, n));
    n.has(l) || (Nc = !0, n.add(l), t = ih.bind(null, t, e, l), e.then(t, t));
  }
  function ih(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, Mt === t && (ut & l) === l && (jt === 4 || jt === 3 && (ut & 62914560) === ut && 300 > le() - Yi ? (gt & 2) === 0 && Un(t, 0) : Hc |= l, Dn === ut && (Dn = 0)), hl(t);
  }
  function ud(t, e) {
    e === 0 && (e = ku()), t = wa(t, e), t !== null && (Ql(t, e), hl(t));
  }
  function fh(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), ud(t, l);
  }
  function ch(t, e) {
    var l = 0;
    switch (t.tag) {
      case 31:
      case 13:
        var a = t.stateNode, n = t.memoizedState;
        n !== null && (l = n.retryLane);
        break;
      case 19:
        a = t.stateNode;
        break;
      case 22:
        a = t.stateNode._retryCache;
        break;
      default:
        throw Error(b(314));
    }
    a !== null && a.delete(e), ud(t, l);
  }
  function oh(t, e) {
    return Gn(t, e);
  }
  var Ki = null, Bn = null, Qc = !1, Ji = !1, Vc = !1, ma = 0;
  function hl(t) {
    t !== Bn && t.next === null && (Bn === null ? Ki = Bn = t : Bn = Bn.next = t), Ji = !0, Qc || (Qc = !0, rh());
  }
  function Du(t, e) {
    if (!Vc && Ji) {
      Vc = !0;
      do
        for (var l = !1, a = Ki; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var u = 0;
            else {
              var i = a.suspendedLanes, f = a.pingedLanes;
              u = (1 << 31 - ge(42 | t) + 1) - 1, u &= n & ~(i & ~f), u = u & 201326741 ? u & 201326741 | 1 : u ? u | 2 : 0;
            }
            u !== 0 && (l = !0, od(a, u));
          } else
            u = ut, u = Pa(
              a,
              a === Mt ? u : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (u & 3) === 0 || Xl(a, u) || (l = !0, od(a, u));
          a = a.next;
        }
      while (l);
      Vc = !1;
    }
  }
  function sh() {
    id();
  }
  function id() {
    Ji = Qc = !1;
    var t = 0;
    ma !== 0 && xh() && (t = ma);
    for (var e = le(), l = null, a = Ki; a !== null; ) {
      var n = a.next, u = fd(a, e);
      u === 0 ? (a.next = null, l === null ? Ki = n : l.next = n, n === null && (Bn = l)) : (l = a, (t !== 0 || (u & 3) !== 0) && (Ji = !0)), a = n;
    }
    Wt !== 0 && Wt !== 5 || Du(t), ma !== 0 && (ma = 0);
  }
  function fd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, u = t.pendingLanes & -62914561; 0 < u; ) {
      var i = 31 - ge(u), f = 1 << i, s = n[i];
      s === -1 ? ((f & l) === 0 || (f & a) !== 0) && (n[i] = Ju(f, e)) : s <= e && (t.expiredLanes |= f), u &= ~f;
    }
    if (e = Mt, l = ut, l = Pa(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (bt === 2 || bt === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && Sa(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Xl(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && Sa(a), Ea(l)) {
        case 2:
        case 8:
          l = $a;
          break;
        case 32:
          l = xa;
          break;
        case 268435456:
          l = Vu;
          break;
        default:
          l = xa;
      }
      return a = cd.bind(null, t), l = Gn(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && Sa(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function cd(t, e) {
    if (Wt !== 0 && Wt !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Zi() && t.callbackNode !== l)
      return null;
    var a = ut;
    return a = Pa(
      t,
      t === Mt ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Qr(t, a, e), fd(t, le()), t.callbackNode != null && t.callbackNode === l ? cd.bind(null, t) : null);
  }
  function od(t, e) {
    if (Zi()) return null;
    Qr(t, e, !0);
  }
  function rh() {
    zh(function() {
      (gt & 6) !== 0 ? Gn(
        Qu,
        sh
      ) : id();
    });
  }
  function Zc() {
    if (ma === 0) {
      var t = vn;
      t === 0 && (t = vl, vl <<= 1, (vl & 261888) === 0 && (vl = 256)), ma = t;
    }
    return ma;
  }
  function sd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : ot("" + t);
  }
  function rd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function dh(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var u = sd(
        (n[re] || null).action
      ), i = a.submitter;
      i && (e = (e = i[re] || null) ? sd(e.formAction) : i.getAttribute("formAction"), e !== null && (u = e, i = null));
      var f = new El(
        "action",
        "action",
        null,
        a,
        n
      );
      t.push({
        event: f,
        listeners: [
          {
            instance: null,
            listener: function() {
              if (a.defaultPrevented) {
                if (ma !== 0) {
                  var s = i ? rd(n, i) : new FormData(n);
                  rc(
                    l,
                    {
                      pending: !0,
                      data: s,
                      method: n.method,
                      action: u
                    },
                    null,
                    s
                  );
                }
              } else
                typeof u == "function" && (f.preventDefault(), s = i ? rd(n, i) : new FormData(n), rc(
                  l,
                  {
                    pending: !0,
                    data: s,
                    method: n.method,
                    action: u
                  },
                  u,
                  s
                ));
            },
            currentTarget: n
          }
        ]
      });
    }
  }
  for (var Kc = 0; Kc < Df.length; Kc++) {
    var Jc = Df[Kc], mh = Jc.toLowerCase(), hh = Jc[0].toUpperCase() + Jc.slice(1);
    tl(
      mh,
      "on" + hh
    );
  }
  tl(Xo, "onAnimationEnd"), tl(Qo, "onAnimationIteration"), tl(Vo, "onAnimationStart"), tl("dblclick", "onDoubleClick"), tl("focusin", "onFocus"), tl("focusout", "onBlur"), tl(Um, "onTransitionRun"), tl(Cm, "onTransitionStart"), tl(Bm, "onTransitionCancel"), tl(Zo, "onTransitionEnd"), Zl("onMouseEnter", ["mouseout", "mouseover"]), Zl("onMouseLeave", ["mouseout", "mouseover"]), Zl("onPointerEnter", ["pointerout", "pointerover"]), Zl("onPointerLeave", ["pointerout", "pointerover"]), cl(
    "onChange",
    "change click focusin focusout input keydown keyup selectionchange".split(" ")
  ), cl(
    "onSelect",
    "focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(
      " "
    )
  ), cl("onBeforeInput", [
    "compositionend",
    "keypress",
    "textInput",
    "paste"
  ]), cl(
    "onCompositionEnd",
    "compositionend focusout keydown keypress keyup mousedown".split(" ")
  ), cl(
    "onCompositionStart",
    "compositionstart focusout keydown keypress keyup mousedown".split(" ")
  ), cl(
    "onCompositionUpdate",
    "compositionupdate focusout keydown keypress keyup mousedown".split(" ")
  );
  var Ou = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), yh = new Set(
    "beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(Ou)
  );
  function dd(t, e) {
    e = (e & 4) !== 0;
    for (var l = 0; l < t.length; l++) {
      var a = t[l], n = a.event;
      a = a.listeners;
      t: {
        var u = void 0;
        if (e)
          for (var i = a.length - 1; 0 <= i; i--) {
            var f = a[i], s = f.instance, v = f.currentTarget;
            if (f = f.listener, s !== u && n.isPropagationStopped())
              break t;
            u = f, n.currentTarget = v;
            try {
              u(n);
            } catch (x) {
              ci(x);
            }
            n.currentTarget = null, u = s;
          }
        else
          for (i = 0; i < a.length; i++) {
            if (f = a[i], s = f.instance, v = f.currentTarget, f = f.listener, s !== u && n.isPropagationStopped())
              break t;
            u = f, n.currentTarget = v;
            try {
              u(n);
            } catch (x) {
              ci(x);
            }
            n.currentTarget = null, u = s;
          }
      }
    }
  }
  function nt(t, e) {
    var l = e[en];
    l === void 0 && (l = e[en] = /* @__PURE__ */ new Set());
    var a = t + "__bubble";
    l.has(a) || (md(e, t, 2, !1), l.add(a));
  }
  function kc(t, e, l) {
    var a = 0;
    e && (a |= 4), md(
      l,
      t,
      a,
      e
    );
  }
  var ki = "_reactListening" + Math.random().toString(36).slice(2);
  function Fc(t) {
    if (!t[ki]) {
      t[ki] = !0, _a.forEach(function(l) {
        l !== "selectionchange" && (yh.has(l) || kc(l, !1, t), kc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[ki] || (e[ki] = !0, kc("selectionchange", !1, e));
    }
  }
  function md(t, e, l, a) {
    switch (Xd(e)) {
      case 2:
        var n = Qh;
        break;
      case 8:
        n = Vh;
        break;
      default:
        n = so;
    }
    l = n.bind(
      null,
      e,
      l,
      t
    ), n = void 0, !Wn || e !== "touchstart" && e !== "touchmove" && e !== "wheel" || (n = !0), a ? n !== void 0 ? t.addEventListener(e, l, {
      capture: !0,
      passive: n
    }) : t.addEventListener(e, l, !0) : n !== void 0 ? t.addEventListener(e, l, {
      passive: n
    }) : t.addEventListener(e, l, !1);
  }
  function Wc(t, e, l, a, n) {
    var u = a;
    if ((e & 1) === 0 && (e & 2) === 0 && a !== null)
      t: for (; ; ) {
        if (a === null) return;
        var i = a.tag;
        if (i === 3 || i === 4) {
          var f = a.stateNode.containerInfo;
          if (f === n) break;
          if (i === 4)
            for (i = a.return; i !== null; ) {
              var s = i.tag;
              if ((s === 3 || s === 4) && i.stateNode.containerInfo === n)
                return;
              i = i.return;
            }
          for (; f !== null; ) {
            if (i = xl(f), i === null) return;
            if (s = i.tag, s === 5 || s === 6 || s === 26 || s === 27) {
              a = u = i;
              continue t;
            }
            f = f.parentNode;
          }
        }
        a = a.return;
      }
    ai(function() {
      var v = u, x = Fn(l), E = [];
      t: {
        var p = Ko.get(t);
        if (p !== void 0) {
          var S = El, j = t;
          switch (t) {
            case "keypress":
              if (nn(l) === 0) break t;
            case "keydown":
            case "keyup":
              S = cm;
              break;
            case "focusin":
              j = "focus", S = T;
              break;
            case "focusout":
              j = "blur", S = T;
              break;
            case "beforeblur":
            case "afterblur":
              S = T;
              break;
            case "click":
              if (l.button === 2) break t;
            case "auxclick":
            case "dblclick":
            case "mousedown":
            case "mousemove":
            case "mouseup":
            case "mouseout":
            case "mouseover":
            case "contextmenu":
              S = Al;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              S = ui;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              S = rm;
              break;
            case Xo:
            case Qo:
            case Vo:
              S = Z;
              break;
            case Zo:
              S = mm;
              break;
            case "scroll":
            case "scrollend":
              S = Sf;
              break;
            case "wheel":
              S = ym;
              break;
            case "copy":
            case "cut":
            case "paste":
              S = dt;
              break;
            case "gotpointercapture":
            case "lostpointercapture":
            case "pointercancel":
            case "pointerdown":
            case "pointermove":
            case "pointerout":
            case "pointerover":
            case "pointerup":
              S = zo;
              break;
            case "toggle":
            case "beforetoggle":
              S = vm;
          }
          var V = (e & 4) !== 0, zt = !V && (t === "scroll" || t === "scrollend"), h = V ? p !== null ? p + "Capture" : null : p;
          V = [];
          for (var d = v, g; d !== null; ) {
            var z = d;
            if (g = z.stateNode, z = z.tag, z !== 5 && z !== 26 && z !== 27 || g === null || h === null || (z = Ml(d, h), z != null && V.push(
              Uu(d, z, g)
            )), zt) break;
            d = d.return;
          }
          0 < V.length && (p = new S(
            p,
            j,
            null,
            l,
            x
          ), E.push({ event: p, listeners: V }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (p = t === "mouseover" || t === "pointerover", S = t === "mouseout" || t === "pointerout", p && l !== kn && (j = l.relatedTarget || l.fromElement) && (xl(j) || j[Sl]))
            break t;
          if ((S || p) && (p = x.window === x ? x : (p = x.ownerDocument) ? p.defaultView || p.parentWindow : window, S ? (j = l.relatedTarget || l.toElement, S = v, j = j ? xl(j) : null, j !== null && (zt = wt(j), V = j.tag, j !== zt || V !== 5 && V !== 27 && V !== 6) && (j = null)) : (S = null, j = v), S !== j)) {
            if (V = Al, z = "onMouseLeave", h = "onMouseEnter", d = "mouse", (t === "pointerout" || t === "pointerover") && (V = zo, z = "onPointerLeave", h = "onPointerEnter", d = "pointer"), zt = S == null ? p : Tl(S), g = j == null ? p : Tl(j), p = new V(
              z,
              d + "leave",
              S,
              l,
              x
            ), p.target = zt, p.relatedTarget = g, z = null, xl(x) === v && (V = new V(
              h,
              d + "enter",
              j,
              l,
              x
            ), V.target = g, V.relatedTarget = zt, z = V), zt = z, S && j)
              e: {
                for (V = gh, h = S, d = j, g = 0, z = h; z; z = V(z))
                  g++;
                z = 0;
                for (var X = d; X; X = V(X))
                  z++;
                for (; 0 < g - z; )
                  h = V(h), g--;
                for (; 0 < z - g; )
                  d = V(d), z--;
                for (; g--; ) {
                  if (h === d || d !== null && h === d.alternate) {
                    V = h;
                    break e;
                  }
                  h = V(h), d = V(d);
                }
                V = null;
              }
            else V = null;
            S !== null && hd(
              E,
              p,
              S,
              V,
              !1
            ), j !== null && zt !== null && hd(
              E,
              zt,
              j,
              V,
              !0
            );
          }
        }
        t: {
          if (p = v ? Tl(v) : window, S = p.nodeName && p.nodeName.toLowerCase(), S === "select" || S === "input" && p.type === "file")
            var ht = Co;
          else if (Oo(p))
            if (Bo)
              ht = _m;
            else {
              ht = Em;
              var w = Mm;
            }
          else
            S = p.nodeName, !S || S.toLowerCase() !== "input" || p.type !== "checkbox" && p.type !== "radio" ? v && N(v.elementType) && (ht = Co) : ht = Am;
          if (ht && (ht = ht(t, v))) {
            Uo(
              E,
              ht,
              l,
              x
            );
            break t;
          }
          w && w(t, p, v), t === "focusout" && v && p.type === "number" && v.memoizedProps.value != null && Jn(p, "number", p.value);
        }
        switch (w = v ? Tl(v) : window, t) {
          case "focusin":
            (Oo(w) || w.contentEditable === "true") && (on = w, Ef = v, uu = null);
            break;
          case "focusout":
            uu = Ef = on = null;
            break;
          case "mousedown":
            Af = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Af = !1, Go(E, l, x);
            break;
          case "selectionchange":
            if (Om) break;
          case "keydown":
          case "keyup":
            Go(E, l, x);
        }
        var P;
        if (xf)
          t: {
            switch (t) {
              case "compositionstart":
                var it = "onCompositionStart";
                break t;
              case "compositionend":
                it = "onCompositionEnd";
                break t;
              case "compositionupdate":
                it = "onCompositionUpdate";
                break t;
            }
            it = void 0;
          }
        else
          cn ? _o(t, l) && (it = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (it = "onCompositionStart");
        it && (Mo && l.locale !== "ko" && (cn || it !== "onCompositionStart" ? it === "onCompositionEnd" && cn && (P = $n()) : (Qe = x, Ba = "value" in Qe ? Qe.value : Qe.textContent, cn = !0)), w = Fi(v, it), 0 < w.length && (it = new Ht(
          it,
          t,
          null,
          l,
          x
        ), E.push({ event: it, listeners: w }), P ? it.data = P : (P = Do(l), P !== null && (it.data = P)))), (P = bm ? Sm(t, l) : xm(t, l)) && (it = Fi(v, "onBeforeInput"), 0 < it.length && (w = new Ht(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          x
        ), E.push({
          event: w,
          listeners: it
        }), w.data = P)), dh(
          E,
          t,
          v,
          l,
          x
        );
      }
      dd(E, e);
    });
  }
  function Uu(t, e, l) {
    return {
      instance: t,
      listener: e,
      currentTarget: l
    };
  }
  function Fi(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, u = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || u === null || (n = Ml(t, l), n != null && a.unshift(
        Uu(t, n, u)
      ), n = Ml(t, e), n != null && a.push(
        Uu(t, n, u)
      )), t.tag === 3) return a;
      t = t.return;
    }
    return [];
  }
  function gh(t) {
    if (t === null) return null;
    do
      t = t.return;
    while (t && t.tag !== 5 && t.tag !== 27);
    return t || null;
  }
  function hd(t, e, l, a, n) {
    for (var u = e._reactName, i = []; l !== null && l !== a; ) {
      var f = l, s = f.alternate, v = f.stateNode;
      if (f = f.tag, s !== null && s === a) break;
      f !== 5 && f !== 26 && f !== 27 || v === null || (s = v, n ? (v = Ml(l, u), v != null && i.unshift(
        Uu(l, v, s)
      )) : n || (v = Ml(l, u), v != null && i.push(
        Uu(l, v, s)
      ))), l = l.return;
    }
    i.length !== 0 && t.push({ event: e, listeners: i });
  }
  var vh = /\r\n?/g, ph = /\u0000|\uFFFD/g;
  function yd(t) {
    return (typeof t == "string" ? t : "" + t).replace(vh, `
`).replace(ph, "");
  }
  function gd(t, e) {
    return e = yd(e), yd(t) === e;
  }
  function Tt(t, e, l, a, n, u) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || y(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && y(t, "" + a);
        break;
      case "className":
        Kl(t, "class", a);
        break;
      case "tabIndex":
        Kl(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        Kl(t, l, a);
        break;
      case "style":
        R(t, a, u);
        break;
      case "data":
        if (e !== "object") {
          Kl(t, "data", a);
          break;
        }
      case "src":
      case "href":
        if (a === "" && (e !== "a" || l !== "href")) {
          t.removeAttribute(l);
          break;
        }
        if (a == null || typeof a == "function" || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = ot("" + a), t.setAttribute(l, a);
        break;
      case "action":
      case "formAction":
        if (typeof a == "function") {
          t.setAttribute(
            l,
            "javascript:throw new Error('A React form was unexpectedly submitted. If you called form.submit() manually, consider using form.requestSubmit() instead. If you\\'re trying to use event.stopPropagation() in a submit event handler, consider also calling event.preventDefault().')"
          );
          break;
        } else
          typeof u == "function" && (l === "formAction" ? (e !== "input" && Tt(t, e, "name", n.name, n, null), Tt(
            t,
            e,
            "formEncType",
            n.formEncType,
            n,
            null
          ), Tt(
            t,
            e,
            "formMethod",
            n.formMethod,
            n,
            null
          ), Tt(
            t,
            e,
            "formTarget",
            n.formTarget,
            n,
            null
          )) : (Tt(t, e, "encType", n.encType, n, null), Tt(t, e, "method", n.method, n, null), Tt(t, e, "target", n.target, n, null)));
        if (a == null || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = ot("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = de);
        break;
      case "onScroll":
        a != null && nt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && nt("scrollend", t);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(b(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(b(60));
            t.innerHTML = l;
          }
        }
        break;
      case "multiple":
        t.multiple = a && typeof a != "function" && typeof a != "symbol";
        break;
      case "muted":
        t.muted = a && typeof a != "function" && typeof a != "symbol";
        break;
      case "suppressContentEditableWarning":
      case "suppressHydrationWarning":
      case "defaultValue":
      case "defaultChecked":
      case "innerHTML":
      case "ref":
        break;
      case "autoFocus":
        break;
      case "xlinkHref":
        if (a == null || typeof a == "function" || typeof a == "boolean" || typeof a == "symbol") {
          t.removeAttribute("xlink:href");
          break;
        }
        l = ot("" + a), t.setAttributeNS(
          "http://www.w3.org/1999/xlink",
          "xlink:href",
          l
        );
        break;
      case "contentEditable":
      case "spellCheck":
      case "draggable":
      case "value":
      case "autoReverse":
      case "externalResourcesRequired":
      case "focusable":
      case "preserveAlpha":
        a != null && typeof a != "function" && typeof a != "symbol" ? t.setAttribute(l, "" + a) : t.removeAttribute(l);
        break;
      case "inert":
      case "allowFullScreen":
      case "async":
      case "autoPlay":
      case "controls":
      case "default":
      case "defer":
      case "disabled":
      case "disablePictureInPicture":
      case "disableRemotePlayback":
      case "formNoValidate":
      case "hidden":
      case "loop":
      case "noModule":
      case "noValidate":
      case "open":
      case "playsInline":
      case "readOnly":
      case "required":
      case "reversed":
      case "scoped":
      case "seamless":
      case "itemScope":
        a && typeof a != "function" && typeof a != "symbol" ? t.setAttribute(l, "") : t.removeAttribute(l);
        break;
      case "capture":
      case "download":
        a === !0 ? t.setAttribute(l, "") : a !== !1 && a != null && typeof a != "function" && typeof a != "symbol" ? t.setAttribute(l, a) : t.removeAttribute(l);
        break;
      case "cols":
      case "rows":
      case "size":
      case "span":
        a != null && typeof a != "function" && typeof a != "symbol" && !isNaN(a) && 1 <= a ? t.setAttribute(l, a) : t.removeAttribute(l);
        break;
      case "rowSpan":
      case "start":
        a == null || typeof a == "function" || typeof a == "symbol" || isNaN(a) ? t.removeAttribute(l) : t.setAttribute(l, a);
        break;
      case "popover":
        nt("beforetoggle", t), nt("toggle", t), ln(t, "popover", a);
        break;
      case "xlinkActuate":
        Pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:actuate",
          a
        );
        break;
      case "xlinkArcrole":
        Pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:arcrole",
          a
        );
        break;
      case "xlinkRole":
        Pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:role",
          a
        );
        break;
      case "xlinkShow":
        Pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:show",
          a
        );
        break;
      case "xlinkTitle":
        Pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:title",
          a
        );
        break;
      case "xlinkType":
        Pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:type",
          a
        );
        break;
      case "xmlBase":
        Pe(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:base",
          a
        );
        break;
      case "xmlLang":
        Pe(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:lang",
          a
        );
        break;
      case "xmlSpace":
        Pe(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:space",
          a
        );
        break;
      case "is":
        ln(t, "is", a);
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = rt.get(l) || l, ln(t, l, a));
    }
  }
  function $c(t, e, l, a, n, u) {
    switch (l) {
      case "style":
        R(t, a, u);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(b(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(b(60));
            t.innerHTML = l;
          }
        }
        break;
      case "children":
        typeof a == "string" ? y(t, a) : (typeof a == "number" || typeof a == "bigint") && y(t, "" + a);
        break;
      case "onScroll":
        a != null && nt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && nt("scrollend", t);
        break;
      case "onClick":
        a != null && (t.onclick = de);
        break;
      case "suppressContentEditableWarning":
      case "suppressHydrationWarning":
      case "innerHTML":
      case "ref":
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        if (!Vn.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), u = t[re] || null, u = u != null ? u[l] : null, typeof u == "function" && t.removeEventListener(e, u, n), typeof a == "function")) {
              typeof u != "function" && u !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : ln(t, l, a);
          }
    }
  }
  function ie(t, e, l) {
    switch (e) {
      case "div":
      case "span":
      case "svg":
      case "path":
      case "a":
      case "g":
      case "p":
      case "li":
        break;
      case "img":
        nt("error", t), nt("load", t);
        var a = !1, n = !1, u;
        for (u in l)
          if (l.hasOwnProperty(u)) {
            var i = l[u];
            if (i != null)
              switch (u) {
                case "src":
                  a = !0;
                  break;
                case "srcSet":
                  n = !0;
                  break;
                case "children":
                case "dangerouslySetInnerHTML":
                  throw Error(b(137, e));
                default:
                  Tt(t, e, u, i, l, null);
              }
          }
        n && Tt(t, e, "srcSet", l.srcSet, l, null), a && Tt(t, e, "src", l.src, l, null);
        return;
      case "input":
        nt("invalid", t);
        var f = u = i = n = null, s = null, v = null;
        for (a in l)
          if (l.hasOwnProperty(a)) {
            var x = l[a];
            if (x != null)
              switch (a) {
                case "name":
                  n = x;
                  break;
                case "type":
                  i = x;
                  break;
                case "checked":
                  s = x;
                  break;
                case "defaultChecked":
                  v = x;
                  break;
                case "value":
                  u = x;
                  break;
                case "defaultValue":
                  f = x;
                  break;
                case "children":
                case "dangerouslySetInnerHTML":
                  if (x != null)
                    throw Error(b(137, e));
                  break;
                default:
                  Tt(t, e, a, x, l, null);
              }
          }
        Ca(
          t,
          u,
          f,
          s,
          v,
          i,
          n,
          !1
        );
        return;
      case "select":
        nt("invalid", t), a = i = u = null;
        for (n in l)
          if (l.hasOwnProperty(n) && (f = l[n], f != null))
            switch (n) {
              case "value":
                u = f;
                break;
              case "defaultValue":
                i = f;
                break;
              case "multiple":
                a = f;
              default:
                Tt(t, e, n, f, l, null);
            }
        e = u, l = i, t.multiple = !!a, e != null ? Jl(t, !!a, e, !1) : l != null && Jl(t, !!a, l, !0);
        return;
      case "textarea":
        nt("invalid", t), u = n = a = null;
        for (i in l)
          if (l.hasOwnProperty(i) && (f = l[i], f != null))
            switch (i) {
              case "value":
                a = f;
                break;
              case "defaultValue":
                n = f;
                break;
              case "children":
                u = f;
                break;
              case "dangerouslySetInnerHTML":
                if (f != null) throw Error(b(91));
                break;
              default:
                Tt(t, e, i, f, l, null);
            }
        o(t, a, n, u);
        return;
      case "option":
        for (s in l)
          l.hasOwnProperty(s) && (a = l[s], a != null) && (s === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : Tt(t, e, s, a, l, null));
        return;
      case "dialog":
        nt("beforetoggle", t), nt("toggle", t), nt("cancel", t), nt("close", t);
        break;
      case "iframe":
      case "object":
        nt("load", t);
        break;
      case "video":
      case "audio":
        for (a = 0; a < Ou.length; a++)
          nt(Ou[a], t);
        break;
      case "image":
        nt("error", t), nt("load", t);
        break;
      case "details":
        nt("toggle", t);
        break;
      case "embed":
      case "source":
      case "link":
        nt("error", t), nt("load", t);
      case "area":
      case "base":
      case "br":
      case "col":
      case "hr":
      case "keygen":
      case "meta":
      case "param":
      case "track":
      case "wbr":
      case "menuitem":
        for (v in l)
          if (l.hasOwnProperty(v) && (a = l[v], a != null))
            switch (v) {
              case "children":
              case "dangerouslySetInnerHTML":
                throw Error(b(137, e));
              default:
                Tt(t, e, v, a, l, null);
            }
        return;
      default:
        if (N(e)) {
          for (x in l)
            l.hasOwnProperty(x) && (a = l[x], a !== void 0 && $c(
              t,
              e,
              x,
              a,
              l,
              void 0
            ));
          return;
        }
    }
    for (f in l)
      l.hasOwnProperty(f) && (a = l[f], a != null && Tt(t, e, f, a, l, null));
  }
  function bh(t, e, l, a) {
    switch (e) {
      case "div":
      case "span":
      case "svg":
      case "path":
      case "a":
      case "g":
      case "p":
      case "li":
        break;
      case "input":
        var n = null, u = null, i = null, f = null, s = null, v = null, x = null;
        for (S in l) {
          var E = l[S];
          if (l.hasOwnProperty(S) && E != null)
            switch (S) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                s = E;
              default:
                a.hasOwnProperty(S) || Tt(t, e, S, null, a, E);
            }
        }
        for (var p in a) {
          var S = a[p];
          if (E = l[p], a.hasOwnProperty(p) && (S != null || E != null))
            switch (p) {
              case "type":
                u = S;
                break;
              case "name":
                n = S;
                break;
              case "checked":
                v = S;
                break;
              case "defaultChecked":
                x = S;
                break;
              case "value":
                i = S;
                break;
              case "defaultValue":
                f = S;
                break;
              case "children":
              case "dangerouslySetInnerHTML":
                if (S != null)
                  throw Error(b(137, e));
                break;
              default:
                S !== E && Tt(
                  t,
                  e,
                  p,
                  S,
                  a,
                  E
                );
            }
        }
        pe(
          t,
          i,
          f,
          s,
          v,
          x,
          u,
          n
        );
        return;
      case "select":
        S = i = f = p = null;
        for (u in l)
          if (s = l[u], l.hasOwnProperty(u) && s != null)
            switch (u) {
              case "value":
                break;
              case "multiple":
                S = s;
              default:
                a.hasOwnProperty(u) || Tt(
                  t,
                  e,
                  u,
                  null,
                  a,
                  s
                );
            }
        for (n in a)
          if (u = a[n], s = l[n], a.hasOwnProperty(n) && (u != null || s != null))
            switch (n) {
              case "value":
                p = u;
                break;
              case "defaultValue":
                f = u;
                break;
              case "multiple":
                i = u;
              default:
                u !== s && Tt(
                  t,
                  e,
                  n,
                  u,
                  a,
                  s
                );
            }
        e = f, l = i, a = S, p != null ? Jl(t, !!l, p, !1) : !!a != !!l && (e != null ? Jl(t, !!l, e, !0) : Jl(t, !!l, l ? [] : "", !1));
        return;
      case "textarea":
        S = p = null;
        for (f in l)
          if (n = l[f], l.hasOwnProperty(f) && n != null && !a.hasOwnProperty(f))
            switch (f) {
              case "value":
                break;
              case "children":
                break;
              default:
                Tt(t, e, f, null, a, n);
            }
        for (i in a)
          if (n = a[i], u = l[i], a.hasOwnProperty(i) && (n != null || u != null))
            switch (i) {
              case "value":
                p = n;
                break;
              case "defaultValue":
                S = n;
                break;
              case "children":
                break;
              case "dangerouslySetInnerHTML":
                if (n != null) throw Error(b(91));
                break;
              default:
                n !== u && Tt(t, e, i, n, a, u);
            }
        c(t, p, S);
        return;
      case "option":
        for (var j in l)
          p = l[j], l.hasOwnProperty(j) && p != null && !a.hasOwnProperty(j) && (j === "selected" ? t.selected = !1 : Tt(
            t,
            e,
            j,
            null,
            a,
            p
          ));
        for (s in a)
          p = a[s], S = l[s], a.hasOwnProperty(s) && p !== S && (p != null || S != null) && (s === "selected" ? t.selected = p && typeof p != "function" && typeof p != "symbol" : Tt(
            t,
            e,
            s,
            p,
            a,
            S
          ));
        return;
      case "img":
      case "link":
      case "area":
      case "base":
      case "br":
      case "col":
      case "embed":
      case "hr":
      case "keygen":
      case "meta":
      case "param":
      case "source":
      case "track":
      case "wbr":
      case "menuitem":
        for (var V in l)
          p = l[V], l.hasOwnProperty(V) && p != null && !a.hasOwnProperty(V) && Tt(t, e, V, null, a, p);
        for (v in a)
          if (p = a[v], S = l[v], a.hasOwnProperty(v) && p !== S && (p != null || S != null))
            switch (v) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (p != null)
                  throw Error(b(137, e));
                break;
              default:
                Tt(
                  t,
                  e,
                  v,
                  p,
                  a,
                  S
                );
            }
        return;
      default:
        if (N(e)) {
          for (var zt in l)
            p = l[zt], l.hasOwnProperty(zt) && p !== void 0 && !a.hasOwnProperty(zt) && $c(
              t,
              e,
              zt,
              void 0,
              a,
              p
            );
          for (x in a)
            p = a[x], S = l[x], !a.hasOwnProperty(x) || p === S || p === void 0 && S === void 0 || $c(
              t,
              e,
              x,
              p,
              a,
              S
            );
          return;
        }
    }
    for (var h in l)
      p = l[h], l.hasOwnProperty(h) && p != null && !a.hasOwnProperty(h) && Tt(t, e, h, null, a, p);
    for (E in a)
      p = a[E], S = l[E], !a.hasOwnProperty(E) || p === S || p == null && S == null || Tt(t, e, E, p, a, S);
  }
  function vd(t) {
    switch (t) {
      case "css":
      case "script":
      case "font":
      case "img":
      case "image":
      case "input":
      case "link":
        return !0;
      default:
        return !1;
    }
  }
  function Sh() {
    if (typeof performance.getEntriesByType == "function") {
      for (var t = 0, e = 0, l = performance.getEntriesByType("resource"), a = 0; a < l.length; a++) {
        var n = l[a], u = n.transferSize, i = n.initiatorType, f = n.duration;
        if (u && f && vd(i)) {
          for (i = 0, f = n.responseEnd, a += 1; a < l.length; a++) {
            var s = l[a], v = s.startTime;
            if (v > f) break;
            var x = s.transferSize, E = s.initiatorType;
            x && vd(E) && (s = s.responseEnd, i += x * (s < f ? 1 : (f - v) / (s - v)));
          }
          if (--a, e += 8 * (u + i) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var Ic = null, Pc = null;
  function Wi(t) {
    return t.nodeType === 9 ? t : t.ownerDocument;
  }
  function pd(t) {
    switch (t) {
      case "http://www.w3.org/2000/svg":
        return 1;
      case "http://www.w3.org/1998/Math/MathML":
        return 2;
      default:
        return 0;
    }
  }
  function bd(t, e) {
    if (t === 0)
      switch (e) {
        case "svg":
          return 1;
        case "math":
          return 2;
        default:
          return 0;
      }
    return t === 1 && e === "foreignObject" ? 0 : t;
  }
  function to(t, e) {
    return t === "textarea" || t === "noscript" || typeof e.children == "string" || typeof e.children == "number" || typeof e.children == "bigint" || typeof e.dangerouslySetInnerHTML == "object" && e.dangerouslySetInnerHTML !== null && e.dangerouslySetInnerHTML.__html != null;
  }
  var eo = null;
  function xh() {
    var t = window.event;
    return t && t.type === "popstate" ? t === eo ? !1 : (eo = t, !0) : (eo = null, !1);
  }
  var Sd = typeof setTimeout == "function" ? setTimeout : void 0, Th = typeof clearTimeout == "function" ? clearTimeout : void 0, xd = typeof Promise == "function" ? Promise : void 0, zh = typeof queueMicrotask == "function" ? queueMicrotask : typeof xd < "u" ? function(t) {
    return xd.resolve(null).then(t).catch(Mh);
  } : Sd;
  function Mh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function ha(t) {
    return t === "head";
  }
  function Td(t, e) {
    var l = e, a = 0;
    do {
      var n = l.nextSibling;
      if (t.removeChild(l), n && n.nodeType === 8)
        if (l = n.data, l === "/$" || l === "/&") {
          if (a === 0) {
            t.removeChild(n), qn(e);
            return;
          }
          a--;
        } else if (l === "$" || l === "$?" || l === "$~" || l === "$!" || l === "&")
          a++;
        else if (l === "html")
          Cu(t.ownerDocument.documentElement);
        else if (l === "head") {
          l = t.ownerDocument.head, Cu(l);
          for (var u = l.firstChild; u; ) {
            var i = u.nextSibling, f = u.nodeName;
            u[Aa] || f === "SCRIPT" || f === "STYLE" || f === "LINK" && u.rel.toLowerCase() === "stylesheet" || l.removeChild(u), u = i;
          }
        } else
          l === "body" && Cu(t.ownerDocument.body);
      l = n;
    } while (l);
    qn(e);
  }
  function zd(t, e) {
    var l = t;
    t = 0;
    do {
      var a = l.nextSibling;
      if (l.nodeType === 1 ? e ? (l._stashedDisplay = l.style.display, l.style.display = "none") : (l.style.display = l._stashedDisplay || "", l.getAttribute("style") === "" && l.removeAttribute("style")) : l.nodeType === 3 && (e ? (l._stashedText = l.nodeValue, l.nodeValue = "") : l.nodeValue = l._stashedText || ""), a && a.nodeType === 8)
        if (l = a.data, l === "/$") {
          if (t === 0) break;
          t--;
        } else
          l !== "$" && l !== "$?" && l !== "$~" && l !== "$!" || t++;
      l = a;
    } while (l);
  }
  function lo(t) {
    var e = t.firstChild;
    for (e && e.nodeType === 10 && (e = e.nextSibling); e; ) {
      var l = e;
      switch (e = e.nextSibling, l.nodeName) {
        case "HTML":
        case "HEAD":
        case "BODY":
          lo(l), Qn(l);
          continue;
        case "SCRIPT":
        case "STYLE":
          continue;
        case "LINK":
          if (l.rel.toLowerCase() === "stylesheet") continue;
      }
      t.removeChild(l);
    }
  }
  function Eh(t, e, l, a) {
    for (; t.nodeType === 1; ) {
      var n = l;
      if (t.nodeName.toLowerCase() !== e.toLowerCase()) {
        if (!a && (t.nodeName !== "INPUT" || t.type !== "hidden"))
          break;
      } else if (a) {
        if (!t[Aa])
          switch (e) {
            case "meta":
              if (!t.hasAttribute("itemprop")) break;
              return t;
            case "link":
              if (u = t.getAttribute("rel"), u === "stylesheet" && t.hasAttribute("data-precedence"))
                break;
              if (u !== n.rel || t.getAttribute("href") !== (n.href == null || n.href === "" ? null : n.href) || t.getAttribute("crossorigin") !== (n.crossOrigin == null ? null : n.crossOrigin) || t.getAttribute("title") !== (n.title == null ? null : n.title))
                break;
              return t;
            case "style":
              if (t.hasAttribute("data-precedence")) break;
              return t;
            case "script":
              if (u = t.getAttribute("src"), (u !== (n.src == null ? null : n.src) || t.getAttribute("type") !== (n.type == null ? null : n.type) || t.getAttribute("crossorigin") !== (n.crossOrigin == null ? null : n.crossOrigin)) && u && t.hasAttribute("async") && !t.hasAttribute("itemprop"))
                break;
              return t;
            default:
              return t;
          }
      } else if (e === "input" && t.type === "hidden") {
        var u = n.name == null ? null : "" + n.name;
        if (n.type === "hidden" && t.getAttribute("name") === u)
          return t;
      } else return t;
      if (t = We(t.nextSibling), t === null) break;
    }
    return null;
  }
  function Ah(t, e, l) {
    if (e === "") return null;
    for (; t.nodeType !== 3; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !l || (t = We(t.nextSibling), t === null)) return null;
    return t;
  }
  function Md(t, e) {
    for (; t.nodeType !== 8; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !e || (t = We(t.nextSibling), t === null)) return null;
    return t;
  }
  function ao(t) {
    return t.data === "$?" || t.data === "$~";
  }
  function no(t) {
    return t.data === "$!" || t.data === "$?" && t.ownerDocument.readyState !== "loading";
  }
  function _h(t, e) {
    var l = t.ownerDocument;
    if (t.data === "$~") t._reactRetry = e;
    else if (t.data !== "$?" || l.readyState !== "loading")
      e();
    else {
      var a = function() {
        e(), l.removeEventListener("DOMContentLoaded", a);
      };
      l.addEventListener("DOMContentLoaded", a), t._reactRetry = a;
    }
  }
  function We(t) {
    for (; t != null; t = t.nextSibling) {
      var e = t.nodeType;
      if (e === 1 || e === 3) break;
      if (e === 8) {
        if (e = t.data, e === "$" || e === "$!" || e === "$?" || e === "$~" || e === "&" || e === "F!" || e === "F")
          break;
        if (e === "/$" || e === "/&") return null;
      }
    }
    return t;
  }
  var uo = null;
  function Ed(t) {
    t = t.nextSibling;
    for (var e = 0; t; ) {
      if (t.nodeType === 8) {
        var l = t.data;
        if (l === "/$" || l === "/&") {
          if (e === 0)
            return We(t.nextSibling);
          e--;
        } else
          l !== "$" && l !== "$!" && l !== "$?" && l !== "$~" && l !== "&" || e++;
      }
      t = t.nextSibling;
    }
    return null;
  }
  function Ad(t) {
    t = t.previousSibling;
    for (var e = 0; t; ) {
      if (t.nodeType === 8) {
        var l = t.data;
        if (l === "$" || l === "$!" || l === "$?" || l === "$~" || l === "&") {
          if (e === 0) return t;
          e--;
        } else l !== "/$" && l !== "/&" || e++;
      }
      t = t.previousSibling;
    }
    return null;
  }
  function _d(t, e, l) {
    switch (e = Wi(l), t) {
      case "html":
        if (t = e.documentElement, !t) throw Error(b(452));
        return t;
      case "head":
        if (t = e.head, !t) throw Error(b(453));
        return t;
      case "body":
        if (t = e.body, !t) throw Error(b(454));
        return t;
      default:
        throw Error(b(451));
    }
  }
  function Cu(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    Qn(t);
  }
  var $e = /* @__PURE__ */ new Map(), Dd = /* @__PURE__ */ new Set();
  function $i(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var Ll = D.d;
  D.d = {
    f: Dh,
    r: Oh,
    D: Uh,
    C: Ch,
    L: Bh,
    m: Rh,
    X: Hh,
    S: Nh,
    M: qh
  };
  function Dh() {
    var t = Ll.f(), e = Xi();
    return t || e;
  }
  function Oh(t) {
    var e = fl(t);
    e !== null && e.tag === 5 && e.type === "form" ? Zs(e) : Ll.r(t);
  }
  var Rn = typeof document > "u" ? null : document;
  function Od(t, e, l) {
    var a = Rn;
    if (a && typeof e == "string" && e) {
      var n = Te(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Dd.has(n) || (Dd.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), ie(e, "link", t), Yt(e), a.head.appendChild(e)));
    }
  }
  function Uh(t) {
    Ll.D(t), Od("dns-prefetch", t, null);
  }
  function Ch(t, e) {
    Ll.C(t, e), Od("preconnect", t, e);
  }
  function Bh(t, e, l) {
    Ll.L(t, e, l);
    var a = Rn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + Te(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + Te(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + Te(
        l.imageSizes
      ) + '"]')) : n += '[href="' + Te(t) + '"]';
      var u = n;
      switch (e) {
        case "style":
          u = Nn(t);
          break;
        case "script":
          u = Hn(t);
      }
      $e.has(u) || (t = L(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), $e.set(u, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Bu(u)) || e === "script" && a.querySelector(Ru(u)) || (e = a.createElement("link"), ie(e, "link", t), Yt(e), a.head.appendChild(e)));
    }
  }
  function Rh(t, e) {
    Ll.m(t, e);
    var l = Rn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + Te(a) + '"][href="' + Te(t) + '"]', u = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          u = Hn(t);
      }
      if (!$e.has(u) && (t = L({ rel: "modulepreload", href: t }, e), $e.set(u, t), l.querySelector(n) === null)) {
        switch (a) {
          case "audioworklet":
          case "paintworklet":
          case "serviceworker":
          case "sharedworker":
          case "worker":
          case "script":
            if (l.querySelector(Ru(u)))
              return;
        }
        a = l.createElement("link"), ie(a, "link", t), Yt(a), l.head.appendChild(a);
      }
    }
  }
  function Nh(t, e, l) {
    Ll.S(t, e, l);
    var a = Rn;
    if (a && t) {
      var n = Vl(a).hoistableStyles, u = Nn(t);
      e = e || "default";
      var i = n.get(u);
      if (!i) {
        var f = { loading: 0, preload: null };
        if (i = a.querySelector(
          Bu(u)
        ))
          f.loading = 5;
        else {
          t = L(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = $e.get(u)) && io(t, l);
          var s = i = a.createElement("link");
          Yt(s), ie(s, "link", t), s._p = new Promise(function(v, x) {
            s.onload = v, s.onerror = x;
          }), s.addEventListener("load", function() {
            f.loading |= 1;
          }), s.addEventListener("error", function() {
            f.loading |= 2;
          }), f.loading |= 4, Ii(i, e, a);
        }
        i = {
          type: "stylesheet",
          instance: i,
          count: 1,
          state: f
        }, n.set(u, i);
      }
    }
  }
  function Hh(t, e) {
    Ll.X(t, e);
    var l = Rn;
    if (l && t) {
      var a = Vl(l).hoistableScripts, n = Hn(t), u = a.get(n);
      u || (u = l.querySelector(Ru(n)), u || (t = L({ src: t, async: !0 }, e), (e = $e.get(n)) && fo(t, e), u = l.createElement("script"), Yt(u), ie(u, "link", t), l.head.appendChild(u)), u = {
        type: "script",
        instance: u,
        count: 1,
        state: null
      }, a.set(n, u));
    }
  }
  function qh(t, e) {
    Ll.M(t, e);
    var l = Rn;
    if (l && t) {
      var a = Vl(l).hoistableScripts, n = Hn(t), u = a.get(n);
      u || (u = l.querySelector(Ru(n)), u || (t = L({ src: t, async: !0, type: "module" }, e), (e = $e.get(n)) && fo(t, e), u = l.createElement("script"), Yt(u), ie(u, "link", t), l.head.appendChild(u)), u = {
        type: "script",
        instance: u,
        count: 1,
        state: null
      }, a.set(n, u));
    }
  }
  function Ud(t, e, l, a) {
    var n = (n = W.current) ? $i(n) : null;
    if (!n) throw Error(b(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = Nn(l.href), l = Vl(
          n
        ).hoistableStyles, a = l.get(e), a || (a = {
          type: "style",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      case "link":
        if (l.rel === "stylesheet" && typeof l.href == "string" && typeof l.precedence == "string") {
          t = Nn(l.href);
          var u = Vl(
            n
          ).hoistableStyles, i = u.get(t);
          if (i || (n = n.ownerDocument || n, i = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, u.set(t, i), (u = n.querySelector(
            Bu(t)
          )) && !u._p && (i.instance = u, i.state.loading = 5), $e.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, $e.set(t, l), u || jh(
            n,
            t,
            l,
            i.state
          ))), e && a === null)
            throw Error(b(528, ""));
          return i;
        }
        if (e && a !== null)
          throw Error(b(529, ""));
        return null;
      case "script":
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = Hn(l), l = Vl(
          n
        ).hoistableScripts, a = l.get(e), a || (a = {
          type: "script",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      default:
        throw Error(b(444, t));
    }
  }
  function Nn(t) {
    return 'href="' + Te(t) + '"';
  }
  function Bu(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Cd(t) {
    return L({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function jh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), ie(e, "link", l), Yt(e), t.head.appendChild(e));
  }
  function Hn(t) {
    return '[src="' + Te(t) + '"]';
  }
  function Ru(t) {
    return "script[async]" + t;
  }
  function Bd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + Te(l.href) + '"]'
          );
          if (a)
            return e.instance = a, Yt(a), a;
          var n = L({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), Yt(a), ie(a, "style", n), Ii(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = Nn(l.href);
          var u = t.querySelector(
            Bu(n)
          );
          if (u)
            return e.state.loading |= 4, e.instance = u, Yt(u), u;
          a = Cd(l), (n = $e.get(n)) && io(a, n), u = (t.ownerDocument || t).createElement("link"), Yt(u);
          var i = u;
          return i._p = new Promise(function(f, s) {
            i.onload = f, i.onerror = s;
          }), ie(u, "link", a), e.state.loading |= 4, Ii(u, l.precedence, t), e.instance = u;
        case "script":
          return u = Hn(l.src), (n = t.querySelector(
            Ru(u)
          )) ? (e.instance = n, Yt(n), n) : (a = l, (n = $e.get(u)) && (a = L({}, l), fo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Yt(n), ie(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(b(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, Ii(a, l.precedence, t));
    return e.instance;
  }
  function Ii(t, e, l) {
    for (var a = l.querySelectorAll(
      'link[rel="stylesheet"][data-precedence],style[data-precedence]'
    ), n = a.length ? a[a.length - 1] : null, u = n, i = 0; i < a.length; i++) {
      var f = a[i];
      if (f.dataset.precedence === e) u = f;
      else if (u !== n) break;
    }
    u ? u.parentNode.insertBefore(t, u.nextSibling) : (e = l.nodeType === 9 ? l.head : l, e.insertBefore(t, e.firstChild));
  }
  function io(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.title == null && (t.title = e.title);
  }
  function fo(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.integrity == null && (t.integrity = e.integrity);
  }
  var Pi = null;
  function Rd(t, e, l) {
    if (Pi === null) {
      var a = /* @__PURE__ */ new Map(), n = Pi = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = Pi, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var u = l[n];
      if (!(u[Aa] || u[Qt] || t === "link" && u.getAttribute("rel") === "stylesheet") && u.namespaceURI !== "http://www.w3.org/2000/svg") {
        var i = u.getAttribute(e) || "";
        i = t + i;
        var f = a.get(i);
        f ? f.push(u) : a.set(i, [u]);
      }
    }
    return a;
  }
  function Nd(t, e, l) {
    t = t.ownerDocument || t, t.head.insertBefore(
      l,
      e === "title" ? t.querySelector("head > title") : null
    );
  }
  function wh(t, e, l) {
    if (l === 1 || e.itemProp != null) return !1;
    switch (t) {
      case "meta":
      case "title":
        return !0;
      case "style":
        if (typeof e.precedence != "string" || typeof e.href != "string" || e.href === "")
          break;
        return !0;
      case "link":
        if (typeof e.rel != "string" || typeof e.href != "string" || e.href === "" || e.onLoad || e.onError)
          break;
        return e.rel === "stylesheet" ? (t = e.disabled, typeof e.precedence == "string" && t == null) : !0;
      case "script":
        if (e.async && typeof e.async != "function" && typeof e.async != "symbol" && !e.onLoad && !e.onError && e.src && typeof e.src == "string")
          return !0;
    }
    return !1;
  }
  function Hd(t) {
    return !(t.type === "stylesheet" && (t.state.loading & 3) === 0);
  }
  function Yh(t, e, l, a) {
    if (l.type === "stylesheet" && (typeof a.media != "string" || matchMedia(a.media).matches !== !1) && (l.state.loading & 4) === 0) {
      if (l.instance === null) {
        var n = Nn(a.href), u = e.querySelector(
          Bu(n)
        );
        if (u) {
          e = u._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = tf.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = u, Yt(u);
          return;
        }
        u = e.ownerDocument || e, a = Cd(a), (n = $e.get(n)) && io(a, n), u = u.createElement("link"), Yt(u);
        var i = u;
        i._p = new Promise(function(f, s) {
          i.onload = f, i.onerror = s;
        }), ie(u, "link", a), l.instance = u;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = tf.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var co = 0;
  function Gh(t, e) {
    return t.stylesheets && t.count === 0 && lf(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && lf(t, t.stylesheets), t.unsuspend) {
          var u = t.unsuspend;
          t.unsuspend = null, u();
        }
      }, 6e4 + e);
      0 < t.imgBytes && co === 0 && (co = 62500 * Sh());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && lf(t, t.stylesheets), t.unsuspend)) {
            var u = t.unsuspend;
            t.unsuspend = null, u();
          }
        },
        (t.imgBytes > co ? 50 : 800) + e
      );
      return t.unsuspend = l, function() {
        t.unsuspend = null, clearTimeout(a), clearTimeout(n);
      };
    } : null;
  }
  function tf() {
    if (this.count--, this.count === 0 && (this.imgCount === 0 || !this.waitingForImages)) {
      if (this.stylesheets) lf(this, this.stylesheets);
      else if (this.unsuspend) {
        var t = this.unsuspend;
        this.unsuspend = null, t();
      }
    }
  }
  var ef = null;
  function lf(t, e) {
    t.stylesheets = null, t.unsuspend !== null && (t.count++, ef = /* @__PURE__ */ new Map(), e.forEach(Lh, t), ef = null, tf.call(t));
  }
  function Lh(t, e) {
    if (!(e.state.loading & 4)) {
      var l = ef.get(t);
      if (l) var a = l.get(null);
      else {
        l = /* @__PURE__ */ new Map(), ef.set(t, l);
        for (var n = t.querySelectorAll(
          "link[data-precedence],style[data-precedence]"
        ), u = 0; u < n.length; u++) {
          var i = n[u];
          (i.nodeName === "LINK" || i.getAttribute("media") !== "not all") && (l.set(i.dataset.precedence, i), a = i);
        }
        a && l.set(null, a);
      }
      n = e.instance, i = n.getAttribute("data-precedence"), u = l.get(i) || a, u === a && l.set(null, n), l.set(i, n), this.count++, a = tf.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), u ? u.parentNode.insertBefore(n, u.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Nu = {
    $$typeof: Rt,
    Provider: null,
    Consumer: null,
    _currentValue: Y,
    _currentValue2: Y,
    _threadCount: 0
  };
  function Xh(t, e, l, a, n, u, i, f, s) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Ie(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Ie(0), this.hiddenUpdates = Ie(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = u, this.onRecoverableError = i, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = s, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function qd(t, e, l, a, n, u, i, f, s, v, x, E) {
    return t = new Xh(
      t,
      e,
      l,
      i,
      s,
      v,
      x,
      E,
      f
    ), e = 1, u === !0 && (e |= 24), u = Re(3, null, null, e), t.current = u, u.stateNode = t, e = Lf(), e.refCount++, t.pooledCache = e, e.refCount++, u.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Zf(u), t;
  }
  function jd(t) {
    return t ? (t = dn, t) : dn;
  }
  function wd(t, e, l, a, n, u) {
    n = jd(n), a.context === null ? a.context = n : a.pendingContext = n, a = aa(e), a.payload = { element: l }, u = u === void 0 ? null : u, u !== null && (a.callback = u), l = na(t, a, e), l !== null && (_e(l, t, e), du(l, t, e));
  }
  function Yd(t, e) {
    if (t = t.memoizedState, t !== null && t.dehydrated !== null) {
      var l = t.retryLane;
      t.retryLane = l !== 0 && l < e ? l : e;
    }
  }
  function oo(t, e) {
    Yd(t, e), (t = t.alternate) && Yd(t, e);
  }
  function Gd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = wa(t, 67108864);
      e !== null && _e(e, t, 67108864), oo(t, 67108864);
    }
  }
  function Ld(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = we();
      e = se(e);
      var l = wa(t, e);
      l !== null && _e(l, t, e), oo(t, e);
    }
  }
  var af = !0;
  function Qh(t, e, l, a) {
    var n = m.T;
    m.T = null;
    var u = D.p;
    try {
      D.p = 2, so(t, e, l, a);
    } finally {
      D.p = u, m.T = n;
    }
  }
  function Vh(t, e, l, a) {
    var n = m.T;
    m.T = null;
    var u = D.p;
    try {
      D.p = 8, so(t, e, l, a);
    } finally {
      D.p = u, m.T = n;
    }
  }
  function so(t, e, l, a) {
    if (af) {
      var n = ro(a);
      if (n === null)
        Wc(
          t,
          e,
          a,
          nf,
          l
        ), Qd(t, a);
      else if (Kh(
        n,
        t,
        e,
        l,
        a
      ))
        a.stopPropagation();
      else if (Qd(t, a), e & 4 && -1 < Zh.indexOf(t)) {
        for (; n !== null; ) {
          var u = fl(n);
          if (u !== null)
            switch (u.tag) {
              case 3:
                if (u = u.stateNode, u.current.memoizedState.isDehydrated) {
                  var i = bl(u.pendingLanes);
                  if (i !== 0) {
                    var f = u;
                    for (f.pendingLanes |= 2, f.entangledLanes |= 2; i; ) {
                      var s = 1 << 31 - ge(i);
                      f.entanglements[1] |= s, i &= ~s;
                    }
                    hl(u), (gt & 6) === 0 && (Gi = le() + 500, Du(0));
                  }
                }
                break;
              case 31:
              case 13:
                f = wa(u, 2), f !== null && _e(f, u, 2), Xi(), oo(u, 2);
            }
          if (u = ro(a), u === null && Wc(
            t,
            e,
            a,
            nf,
            l
          ), u === n) break;
          n = u;
        }
        n !== null && a.stopPropagation();
      } else
        Wc(
          t,
          e,
          a,
          null,
          l
        );
    }
  }
  function ro(t) {
    return t = Fn(t), mo(t);
  }
  var nf = null;
  function mo(t) {
    if (nf = null, t = xl(t), t !== null) {
      var e = wt(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = kt(e), t !== null) return t;
          t = null;
        } else if (l === 31) {
          if (t = Pt(e), t !== null) return t;
          t = null;
        } else if (l === 3) {
          if (e.stateNode.current.memoizedState.isDehydrated)
            return e.tag === 3 ? e.stateNode.containerInfo : null;
          t = null;
        } else e !== t && (t = null);
      }
    }
    return nf = t, null;
  }
  function Xd(t) {
    switch (t) {
      case "beforetoggle":
      case "cancel":
      case "click":
      case "close":
      case "contextmenu":
      case "copy":
      case "cut":
      case "auxclick":
      case "dblclick":
      case "dragend":
      case "dragstart":
      case "drop":
      case "focusin":
      case "focusout":
      case "input":
      case "invalid":
      case "keydown":
      case "keypress":
      case "keyup":
      case "mousedown":
      case "mouseup":
      case "paste":
      case "pause":
      case "play":
      case "pointercancel":
      case "pointerdown":
      case "pointerup":
      case "ratechange":
      case "reset":
      case "resize":
      case "seeked":
      case "submit":
      case "toggle":
      case "touchcancel":
      case "touchend":
      case "touchstart":
      case "volumechange":
      case "change":
      case "selectionchange":
      case "textInput":
      case "compositionstart":
      case "compositionend":
      case "compositionupdate":
      case "beforeblur":
      case "afterblur":
      case "beforeinput":
      case "blur":
      case "fullscreenchange":
      case "focus":
      case "hashchange":
      case "popstate":
      case "select":
      case "selectstart":
        return 2;
      case "drag":
      case "dragenter":
      case "dragexit":
      case "dragleave":
      case "dragover":
      case "mousemove":
      case "mouseout":
      case "mouseover":
      case "pointermove":
      case "pointerout":
      case "pointerover":
      case "scroll":
      case "touchmove":
      case "wheel":
      case "mouseenter":
      case "mouseleave":
      case "pointerenter":
      case "pointerleave":
        return 8;
      case "message":
        switch (Xu()) {
          case Qu:
            return 2;
          case $a:
            return 8;
          case xa:
          case mf:
            return 32;
          case Vu:
            return 268435456;
          default:
            return 32;
        }
      default:
        return 32;
    }
  }
  var ho = !1, ya = null, ga = null, va = null, Hu = /* @__PURE__ */ new Map(), qu = /* @__PURE__ */ new Map(), pa = [], Zh = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Qd(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        ya = null;
        break;
      case "dragenter":
      case "dragleave":
        ga = null;
        break;
      case "mouseover":
      case "mouseout":
        va = null;
        break;
      case "pointerover":
      case "pointerout":
        Hu.delete(e.pointerId);
        break;
      case "gotpointercapture":
      case "lostpointercapture":
        qu.delete(e.pointerId);
    }
  }
  function ju(t, e, l, a, n, u) {
    return t === null || t.nativeEvent !== u ? (t = {
      blockedOn: e,
      domEventName: l,
      eventSystemFlags: a,
      nativeEvent: u,
      targetContainers: [n]
    }, e !== null && (e = fl(e), e !== null && Gd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function Kh(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return ya = ju(
          ya,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return ga = ju(
          ga,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return va = ju(
          va,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "pointerover":
        var u = n.pointerId;
        return Hu.set(
          u,
          ju(
            Hu.get(u) || null,
            t,
            e,
            l,
            a,
            n
          )
        ), !0;
      case "gotpointercapture":
        return u = n.pointerId, qu.set(
          u,
          ju(
            qu.get(u) || null,
            t,
            e,
            l,
            a,
            n
          )
        ), !0;
    }
    return !1;
  }
  function Vd(t) {
    var e = xl(t.target);
    if (e !== null) {
      var l = wt(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = kt(l), e !== null) {
            t.blockedOn = e, Wu(t.priority, function() {
              Ld(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = Pt(l), e !== null) {
            t.blockedOn = e, Wu(t.priority, function() {
              Ld(l);
            });
            return;
          }
        } else if (e === 3 && l.stateNode.current.memoizedState.isDehydrated) {
          t.blockedOn = l.tag === 3 ? l.stateNode.containerInfo : null;
          return;
        }
      }
    }
    t.blockedOn = null;
  }
  function uf(t) {
    if (t.blockedOn !== null) return !1;
    for (var e = t.targetContainers; 0 < e.length; ) {
      var l = ro(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        kn = a, l.target.dispatchEvent(a), kn = null;
      } else
        return e = fl(l), e !== null && Gd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function Zd(t, e, l) {
    uf(t) && l.delete(e);
  }
  function Jh() {
    ho = !1, ya !== null && uf(ya) && (ya = null), ga !== null && uf(ga) && (ga = null), va !== null && uf(va) && (va = null), Hu.forEach(Zd), qu.forEach(Zd);
  }
  function ff(t, e) {
    t.blockedOn === e && (t.blockedOn = null, ho || (ho = !0, A.unstable_scheduleCallback(
      A.unstable_NormalPriority,
      Jh
    )));
  }
  var cf = null;
  function Kd(t) {
    cf !== t && (cf = t, A.unstable_scheduleCallback(
      A.unstable_NormalPriority,
      function() {
        cf === t && (cf = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (mo(a || l) === null)
              continue;
            break;
          }
          var u = fl(l);
          u !== null && (t.splice(e, 3), e -= 3, rc(
            u,
            {
              pending: !0,
              data: n,
              method: l.method,
              action: a
            },
            a,
            n
          ));
        }
      }
    ));
  }
  function qn(t) {
    function e(s) {
      return ff(s, t);
    }
    ya !== null && ff(ya, t), ga !== null && ff(ga, t), va !== null && ff(va, t), Hu.forEach(e), qu.forEach(e);
    for (var l = 0; l < pa.length; l++) {
      var a = pa[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < pa.length && (l = pa[0], l.blockedOn === null); )
      Vd(l), l.blockedOn === null && pa.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], u = l[a + 1], i = n[re] || null;
        if (typeof u == "function")
          i || Kd(l);
        else if (i) {
          var f = null;
          if (u && u.hasAttribute("formAction")) {
            if (n = u, i = u[re] || null)
              f = i.formAction;
            else if (mo(n) !== null) continue;
          } else f = i.action;
          typeof f == "function" ? l[a + 1] = f : (l.splice(a, 3), a -= 3), Kd(l);
        }
      }
  }
  function Jd() {
    function t(u) {
      u.canIntercept && u.info === "react-transition" && u.intercept({
        handler: function() {
          return new Promise(function(i) {
            return n = i;
          });
        },
        focusReset: "manual",
        scroll: "manual"
      });
    }
    function e() {
      n !== null && (n(), n = null), a || setTimeout(l, 20);
    }
    function l() {
      if (!a && !navigation.transition) {
        var u = navigation.currentEntry;
        u && u.url != null && navigation.navigate(u.url, {
          state: u.getState(),
          info: "react-transition",
          history: "replace"
        });
      }
    }
    if (typeof navigation == "object") {
      var a = !1, n = null;
      return navigation.addEventListener("navigate", t), navigation.addEventListener("navigatesuccess", e), navigation.addEventListener("navigateerror", e), setTimeout(l, 100), function() {
        a = !0, navigation.removeEventListener("navigate", t), navigation.removeEventListener("navigatesuccess", e), navigation.removeEventListener("navigateerror", e), n !== null && (n(), n = null);
      };
    }
  }
  function yo(t) {
    this._internalRoot = t;
  }
  of.prototype.render = yo.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(b(409));
    var l = e.current, a = we();
    wd(l, a, t, e, null, null);
  }, of.prototype.unmount = yo.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      wd(t.current, 2, null, t, null, null), Xi(), e[Sl] = null;
    }
  };
  function of(t) {
    this._internalRoot = t;
  }
  of.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = tn();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < pa.length && e !== 0 && e < pa[l].priority; l++) ;
      pa.splice(l, 0, t), l === 0 && Vd(t);
    }
  };
  var kd = J.version;
  if (kd !== "19.2.3")
    throw Error(
      b(
        527,
        kd,
        "19.2.3"
      )
    );
  D.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(b(188)) : (t = Object.keys(t).join(","), Error(b(268, t)));
    return t = _(e), t = t !== null ? lt(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var kh = {
    bundleType: 0,
    version: "19.2.3",
    rendererPackageName: "react-dom",
    currentDispatcherRef: m,
    reconcilerVersion: "19.2.3"
  };
  if (typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ < "u") {
    var sf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!sf.isDisabled && sf.supportsFiber)
      try {
        Ta = sf.inject(
          kh
        ), ye = sf;
      } catch {
      }
  }
  return Yu.createRoot = function(t, e) {
    if (!Bt(t)) throw Error(b(299));
    var l = !1, a = "", n = er, u = lr, i = ar;
    return e != null && (e.unstable_strictMode === !0 && (l = !0), e.identifierPrefix !== void 0 && (a = e.identifierPrefix), e.onUncaughtError !== void 0 && (n = e.onUncaughtError), e.onCaughtError !== void 0 && (u = e.onCaughtError), e.onRecoverableError !== void 0 && (i = e.onRecoverableError)), e = qd(
      t,
      1,
      !1,
      null,
      null,
      l,
      a,
      null,
      n,
      u,
      i,
      Jd
    ), t[Sl] = e.current, Fc(t), new yo(e);
  }, Yu.hydrateRoot = function(t, e, l) {
    if (!Bt(t)) throw Error(b(299));
    var a = !1, n = "", u = er, i = lr, f = ar, s = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (u = l.onUncaughtError), l.onCaughtError !== void 0 && (i = l.onCaughtError), l.onRecoverableError !== void 0 && (f = l.onRecoverableError), l.formState !== void 0 && (s = l.formState)), e = qd(
      t,
      1,
      !0,
      e,
      l ?? null,
      a,
      n,
      s,
      u,
      i,
      f,
      Jd
    ), e.context = jd(null), l = e.current, a = we(), a = se(a), n = aa(a), n.callback = null, na(l, n, a), l = a, e.current.lanes = l, Ql(e, l), hl(e), t[Sl] = e.current, Fc(t), new of(e);
  }, Yu.version = "19.2.3", Yu;
}
var nm;
function n0() {
  if (nm) return vo.exports;
  nm = 1;
  function A() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(A);
      } catch (J) {
        console.error(J);
      }
  }
  return A(), vo.exports = a0(), vo.exports;
}
var u0 = n0(), um = To();
function i0(A) {
  const J = (c) => {
    const o = document.getElementById(c);
    if (!o)
      throw new Error(`Missing cmux diff viewer element: ${c}`);
    return o;
  }, st = A.assets ?? {}, b = (c, o) => {
    if (typeof c != "string" || c.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${o}`);
    return new URL(c, window.location.href).href;
  }, Bt = b(st.diffsModuleURL, "diffsModuleURL"), wt = b(st.treesModuleURL, "treesModuleURL"), kt = b(st.workerPoolModuleURL, "workerPoolModuleURL"), Pt = b(st.workerModuleURL, "workerModuleURL"), C = A.payload ?? {}, _ = C.labels ?? {}, lt = J("viewer"), L = J("status"), Et = J("toolbar"), Xt = J("source-select"), fe = J("repo-select"), te = J("base-select"), Ye = J("source-detail"), vt = J("jump-select"), Ge = J("external-link"), Rt = J("files-toggle"), Ft = J("layout-toggle"), ce = J("options-button"), Nt = J("options-menu"), et = J("files-sidebar"), Ut = J("file-list"), De = J("files-count"), xe = J("file-search-toggle"), oe = J("file-collapse-toggle"), ee = J("stats-files"), al = J("stats-added"), Le = J("stats-deleted"), G = (c) => _[c] ?? c, m = {
    layout: C.layout === "unified" ? "unified" : "split",
    filesVisible: !0,
    wordWrap: !1,
    collapsed: !1,
    expandUnchanged: !1,
    showBackgrounds: !0,
    lineNumbers: !0,
    diffIndicators: "bars",
    wordDiffs: !1,
    fileSearchOpen: !1
  };
  let D, Y, Q;
  const K = [], r = [], M = /* @__PURE__ */ new Map();
  let B = /* @__PURE__ */ new Set(), H = null, k = null, W = /* @__PURE__ */ new Map(), ct = { value: null }, $t = "", pt = "", yl = !1, Xe = /* @__PURE__ */ new Map(), nl = /* @__PURE__ */ new Map();
  document.title = C.title, ye(C.appearance), ge(), re(C.sourceOptions ?? []), en(fe, C.repoOptions ?? [], C.repoRoot ?? "", G("repoPath")), en(te, C.baseOptions ?? [], C.branchBaseRef ?? "", G("branchBase"));
  const jn = globalThis.queueMicrotask ?? ((c) => setTimeout(c, 0));
  C.pendingReplacement === !0 ? (Oe(C.statusMessage ?? G("loadingDiff"), { pending: !0 }), Gu()) : typeof C.statusMessage == "string" && C.statusMessage.length > 0 ? Oe(C.statusMessage, { error: C.statusIsError === !0 }) : jn(() => {
    gl().catch((c) => {
      console.error("cmux diff viewer render failed", c), Oe(G("renderFailed"), { error: !0 });
    });
  });
  async function gl() {
    Oe(G("loadingRenderer"));
    const [
      {
        CodeView: c,
        getFiletypeFromFileName: o,
        parsePatchFiles: y,
        preloadHighlighter: O,
        processFile: q,
        registerCustomTheme: R
      },
      N
    ] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(Bt),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(wt).catch((At) => (console.warn("cmux diff file tree import failed", At), null))
    ]);
    if (Ca(R, C.appearance.themes.light), Ca(R, C.appearance.themes.dark), Oe(G("parsingDiff")), Sa("loading"), Y = await Yn(), Zn(K), se(), window.__cmuxDiffViewer = { codeView: D, items: K, state: m, workerPool: Y }, Gn(Y), Y?.initialize?.()?.then?.(() => Ln(Y?.getStats?.()))?.catch?.((At) => console.warn("cmux diff worker pool initialization failed", At)), window.addEventListener("pagehide", () => Y?.terminate?.(), { once: !0 }), await Qu({
      CodeView: c,
      parsePatchFiles: y,
      processFile: q,
      treesModule: N
    }), K.length === 0)
      throw new Error(G("noFileDiffs"));
    Y || Jn(C.appearance, r.length > 0 ? r : K, o, O).catch((At) => console.warn("cmux diff highlighter preload failed", At));
  }
  function Oe(c, o = {}) {
    L.isConnected || lt.replaceChildren(L), document.body.dataset.statusOnly = o.pending === !0 || o.error === !0 ? "true" : "false", L.dataset.error = o.error === !0 ? "true" : "false", L.dataset.pending = o.pending === !0 ? "true" : "false", L.textContent = c;
  }
  function wn(c) {
    document.open(), document.write(c), document.close();
  }
  async function df(c) {
    if (!c.ok)
      return Oe(G("renderFailed"), { error: !0 }), !1;
    const o = await c.text();
    return o.includes('data-cmux-diff-pending="true"') ? !1 : (wn(o), !0);
  }
  async function Gu() {
    try {
      const c = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
      await df(c);
    } catch (c) {
      document.documentElement.dataset.cmuxDiffWait = "failed", Oe(G("renderFailed"), { error: !0 }), console.warn("cmux diff viewer deferred load failed", c);
    }
  }
  async function Yn() {
    if (typeof Worker > "u")
      return null;
    try {
      const c = await import(kt);
      Ca(c.registerCustomTheme, C.appearance.themes.light), Ca(c.registerCustomTheme, C.appearance.themes.dark);
      const o = new URL(Pt, window.location.href).href;
      return c.createDiffWorkerPool({
        workerURL: o,
        highlighterOptions: Lu()
      }) ?? null;
    } catch (c) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", c), null;
    }
  }
  function Gn(c) {
    if (!c) {
      Sa("fallback");
      return;
    }
    Sa("enabled"), Ln(c.getStats?.());
    const o = c.subscribeToStatChanges?.((y) => {
      Ln(y);
    });
    typeof o == "function" && window.addEventListener("pagehide", o, { once: !0 });
  }
  function Sa(c) {
    document.body.dataset.workerPool = c;
  }
  function Ln(c) {
    !c || typeof c != "object" || (typeof c.managerState == "string" && (document.body.dataset.workerPoolState = c.managerState), Number.isFinite(c.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(c.totalWorkers)), typeof c.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(c.workersFailed)));
  }
  function Lu() {
    return {
      theme: C.appearance.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: m.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const le = /^From\s+([a-f0-9]+)\s/im;
  function Xu(c, o) {
    const y = c?.match(le);
    return y?.[1] ? new TextDecoder().decode(new TextEncoder().encode(y[1].slice(0, 5))) : `Commit ${o + 1}`;
  }
  async function Qu({ CodeView: c, parsePatchFiles: o, processFile: y, treesModule: O }) {
    const q = mf(), R = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, N = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let rt = performance.now(), At = performance.now(), ot = !0;
    const de = {
      initialBatchSize: cl(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function kn(T, U) {
      const Z = Fn(q, T, U);
      return Z?.renamedItem && ai(Z.renamedItem), Z?.item;
    }
    function Fn(T, U, Z) {
      if (!U)
        return null;
      const $ = Da(U), dt = Z == null ? $ : `${Z}/${$}`, mt = $.length === 0 ? void 0 : T.pathStateByTreePath.get(dt), Ht = mt == null ? void 0 : kl(T, dt, mt), be = Ua(U), Ce = {
        id: T.itemIdToFile.has(dt) ? zl(T, `${dt}?2`) : dt,
        type: "diff",
        fileDiff: U,
        version: 0
      }, ii = T.items.length;
      T.fileIndex += 1, T.items.push(Ce), T.pendingItems.push(Ce), T.pendingItemById.set(Ce.id, Ce), T.itemIdToFile.set(Ce.id, { fileOrder: ii, path: $ }), T.itemIdByTreePath.set(dt, Ce.id), T.treePathByItemId.set(Ce.id, dt), T.diffStats.addedLines += be.added, T.diffStats.deletedLines += be.deleted, T.diffStats.fileCount += 1, T.diffStats.totalLinesOfCode += U.unifiedLineCount ?? U.splitLineCount ?? 0;
      const tu = T.statsByPath.get(dt);
      return T.statsByPath.set(dt, be), mt != null && !Te(tu, be) && (T.pendingStatsChanged = !0), $.length > 0 && (mt == null && T.paths.push(dt), T.pathToItemId.set(dt, Ce.id), li(T, dt, U.type, mt?.sawDeleted === !0), T.pathStateByTreePath.set(dt, {
        currentItem: Ce,
        currentItemId: Ce.id,
        currentType: U.type,
        fileOrder: ii,
        sawDeleted: mt?.sawDeleted === !0 || U.type === "deleted"
      })), { item: Ce, renamedItem: Ht };
    }
    function kl(T, U, Z) {
      const $ = Z.currentItemId, dt = Z.currentType === "deleted" ? "?deleted" : "?previous", mt = zl(T, `${U}${dt}`);
      if (Z.currentItem.id = mt, Z.currentItemId = mt, T.itemIdToFile.has($)) {
        const Ht = T.itemIdToFile.get($);
        T.itemIdToFile.delete($), T.itemIdToFile.set(mt, Ht);
      }
      if (T.treePathByItemId.has($) && (T.treePathByItemId.delete($), T.treePathByItemId.set(mt, U)), T.pendingItemById.has($)) {
        const Ht = T.pendingItemById.get($);
        T.pendingItemById.delete($), T.pendingItemById.set(mt, Ht);
        return;
      }
      return { oldId: $, newId: mt };
    }
    function zl(T, U) {
      if (!T.itemIdToFile.has(U))
        return U;
      let Z = T.nextCollisionSuffixByBase.get(U) ?? 2, $ = `${U}-${Z}`;
      for (; T.itemIdToFile.has($); )
        Z += 1, $ = `${U}-${Z}`;
      return T.nextCollisionSuffixByBase.set(U, Z + 1), $;
    }
    function li(T, U, Z, $) {
      if ($ && Z !== "deleted") {
        T.gitStatusByPath.delete(U) && an(T, U);
        return;
      }
      const dt = Oa(Z);
      if (dt === "modified") {
        T.gitStatusByPath.delete(U) && an(T, U);
        return;
      }
      if (T.gitStatusByPath.get(U)?.status === dt)
        return;
      const Ht = { path: U, status: dt };
      T.gitStatusByPath.set(U, Ht), T.pendingGitStatusRemovePaths.delete(U), T.pendingGitStatusSetByPath.set(U, Ht);
    }
    function an(T, U) {
      T.pendingGitStatusSetByPath.delete(U), T.pendingGitStatusRemovePaths.add(U);
    }
    function ai(T) {
      if (B.delete(T.oldId) && B.add(T.newId), M.has(T.oldId)) {
        const U = M.get(T.oldId);
        M.delete(T.oldId), M.set(T.newId, U);
      }
      ln(T.oldId, T.newId), D?.updateItemId?.(T.oldId, T.newId);
    }
    async function Ml(T, U) {
      kn(T, U) && await Ue(!1);
    }
    async function Ue(T) {
      if (q.pendingItems.length === 0)
        return;
      const U = performance.now();
      if (!T && ot && U - rt >= 8 && q.pendingItems.length < de.initialBatchSize && U - At < de.initialMaxWait) {
        await Zu(), rt = performance.now();
        return;
      }
      const Z = ot ? de.initialBatchSize : de.incrementalBatchSize, $ = ot ? de.initialMaxWait : de.incrementalMaxWait;
      if (T || q.pendingItems.length >= Z || U - At >= $) {
        Wn(), await Zu(), rt = performance.now();
        return;
      }
    }
    function Wn() {
      if (q.pendingItems.length === 0)
        return;
      const T = q.pendingItems.splice(0, q.pendingItems.length);
      q.pendingItemById.clear();
      const U = T, Z = r.length > 0;
      K.push(...T);
      for (const $ of T)
        M.set($.id, $);
      if (U.length > 0) {
        r.push(...U);
        for (const $ of U)
          B.add($.id);
        D ? D.addItems(U) : (D = new c(Ju(), Y ?? void 0), D.setup(lt), D.setItems(r), D.render(!0), window.__cmuxDiffViewer.codeView = D);
      }
      bf(T), Qe(O, !1, T.length), N.flushCount += 1, N.maxBatchSize = Math.max(N.maxBatchSize, T.length), N.fileCount = K.length, N.renderableFileCount = r.length, $a(N), At = performance.now(), ot && (ot = !1, L.remove()), Z || ve(r[0]?.id ?? K[0]?.id ?? ""), window.__cmuxDiffViewer.items = K, window.__cmuxDiffViewer.codeViewItems = r, window.__cmuxDiffViewer.streamMetrics = N;
    }
    function Fl() {
      D && (D.syncContainerHeight?.(), D.render(!0));
    }
    function Qe(T, U, Z = 1) {
      if (R.treesModule = T, R.dirtyCount += Z, U || R.lastRefreshAt === 0) {
        Ba(R.treesModule);
        return;
      }
      const $ = performance.now() - R.lastRefreshAt;
      if (R.dirtyCount >= 1e3 || $ >= 1e3) {
        Ba(R.treesModule);
        return;
      }
      if (R.timeout !== 0)
        return;
      const dt = Math.max(0, 1e3 - $);
      R.timeout = window.setTimeout(() => {
        R.timeout = 0, Ba(R.treesModule);
      }, dt);
    }
    function Ba(T) {
      R.timeout !== 0 && (window.clearTimeout(R.timeout), R.timeout = 0), R.dirtyCount = 0, R.lastRefreshAt = performance.now(), N.treeRefreshCount += 1, k = Vu(q), pf(k, T), se(), $a(N);
    }
    const ol = await fetch(C.patchURL, { cache: "no-store" });
    if (!ol.ok)
      throw new Error(`${G("loadingDiff")} (${ol.status})`);
    if (!ol.body?.getReader) {
      const T = await ol.text();
      await xa(T, o, Ml), await Ue(!0), Fl(), Qe(O, !0), N.completedAt = performance.now();
      return;
    }
    const $n = new TextDecoder(), nn = ol.body.getReader(), Ra = "diff --git ", In = `
` + Ra, me = In.length - 1, sl = /\S/;
    function El(T, U) {
      const Z = Math.max(U, 0);
      if (Z === 0 && T.startsWith(Ra))
        return 0;
      const $ = T.indexOf(In, Z);
      return $ === -1 ? void 0 : $ + 1;
    }
    function Wl(T, U) {
      return Math.max(U, T.length - me);
    }
    function Sf(T, U, Z) {
      const $ = Math.max(U, 0), dt = Math.min(Z, T.length);
      if ($ >= dt)
        return;
      let mt = T.lastIndexOf(`
From `, dt - 1);
      for (; mt !== -1; ) {
        const Ht = mt + 1;
        if (Ht < $)
          return;
        if (Ht >= dt) {
          mt = T.lastIndexOf(`
From `, mt - 1);
          continue;
        }
        const be = T.indexOf(`
`, Ht + 1), Ha = T.slice(Ht, be === -1 || be > dt ? dt : be);
        if (le.test(Ha))
          return Ht;
        mt = T.lastIndexOf(`
From `, mt - 1);
      }
    }
    function Pn(T) {
      const U = El(T, 0);
      if (U == null || U <= 0)
        return;
      const Z = T.slice(0, U);
      return le.test(Z) ? Z : void 0;
    }
    async function un(T) {
      if (T.trim() === "")
        return;
      const U = Pn(T);
      U != null && (ni = Xu(U, ui), ui += 1);
      const Z = `cmux-diff-file-${q.fileIndex}`;
      await Ml(y(T, {
        cacheKey: Z,
        isGitDiff: !0
      }), ni);
    }
    function Na() {
      let T, U = "", Z = 0, $ = !1;
      function dt() {
        if (T == null) {
          if (T = El(U, Z), T == null)
            return Z = Wl(U, 0), null;
          $ = !0, Z = T + 1;
        }
        for (; ; ) {
          const mt = T;
          if (mt == null)
            return null;
          const Ht = El(U, Z);
          if (Ht == null)
            return Z = Wl(U, mt + 1), null;
          const be = Sf(U, mt + 1, Ht) ?? Ht, Ha = U.slice(0, be);
          if (U = U.slice(be), T = El(U, 0), Z = T == null ? 0 : T + 1, sl.test(Ha))
            return Ha;
        }
      }
      return {
        push(mt) {
          mt.length > 0 && (U += mt);
        },
        takeAvailableFile: dt,
        finish() {
          const mt = dt();
          if (mt != null)
            return { fileText: mt };
          if (!sl.test(U))
            return U = "", {};
          if (!$) {
            const be = U;
            return U = "", { fallbackPatchContent: be };
          }
          const Ht = U;
          return U = "", { fileText: Ht };
        }
      };
    }
    async function $l(T) {
      let U;
      for (; (U = T.takeAvailableFile()) != null; )
        await un(U);
    }
    const Al = Na();
    let ni, ui = 0;
    for (; ; ) {
      const { done: T, value: U } = await nn.read();
      if (T) {
        const Z = $n.decode();
        Z.length > 0 && (Al.push(Z), await $l(Al));
        break;
      }
      Al.push($n.decode(U, { stream: !0 })), await $l(Al);
    }
    const fn = Al.finish();
    fn.fileText != null ? (await un(fn.fileText), await $l(Al)) : fn.fallbackPatchContent != null && await xa(fn.fallbackPatchContent, o, Ml), await Ue(!0), Fl(), Qe(O, !0), N.completedAt = performance.now(), $a(N);
  }
  function $a(c) {
    document.body.dataset.streamFileCount = String(c.fileCount ?? K.length), document.body.dataset.streamRenderableFileCount = String(c.renderableFileCount ?? r.length), document.body.dataset.streamFlushCount = String(c.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(c.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(c.treeRefreshCount ?? 0), Number.isFinite(c.completedAt) && c.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(c.completedAt - c.startedAt)));
  }
  async function xa(c, o, y) {
    const O = o(c, "cmux-diff"), q = O.length > 1;
    for (const [R, N] of O.entries()) {
      const rt = q ? Xu(N.patchMetadata, R) : void 0;
      for (const At of N.files ?? [])
        await y(At, rt);
    }
  }
  function mf() {
    return {
      diffStats: {
        addedLines: 0,
        deletedLines: 0,
        fileCount: 0,
        totalLinesOfCode: 0
      },
      fileIndex: 0,
      gitStatusByPath: /* @__PURE__ */ new Map(),
      itemIdToFile: /* @__PURE__ */ new Map(),
      itemIdByTreePath: /* @__PURE__ */ new Map(),
      lastTreeSource: void 0,
      nextCollisionSuffixByBase: /* @__PURE__ */ new Map(),
      items: [],
      pathStateByTreePath: /* @__PURE__ */ new Map(),
      paths: [],
      pathToItemId: /* @__PURE__ */ new Map(),
      pendingGitStatusRemovePaths: /* @__PURE__ */ new Set(),
      pendingGitStatusSetByPath: /* @__PURE__ */ new Map(),
      pendingItems: [],
      pendingItemById: /* @__PURE__ */ new Map(),
      pendingStatsChanged: !1,
      statsByPath: /* @__PURE__ */ new Map(),
      treePathByItemId: /* @__PURE__ */ new Map()
    };
  }
  function Vu(c) {
    const o = c.lastTreeSource, y = hf(c), O = {
      diffStats: { ...c.diffStats },
      gitStatus: Array.from(c.gitStatusByPath.values()),
      gitStatusPatch: y,
      pathCount: c.paths.length,
      paths: c.paths,
      pathToItemId: c.pathToItemId,
      previousSource: o,
      statsChanged: c.pendingStatsChanged,
      statsByPath: c.statsByPath,
      treePathByItemId: c.treePathByItemId
    };
    return c.pendingStatsChanged = !1, c.lastTreeSource = O, O;
  }
  function hf(c) {
    if (c.pendingGitStatusRemovePaths.size === 0 && c.pendingGitStatusSetByPath.size === 0)
      return;
    const o = {};
    return c.pendingGitStatusRemovePaths.size > 0 && (o.remove = Array.from(c.pendingGitStatusRemovePaths), c.pendingGitStatusRemovePaths.clear()), c.pendingGitStatusSetByPath.size > 0 && (o.set = Array.from(c.pendingGitStatusSetByPath.values()), c.pendingGitStatusSetByPath.clear()), o;
  }
  function Zu() {
    return new Promise((c) => {
      let o = !1, y = 0;
      const O = () => {
        o || (o = !0, y !== 0 && window.clearTimeout(y), c());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        y = window.setTimeout(O, 50), window.requestAnimationFrame(O);
      else if (typeof MessageChannel < "u") {
        const q = new MessageChannel();
        q.port1.onmessage = O, q.port2.postMessage(void 0);
      } else
        queueMicrotask(O);
    });
  }
  async function Ta() {
    return ct.value == null && (ct.value = fetch(C.patchURL, { cache: "no-store" }).then(async (c) => {
      if (!c.ok)
        throw new Error(`${G("loadingDiff")} (${c.status})`);
      return c.text();
    })), ct.value;
  }
  function ye(c) {
    const o = document.documentElement.style;
    o.setProperty("--cmux-diff-bg-light", c.themes.light.background), o.setProperty("--cmux-diff-bg-dark", c.themes.dark.background), o.setProperty("--cmux-diff-fg-light", c.themes.light.foreground), o.setProperty("--cmux-diff-fg-dark", c.themes.dark.foreground), o.setProperty("--cmux-diff-selection-bg-light", c.themes.light.selectionBackground), o.setProperty("--cmux-diff-selection-bg-dark", c.themes.dark.selectionBackground), o.setProperty("--cmux-diff-code-font-family", ul(c.fontFamily)), o.setProperty("--cmux-diff-font-size", `${c.fontSize}px`), o.setProperty("--cmux-diff-line-height", `${c.lineHeight}px`);
  }
  function ul(c) {
    const o = typeof c == "string" && c.trim() !== "" ? c.trim() : "Menlo";
    return `${JSON.stringify(o)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
  }
  function ge() {
    Rt.innerHTML = pe("files"), xe.innerHTML = pe("search"), oe.innerHTML = pe("sidebarCollapse"), Ft.innerHTML = pe(m.layout), ce.innerHTML = pe("dots"), typeof C.externalURL == "string" && C.externalURL.length > 0 && (Ge.href = C.externalURL, Ge.innerHTML = pe("external"), Ge.hidden = !1), Rt.addEventListener("click", () => Ma(!m.filesVisible)), oe.addEventListener("click", () => Ma(!1)), xe.addEventListener("click", () => Xn(!m.fileSearchOpen)), Ft.addEventListener("click", () => gf(m.layout === "split" ? "unified" : "split")), ce.addEventListener("click", () => Ea(Nt.hidden)), document.addEventListener("click", (c) => {
      Nt.hidden || c.target instanceof Node && Et.contains(c.target) || Ea(!1);
    }), document.addEventListener("keydown", (c) => {
      c.key === "Escape" && Ea(!1);
    }), yf(), se();
  }
  function yf() {
    const c = C.shortcuts ?? {}, o = za(c.diffViewerScrollDown), y = za(c.diffViewerScrollUp), O = za(c.diffViewerScrollToBottom), q = za(c.diffViewerScrollToTop), R = za(c.diffViewerOpenFileSearch);
    let N = null, rt = 0;
    document.addEventListener("keydown", (ot) => {
      if (!(ot.defaultPrevented || Pa(ot.target))) {
        if (N && !pl(N.shortcut.second, ot) && At(), N && pl(N.shortcut.second, ot)) {
          ot.preventDefault(), N.action(), At();
          return;
        }
        if (vl(o, ot)) {
          ot.preventDefault(), Xl(1);
          return;
        }
        if (vl(y, ot)) {
          ot.preventDefault(), Xl(-1);
          return;
        }
        if (vl(O, ot)) {
          ot.preventDefault(), lt.scrollTo({ top: lt.scrollHeight, behavior: "auto" });
          return;
        }
        if (vl(R, ot) && Q) {
          ot.preventDefault(), Ma(!0), Xn(!0);
          return;
        }
        Ia(q, ot) && (ot.preventDefault(), N = {
          shortcut: q,
          action: () => lt.scrollTo({ top: 0, behavior: "auto" })
        }, rt = setTimeout(At, 700));
      }
    });
    function At() {
      N = null, rt !== 0 && (clearTimeout(rt), rt = 0);
    }
  }
  function za(c) {
    return !c || c.unbound === !0 || !c.first ? null : {
      first: Ku(c.first),
      second: c.second ? Ku(c.second) : null
    };
  }
  function Ku(c) {
    return {
      key: String(c?.key ?? "").toLowerCase(),
      command: c?.command === !0,
      shift: c?.shift === !0,
      option: c?.option === !0,
      control: c?.control === !0
    };
  }
  function vl(c, o) {
    return c && !c.second && pl(c.first, o);
  }
  function Ia(c, o) {
    return c && c.second && pl(c.first, o);
  }
  function pl(c, o) {
    return !c || o.metaKey !== c.command || o.ctrlKey !== c.control || o.altKey !== c.option || o.shiftKey !== c.shift ? !1 : bl(o) === c.key;
  }
  function bl(c) {
    return c.code === "Space" ? "space" : typeof c.key != "string" || c.key.length === 0 ? "" : (c.key.length === 1, c.key.toLowerCase());
  }
  function Pa(c) {
    const o = c instanceof Element ? c : null;
    return o ? !!o.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function Xl(c) {
    const o = Math.max(80, Math.floor(lt.clientHeight * 0.38));
    lt.scrollBy({ top: c * o, behavior: "auto" });
  }
  function Ju() {
    return {
      layout: { paddingTop: 0, gap: 1, paddingBottom: 0 },
      diffStyle: m.layout,
      diffIndicators: m.diffIndicators,
      overflow: m.wordWrap ? "wrap" : "scroll",
      expandUnchanged: m.expandUnchanged,
      disableBackground: !m.showBackgrounds,
      disableLineNumbers: !m.lineNumbers,
      lineHoverHighlight: "number",
      enableLineSelection: !0,
      enableGutterUtility: !0,
      lineDiffType: m.wordDiffs ? "word" : "none",
      stickyHeaders: !0,
      unsafeCSS: ku(),
      theme: C.appearance.theme,
      themeType: "system"
    };
  }
  function ku() {
    return `
    [data-diffs-header] {
      container-type: scroll-state;
      container-name: sticky-header;
    }
    @container sticky-header scroll-state(stuck: top) {
      [data-diffs-header]::after {
        position: absolute;
        bottom: -1px;
        left: 0;
        width: 100%;
        height: 1px;
        content: '';
        background-color: var(--cmux-diff-border);
      }
    }
    [data-diffs-header=default],
    [data-diffs-header=default] [data-additions-count],
    [data-diffs-header=default] [data-deletions-count],
    [data-separator-wrapper],
    [data-separator-content],
    [data-unmodified-lines],
    [data-expand-button] {
      font-family: var(--diffs-header-font-family, var(--diffs-header-font-fallback));
    }
  `;
  }
  function Ie() {
    const c = Ju();
    if (!D) {
      Ql();
      return;
    }
    D.setOptions(c), Ql(), D.render(!0);
  }
  function Ql() {
    Y?.setRenderOptions && Y.setRenderOptions(Lu()).then(() => D?.render(!0)).catch((c) => console.warn("cmux diff worker render options update failed", c));
  }
  function gf(c) {
    m.layout = c === "unified" ? "unified" : "split", se(), Ie();
  }
  function Ma(c) {
    m.filesVisible = c, document.body.dataset.filesHidden = c ? "false" : "true", et.setAttribute("aria-hidden", String(!c)), c ? et.removeAttribute("inert") : et.setAttribute("inert", ""), se();
  }
  function Xn(c) {
    m.fileSearchOpen = !!c, Q && (m.fileSearchOpen ? Q.openSearch("") : Q.closeSearch()), se();
  }
  function Fu(c) {
    m.collapsed = c;
    const o = r.map((q) => ({
      ...q,
      collapsed: c,
      version: (q.version ?? 0) + 1
    })), y = new Map(o.map((q) => [q.id, q])), O = K.map((q) => y.get(q.id) ?? {
      ...q,
      collapsed: c,
      version: (q.version ?? 0) + 1
    });
    r.splice(0, r.length, ...o), K.splice(0, K.length, ...O), D && (D.setItems(r), D.render(!0)), se();
  }
  function se() {
    Rt.setAttribute("aria-pressed", String(m.filesVisible)), Rt.title = m.filesVisible ? G("hideFiles") : G("showFiles"), Rt.setAttribute("aria-label", Rt.title), oe.title = G("hideFiles"), oe.setAttribute("aria-label", oe.title), Ft.innerHTML = pe(m.layout), Ft.title = m.layout === "split" ? G("switchToUnifiedDiff") : G("switchToSplitDiff"), Ft.setAttribute("aria-label", Ft.title), ce.setAttribute("aria-expanded", String(!Nt.hidden)), document.documentElement.dataset.layout = m.layout, document.documentElement.dataset.wordWrap = String(m.wordWrap), document.documentElement.dataset.diffIndicators = m.diffIndicators, xe.disabled = !Q, xe.setAttribute("aria-pressed", String(m.fileSearchOpen)), xe.title = m.fileSearchOpen ? G("hideFileSearch") : G("showFileSearch"), xe.setAttribute("aria-label", xe.title);
  }
  function Ea(c) {
    c && tn(), Nt.hidden = !c, se();
  }
  function tn() {
    Nt.textContent = "";
    const c = [
      { label: G("refresh"), icon: "refresh", action: () => window.location.reload() },
      { label: m.wordWrap ? G("disableWordWrap") : G("enableWordWrap"), icon: "wrap", checked: m.wordWrap, action: () => {
        m.wordWrap = !m.wordWrap, Ie();
      } },
      { label: m.collapsed ? G("expandAllDiffs") : G("collapseAllDiffs"), icon: "collapse", checked: m.collapsed, action: () => Fu(!m.collapsed) },
      "separator",
      { label: m.filesVisible ? G("hideFiles") : G("showFiles"), icon: "files", checked: m.filesVisible, action: () => Ma(!m.filesVisible) },
      { label: m.expandUnchanged ? G("collapseUnchangedContext") : G("expandUnchangedContext"), icon: "document", checked: m.expandUnchanged, action: () => {
        m.expandUnchanged = !m.expandUnchanged, Ie();
      } },
      { label: m.showBackgrounds ? G("hideBackgrounds") : G("showBackgrounds"), icon: "background", checked: m.showBackgrounds, action: () => {
        m.showBackgrounds = !m.showBackgrounds, Ie();
      } },
      { label: m.lineNumbers ? G("hideLineNumbers") : G("showLineNumbers"), icon: "numbers", checked: m.lineNumbers, action: () => {
        m.lineNumbers = !m.lineNumbers, Ie();
      } },
      { label: m.wordDiffs ? G("disableWordDiffs") : G("enableWordDiffs"), icon: "word", checked: m.wordDiffs, action: () => {
        m.wordDiffs = !m.wordDiffs, Ie();
      } },
      { kind: "segment", label: G("indicatorStyle"), icon: "bars", options: [
        { value: "bars", icon: "bars", label: G("bars") },
        { value: "classic", icon: "classic", label: G("classic") },
        { value: "none", icon: "eye", label: G("none") }
      ] },
      "separator",
      { label: G("copyGitApplyCommand"), icon: "clipboard", action: il }
    ];
    for (const o of c) {
      if (o === "separator") {
        const O = document.createElement("div");
        O.className = "menu-separator", Nt.append(O);
        continue;
      }
      if (o.kind === "segment") {
        const O = document.createElement("div");
        O.className = "menu-item menu-segment", O.setAttribute("role", "presentation"), O.innerHTML = `${pe(o.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`, O.querySelector(".menu-label").textContent = o.label;
        const q = O.querySelector(".menu-segment-controls");
        for (const R of o.options) {
          const N = document.createElement("button");
          N.type = "button", N.className = "segment-button", N.title = R.label, N.setAttribute("aria-label", R.label), N.setAttribute("aria-pressed", String(m.diffIndicators === R.value)), N.innerHTML = pe(R.icon), N.addEventListener("click", () => {
            m.diffIndicators = R.value, Ie(), tn(), se();
          }), q.append(N);
        }
        Nt.append(O);
        continue;
      }
      const y = document.createElement("button");
      y.type = "button", y.className = "menu-item", y.setAttribute("role", o.checked == null ? "menuitem" : "menuitemcheckbox"), o.checked != null && y.setAttribute("aria-checked", String(!!o.checked)), y.disabled = !!o.disabled, y.innerHTML = `${pe(o.icon)}<span class="menu-label"></span><span class="menu-check">${o.checked ? pe("check") : ""}</span>`, y.querySelector(".menu-label").textContent = o.label, y.addEventListener("click", () => {
        y.disabled || (o.action?.(), tn(), se());
      }), Nt.append(y);
    }
  }
  function Wu(c) {
    const o = new Set(c.split(/\r?\n/));
    let y = "CMUX_DIFF_PATCH", O = 0;
    for (; o.has(y); )
      O += 1, y = `CMUX_DIFF_PATCH_${O}`;
    return y;
  }
  async function il() {
    const o = await Ta(), y = o.endsWith(`
`) ? o : `${o}
`, O = Wu(y), q = `git apply <<'${O}'
${y}${O}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(q);
      } catch {
        Qt(q);
      }
    else
      Qt(q);
    ce.title = G("copiedGitApplyCommand"), ce.setAttribute("aria-label", G("copiedGitApplyCommand"));
  }
  function Qt(c) {
    const o = document.createElement("textarea");
    o.value = c, o.setAttribute("readonly", ""), o.style.position = "fixed", o.style.left = "-9999px", document.body.append(o), o.select(), document.execCommand("copy"), o.remove();
  }
  function re(c) {
    if (Ye.textContent = Sl(), !Array.isArray(c) || c.length < 2)
      return;
    Xt.textContent = "";
    const o = c.find((y) => y.selected) ?? c.find((y) => !y.disabled);
    for (const y of c) {
      const O = document.createElement("option");
      O.value = y.value, O.textContent = y.label, O.disabled = y.disabled || !y.url, O.selected = y.value === o?.value, y.message && (O.title = y.message), Xt.append(O);
    }
    Ye.textContent = o?.sourceLabel ?? Sl(), Xt.hidden = !1, Xt.addEventListener("change", () => {
      const y = c.find((O) => O.value === Xt.value);
      if (!y?.url) {
        Xt.value = o?.value ?? "";
        return;
      }
      Oe(G("loadingDiff"), { pending: !0 }), window.location.href = y.url;
    });
  }
  function Sl() {
    return [C.sourceLabel, C.repoRoot, C.branchBaseRef].filter((o) => typeof o == "string" && o.trim() !== "").join(" | ");
  }
  function en(c, o, y, O) {
    if (!c || !Array.isArray(o) || o.length < 2)
      return;
    c.textContent = "";
    const q = o.find((R) => R.selected) ?? o.find((R) => !R.disabled);
    for (const R of o) {
      const N = document.createElement("option");
      N.value = R.value, N.textContent = R.label, N.disabled = R.disabled || !R.url, N.selected = R.value === q?.value, R.message && (N.title = R.message), c.append(N);
    }
    c.hidden = !1, c.title = O, c.addEventListener("change", () => {
      const R = o.find((N) => N.value === c.value);
      if (!R?.url) {
        c.value = q?.value ?? y ?? "";
        return;
      }
      Oe(G("loadingDiff"), { pending: !0 }), window.location.href = R.url;
    });
  }
  function vf(c, o) {
    const y = xl(c), O = Qn(o);
    if (_a(c, []), Q && (Q.cleanUp?.(), Q = null), H = null, m.fileSearchOpen = !1, Ut.textContent = "", De.textContent = `${y}`, Iu(c), O)
      try {
        $u(c, o), se();
        return;
      } catch (R) {
        console.warn("cmux diff file tree setup failed", R);
      }
    const q = fl(c);
    _a(c, q), Vn(q), se();
  }
  function pf(c, o) {
    const y = xl(c);
    if (_a(c, []), De.textContent = `${y}`, Iu(c), Q && Ut.dataset.treeMode === "pierre" && o?.preparePresortedFileTreeInput) {
      Aa(c, o);
      return;
    }
    if (Q || Ut.childElementCount === 0) {
      vf(c, o);
      return;
    }
    const O = fl(c);
    _a(c, O), Ut.textContent = "", Vn(O);
  }
  function $u(c, o) {
    const { FileTree: y, preparePresortedFileTreeInput: O } = o, q = Tl(c);
    H = c;
    const R = q[0];
    Yt(c), Ut.dataset.treeMode = "pierre", Q = new y({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: R ? [R] : [],
      initialVisibleRowCount: cl(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: O(q),
      presorted: !0,
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: c.gitStatus,
      renderRowDecoration(N) {
        if (N.item.kind !== "file")
          return null;
        const rt = W.get(N.item.path);
        return rt == null || rt.added === 0 && rt.deleted === 0 ? null : {
          text: `+${rt.added} -${rt.deleted}`,
          title: `${rt.added} ${G("additions")}, ${rt.deleted} ${G("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Zl(),
      onSelectionChange(N) {
        if (yl)
          return;
        const rt = N[N.length - 1], At = Xe.get(rt);
        At && Kl(At);
      }
    }), Q.render({ containerWrapper: Ut });
  }
  function Aa(c, o) {
    const y = H, O = Tl(c);
    H = c, Yt(c);
    let q = !1;
    if (y && (c.previousSource === y || Vl(y, c)) && c.pathCount >= y.pathCount) {
      const R = c.paths.slice(y.pathCount, c.pathCount);
      if (R.length > 0)
        try {
          Q.batch(R.map((N) => ({ type: "add", path: N })));
        } catch (N) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", N), Q.resetPaths(O, {
            preparedInput: o.preparePresortedFileTreeInput(O)
          }), q = !0;
        }
    } else
      Q.resetPaths(O, {
        preparedInput: o.preparePresortedFileTreeInput(O)
      }), q = !0;
    c.gitStatusPatch ? typeof Q.applyGitStatusPatch == "function" ? Q.applyGitStatusPatch(c.gitStatusPatch) : Q.setGitStatus(c.gitStatus) : (q || c.statsChanged === !0) && Q.setGitStatus(c.gitStatus);
  }
  function Qn(c) {
    return !!(c?.FileTree && c?.preparePresortedFileTreeInput);
  }
  function xl(c) {
    return c?.pathCount ?? c?.entries?.length ?? 0;
  }
  function fl(c) {
    const o = c?.pathCount ?? c?.entries?.length ?? 0, y = c?.entries ?? [];
    if (y.length > 0)
      return y.length === o ? y : y.slice(0, o);
    const O = Tl(c), q = c?.pathToItemId, R = c?.statsByPath;
    return O.map((N) => {
      const rt = q instanceof Map ? q.get(N) : void 0, At = rt ? M.get(rt) : void 0, ot = At?.fileDiff ?? {};
      return {
        item: At ?? { id: rt ?? N, fileDiff: ot },
        path: N,
        status: ei(ot),
        stats: R instanceof Map ? R.get(N) ?? Ua(ot) : Ua(ot)
      };
    });
  }
  function Tl(c) {
    const o = c?.pathCount ?? c?.paths?.length ?? 0, y = c?.paths ?? [];
    return y.length === o ? y : y.slice(0, o);
  }
  function Vl(c, o) {
    const y = c?.paths, O = o?.paths, q = c?.pathCount ?? y?.length ?? 0, R = o?.pathCount ?? O?.length ?? 0;
    if (!Array.isArray(y) || !Array.isArray(O) || q > R)
      return !1;
    for (let N = 0; N < q; N += 1)
      if (y[N] !== O[N])
        return !1;
    return !0;
  }
  function Yt(c) {
    if (c?.statsByPath instanceof Map) {
      W = c.statsByPath;
      return;
    }
    W = /* @__PURE__ */ new Map();
    const o = fl(c);
    for (const y of o)
      W.set(y.path, y.stats);
  }
  function _a(c, o) {
    if (c?.pathToItemId instanceof Map && c?.treePathByItemId instanceof Map)
      Xe = c.pathToItemId, nl = c.treePathByItemId;
    else if (c?.pathToItemId instanceof Map) {
      Xe = c.pathToItemId, nl = /* @__PURE__ */ new Map();
      for (const [y, O] of Xe)
        nl.set(O, y);
    } else {
      Xe = /* @__PURE__ */ new Map(), nl = /* @__PURE__ */ new Map();
      for (const y of o) {
        const O = y.item?.id;
        O && (Xe.set(y.path, O), nl.set(O, y.path));
      }
    }
    pt && !Xe.has(pt) && (pt = "");
  }
  function Vn(c) {
    delete Ut.dataset.treeMode;
    for (const o of c) {
      const y = o.item, O = y.fileDiff ?? {}, q = o.stats ?? Ua(O), R = document.createElement("button");
      R.type = "button", R.className = "file-entry", R.dataset.itemId = y.id, R.title = Da(O), R.innerHTML = `
      <span class="file-status">${Kn(O)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${q.added}</span>
        <span class="stat-del">-${q.deleted}</span>
      </span>
    `, R.querySelector(".file-name").textContent = Da(O), R.addEventListener("click", () => Kl(y.id)), Ut.append(R);
    }
  }
  function cl() {
    const c = window.visualViewport?.height ?? window.innerHeight;
    return !Number.isFinite(c) || c <= 0 ? 25 : Math.min(96, Math.max(25, Math.ceil(c / 24)));
  }
  function Zl() {
    return `
    [data-file-tree-search-container][data-open='false'] {
      display: none;
    }
    [data-file-tree-search-container] {
      margin: 0 4px 8px 0;
      padding: 0 5px 8px 1px;
      border-bottom: 1px solid var(--trees-border-color);
    }
    [data-file-tree-virtualized-scroll='true'] {
      padding-inline-start: 0;
      padding-inline-end: 2px;
      margin-inline-end: 2px;
    }
    [data-item-contains-git-change='true'] > [data-item-section='git'] {
      display: none;
    }
    [data-item-type='folder'] {
      color: color-mix(in lab, var(--trees-fg) 85%, var(--trees-bg));
      font-weight: 500;
    }
    [data-file-tree-sticky-overlay-content] {
      box-shadow: 0 1px 0 var(--trees-border-color);
    }
  `;
  }
  function Iu(c) {
    const o = c?.diffStats;
    if (o && Number.isFinite(o.addedLines) && Number.isFinite(o.deletedLines) && Number.isFinite(o.fileCount)) {
      ee.textContent = `${o.fileCount}`, al.textContent = `+${o.addedLines}`, Le.textContent = `-${o.deletedLines}`;
      return;
    }
    Pu(c?.entries ?? []);
  }
  function Pu(c) {
    const o = c.reduce((y, O) => {
      const q = O.stats ?? Ua(O.item?.fileDiff ?? {});
      return y.added += q.added, y.deleted += q.deleted, y;
    }, { added: 0, deleted: 0 });
    ee.textContent = `${c.length}`, al.textContent = `+${o.added}`, Le.textContent = `-${o.deleted}`;
  }
  function Zn(c) {
    vt.textContent = "";
    const o = document.createElement("option");
    o.value = "", o.textContent = G("jumpToFile"), vt.append(o), vt.dataset.initialized = "true";
    for (const y of c) {
      const O = document.createElement("option");
      O.value = y.id, O.textContent = Da(y.fileDiff ?? {}), vt.append(O);
    }
    vt.hidden = c.length === 0, vt.onchange = () => {
      vt.value && Kl(vt.value);
    };
  }
  function bf(c) {
    if (c.length === 0)
      return;
    vt.dataset.initialized !== "true" && Zn([]);
    const o = document.createDocumentFragment();
    for (const y of c) {
      const O = document.createElement("option");
      O.value = y.id, O.textContent = Da(y.fileDiff ?? {}), o.append(O);
    }
    vt.append(o), vt.hidden = !1;
  }
  function ln(c, o) {
    if (vt.dataset.initialized === "true") {
      for (const y of vt.options)
        if (y.value === c) {
          y.value = o;
          return;
        }
    }
  }
  function Kl(c) {
    if (!D)
      return;
    const o = Pe(c);
    o && (D.scrollTo({ type: "item", id: o, align: "start", behavior: "smooth-auto" }), ve(o));
  }
  function Pe(c) {
    if (B.has(c))
      return c;
    const o = K.findIndex((y) => y.id === c);
    if (o === -1)
      return r[0]?.id ?? "";
    for (let y = o + 1; y < K.length; y += 1)
      if (B.has(K[y].id))
        return K[y].id;
    for (let y = o - 1; y >= 0; y -= 1)
      if (B.has(K[y].id))
        return K[y].id;
    return "";
  }
  function ve(c) {
    if (!(!c || $t === c)) {
      $t = c, ti(c);
      for (const o of Ut.querySelectorAll(".file-entry"))
        o.setAttribute("aria-current", o.dataset.itemId === c ? "true" : "false");
      vt.value !== c && (vt.value = c);
    }
  }
  function ti(c) {
    if (!Q)
      return;
    const o = nl.get(c);
    if (!(!o || o === pt)) {
      yl = !0;
      try {
        pt && Q.getItem(pt)?.deselect(), Q.getItem(o)?.select(), Q.scrollToPath(o, { focus: !1, offset: "nearest" }), pt = o;
      } finally {
        jn(() => {
          yl = !1;
        });
      }
    }
  }
  function Da(c) {
    return c.name ?? c.newName ?? c.oldName ?? c.prevName ?? G("untitled");
  }
  function Kn(c) {
    switch (c.type) {
      case "new":
        return "A";
      case "deleted":
        return "D";
      case "rename-pure":
      case "rename-changed":
        return "R";
      default:
        return "M";
    }
  }
  function ei(c) {
    return Oa(c.type);
  }
  function Oa(c) {
    switch (c) {
      case "new":
        return "added";
      case "deleted":
        return "deleted";
      case "rename-pure":
      case "rename-changed":
        return "renamed";
      default:
        return "modified";
    }
  }
  function Ua(c) {
    const o = { added: 0, deleted: 0 };
    for (const y of c.hunks ?? [])
      o.added += y.additionLines ?? 0, o.deleted += y.deletionLines ?? 0;
    return o;
  }
  function Te(c, o) {
    return c?.added === o.added && c?.deleted === o.deleted;
  }
  function pe(c) {
    return `<svg viewBox="0 0 20 20" aria-hidden="true">${{
      background: '<rect x="4" y="4" width="12" height="12" rx="2"/><path d="M7 8h6"/><path d="M7 12h6"/>',
      bars: '<path d="M5 4v12"/><path d="M9 6v8"/><path d="M13 8v4"/>',
      check: '<path d="M4 10.5 8 14l8-9"/>',
      classic: '<path d="M4 5h12"/><path d="M4 10h12"/><path d="M4 15h12"/><path d="M7 3v4"/><path d="M13 8v4"/>',
      collapse: '<path d="M7 3v4H3"/><path d="M3 7l5-5"/><path d="M13 17v-4h4"/><path d="M17 13l-5 5"/>',
      document: '<path d="M6 3h6l4 4v10H6z"/><path d="M12 3v5h5"/>',
      dots: '<path d="M5 10h.01"/><path d="M10 10h.01"/><path d="M15 10h.01"/>',
      external: '<path d="M7 5H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-2"/><path d="M11 3h6v6"/><path d="m10 10 7-7"/>',
      eye: '<path d="M2.5 10s2.75-5 7.5-5 7.5 5 7.5 5-2.75 5-7.5 5-7.5-5-7.5-5z"/><circle cx="10" cy="10" r="2.4"/>',
      files: '<path d="M3 5h5l1.5 2H17v9.5H3z"/><path d="M3 7h14"/>',
      image: '<rect x="3" y="4" width="14" height="12" rx="2"/><circle cx="8" cy="8" r="1.3"/><path d="m4 15 4.5-4 3 2.8 2-1.8L17 15"/>',
      numbers: '<path d="M5 5h2v10"/><path d="M4 15h4"/><path d="M11 6.5a2 2 0 1 1 3.2 1.6L11 12h4"/><path d="M11 15h4"/>',
      refresh: '<path d="M16 8a6 6 0 0 0-10.3-3.7L4 6"/><path d="M4 3v3h3"/><path d="M4 12a6 6 0 0 0 10.3 3.7L16 14"/><path d="M16 17v-3h-3"/>',
      search: '<circle cx="8.5" cy="8.5" r="4.5"/><path d="m12 12 4 4"/>',
      sidebarCollapse: '<rect x="3.5" y="4" width="13" height="12" rx="2"/><path d="M12 4v12"/><path d="m8 8-2 2 2 2"/>',
      split: '<rect x="3" y="4" width="14" height="12" rx="2"/><path d="M10 4v12" data-accent="true"/><path d="M6 8h2"/><path d="M6 12h2"/><path d="M12 8h2"/><path d="M12 12h2"/>',
      unified: '<rect x="4" y="3.5" width="12" height="13" rx="2"/><path d="M7 7h6"/><path d="M7 10h6" data-accent="true"/><path d="M7 13h6"/>',
      word: '<path d="M3 6h14"/><path d="M3 10h8"/><path d="M3 14h11"/><path d="M14 10h3"/>',
      wrap: '<path d="M3 6h10a4 4 0 0 1 0 8H8"/><path d="m10 11-3 3 3 3"/>',
      clipboard: '<rect x="5" y="4" width="10" height="13" rx="2"/><path d="M8 4a2 2 0 0 1 4 0"/><path d="M8 7h4"/>'
    }[c] ?? ""}</svg>`;
  }
  function Ca(c, o) {
    c(o.name, () => Promise.resolve(Jl(o)));
  }
  function Jn(c, o, y, O) {
    const q = Array.from(new Set([
      c.theme?.light,
      c.theme?.dark
    ].filter(Boolean))), R = Array.from(new Set(o.flatMap((N) => {
      const rt = N.fileDiff ?? {}, At = rt.name ?? rt.newName ?? rt.oldName ?? rt.prevName ?? "", ot = rt.lang ?? y(At) ?? "text";
      return ot ? [ot] : [];
    })));
    return O({
      themes: q,
      langs: R.length > 0 ? R : ["text"]
    });
  }
  function Jl(c) {
    const o = c.palette ?? {}, y = c.foreground, O = c.background;
    return {
      name: c.name,
      displayName: c.ghosttyName,
      type: c.type,
      colors: {
        "editor.background": O,
        "editor.foreground": y,
        "terminal.background": O,
        "terminal.foreground": y,
        "terminal.ansiBlack": o[0] ?? y,
        "terminal.ansiRed": o[1] ?? y,
        "terminal.ansiGreen": o[2] ?? y,
        "terminal.ansiYellow": o[3] ?? y,
        "terminal.ansiBlue": o[4] ?? y,
        "terminal.ansiMagenta": o[5] ?? y,
        "terminal.ansiCyan": o[6] ?? y,
        "terminal.ansiWhite": o[7] ?? y,
        "terminal.ansiBrightBlack": o[8] ?? y,
        "terminal.ansiBrightRed": o[9] ?? o[1] ?? y,
        "terminal.ansiBrightGreen": o[10] ?? o[2] ?? y,
        "terminal.ansiBrightYellow": o[11] ?? o[3] ?? y,
        "terminal.ansiBrightBlue": o[12] ?? o[4] ?? y,
        "terminal.ansiBrightMagenta": o[13] ?? o[5] ?? y,
        "terminal.ansiBrightCyan": o[14] ?? o[6] ?? y,
        "terminal.ansiBrightWhite": o[15] ?? y,
        "gitDecoration.addedResourceForeground": o[10] ?? o[2] ?? "#32d74b",
        "gitDecoration.deletedResourceForeground": o[9] ?? o[1] ?? "#ff453a",
        "gitDecoration.modifiedResourceForeground": o[12] ?? o[4] ?? "#0a84ff",
        "editor.selectionBackground": c.selectionBackground,
        "editor.selectionForeground": c.selectionForeground
      },
      tokenColors: [
        { settings: { foreground: y, background: O } },
        { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: o[8] ?? y, fontStyle: "italic" } },
        { scope: ["string", "constant.other.symbol"], settings: { foreground: o[2] ?? y } },
        { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: o[3] ?? y } },
        { scope: ["keyword", "storage", "storage.type"], settings: { foreground: o[5] ?? y } },
        { scope: ["entity.name.function", "support.function"], settings: { foreground: o[4] ?? y } },
        { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: o[6] ?? y } },
        { scope: ["variable", "meta.definition.variable"], settings: { foreground: y } },
        { scope: ["invalid", "message.error"], settings: { foreground: o[9] ?? o[1] ?? y } }
      ]
    };
  }
}
function Ot(A, J) {
  return A.payload?.labels?.[J] ?? J;
}
function f0({ config: A }) {
  return /* @__PURE__ */ tt.jsxs("div", { className: "toolbar-left", children: [
    /* @__PURE__ */ tt.jsx("select", { id: "source-select", "aria-label": Ot(A, "diffTarget"), hidden: !0 }),
    /* @__PURE__ */ tt.jsx("select", { id: "repo-select", "aria-label": Ot(A, "repoPath"), hidden: !0 }),
    /* @__PURE__ */ tt.jsx("select", { id: "base-select", "aria-label": Ot(A, "branchBase"), hidden: !0 }),
    /* @__PURE__ */ tt.jsx("span", { id: "source-detail" })
  ] });
}
function c0({ config: A }) {
  return /* @__PURE__ */ tt.jsxs("header", { id: "toolbar", children: [
    /* @__PURE__ */ tt.jsx(f0, { config: A }),
    /* @__PURE__ */ tt.jsx("div", { className: "toolbar-middle", children: /* @__PURE__ */ tt.jsx("select", { id: "jump-select", "aria-label": Ot(A, "jumpToFile"), hidden: !0 }) }),
    /* @__PURE__ */ tt.jsxs("div", { className: "toolbar-actions", children: [
      /* @__PURE__ */ tt.jsx(
        "a",
        {
          id: "external-link",
          className: "toolbar-icon",
          href: A.payload?.externalURL ?? "#",
          target: "_blank",
          rel: "noreferrer",
          title: Ot(A, "openSourceURL"),
          "aria-label": Ot(A, "openSourceURL"),
          hidden: !0
        }
      ),
      /* @__PURE__ */ tt.jsx(
        "button",
        {
          id: "files-toggle",
          className: "toolbar-icon",
          type: "button",
          title: Ot(A, "hideFiles"),
          "aria-label": Ot(A, "hideFiles"),
          "aria-pressed": "true"
        }
      ),
      /* @__PURE__ */ tt.jsx(
        "button",
        {
          id: "layout-toggle",
          className: "toolbar-icon",
          type: "button",
          title: Ot(A, "switchToUnifiedDiff"),
          "aria-label": Ot(A, "switchToUnifiedDiff")
        }
      ),
      /* @__PURE__ */ tt.jsx(
        "button",
        {
          id: "options-button",
          className: "toolbar-icon",
          type: "button",
          title: Ot(A, "options"),
          "aria-label": Ot(A, "options"),
          "aria-expanded": "false",
          "aria-haspopup": "menu"
        }
      )
    ] }),
    /* @__PURE__ */ tt.jsx("div", { id: "options-menu", role: "menu", "aria-label": Ot(A, "options"), hidden: !0 })
  ] });
}
function o0({ config: A }) {
  return /* @__PURE__ */ tt.jsxs("aside", { id: "files-sidebar", "aria-label": Ot(A, "changedFiles"), children: [
    /* @__PURE__ */ tt.jsxs("div", { id: "files-header", children: [
      /* @__PURE__ */ tt.jsxs("span", { id: "files-title", children: [
        /* @__PURE__ */ tt.jsx("span", { children: Ot(A, "files") }),
        /* @__PURE__ */ tt.jsx("span", { id: "files-count" })
      ] }),
      /* @__PURE__ */ tt.jsxs("span", { id: "files-header-actions", children: [
        /* @__PURE__ */ tt.jsx(
          "button",
          {
            id: "file-search-toggle",
            type: "button",
            title: Ot(A, "showFileSearch"),
            "aria-label": Ot(A, "showFileSearch"),
            "aria-pressed": "false"
          }
        ),
        /* @__PURE__ */ tt.jsx(
          "button",
          {
            id: "file-collapse-toggle",
            type: "button",
            title: Ot(A, "hideFiles"),
            "aria-label": Ot(A, "hideFiles")
          }
        )
      ] })
    ] }),
    /* @__PURE__ */ tt.jsx("div", { id: "file-list" }),
    /* @__PURE__ */ tt.jsxs("div", { id: "files-footer", "aria-label": Ot(A, "diffStats"), children: [
      /* @__PURE__ */ tt.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ tt.jsx("span", { children: Ot(A, "files") }),
        /* @__PURE__ */ tt.jsx("strong", { id: "stats-files", children: "0" })
      ] }),
      /* @__PURE__ */ tt.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ tt.jsx("span", { children: Ot(A, "additions") }),
        /* @__PURE__ */ tt.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" })
      ] }),
      /* @__PURE__ */ tt.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ tt.jsx("span", { children: Ot(A, "deletions") }),
        /* @__PURE__ */ tt.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" })
      ] })
    ] })
  ] });
}
function s0({ config: A }) {
  const J = um.useRef(!1), st = um.useCallback((b) => {
    !b || J.current || (J.current = !0, queueMicrotask(() => i0(A)));
  }, [A]);
  return /* @__PURE__ */ tt.jsxs("div", { id: "app", ref: st, children: [
    /* @__PURE__ */ tt.jsx(c0, { config: A }),
    /* @__PURE__ */ tt.jsxs("section", { id: "content", children: [
      /* @__PURE__ */ tt.jsx(o0, { config: A }),
      /* @__PURE__ */ tt.jsx("main", { id: "viewer", "aria-label": Ot(A, "diffViewer"), children: /* @__PURE__ */ tt.jsx("div", { id: "status", children: A.payload?.statusMessage ?? Ot(A, "loadingDiff") }) })
    ] })
  ] });
}
const r0 = ':root{color-scheme:light dark;--cmux-diff-bg-light: #fff;--cmux-diff-bg-dark: #000;--cmux-diff-fg-light: #000;--cmux-diff-fg-dark: #fff;--cmux-diff-selection-bg-light: #abd8ff;--cmux-diff-selection-bg-dark: #3f638b;--cmux-diff-ui-font-family: system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size: 12px;--cmux-diff-ui-line-height: 16px;--cmux-diff-code-font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size: 10px;--cmux-diff-line-height: 20px;--cmux-diff-bg: var(--cmux-diff-bg-light);--cmux-diff-fg: var(--cmux-diff-fg-light);--cmux-diff-border: color-mix(in lab, var(--cmux-diff-fg) 12%, transparent);--cmux-diff-sidebar-bg: color-mix(in lab, var(--cmux-diff-bg) 98%, var(--cmux-diff-fg));--cmux-diff-muted-bg: color-mix(in lab, var(--cmux-diff-fg) 8%, transparent);--cmux-diff-hover-bg: color-mix(in lab, var(--cmux-diff-fg) 10%, transparent);--cmux-diff-accent: light-dark(#0a84ff, #7ab7ff);background:var(--cmux-diff-bg);color:var(--cmux-diff-fg)}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg: var(--cmux-diff-bg-dark);--cmux-diff-fg: var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{height:100%;overflow:hidden}body{margin:0;height:100vh;min-height:0;background:var(--cmux-diff-bg);color:var(--cmux-diff-fg);display:flex;flex-direction:column;overflow:hidden;font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height)}#app{height:100vh;min-height:0;display:grid;grid-template-rows:auto minmax(0,1fr);overflow:hidden;overscroll-behavior:contain;contain:strict;background:inherit;color:inherit}#toolbar{position:relative;flex:0 0 auto;display:flex;align-items:center;gap:7px;min-height:32px;padding:3px 8px;border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent);background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg));color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg));z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{display:flex;align-items:center;gap:6px;min-width:0}.toolbar-left{flex:0 1 36%}.toolbar-middle{flex:1 1 auto;justify-content:center}.toolbar-actions{flex:0 0 auto}#source-select,#repo-select,#base-select,#jump-select{appearance:none;height:24px;min-width:118px;max-width:min(30vw,320px);padding:0 24px 0 9px;border:1px solid transparent;border-radius:6px;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent);color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent);background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent);outline-offset:1px}#source-detail{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}.toolbar-icon{width:28px;height:26px;display:inline-flex;align-items:center;justify-content:center;border:1px solid transparent;border-radius:6px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg));padding:0;cursor:pointer}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent);background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent);color:var(--cmux-diff-fg)}.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{width:16px;height:16px;display:block;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{position:absolute;top:calc(100% + 7px);right:10px;min-width:246px;padding:8px;border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent);border-radius:8px;background:color-mix(in lab,var(--cmux-diff-bg) 94%,var(--cmux-diff-fg));box-shadow:0 16px 34px color-mix(in lab,#000 28%,transparent);z-index:100}#options-menu[hidden]{display:none}.menu-separator{height:1px;margin:7px 6px;background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}.menu-item{width:100%;min-height:31px;display:grid;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;border:0;border-radius:6px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg));font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent);color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:transparent}.menu-segment-controls{display:inline-flex;align-items:center;gap:2px;justify-self:end;padding:2px;border-radius:7px;background:color-mix(in lab,var(--cmux-diff-bg) 82%,var(--cmux-diff-fg))}.segment-button{width:27px;height:24px;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:5px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg));padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent);color:var(--cmux-diff-fg)}.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}.menu-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.menu-check{justify-self:end}#content{--cmux-diff-files-width: clamp(190px, 22vw, 252px);position:relative;flex:1 1 auto;min-height:0;min-width:0;display:grid;grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";overflow:hidden;overscroll-behavior:contain;contain:strict;background:inherit}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}#files-sidebar{grid-area:files;position:relative;width:100%;height:100%;min-height:0;min-width:0;display:flex;flex-direction:column;overflow:hidden;border-left:1px solid var(--cmux-diff-border);background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg));contain:strict;opacity:1;transition:opacity .1s ease,visibility 0s linear 0s}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s ease,visibility 0s linear .1s}#files-header{position:relative;z-index:1;display:flex;align-items:center;justify-content:space-between;min-height:30px;gap:8px;padding:0 7px 0 10px;border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent);background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg));color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}#files-title{display:inline-flex;align-items:center;gap:6px;min-width:0}#files-header-actions{display:inline-flex;align-items:center;gap:2px;flex:0 0 auto}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;flex:0 0 auto;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:5px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg));padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{width:15px;height:15px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round}#file-list{flex:1 1 auto;min-height:0;overflow:hidden;padding:6px 4px 6px 6px;--trees-bg-override: var(--cmux-diff-sidebar-bg);--trees-fg-override: color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg));--trees-fg-muted-override: color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg));--trees-bg-muted-override: var(--cmux-diff-hover-bg);--trees-selected-bg-override: color-mix(in lab, var(--cmux-diff-fg) 11%, transparent);--trees-selected-fg-override: var(--cmux-diff-fg);--trees-selected-focused-border-color-override: transparent;--trees-border-color-override: var(--cmux-diff-border);--trees-focus-ring-color-override: color-mix(in lab, var(--cmux-diff-accent) 72%, transparent);--trees-font-family-override: var(--cmux-diff-ui-font-family);--trees-font-size-override: var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override: 500;--trees-density-override: .78;--trees-border-radius-override: 5px;--trees-item-padding-x-override: 7px;--trees-item-margin-x-override: 0;--trees-padding-inline-override: 0;--trees-search-bg-override: color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg));--trees-status-added-override: light-dark(#257a3e, #8fd88f);--trees-status-modified-override: var(--cmux-diff-accent);--trees-status-renamed-override: light-dark(#a26300, #ffd166);--trees-status-deleted-override: light-dark(#b42318, #ff8a80)}#file-list file-tree-container{width:100%;height:100%}#files-footer{flex:0 0 auto;padding:7px 10px 8px;border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent);background:color-mix(in lab,var(--cmux-diff-bg) 97%,var(--cmux-diff-fg))}.stats-row{display:flex;align-items:center;justify-content:space-between;gap:10px;min-height:19px;color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg));font-weight:600}.file-entry{width:100%;min-height:30px;display:grid;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;border:0;border-radius:6px;background:transparent;color:inherit;font:inherit;text-align:left;padding:3px 7px}.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}.file-status{width:17px;height:17px;border:1px solid currentColor;border-radius:5px;display:inline-flex;align-items:center;justify-content:center;font-size:9px;line-height:1;color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}.file-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-stats{display:inline-flex;gap:5px;color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family: var(--cmux-diff-code-font-family);--diffs-header-font-family: var(--cmux-diff-ui-font-family);--diffs-font-size: var(--cmux-diff-font-size);--diffs-line-height: var(--cmux-diff-line-height);--diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));grid-area:viewer;width:100%;height:100%;min-height:0;min-width:0;position:relative;overflow-y:auto;overflow-x:clip;overscroll-behavior:contain;overflow-anchor:none;contain:strict;will-change:scroll-position;border-bottom:1px solid var(--cmux-diff-border);background:inherit}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}body[data-status-only=true] #files-sidebar{display:none}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family: var(--cmux-diff-code-font-family);--diffs-header-font-family: var(--cmux-diff-ui-font-family);--diffs-font-size: var(--cmux-diff-font-size);--diffs-line-height: var(--cmux-diff-line-height);--diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));display:block;overflow:clip;contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border)}#status{padding:16px;font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}#status[data-pending=true]{display:inline-flex;align-items:center;gap:10px}#status[data-pending=true]:before{content:"";width:16px;height:16px;flex:0 0 auto;border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent);border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg));border-radius:50%;animation:cmuxDiffPendingSpin .8s linear infinite}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before{animation:none}}';
function d0() {
  const A = document.getElementById("cmux-diff-viewer-config");
  if (!A?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(A.textContent);
}
function m0() {
  const A = document.createElement("style");
  A.dataset.cmuxDiffViewerStyle = "true", A.textContent = r0, document.head.append(A);
}
const rf = d0();
m0();
document.title = rf.payload?.title ?? document.title;
document.body.dataset.filesHidden = "false";
document.body.dataset.statusOnly = rf.payload?.statusMessage || rf.payload?.pendingReplacement ? "true" : "false";
const im = document.getElementById("root");
if (!im)
  throw new Error("Missing cmux diff viewer root");
u0.createRoot(im).render(/* @__PURE__ */ tt.jsx(s0, { config: rf }));
