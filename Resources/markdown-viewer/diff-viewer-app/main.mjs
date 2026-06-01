var go = { exports: {} }, ji = {};
var Fd;
function ng() {
  if (Fd) return ji;
  Fd = 1;
  var v = /* @__PURE__ */ Symbol.for("react.transitional.element"), D = /* @__PURE__ */ Symbol.for("react.fragment");
  function q(g, nt, xt) {
    var it = null;
    if (xt !== void 0 && (it = "" + xt), nt.key !== void 0 && (it = "" + nt.key), "key" in nt) {
      xt = {};
      for (var Pt in nt)
        Pt !== "key" && (xt[Pt] = nt[Pt]);
    } else xt = nt;
    return nt = xt.ref, {
      $$typeof: v,
      type: g,
      key: it,
      ref: nt !== void 0 ? nt : null,
      props: xt
    };
  }
  return ji.Fragment = D, ji.jsx = q, ji.jsxs = q, ji;
}
var Wd;
function ig() {
  return Wd || (Wd = 1, go.exports = ng()), go.exports;
}
var X = ig(), po = { exports: {} }, qi = {}, yo = { exports: {} }, vo = {};
var $d;
function ug() {
  return $d || ($d = 1, (function(v) {
    function D(m, O) {
      var L = m.length;
      m.push(O);
      t: for (; 0 < L; ) {
        var K = L - 1 >>> 1, F = m[K];
        if (0 < nt(F, O))
          m[K] = O, m[L] = F, L = K;
        else break t;
      }
    }
    function q(m) {
      return m.length === 0 ? null : m[0];
    }
    function g(m) {
      if (m.length === 0) return null;
      var O = m[0], L = m.pop();
      if (L !== O) {
        m[0] = L;
        t: for (var K = 0, F = m.length, s = F >>> 1; K < s; ) {
          var M = 2 * (K + 1) - 1, N = m[M], H = M + 1, W = m[H];
          if (0 > nt(N, L))
            H < F && 0 > nt(W, N) ? (m[K] = W, m[H] = L, K = H) : (m[K] = N, m[M] = L, K = M);
          else if (H < F && 0 > nt(W, L))
            m[K] = W, m[H] = L, K = H;
          else break t;
        }
      }
      return O;
    }
    function nt(m, O) {
      var L = m.sortIndex - O.sortIndex;
      return L !== 0 ? L : m.id - O.id;
    }
    if (v.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var xt = performance;
      v.unstable_now = function() {
        return xt.now();
      };
    } else {
      var it = Date, Pt = it.now();
      v.unstable_now = function() {
        return it.now() - Pt;
      };
    }
    var B = [], _ = [], ut = 1, V = null, Ot = 3, Xt = !1, oe = !1, te = !1, qe = !1, St = typeof setTimeout == "function" ? setTimeout : null, Ge = typeof clearTimeout == "function" ? clearTimeout : null, Rt = typeof setImmediate < "u" ? setImmediate : null;
    function kt(m) {
      for (var O = q(_); O !== null; ) {
        if (O.callback === null) g(_);
        else if (O.startTime <= m)
          g(_), O.sortIndex = O.expirationTime, D(B, O);
        else break;
        O = q(_);
      }
    }
    function re(m) {
      if (te = !1, kt(m), !oe)
        if (q(B) !== null)
          oe = !0, wt || (wt = !0, ee());
        else {
          var O = q(_);
          O !== null && Y(re, O.startTime - m);
        }
    }
    var wt = !1, at = -1, Bt = 5, De = -1;
    function be() {
      return qe ? !0 : !(v.unstable_now() - De < Bt);
    }
    function se() {
      if (qe = !1, wt) {
        var m = v.unstable_now();
        De = m;
        var O = !0;
        try {
          t: {
            oe = !1, te && (te = !1, Ge(at), at = -1), Xt = !0;
            var L = Ot;
            try {
              e: {
                for (kt(m), V = q(B); V !== null && !(V.expirationTime > m && be()); ) {
                  var K = V.callback;
                  if (typeof K == "function") {
                    V.callback = null, Ot = V.priorityLevel;
                    var F = K(
                      V.expirationTime <= m
                    );
                    if (m = v.unstable_now(), typeof F == "function") {
                      V.callback = F, kt(m), O = !0;
                      break e;
                    }
                    V === q(B) && g(B), kt(m);
                  } else g(B);
                  V = q(B);
                }
                if (V !== null) O = !0;
                else {
                  var s = q(_);
                  s !== null && Y(
                    re,
                    s.startTime - m
                  ), O = !1;
                }
              }
              break t;
            } finally {
              V = null, Ot = L, Xt = !1;
            }
            O = void 0;
          }
        } finally {
          O ? ee() : wt = !1;
        }
      }
    }
    var ee;
    if (typeof Rt == "function")
      ee = function() {
        Rt(se);
      };
    else if (typeof MessageChannel < "u") {
      var ll = new MessageChannel(), Ye = ll.port2;
      ll.port1.onmessage = se, ee = function() {
        Ye.postMessage(null);
      };
    } else
      ee = function() {
        St(se, 0);
      };
    function Y(m, O) {
      at = St(function() {
        m(v.unstable_now());
      }, O);
    }
    v.unstable_IdlePriority = 5, v.unstable_ImmediatePriority = 1, v.unstable_LowPriority = 4, v.unstable_NormalPriority = 3, v.unstable_Profiling = null, v.unstable_UserBlockingPriority = 2, v.unstable_cancelCallback = function(m) {
      m.callback = null;
    }, v.unstable_forceFrameRate = function(m) {
      0 > m || 125 < m ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : Bt = 0 < m ? Math.floor(1e3 / m) : 5;
    }, v.unstable_getCurrentPriorityLevel = function() {
      return Ot;
    }, v.unstable_next = function(m) {
      switch (Ot) {
        case 1:
        case 2:
        case 3:
          var O = 3;
          break;
        default:
          O = Ot;
      }
      var L = Ot;
      Ot = O;
      try {
        return m();
      } finally {
        Ot = L;
      }
    }, v.unstable_requestPaint = function() {
      qe = !0;
    }, v.unstable_runWithPriority = function(m, O) {
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
      var L = Ot;
      Ot = m;
      try {
        return O();
      } finally {
        Ot = L;
      }
    }, v.unstable_scheduleCallback = function(m, O, L) {
      var K = v.unstable_now();
      switch (typeof L == "object" && L !== null ? (L = L.delay, L = typeof L == "number" && 0 < L ? K + L : K) : L = K, m) {
        case 1:
          var F = -1;
          break;
        case 2:
          F = 250;
          break;
        case 5:
          F = 1073741823;
          break;
        case 4:
          F = 1e4;
          break;
        default:
          F = 5e3;
      }
      return F = L + F, m = {
        id: ut++,
        callback: O,
        priorityLevel: m,
        startTime: L,
        expirationTime: F,
        sortIndex: -1
      }, L > K ? (m.sortIndex = L, D(_, m), q(B) === null && m === q(_) && (te ? (Ge(at), at = -1) : te = !0, Y(re, L - K))) : (m.sortIndex = F, D(B, m), oe || Xt || (oe = !0, wt || (wt = !0, ee()))), m;
    }, v.unstable_shouldYield = be, v.unstable_wrapCallback = function(m) {
      var O = Ot;
      return function() {
        var L = Ot;
        Ot = O;
        try {
          return m.apply(this, arguments);
        } finally {
          Ot = L;
        }
      };
    };
  })(vo)), vo;
}
var Id;
function fg() {
  return Id || (Id = 1, yo.exports = ug()), yo.exports;
}
var bo = { exports: {} }, P = {};
var Pd;
function cg() {
  if (Pd) return P;
  Pd = 1;
  var v = /* @__PURE__ */ Symbol.for("react.transitional.element"), D = /* @__PURE__ */ Symbol.for("react.portal"), q = /* @__PURE__ */ Symbol.for("react.fragment"), g = /* @__PURE__ */ Symbol.for("react.strict_mode"), nt = /* @__PURE__ */ Symbol.for("react.profiler"), xt = /* @__PURE__ */ Symbol.for("react.consumer"), it = /* @__PURE__ */ Symbol.for("react.context"), Pt = /* @__PURE__ */ Symbol.for("react.forward_ref"), B = /* @__PURE__ */ Symbol.for("react.suspense"), _ = /* @__PURE__ */ Symbol.for("react.memo"), ut = /* @__PURE__ */ Symbol.for("react.lazy"), V = /* @__PURE__ */ Symbol.for("react.activity"), Ot = Symbol.iterator;
  function Xt(s) {
    return s === null || typeof s != "object" ? null : (s = Ot && s[Ot] || s["@@iterator"], typeof s == "function" ? s : null);
  }
  var oe = {
    isMounted: function() {
      return !1;
    },
    enqueueForceUpdate: function() {
    },
    enqueueReplaceState: function() {
    },
    enqueueSetState: function() {
    }
  }, te = Object.assign, qe = {};
  function St(s, M, N) {
    this.props = s, this.context = M, this.refs = qe, this.updater = N || oe;
  }
  St.prototype.isReactComponent = {}, St.prototype.setState = function(s, M) {
    if (typeof s != "object" && typeof s != "function" && s != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, s, M, "setState");
  }, St.prototype.forceUpdate = function(s) {
    this.updater.enqueueForceUpdate(this, s, "forceUpdate");
  };
  function Ge() {
  }
  Ge.prototype = St.prototype;
  function Rt(s, M, N) {
    this.props = s, this.context = M, this.refs = qe, this.updater = N || oe;
  }
  var kt = Rt.prototype = new Ge();
  kt.constructor = Rt, te(kt, St.prototype), kt.isPureReactComponent = !0;
  var re = Array.isArray;
  function wt() {
  }
  var at = { H: null, A: null, T: null, S: null }, Bt = Object.prototype.hasOwnProperty;
  function De(s, M, N) {
    var H = N.ref;
    return {
      $$typeof: v,
      type: s,
      key: M,
      ref: H !== void 0 ? H : null,
      props: N
    };
  }
  function be(s, M) {
    return De(s.type, M, s.props);
  }
  function se(s) {
    return typeof s == "object" && s !== null && s.$$typeof === v;
  }
  function ee(s) {
    var M = { "=": "=0", ":": "=2" };
    return "$" + s.replace(/[=:]/g, function(N) {
      return M[N];
    });
  }
  var ll = /\/+/g;
  function Ye(s, M) {
    return typeof s == "object" && s !== null && s.key != null ? ee("" + s.key) : M.toString(36);
  }
  function Y(s) {
    switch (s.status) {
      case "fulfilled":
        return s.value;
      case "rejected":
        throw s.reason;
      default:
        switch (typeof s.status == "string" ? s.then(wt, wt) : (s.status = "pending", s.then(
          function(M) {
            s.status === "pending" && (s.status = "fulfilled", s.value = M);
          },
          function(M) {
            s.status === "pending" && (s.status = "rejected", s.reason = M);
          }
        )), s.status) {
          case "fulfilled":
            return s.value;
          case "rejected":
            throw s.reason;
        }
    }
    throw s;
  }
  function m(s, M, N, H, W) {
    var tt = typeof s;
    (tt === "undefined" || tt === "boolean") && (s = null);
    var mt = !1;
    if (s === null) mt = !0;
    else
      switch (tt) {
        case "bigint":
        case "string":
        case "number":
          mt = !0;
          break;
        case "object":
          switch (s.$$typeof) {
            case v:
            case D:
              mt = !0;
              break;
            case ut:
              return mt = s._init, m(
                mt(s._payload),
                M,
                N,
                H,
                W
              );
          }
      }
    if (mt)
      return W = W(s), mt = H === "" ? "." + Ye(s, 0) : H, re(W) ? (N = "", mt != null && (N = mt.replace(ll, "$&/") + "/"), m(W, M, N, "", function(gl) {
        return gl;
      })) : W != null && (se(W) && (W = be(
        W,
        N + (W.key == null || s && s.key === W.key ? "" : ("" + W.key).replace(
          ll,
          "$&/"
        ) + "/") + mt
      )), M.push(W)), 1;
    mt = 0;
    var $t = H === "" ? "." : H + ":";
    if (re(s))
      for (var Tt = 0; Tt < s.length; Tt++)
        H = s[Tt], tt = $t + Ye(H, Tt), mt += m(
          H,
          M,
          N,
          tt,
          W
        );
    else if (Tt = Xt(s), typeof Tt == "function")
      for (s = Tt.call(s), Tt = 0; !(H = s.next()).done; )
        H = H.value, tt = $t + Ye(H, Tt++), mt += m(
          H,
          M,
          N,
          tt,
          W
        );
    else if (tt === "object") {
      if (typeof s.then == "function")
        return m(
          Y(s),
          M,
          N,
          H,
          W
        );
      throw M = String(s), Error(
        "Objects are not valid as a React child (found: " + (M === "[object Object]" ? "object with keys {" + Object.keys(s).join(", ") + "}" : M) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return mt;
  }
  function O(s, M, N) {
    if (s == null) return s;
    var H = [], W = 0;
    return m(s, H, "", "", function(tt) {
      return M.call(N, tt, W++);
    }), H;
  }
  function L(s) {
    if (s._status === -1) {
      var M = s._result;
      M = M(), M.then(
        function(N) {
          (s._status === 0 || s._status === -1) && (s._status = 1, s._result = N);
        },
        function(N) {
          (s._status === 0 || s._status === -1) && (s._status = 2, s._result = N);
        }
      ), s._status === -1 && (s._status = 0, s._result = M);
    }
    if (s._status === 1) return s._result.default;
    throw s._result;
  }
  var K = typeof reportError == "function" ? reportError : function(s) {
    if (typeof window == "object" && typeof window.ErrorEvent == "function") {
      var M = new window.ErrorEvent("error", {
        bubbles: !0,
        cancelable: !0,
        message: typeof s == "object" && s !== null && typeof s.message == "string" ? String(s.message) : String(s),
        error: s
      });
      if (!window.dispatchEvent(M)) return;
    } else if (typeof process == "object" && typeof process.emit == "function") {
      process.emit("uncaughtException", s);
      return;
    }
    console.error(s);
  }, F = {
    map: O,
    forEach: function(s, M, N) {
      O(
        s,
        function() {
          M.apply(this, arguments);
        },
        N
      );
    },
    count: function(s) {
      var M = 0;
      return O(s, function() {
        M++;
      }), M;
    },
    toArray: function(s) {
      return O(s, function(M) {
        return M;
      }) || [];
    },
    only: function(s) {
      if (!se(s))
        throw Error(
          "React.Children.only expected to receive a single React element child."
        );
      return s;
    }
  };
  return P.Activity = V, P.Children = F, P.Component = St, P.Fragment = q, P.Profiler = nt, P.PureComponent = Rt, P.StrictMode = g, P.Suspense = B, P.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = at, P.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(s) {
      return at.H.useMemoCache(s);
    }
  }, P.cache = function(s) {
    return function() {
      return s.apply(null, arguments);
    };
  }, P.cacheSignal = function() {
    return null;
  }, P.cloneElement = function(s, M, N) {
    if (s == null)
      throw Error(
        "The argument must be a React element, but you passed " + s + "."
      );
    var H = te({}, s.props), W = s.key;
    if (M != null)
      for (tt in M.key !== void 0 && (W = "" + M.key), M)
        !Bt.call(M, tt) || tt === "key" || tt === "__self" || tt === "__source" || tt === "ref" && M.ref === void 0 || (H[tt] = M[tt]);
    var tt = arguments.length - 2;
    if (tt === 1) H.children = N;
    else if (1 < tt) {
      for (var mt = Array(tt), $t = 0; $t < tt; $t++)
        mt[$t] = arguments[$t + 2];
      H.children = mt;
    }
    return De(s.type, W, H);
  }, P.createContext = function(s) {
    return s = {
      $$typeof: it,
      _currentValue: s,
      _currentValue2: s,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, s.Provider = s, s.Consumer = {
      $$typeof: xt,
      _context: s
    }, s;
  }, P.createElement = function(s, M, N) {
    var H, W = {}, tt = null;
    if (M != null)
      for (H in M.key !== void 0 && (tt = "" + M.key), M)
        Bt.call(M, H) && H !== "key" && H !== "__self" && H !== "__source" && (W[H] = M[H]);
    var mt = arguments.length - 2;
    if (mt === 1) W.children = N;
    else if (1 < mt) {
      for (var $t = Array(mt), Tt = 0; Tt < mt; Tt++)
        $t[Tt] = arguments[Tt + 2];
      W.children = $t;
    }
    if (s && s.defaultProps)
      for (H in mt = s.defaultProps, mt)
        W[H] === void 0 && (W[H] = mt[H]);
    return De(s, tt, W);
  }, P.createRef = function() {
    return { current: null };
  }, P.forwardRef = function(s) {
    return { $$typeof: Pt, render: s };
  }, P.isValidElement = se, P.lazy = function(s) {
    return {
      $$typeof: ut,
      _payload: { _status: -1, _result: s },
      _init: L
    };
  }, P.memo = function(s, M) {
    return {
      $$typeof: _,
      type: s,
      compare: M === void 0 ? null : M
    };
  }, P.startTransition = function(s) {
    var M = at.T, N = {};
    at.T = N;
    try {
      var H = s(), W = at.S;
      W !== null && W(N, H), typeof H == "object" && H !== null && typeof H.then == "function" && H.then(wt, K);
    } catch (tt) {
      K(tt);
    } finally {
      M !== null && N.types !== null && (M.types = N.types), at.T = M;
    }
  }, P.unstable_useCacheRefresh = function() {
    return at.H.useCacheRefresh();
  }, P.use = function(s) {
    return at.H.use(s);
  }, P.useActionState = function(s, M, N) {
    return at.H.useActionState(s, M, N);
  }, P.useCallback = function(s, M) {
    return at.H.useCallback(s, M);
  }, P.useContext = function(s) {
    return at.H.useContext(s);
  }, P.useDebugValue = function() {
  }, P.useDeferredValue = function(s, M) {
    return at.H.useDeferredValue(s, M);
  }, P.useEffect = function(s, M) {
    return at.H.useEffect(s, M);
  }, P.useEffectEvent = function(s) {
    return at.H.useEffectEvent(s);
  }, P.useId = function() {
    return at.H.useId();
  }, P.useImperativeHandle = function(s, M, N) {
    return at.H.useImperativeHandle(s, M, N);
  }, P.useInsertionEffect = function(s, M) {
    return at.H.useInsertionEffect(s, M);
  }, P.useLayoutEffect = function(s, M) {
    return at.H.useLayoutEffect(s, M);
  }, P.useMemo = function(s, M) {
    return at.H.useMemo(s, M);
  }, P.useOptimistic = function(s, M) {
    return at.H.useOptimistic(s, M);
  }, P.useReducer = function(s, M, N) {
    return at.H.useReducer(s, M, N);
  }, P.useRef = function(s) {
    return at.H.useRef(s);
  }, P.useState = function(s) {
    return at.H.useState(s);
  }, P.useSyncExternalStore = function(s, M, N) {
    return at.H.useSyncExternalStore(
      s,
      M,
      N
    );
  }, P.useTransition = function() {
    return at.H.useTransition();
  }, P.version = "19.2.3", P;
}
var tm;
function To() {
  return tm || (tm = 1, bo.exports = cg()), bo.exports;
}
var xo = { exports: {} }, me = {};
var em;
function og() {
  if (em) return me;
  em = 1;
  var v = To();
  function D(B) {
    var _ = "https://react.dev/errors/" + B;
    if (1 < arguments.length) {
      _ += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var ut = 2; ut < arguments.length; ut++)
        _ += "&args[]=" + encodeURIComponent(arguments[ut]);
    }
    return "Minified React error #" + B + "; visit " + _ + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function q() {
  }
  var g = {
    d: {
      f: q,
      r: function() {
        throw Error(D(522));
      },
      D: q,
      C: q,
      L: q,
      m: q,
      X: q,
      S: q,
      M: q
    },
    p: 0,
    findDOMNode: null
  }, nt = /* @__PURE__ */ Symbol.for("react.portal");
  function xt(B, _, ut) {
    var V = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: nt,
      key: V == null ? null : "" + V,
      children: B,
      containerInfo: _,
      implementation: ut
    };
  }
  var it = v.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function Pt(B, _) {
    if (B === "font") return "";
    if (typeof _ == "string")
      return _ === "use-credentials" ? _ : "";
  }
  return me.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = g, me.createPortal = function(B, _) {
    var ut = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!_ || _.nodeType !== 1 && _.nodeType !== 9 && _.nodeType !== 11)
      throw Error(D(299));
    return xt(B, _, null, ut);
  }, me.flushSync = function(B) {
    var _ = it.T, ut = g.p;
    try {
      if (it.T = null, g.p = 2, B) return B();
    } finally {
      it.T = _, g.p = ut, g.d.f();
    }
  }, me.preconnect = function(B, _) {
    typeof B == "string" && (_ ? (_ = _.crossOrigin, _ = typeof _ == "string" ? _ === "use-credentials" ? _ : "" : void 0) : _ = null, g.d.C(B, _));
  }, me.prefetchDNS = function(B) {
    typeof B == "string" && g.d.D(B);
  }, me.preinit = function(B, _) {
    if (typeof B == "string" && _ && typeof _.as == "string") {
      var ut = _.as, V = Pt(ut, _.crossOrigin), Ot = typeof _.integrity == "string" ? _.integrity : void 0, Xt = typeof _.fetchPriority == "string" ? _.fetchPriority : void 0;
      ut === "style" ? g.d.S(
        B,
        typeof _.precedence == "string" ? _.precedence : void 0,
        {
          crossOrigin: V,
          integrity: Ot,
          fetchPriority: Xt
        }
      ) : ut === "script" && g.d.X(B, {
        crossOrigin: V,
        integrity: Ot,
        fetchPriority: Xt,
        nonce: typeof _.nonce == "string" ? _.nonce : void 0
      });
    }
  }, me.preinitModule = function(B, _) {
    if (typeof B == "string")
      if (typeof _ == "object" && _ !== null) {
        if (_.as == null || _.as === "script") {
          var ut = Pt(
            _.as,
            _.crossOrigin
          );
          g.d.M(B, {
            crossOrigin: ut,
            integrity: typeof _.integrity == "string" ? _.integrity : void 0,
            nonce: typeof _.nonce == "string" ? _.nonce : void 0
          });
        }
      } else _ == null && g.d.M(B);
  }, me.preload = function(B, _) {
    if (typeof B == "string" && typeof _ == "object" && _ !== null && typeof _.as == "string") {
      var ut = _.as, V = Pt(ut, _.crossOrigin);
      g.d.L(B, ut, {
        crossOrigin: V,
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
  }, me.preloadModule = function(B, _) {
    if (typeof B == "string")
      if (_) {
        var ut = Pt(_.as, _.crossOrigin);
        g.d.m(B, {
          as: typeof _.as == "string" && _.as !== "script" ? _.as : void 0,
          crossOrigin: ut,
          integrity: typeof _.integrity == "string" ? _.integrity : void 0
        });
      } else g.d.m(B);
  }, me.requestFormReset = function(B) {
    g.d.r(B);
  }, me.unstable_batchedUpdates = function(B, _) {
    return B(_);
  }, me.useFormState = function(B, _, ut) {
    return it.H.useFormState(B, _, ut);
  }, me.useFormStatus = function() {
    return it.H.useHostTransitionStatus();
  }, me.version = "19.2.3", me;
}
var lm;
function rg() {
  if (lm) return xo.exports;
  lm = 1;
  function v() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(v);
      } catch (D) {
        console.error(D);
      }
  }
  return v(), xo.exports = og(), xo.exports;
}
var am;
function sg() {
  if (am) return qi;
  am = 1;
  var v = fg(), D = To(), q = rg();
  function g(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function nt(t) {
    return !(!t || t.nodeType !== 1 && t.nodeType !== 9 && t.nodeType !== 11);
  }
  function xt(t) {
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
  function it(t) {
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
  function B(t) {
    if (xt(t) !== t)
      throw Error(g(188));
  }
  function _(t) {
    var e = t.alternate;
    if (!e) {
      if (e = xt(t), e === null) throw Error(g(188));
      return e !== t ? null : t;
    }
    for (var l = t, a = e; ; ) {
      var n = l.return;
      if (n === null) break;
      var i = n.alternate;
      if (i === null) {
        if (a = n.return, a !== null) {
          l = a;
          continue;
        }
        break;
      }
      if (n.child === i.child) {
        for (i = n.child; i; ) {
          if (i === l) return B(n), t;
          if (i === a) return B(n), e;
          i = i.sibling;
        }
        throw Error(g(188));
      }
      if (l.return !== a.return) l = n, a = i;
      else {
        for (var u = !1, f = n.child; f; ) {
          if (f === l) {
            u = !0, l = n, a = i;
            break;
          }
          if (f === a) {
            u = !0, a = n, l = i;
            break;
          }
          f = f.sibling;
        }
        if (!u) {
          for (f = i.child; f; ) {
            if (f === l) {
              u = !0, l = i, a = n;
              break;
            }
            if (f === a) {
              u = !0, a = i, l = n;
              break;
            }
            f = f.sibling;
          }
          if (!u) throw Error(g(189));
        }
      }
      if (l.alternate !== a) throw Error(g(190));
    }
    if (l.tag !== 3) throw Error(g(188));
    return l.stateNode.current === l ? t : e;
  }
  function ut(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t;
    for (t = t.child; t !== null; ) {
      if (e = ut(t), e !== null) return e;
      t = t.sibling;
    }
    return null;
  }
  var V = Object.assign, Ot = /* @__PURE__ */ Symbol.for("react.element"), Xt = /* @__PURE__ */ Symbol.for("react.transitional.element"), oe = /* @__PURE__ */ Symbol.for("react.portal"), te = /* @__PURE__ */ Symbol.for("react.fragment"), qe = /* @__PURE__ */ Symbol.for("react.strict_mode"), St = /* @__PURE__ */ Symbol.for("react.profiler"), Ge = /* @__PURE__ */ Symbol.for("react.consumer"), Rt = /* @__PURE__ */ Symbol.for("react.context"), kt = /* @__PURE__ */ Symbol.for("react.forward_ref"), re = /* @__PURE__ */ Symbol.for("react.suspense"), wt = /* @__PURE__ */ Symbol.for("react.suspense_list"), at = /* @__PURE__ */ Symbol.for("react.memo"), Bt = /* @__PURE__ */ Symbol.for("react.lazy"), De = /* @__PURE__ */ Symbol.for("react.activity"), be = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), se = Symbol.iterator;
  function ee(t) {
    return t === null || typeof t != "object" ? null : (t = se && t[se] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var ll = /* @__PURE__ */ Symbol.for("react.client.reference");
  function Ye(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === ll ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case te:
        return "Fragment";
      case St:
        return "Profiler";
      case qe:
        return "StrictMode";
      case re:
        return "Suspense";
      case wt:
        return "SuspenseList";
      case De:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case oe:
          return "Portal";
        case Rt:
          return t.displayName || "Context";
        case Ge:
          return (t._context.displayName || "Context") + ".Consumer";
        case kt:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case at:
          return e = t.displayName || null, e !== null ? e : Ye(t.type) || "Memo";
        case Bt:
          e = t._payload, t = t._init;
          try {
            return Ye(t(e));
          } catch {
          }
      }
    return null;
  }
  var Y = Array.isArray, m = D.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, O = q.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, L = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, K = [], F = -1;
  function s(t) {
    return { current: t };
  }
  function M(t) {
    0 > F || (t.current = K[F], K[F] = null, F--);
  }
  function N(t, e) {
    F++, K[F] = t.current, t.current = e;
  }
  var H = s(null), W = s(null), tt = s(null), mt = s(null);
  function $t(t, e) {
    switch (N(tt, e), N(W, t), N(H, null), e.nodeType) {
      case 9:
      case 11:
        t = (t = e.documentElement) && (t = t.namespaceURI) ? vd(t) : 0;
        break;
      default:
        if (t = e.tagName, e = e.namespaceURI)
          e = vd(e), t = bd(e, t);
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
    M(H), N(H, t);
  }
  function Tt() {
    M(H), M(W), M(tt);
  }
  function gl(t) {
    t.memoizedState !== null && N(mt, t);
    var e = H.current, l = bd(e, t.type);
    e !== l && (N(W, t), N(H, l));
  }
  function Le(t) {
    W.current === t && (M(H), M(W)), mt.current === t && (M(mt), Ni._currentValue = L);
  }
  var al, Gn;
  function pl(t) {
    if (al === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        al = e && e[1] || "", Gn = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + al + t + Gn;
  }
  var Oe = !1;
  function Yn(t, e) {
    if (!t || Oe) return "";
    Oe = !0;
    var l = Error.prepareStackTrace;
    Error.prepareStackTrace = void 0;
    try {
      var a = {
        DetermineComponentFrameRoot: function() {
          try {
            if (e) {
              var A = function() {
                throw Error();
              };
              if (Object.defineProperty(A.prototype, "props", {
                set: function() {
                  throw Error();
                }
              }), typeof Reflect == "object" && Reflect.construct) {
                try {
                  Reflect.construct(A, []);
                } catch (S) {
                  var b = S;
                }
                Reflect.construct(t, [], A);
              } else {
                try {
                  A.call();
                } catch (S) {
                  b = S;
                }
                t.call(A.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (S) {
                b = S;
              }
              (A = t()) && typeof A.catch == "function" && A.catch(function() {
              });
            }
          } catch (S) {
            if (S && b && typeof S.stack == "string")
              return [S.stack, b.stack];
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
      var i = a.DetermineComponentFrameRoot(), u = i[0], f = i[1];
      if (u && f) {
        var o = u.split(`
`), y = f.split(`
`);
        for (n = a = 0; a < o.length && !o[a].includes("DetermineComponentFrameRoot"); )
          a++;
        for (; n < y.length && !y[n].includes(
          "DetermineComponentFrameRoot"
        ); )
          n++;
        if (a === o.length || n === y.length)
          for (a = o.length - 1, n = y.length - 1; 1 <= a && 0 <= n && o[a] !== y[n]; )
            n--;
        for (; 1 <= a && 0 <= n; a--, n--)
          if (o[a] !== y[n]) {
            if (a !== 1 || n !== 1)
              do
                if (a--, n--, 0 > n || o[a] !== y[n]) {
                  var T = `
` + o[a].replace(" at new ", " at ");
                  return t.displayName && T.includes("<anonymous>") && (T = T.replace("<anonymous>", t.displayName)), T;
                }
              while (1 <= a && 0 <= n);
            break;
          }
      }
    } finally {
      Oe = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? pl(l) : "";
  }
  function cf(t, e) {
    switch (t.tag) {
      case 26:
      case 27:
      case 5:
        return pl(t.type);
      case 16:
        return pl("Lazy");
      case 13:
        return t.child !== e && e !== null ? pl("Suspense Fallback") : pl("Suspense");
      case 19:
        return pl("SuspenseList");
      case 0:
      case 15:
        return Yn(t.type, !1);
      case 11:
        return Yn(t.type.render, !1);
      case 1:
        return Yn(t.type, !0);
      case 31:
        return pl("Activity");
      default:
        return "";
    }
  }
  function Gi(t) {
    try {
      var e = "", l = null;
      do
        e += cf(t, l), l = t, t = t.return;
      while (t);
      return e;
    } catch (a) {
      return `
Error generating stack: ` + a.message + `
` + a.stack;
    }
  }
  var Ln = Object.prototype.hasOwnProperty, Xn = v.unstable_scheduleCallback, ya = v.unstable_cancelCallback, Qn = v.unstable_shouldYield, Yi = v.unstable_requestPaint, le = v.unstable_now, Li = v.unstable_getCurrentPriorityLevel, Xi = v.unstable_ImmediatePriority, Wa = v.unstable_UserBlockingPriority, va = v.unstable_NormalPriority, of = v.unstable_LowPriority, Qi = v.unstable_IdlePriority, rf = v.log, Vi = v.unstable_setDisableYieldValue, ba = null, he = null;
  function nl(t) {
    if (typeof rf == "function" && Vi(t), he && typeof he.setStrictMode == "function")
      try {
        he.setStrictMode(ba, t);
      } catch {
      }
  }
  var Ft = Math.clz32 ? Math.clz32 : sf, Zi = Math.log, $a = Math.LN2;
  function sf(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (Zi(t) / $a | 0) | 0;
  }
  var yl = 256, Ia = 262144, Pa = 4194304;
  function il(t) {
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
  function xa(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, i = t.suspendedLanes, u = t.pingedLanes;
    t = t.warmLanes;
    var f = a & 134217727;
    return f !== 0 ? (a = f & ~i, a !== 0 ? n = il(a) : (u &= f, u !== 0 ? n = il(u) : l || (l = f & ~t, l !== 0 && (n = il(l))))) : (f = a & ~i, f !== 0 ? n = il(f) : u !== 0 ? n = il(u) : l || (l = a & ~t, l !== 0 && (n = il(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function Sa(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function vl(t, e) {
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
  function Vn() {
    var t = Pa;
    return Pa <<= 1, (Pa & 62914560) === 0 && (Pa = 4194304), t;
  }
  function Zn(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function ul(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function Ki(t, e, l, a, n, i) {
    var u = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var f = t.entanglements, o = t.expirationTimes, y = t.hiddenUpdates;
    for (l = u & ~l; 0 < l; ) {
      var T = 31 - Ft(l), A = 1 << T;
      f[T] = 0, o[T] = -1;
      var b = y[T];
      if (b !== null)
        for (y[T] = null, T = 0; T < b.length; T++) {
          var S = b[T];
          S !== null && (S.lane &= -536870913);
        }
      l &= ~A;
    }
    a !== 0 && Ji(t, a, 0), i !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= i & ~(u & ~e));
  }
  function Ji(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - Ft(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function ge(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - Ft(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function tn(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : Ta(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function Ta(t) {
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
  function Kn(t) {
    return t &= -t, 2 < t ? 8 < t ? (t & 134217727) !== 0 ? 32 : 268435456 : 8 : 2;
  }
  function ki() {
    var t = O.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Xd(t.type));
  }
  function Jn(t, e) {
    var l = O.p;
    try {
      return O.p = t, e();
    } finally {
      O.p = l;
    }
  }
  var fl = Math.random().toString(36).slice(2), Qt = "__reactFiber$" + fl, ae = "__reactProps$" + fl, Xl = "__reactContainer$" + fl, kn = "__reactEvents$" + fl, df = "__reactListeners$" + fl, mf = "__reactHandles$" + fl, Fi = "__reactResources$" + fl, Ql = "__reactMarker$" + fl;
  function za(t) {
    delete t[Qt], delete t[ae], delete t[kn], delete t[df], delete t[mf];
  }
  function cl(t) {
    var e = t[Qt];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[Xl] || l[Qt]) {
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
  function bl(t) {
    if (t = t[Qt] || t[Xl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function ol(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(g(33));
  }
  function xl(t) {
    var e = t[Fi];
    return e || (e = t[Fi] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function Gt(t) {
    t[Ql] = !0;
  }
  var Wi = /* @__PURE__ */ new Set(), Fn = {};
  function Sl(t, e) {
    Tl(t, e), Tl(t + "Capture", e);
  }
  function Tl(t, e) {
    for (Fn[t] = e, t = 0; t < e.length; t++)
      Wi.add(e[t]);
  }
  var hf = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), $i = {}, en = {};
  function gf(t) {
    return Ln.call(en, t) ? !0 : Ln.call($i, t) ? !1 : hf.test(t) ? en[t] = !0 : ($i[t] = !0, !1);
  }
  function Ma(t, e, l) {
    if (gf(e))
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
  function ln(t, e, l) {
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
  function pe(t, e, l, a) {
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
  function xe(t) {
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
  function Ii(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function Pi(t, e, l) {
    var a = Object.getOwnPropertyDescriptor(
      t.constructor.prototype,
      e
    );
    if (!t.hasOwnProperty(e) && typeof a < "u" && typeof a.get == "function" && typeof a.set == "function") {
      var n = a.get, i = a.set;
      return Object.defineProperty(t, e, {
        configurable: !0,
        get: function() {
          return n.call(this);
        },
        set: function(u) {
          l = "" + u, i.call(this, u);
        }
      }), Object.defineProperty(t, e, {
        enumerable: a.enumerable
      }), {
        getValue: function() {
          return l;
        },
        setValue: function(u) {
          l = "" + u;
        },
        stopTracking: function() {
          t._valueTracker = null, delete t[e];
        }
      };
    }
  }
  function zl(t) {
    if (!t._valueTracker) {
      var e = Ii(t) ? "checked" : "value";
      t._valueTracker = Pi(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function tu(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = Ii(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function de(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var an = /[\n"\\]/g;
  function Se(t) {
    return t.replace(
      an,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function Wn(t, e, l, a, n, i, u, f) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + xe(e)) : t.value !== "" + xe(e) && (t.value = "" + xe(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? r(t, u, xe(e)) : l != null ? r(t, u, xe(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), f != null && typeof f != "function" && typeof f != "symbol" && typeof f != "boolean" ? t.name = "" + xe(f) : t.removeAttribute("name");
  }
  function c(t, e, l, a, n, i, u, f) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        zl(t);
        return;
      }
      l = l != null ? "" + xe(l) : "", e = e != null ? "" + xe(e) : l, f || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = f ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), zl(t);
  }
  function r(t, e, l) {
    e === "number" && de(t.ownerDocument) === t || t.defaultValue === "" + l || (t.defaultValue = "" + l);
  }
  function x(t, e, l, a) {
    if (t = t.options, e) {
      e = {};
      for (var n = 0; n < l.length; n++)
        e["$" + l[n]] = !0;
      for (l = 0; l < t.length; l++)
        n = e.hasOwnProperty("$" + t[l].value), t[l].selected !== n && (t[l].selected = n), n && a && (t[l].defaultSelected = !0);
    } else {
      for (l = "" + xe(l), e = null, n = 0; n < t.length; n++) {
        if (t[n].value === l) {
          t[n].selected = !0, a && (t[n].defaultSelected = !0);
          return;
        }
        e !== null || t[n].disabled || (e = t[n]);
      }
      e !== null && (e.selected = !0);
    }
  }
  function U(t, e, l) {
    if (e != null && (e = "" + xe(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + xe(l) : "";
  }
  function R(t, e, l, a) {
    if (e == null) {
      if (a != null) {
        if (l != null) throw Error(g(92));
        if (Y(a)) {
          if (1 < a.length) throw Error(g(93));
          a = a[0];
        }
        l = a;
      }
      l == null && (l = ""), e = l;
    }
    l = xe(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), zl(t);
  }
  function w(t, e) {
    if (e) {
      var l = t.firstChild;
      if (l && l === t.lastChild && l.nodeType === 3) {
        l.nodeValue = e;
        return;
      }
    }
    t.textContent = e;
  }
  var Q = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function $(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || Q.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function st(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(g(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && $(t, n, a);
    } else
      for (var i in e)
        e.hasOwnProperty(i) && $(t, i, e[i]);
  }
  function ht(t) {
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
  var Vl = /* @__PURE__ */ new Map([
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
  ]), pf = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function nn(t) {
    return pf.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function We() {
  }
  var un = null;
  function $n(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Ml = null, Zl = null;
  function fn(t) {
    var e = bl(t);
    if (e && (t = e.stateNode)) {
      var l = t[ae] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if (Wn(
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
              'input[name="' + Se(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[ae] || null;
                if (!n) throw Error(g(90));
                Wn(
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
              a = l[e], a.form === t.form && tu(a);
          }
          break t;
        case "textarea":
          U(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && x(t, !!l.multiple, e, !1);
      }
    }
  }
  var Ea = !1;
  function eu(t, e, l) {
    if (Ea) return t(e, l);
    Ea = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (Ea = !1, (Ml !== null || Zl !== null) && (qu(), Ml && (e = Ml, t = Zl, Zl = Ml = null, fn(e), t)))
        for (e = 0; e < t.length; e++) fn(t[e]);
    }
  }
  function Kl(t, e) {
    var l = t.stateNode;
    if (l === null) return null;
    var a = l[ae] || null;
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
        g(231, e, typeof l)
      );
    return l;
  }
  var Ce = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), Aa = !1;
  if (Ce)
    try {
      var $e = {};
      Object.defineProperty($e, "passive", {
        get: function() {
          Aa = !0;
        }
      }), window.addEventListener("test", $e, $e), window.removeEventListener("test", $e, $e);
    } catch {
      Aa = !1;
    }
  var Ie = null, In = null, _a = null;
  function Pn() {
    if (_a) return _a;
    var t, e = In, l = e.length, a, n = "value" in Ie ? Ie.value : Ie.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return _a = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function cn(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function Da() {
    return !0;
  }
  function Oa() {
    return !1;
  }
  function ne(t) {
    function e(l, a, n, i, u) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = i, this.target = u, this.currentTarget = null;
      for (var f in t)
        t.hasOwnProperty(f) && (l = t[f], this[f] = l ? l(i) : i[f]);
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? Da : Oa, this.isPropagationStopped = Oa, this;
    }
    return V(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = Da);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = Da);
      },
      persist: function() {
      },
      isPersistent: Da
    }), e;
  }
  var El = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, on = ne(El), Jl = V({}, El, { view: 0, detail: 0 }), yf = ne(Jl), Ca, rl, kl, Ua = V({}, Jl, {
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
    getModifierState: bf,
    button: 0,
    buttons: 0,
    relatedTarget: function(t) {
      return t.relatedTarget === void 0 ? t.fromElement === t.srcElement ? t.toElement : t.fromElement : t.relatedTarget;
    },
    movementX: function(t) {
      return "movementX" in t ? t.movementX : (t !== kl && (kl && t.type === "mousemove" ? (Ca = t.screenX - kl.screenX, rl = t.screenY - kl.screenY) : rl = Ca = 0, kl = t), Ca);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : rl;
    }
  }), Ba = ne(Ua), E = V({}, Ua, { dataTransfer: 0 }), C = ne(E), k = V({}, Jl, { relatedTarget: 0 }), I = ne(k), gt = V({}, El, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), pt = ne(gt), Ht = V({}, El, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), ye = ne(Ht), Na = V({}, El, { data: 0 }), Te = ne(Na), lu = {
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
  }, vf = {
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
  }, mm = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function hm(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = mm[t]) ? !!e[t] : !1;
  }
  function bf() {
    return hm;
  }
  var gm = V({}, Jl, {
    key: function(t) {
      if (t.key) {
        var e = lu[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = cn(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? vf[t.keyCode] || "Unidentified" : "";
    },
    code: 0,
    location: 0,
    ctrlKey: 0,
    shiftKey: 0,
    altKey: 0,
    metaKey: 0,
    repeat: 0,
    locale: 0,
    getModifierState: bf,
    charCode: function(t) {
      return t.type === "keypress" ? cn(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? cn(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), pm = ne(gm), ym = V({}, Ua, {
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
  }), zo = ne(ym), vm = V({}, Jl, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: bf
  }), bm = ne(vm), xm = V({}, El, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), Sm = ne(xm), Tm = V({}, Ua, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), zm = ne(Tm), Mm = V({}, El, {
    newState: 0,
    oldState: 0
  }), Em = ne(Mm), Am = [9, 13, 27, 32], xf = Ce && "CompositionEvent" in window, ti = null;
  Ce && "documentMode" in document && (ti = document.documentMode);
  var _m = Ce && "TextEvent" in window && !ti, Mo = Ce && (!xf || ti && 8 < ti && 11 >= ti), Eo = " ", Ao = !1;
  function _o(t, e) {
    switch (t) {
      case "keyup":
        return Am.indexOf(e.keyCode) !== -1;
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
  var rn = !1;
  function Dm(t, e) {
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
  function Om(t, e) {
    if (rn)
      return t === "compositionend" || !xf && _o(t, e) ? (t = Pn(), _a = In = Ie = null, rn = !1, t) : null;
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
  var Cm = {
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
    return e === "input" ? !!Cm[t.type] : e === "textarea";
  }
  function Co(t, e, l, a) {
    Ml ? Zl ? Zl.push(a) : Zl = [a] : Ml = a, e = Zu(e, "onChange"), 0 < e.length && (l = new on(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var ei = null, li = null;
  function Um(t) {
    dd(t, 0);
  }
  function au(t) {
    var e = ol(t);
    if (tu(e)) return t;
  }
  function Uo(t, e) {
    if (t === "change") return e;
  }
  var Bo = !1;
  if (Ce) {
    var Sf;
    if (Ce) {
      var Tf = "oninput" in document;
      if (!Tf) {
        var No = document.createElement("div");
        No.setAttribute("oninput", "return;"), Tf = typeof No.oninput == "function";
      }
      Sf = Tf;
    } else Sf = !1;
    Bo = Sf && (!document.documentMode || 9 < document.documentMode);
  }
  function Ro() {
    ei && (ei.detachEvent("onpropertychange", wo), li = ei = null);
  }
  function wo(t) {
    if (t.propertyName === "value" && au(li)) {
      var e = [];
      Co(
        e,
        li,
        t,
        $n(t)
      ), eu(Um, e);
    }
  }
  function Bm(t, e, l) {
    t === "focusin" ? (Ro(), ei = e, li = l, ei.attachEvent("onpropertychange", wo)) : t === "focusout" && Ro();
  }
  function Nm(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return au(li);
  }
  function Rm(t, e) {
    if (t === "click") return au(e);
  }
  function wm(t, e) {
    if (t === "input" || t === "change")
      return au(e);
  }
  function Hm(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var Ue = typeof Object.is == "function" ? Object.is : Hm;
  function ai(t, e) {
    if (Ue(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!Ln.call(e, n) || !Ue(t[n], e[n]))
        return !1;
    }
    return !0;
  }
  function Ho(t) {
    for (; t && t.firstChild; ) t = t.firstChild;
    return t;
  }
  function jo(t, e) {
    var l = Ho(t);
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
      l = Ho(l);
    }
  }
  function qo(t, e) {
    return t && e ? t === e ? !0 : t && t.nodeType === 3 ? !1 : e && e.nodeType === 3 ? qo(t, e.parentNode) : "contains" in t ? t.contains(e) : t.compareDocumentPosition ? !!(t.compareDocumentPosition(e) & 16) : !1 : !1;
  }
  function Go(t) {
    t = t != null && t.ownerDocument != null && t.ownerDocument.defaultView != null ? t.ownerDocument.defaultView : window;
    for (var e = de(t.document); e instanceof t.HTMLIFrameElement; ) {
      try {
        var l = typeof e.contentWindow.location.href == "string";
      } catch {
        l = !1;
      }
      if (l) t = e.contentWindow;
      else break;
      e = de(t.document);
    }
    return e;
  }
  function zf(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var jm = Ce && "documentMode" in document && 11 >= document.documentMode, sn = null, Mf = null, ni = null, Ef = !1;
  function Yo(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Ef || sn == null || sn !== de(a) || (a = sn, "selectionStart" in a && zf(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), ni && ai(ni, a) || (ni = a, a = Zu(Mf, "onSelect"), 0 < a.length && (e = new on(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = sn)));
  }
  function Ra(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var dn = {
    animationend: Ra("Animation", "AnimationEnd"),
    animationiteration: Ra("Animation", "AnimationIteration"),
    animationstart: Ra("Animation", "AnimationStart"),
    transitionrun: Ra("Transition", "TransitionRun"),
    transitionstart: Ra("Transition", "TransitionStart"),
    transitioncancel: Ra("Transition", "TransitionCancel"),
    transitionend: Ra("Transition", "TransitionEnd")
  }, Af = {}, Lo = {};
  Ce && (Lo = document.createElement("div").style, "AnimationEvent" in window || (delete dn.animationend.animation, delete dn.animationiteration.animation, delete dn.animationstart.animation), "TransitionEvent" in window || delete dn.transitionend.transition);
  function wa(t) {
    if (Af[t]) return Af[t];
    if (!dn[t]) return t;
    var e = dn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Lo)
        return Af[t] = e[l];
    return t;
  }
  var Xo = wa("animationend"), Qo = wa("animationiteration"), Vo = wa("animationstart"), qm = wa("transitionrun"), Gm = wa("transitionstart"), Ym = wa("transitioncancel"), Zo = wa("transitionend"), Ko = /* @__PURE__ */ new Map(), _f = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  _f.push("scrollEnd");
  function Pe(t, e) {
    Ko.set(t, e), Sl(e, [t]);
  }
  var nu = typeof reportError == "function" ? reportError : function(t) {
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
  }, Xe = [], mn = 0, Df = 0;
  function iu() {
    for (var t = mn, e = Df = mn = 0; e < t; ) {
      var l = Xe[e];
      Xe[e++] = null;
      var a = Xe[e];
      Xe[e++] = null;
      var n = Xe[e];
      Xe[e++] = null;
      var i = Xe[e];
      if (Xe[e++] = null, a !== null && n !== null) {
        var u = a.pending;
        u === null ? n.next = n : (n.next = u.next, u.next = n), a.pending = n;
      }
      i !== 0 && Jo(l, n, i);
    }
  }
  function uu(t, e, l, a) {
    Xe[mn++] = t, Xe[mn++] = e, Xe[mn++] = l, Xe[mn++] = a, Df |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Of(t, e, l, a) {
    return uu(t, e, l, a), fu(t);
  }
  function Ha(t, e) {
    return uu(t, null, null, e), fu(t);
  }
  function Jo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, i = t.return; i !== null; )
      i.childLanes |= l, a = i.alternate, a !== null && (a.childLanes |= l), i.tag === 22 && (t = i.stateNode, t === null || t._visibility & 1 || (n = !0)), t = i, i = i.return;
    return t.tag === 3 ? (i = t.stateNode, n && e !== null && (n = 31 - Ft(l), t = i.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), i) : null;
  }
  function fu(t) {
    if (50 < Ai)
      throw Ai = 0, qc = null, Error(g(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var hn = {};
  function Lm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function Be(t, e, l, a) {
    return new Lm(t, e, l, a);
  }
  function Cf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function Al(t, e) {
    var l = t.alternate;
    return l === null ? (l = Be(
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
  function cu(t, e, l, a, n, i) {
    var u = 0;
    if (a = t, typeof t == "function") Cf(t) && (u = 1);
    else if (typeof t == "string")
      u = Kh(
        t,
        l,
        H.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case De:
          return t = Be(31, l, e, n), t.elementType = De, t.lanes = i, t;
        case te:
          return ja(l.children, n, i, e);
        case qe:
          u = 8, n |= 24;
          break;
        case St:
          return t = Be(12, l, e, n | 2), t.elementType = St, t.lanes = i, t;
        case re:
          return t = Be(13, l, e, n), t.elementType = re, t.lanes = i, t;
        case wt:
          return t = Be(19, l, e, n), t.elementType = wt, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case Rt:
                u = 10;
                break t;
              case Ge:
                u = 9;
                break t;
              case kt:
                u = 11;
                break t;
              case at:
                u = 14;
                break t;
              case Bt:
                u = 16, a = null;
                break t;
            }
          u = 29, l = Error(
            g(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = Be(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function ja(t, e, l, a) {
    return t = Be(7, t, a, e), t.lanes = l, t;
  }
  function Uf(t, e, l) {
    return t = Be(6, t, null, e), t.lanes = l, t;
  }
  function Fo(t) {
    var e = Be(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function Bf(t, e, l) {
    return e = Be(
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
  function Qe(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = Wo.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Gi(e)
      }, Wo.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Gi(e)
    };
  }
  var gn = [], pn = 0, ou = null, ii = 0, Ve = [], Ze = 0, Fl = null, sl = 1, dl = "";
  function _l(t, e) {
    gn[pn++] = ii, gn[pn++] = ou, ou = t, ii = e;
  }
  function $o(t, e, l) {
    Ve[Ze++] = sl, Ve[Ze++] = dl, Ve[Ze++] = Fl, Fl = t;
    var a = sl;
    t = dl;
    var n = 32 - Ft(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - Ft(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, sl = 1 << 32 - Ft(e) + n | l << n | a, dl = i + t;
    } else
      sl = 1 << i | l << n | a, dl = t;
  }
  function Nf(t) {
    t.return !== null && (_l(t, 1), $o(t, 1, 0));
  }
  function Rf(t) {
    for (; t === ou; )
      ou = gn[--pn], gn[pn] = null, ii = gn[--pn], gn[pn] = null;
    for (; t === Fl; )
      Fl = Ve[--Ze], Ve[Ze] = null, dl = Ve[--Ze], Ve[Ze] = null, sl = Ve[--Ze], Ve[Ze] = null;
  }
  function Io(t, e) {
    Ve[Ze++] = sl, Ve[Ze++] = dl, Ve[Ze++] = Fl, sl = e.id, dl = e.overflow, Fl = t;
  }
  var ie = null, Ct = null, dt = !1, Wl = null, Ke = !1, wf = Error(g(519));
  function $l(t) {
    var e = Error(
      g(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw ui(Qe(e, t)), wf;
  }
  function Po(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[Qt] = t, e[ae] = a, l) {
      case "dialog":
        ct("cancel", e), ct("close", e);
        break;
      case "iframe":
      case "object":
      case "embed":
        ct("load", e);
        break;
      case "video":
      case "audio":
        for (l = 0; l < Di.length; l++)
          ct(Di[l], e);
        break;
      case "source":
        ct("error", e);
        break;
      case "img":
      case "image":
      case "link":
        ct("error", e), ct("load", e);
        break;
      case "details":
        ct("toggle", e);
        break;
      case "input":
        ct("invalid", e), c(
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
        ct("invalid", e);
        break;
      case "textarea":
        ct("invalid", e), R(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || pd(e.textContent, l) ? (a.popover != null && (ct("beforetoggle", e), ct("toggle", e)), a.onScroll != null && ct("scroll", e), a.onScrollEnd != null && ct("scrollend", e), a.onClick != null && (e.onclick = We), e = !0) : e = !1, e || $l(t, !0);
  }
  function tr(t) {
    for (ie = t.return; ie; )
      switch (ie.tag) {
        case 5:
        case 31:
        case 13:
          Ke = !1;
          return;
        case 27:
        case 3:
          Ke = !0;
          return;
        default:
          ie = ie.return;
      }
  }
  function yn(t) {
    if (t !== ie) return !1;
    if (!dt) return tr(t), dt = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || Pc(t.type, t.memoizedProps)), l = !l), l && Ct && $l(t), tr(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(g(317));
      Ct = Ed(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(g(317));
      Ct = Ed(t);
    } else
      e === 27 ? (e = Ct, sa(t.type) ? (t = no, no = null, Ct = t) : Ct = e) : Ct = ie ? ke(t.stateNode.nextSibling) : null;
    return !0;
  }
  function qa() {
    Ct = ie = null, dt = !1;
  }
  function Hf() {
    var t = Wl;
    return t !== null && (Ae === null ? Ae = t : Ae.push.apply(
      Ae,
      t
    ), Wl = null), t;
  }
  function ui(t) {
    Wl === null ? Wl = [t] : Wl.push(t);
  }
  var jf = s(null), Ga = null, Dl = null;
  function Il(t, e, l) {
    N(jf, e._currentValue), e._currentValue = l;
  }
  function Ol(t) {
    t._currentValue = jf.current, M(jf);
  }
  function qf(t, e, l) {
    for (; t !== null; ) {
      var a = t.alternate;
      if ((t.childLanes & e) !== e ? (t.childLanes |= e, a !== null && (a.childLanes |= e)) : a !== null && (a.childLanes & e) !== e && (a.childLanes |= e), t === l) break;
      t = t.return;
    }
  }
  function Gf(t, e, l, a) {
    var n = t.child;
    for (n !== null && (n.return = t); n !== null; ) {
      var i = n.dependencies;
      if (i !== null) {
        var u = n.child;
        i = i.firstContext;
        t: for (; i !== null; ) {
          var f = i;
          i = n;
          for (var o = 0; o < e.length; o++)
            if (f.context === e[o]) {
              i.lanes |= l, f = i.alternate, f !== null && (f.lanes |= l), qf(
                i.return,
                l,
                t
              ), a || (u = null);
              break t;
            }
          i = f.next;
        }
      } else if (n.tag === 18) {
        if (u = n.return, u === null) throw Error(g(341));
        u.lanes |= l, i = u.alternate, i !== null && (i.lanes |= l), qf(u, l, t), u = null;
      } else u = n.child;
      if (u !== null) u.return = n;
      else
        for (u = n; u !== null; ) {
          if (u === t) {
            u = null;
            break;
          }
          if (n = u.sibling, n !== null) {
            n.return = u.return, u = n;
            break;
          }
          u = u.return;
        }
      n = u;
    }
  }
  function vn(t, e, l, a) {
    t = null;
    for (var n = e, i = !1; n !== null; ) {
      if (!i) {
        if ((n.flags & 524288) !== 0) i = !0;
        else if ((n.flags & 262144) !== 0) break;
      }
      if (n.tag === 10) {
        var u = n.alternate;
        if (u === null) throw Error(g(387));
        if (u = u.memoizedProps, u !== null) {
          var f = n.type;
          Ue(n.pendingProps.value, u.value) || (t !== null ? t.push(f) : t = [f]);
        }
      } else if (n === mt.current) {
        if (u = n.alternate, u === null) throw Error(g(387));
        u.memoizedState.memoizedState !== n.memoizedState.memoizedState && (t !== null ? t.push(Ni) : t = [Ni]);
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
  function ru(t) {
    for (t = t.firstContext; t !== null; ) {
      if (!Ue(
        t.context._currentValue,
        t.memoizedValue
      ))
        return !0;
      t = t.next;
    }
    return !1;
  }
  function Ya(t) {
    Ga = t, Dl = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function ue(t) {
    return er(Ga, t);
  }
  function su(t, e) {
    return Ga === null && Ya(t), er(t, e);
  }
  function er(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Dl === null) {
      if (t === null) throw Error(g(308));
      Dl = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else Dl = Dl.next = e;
    return l;
  }
  var Xm = typeof AbortController < "u" ? AbortController : function() {
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
  }, Qm = v.unstable_scheduleCallback, Vm = v.unstable_NormalPriority, Vt = {
    $$typeof: Rt,
    Consumer: null,
    Provider: null,
    _currentValue: null,
    _currentValue2: null,
    _threadCount: 0
  };
  function Yf() {
    return {
      controller: new Xm(),
      data: /* @__PURE__ */ new Map(),
      refCount: 0
    };
  }
  function fi(t) {
    t.refCount--, t.refCount === 0 && Qm(Vm, function() {
      t.controller.abort();
    });
  }
  var ci = null, Lf = 0, bn = 0, xn = null;
  function Zm(t, e) {
    if (ci === null) {
      var l = ci = [];
      Lf = 0, bn = Vc(), xn = {
        status: "pending",
        value: void 0,
        then: function(a) {
          l.push(a);
        }
      };
    }
    return Lf++, e.then(lr, lr), e;
  }
  function lr() {
    if (--Lf === 0 && ci !== null) {
      xn !== null && (xn.status = "fulfilled");
      var t = ci;
      ci = null, bn = 0, xn = null;
      for (var e = 0; e < t.length; e++) (0, t[e])();
    }
  }
  function Km(t, e) {
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
  var ar = m.S;
  m.S = function(t, e) {
    Ys = le(), typeof e == "object" && e !== null && typeof e.then == "function" && Zm(t, e), ar !== null && ar(t, e);
  };
  var La = s(null);
  function Xf() {
    var t = La.current;
    return t !== null ? t : Dt.pooledCache;
  }
  function du(t, e) {
    e === null ? N(La, La.current) : N(La, e.pool);
  }
  function nr() {
    var t = Xf();
    return t === null ? null : { parent: Vt._currentValue, pool: t };
  }
  var Sn = Error(g(460)), Qf = Error(g(474)), mu = Error(g(542)), hu = { then: function() {
  } };
  function ir(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function ur(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(We, We), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, cr(t), t;
      default:
        if (typeof e.status == "string") e.then(We, We);
        else {
          if (t = Dt, t !== null && 100 < t.shellSuspendCounter)
            throw Error(g(482));
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
            throw t = e.reason, cr(t), t;
        }
        throw Qa = e, Sn;
    }
  }
  function Xa(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (Qa = l, Sn) : l;
    }
  }
  var Qa = null;
  function fr() {
    if (Qa === null) throw Error(g(459));
    var t = Qa;
    return Qa = null, t;
  }
  function cr(t) {
    if (t === Sn || t === mu)
      throw Error(g(483));
  }
  var Tn = null, oi = 0;
  function gu(t) {
    var e = oi;
    return oi += 1, Tn === null && (Tn = []), ur(Tn, t, e);
  }
  function ri(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function pu(t, e) {
    throw e.$$typeof === Ot ? Error(g(525)) : (t = Object.prototype.toString.call(e), Error(
      g(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function or(t) {
    function e(h, d) {
      if (t) {
        var p = h.deletions;
        p === null ? (h.deletions = [d], h.flags |= 16) : p.push(d);
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
      return h = Al(h, d), h.index = 0, h.sibling = null, h;
    }
    function i(h, d, p) {
      return h.index = p, t ? (p = h.alternate, p !== null ? (p = p.index, p < d ? (h.flags |= 67108866, d) : p) : (h.flags |= 67108866, d)) : (h.flags |= 1048576, d);
    }
    function u(h) {
      return t && h.alternate === null && (h.flags |= 67108866), h;
    }
    function f(h, d, p, z) {
      return d === null || d.tag !== 6 ? (d = Uf(p, h.mode, z), d.return = h, d) : (d = n(d, p), d.return = h, d);
    }
    function o(h, d, p, z) {
      var Z = p.type;
      return Z === te ? T(
        h,
        d,
        p.props.children,
        z,
        p.key
      ) : d !== null && (d.elementType === Z || typeof Z == "object" && Z !== null && Z.$$typeof === Bt && Xa(Z) === d.type) ? (d = n(d, p.props), ri(d, p), d.return = h, d) : (d = cu(
        p.type,
        p.key,
        p.props,
        null,
        h.mode,
        z
      ), ri(d, p), d.return = h, d);
    }
    function y(h, d, p, z) {
      return d === null || d.tag !== 4 || d.stateNode.containerInfo !== p.containerInfo || d.stateNode.implementation !== p.implementation ? (d = Bf(p, h.mode, z), d.return = h, d) : (d = n(d, p.children || []), d.return = h, d);
    }
    function T(h, d, p, z, Z) {
      return d === null || d.tag !== 7 ? (d = ja(
        p,
        h.mode,
        z,
        Z
      ), d.return = h, d) : (d = n(d, p), d.return = h, d);
    }
    function A(h, d, p) {
      if (typeof d == "string" && d !== "" || typeof d == "number" || typeof d == "bigint")
        return d = Uf(
          "" + d,
          h.mode,
          p
        ), d.return = h, d;
      if (typeof d == "object" && d !== null) {
        switch (d.$$typeof) {
          case Xt:
            return p = cu(
              d.type,
              d.key,
              d.props,
              null,
              h.mode,
              p
            ), ri(p, d), p.return = h, p;
          case oe:
            return d = Bf(
              d,
              h.mode,
              p
            ), d.return = h, d;
          case Bt:
            return d = Xa(d), A(h, d, p);
        }
        if (Y(d) || ee(d))
          return d = ja(
            d,
            h.mode,
            p,
            null
          ), d.return = h, d;
        if (typeof d.then == "function")
          return A(h, gu(d), p);
        if (d.$$typeof === Rt)
          return A(
            h,
            su(h, d),
            p
          );
        pu(h, d);
      }
      return null;
    }
    function b(h, d, p, z) {
      var Z = d !== null ? d.key : null;
      if (typeof p == "string" && p !== "" || typeof p == "number" || typeof p == "bigint")
        return Z !== null ? null : f(h, d, "" + p, z);
      if (typeof p == "object" && p !== null) {
        switch (p.$$typeof) {
          case Xt:
            return p.key === Z ? o(h, d, p, z) : null;
          case oe:
            return p.key === Z ? y(h, d, p, z) : null;
          case Bt:
            return p = Xa(p), b(h, d, p, z);
        }
        if (Y(p) || ee(p))
          return Z !== null ? null : T(h, d, p, z, null);
        if (typeof p.then == "function")
          return b(
            h,
            d,
            gu(p),
            z
          );
        if (p.$$typeof === Rt)
          return b(
            h,
            d,
            su(h, p),
            z
          );
        pu(h, p);
      }
      return null;
    }
    function S(h, d, p, z, Z) {
      if (typeof z == "string" && z !== "" || typeof z == "number" || typeof z == "bigint")
        return h = h.get(p) || null, f(d, h, "" + z, Z);
      if (typeof z == "object" && z !== null) {
        switch (z.$$typeof) {
          case Xt:
            return h = h.get(
              z.key === null ? p : z.key
            ) || null, o(d, h, z, Z);
          case oe:
            return h = h.get(
              z.key === null ? p : z.key
            ) || null, y(d, h, z, Z);
          case Bt:
            return z = Xa(z), S(
              h,
              d,
              p,
              z,
              Z
            );
        }
        if (Y(z) || ee(z))
          return h = h.get(p) || null, T(d, h, z, Z, null);
        if (typeof z.then == "function")
          return S(
            h,
            d,
            p,
            gu(z),
            Z
          );
        if (z.$$typeof === Rt)
          return S(
            h,
            d,
            p,
            su(d, z),
            Z
          );
        pu(d, z);
      }
      return null;
    }
    function j(h, d, p, z) {
      for (var Z = null, yt = null, G = d, lt = d = 0, rt = null; G !== null && lt < p.length; lt++) {
        G.index > lt ? (rt = G, G = null) : rt = G.sibling;
        var vt = b(
          h,
          G,
          p[lt],
          z
        );
        if (vt === null) {
          G === null && (G = rt);
          break;
        }
        t && G && vt.alternate === null && e(h, G), d = i(vt, d, lt), yt === null ? Z = vt : yt.sibling = vt, yt = vt, G = rt;
      }
      if (lt === p.length)
        return l(h, G), dt && _l(h, lt), Z;
      if (G === null) {
        for (; lt < p.length; lt++)
          G = A(h, p[lt], z), G !== null && (d = i(
            G,
            d,
            lt
          ), yt === null ? Z = G : yt.sibling = G, yt = G);
        return dt && _l(h, lt), Z;
      }
      for (G = a(G); lt < p.length; lt++)
        rt = S(
          G,
          h,
          lt,
          p[lt],
          z
        ), rt !== null && (t && rt.alternate !== null && G.delete(
          rt.key === null ? lt : rt.key
        ), d = i(
          rt,
          d,
          lt
        ), yt === null ? Z = rt : yt.sibling = rt, yt = rt);
      return t && G.forEach(function(pa) {
        return e(h, pa);
      }), dt && _l(h, lt), Z;
    }
    function J(h, d, p, z) {
      if (p == null) throw Error(g(151));
      for (var Z = null, yt = null, G = d, lt = d = 0, rt = null, vt = p.next(); G !== null && !vt.done; lt++, vt = p.next()) {
        G.index > lt ? (rt = G, G = null) : rt = G.sibling;
        var pa = b(h, G, vt.value, z);
        if (pa === null) {
          G === null && (G = rt);
          break;
        }
        t && G && pa.alternate === null && e(h, G), d = i(pa, d, lt), yt === null ? Z = pa : yt.sibling = pa, yt = pa, G = rt;
      }
      if (vt.done)
        return l(h, G), dt && _l(h, lt), Z;
      if (G === null) {
        for (; !vt.done; lt++, vt = p.next())
          vt = A(h, vt.value, z), vt !== null && (d = i(vt, d, lt), yt === null ? Z = vt : yt.sibling = vt, yt = vt);
        return dt && _l(h, lt), Z;
      }
      for (G = a(G); !vt.done; lt++, vt = p.next())
        vt = S(G, h, lt, vt.value, z), vt !== null && (t && vt.alternate !== null && G.delete(vt.key === null ? lt : vt.key), d = i(vt, d, lt), yt === null ? Z = vt : yt.sibling = vt, yt = vt);
      return t && G.forEach(function(ag) {
        return e(h, ag);
      }), dt && _l(h, lt), Z;
    }
    function _t(h, d, p, z) {
      if (typeof p == "object" && p !== null && p.type === te && p.key === null && (p = p.props.children), typeof p == "object" && p !== null) {
        switch (p.$$typeof) {
          case Xt:
            t: {
              for (var Z = p.key; d !== null; ) {
                if (d.key === Z) {
                  if (Z = p.type, Z === te) {
                    if (d.tag === 7) {
                      l(
                        h,
                        d.sibling
                      ), z = n(
                        d,
                        p.props.children
                      ), z.return = h, h = z;
                      break t;
                    }
                  } else if (d.elementType === Z || typeof Z == "object" && Z !== null && Z.$$typeof === Bt && Xa(Z) === d.type) {
                    l(
                      h,
                      d.sibling
                    ), z = n(d, p.props), ri(z, p), z.return = h, h = z;
                    break t;
                  }
                  l(h, d);
                  break;
                } else e(h, d);
                d = d.sibling;
              }
              p.type === te ? (z = ja(
                p.props.children,
                h.mode,
                z,
                p.key
              ), z.return = h, h = z) : (z = cu(
                p.type,
                p.key,
                p.props,
                null,
                h.mode,
                z
              ), ri(z, p), z.return = h, h = z);
            }
            return u(h);
          case oe:
            t: {
              for (Z = p.key; d !== null; ) {
                if (d.key === Z)
                  if (d.tag === 4 && d.stateNode.containerInfo === p.containerInfo && d.stateNode.implementation === p.implementation) {
                    l(
                      h,
                      d.sibling
                    ), z = n(d, p.children || []), z.return = h, h = z;
                    break t;
                  } else {
                    l(h, d);
                    break;
                  }
                else e(h, d);
                d = d.sibling;
              }
              z = Bf(p, h.mode, z), z.return = h, h = z;
            }
            return u(h);
          case Bt:
            return p = Xa(p), _t(
              h,
              d,
              p,
              z
            );
        }
        if (Y(p))
          return j(
            h,
            d,
            p,
            z
          );
        if (ee(p)) {
          if (Z = ee(p), typeof Z != "function") throw Error(g(150));
          return p = Z.call(p), J(
            h,
            d,
            p,
            z
          );
        }
        if (typeof p.then == "function")
          return _t(
            h,
            d,
            gu(p),
            z
          );
        if (p.$$typeof === Rt)
          return _t(
            h,
            d,
            su(h, p),
            z
          );
        pu(h, p);
      }
      return typeof p == "string" && p !== "" || typeof p == "number" || typeof p == "bigint" ? (p = "" + p, d !== null && d.tag === 6 ? (l(h, d.sibling), z = n(d, p), z.return = h, h = z) : (l(h, d), z = Uf(p, h.mode, z), z.return = h, h = z), u(h)) : l(h, d);
    }
    return function(h, d, p, z) {
      try {
        oi = 0;
        var Z = _t(
          h,
          d,
          p,
          z
        );
        return Tn = null, Z;
      } catch (G) {
        if (G === Sn || G === mu) throw G;
        var yt = Be(29, G, null, h.mode);
        return yt.lanes = z, yt.return = h, yt;
      }
    };
  }
  var Va = or(!0), rr = or(!1), Pl = !1;
  function Vf(t) {
    t.updateQueue = {
      baseState: t.memoizedState,
      firstBaseUpdate: null,
      lastBaseUpdate: null,
      shared: { pending: null, lanes: 0, hiddenCallbacks: null },
      callbacks: null
    };
  }
  function Zf(t, e) {
    t = t.updateQueue, e.updateQueue === t && (e.updateQueue = {
      baseState: t.baseState,
      firstBaseUpdate: t.firstBaseUpdate,
      lastBaseUpdate: t.lastBaseUpdate,
      shared: t.shared,
      callbacks: null
    });
  }
  function ta(t) {
    return { lane: t, tag: 0, payload: null, callback: null, next: null };
  }
  function ea(t, e, l) {
    var a = t.updateQueue;
    if (a === null) return null;
    if (a = a.shared, (bt & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = fu(t), Jo(t, null, l), e;
    }
    return uu(t, a, e, l), fu(t);
  }
  function si(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, ge(t, l);
    }
  }
  function Kf(t, e) {
    var l = t.updateQueue, a = t.alternate;
    if (a !== null && (a = a.updateQueue, l === a)) {
      var n = null, i = null;
      if (l = l.firstBaseUpdate, l !== null) {
        do {
          var u = {
            lane: l.lane,
            tag: l.tag,
            payload: l.payload,
            callback: null,
            next: null
          };
          i === null ? n = i = u : i = i.next = u, l = l.next;
        } while (l !== null);
        i === null ? n = i = e : i = i.next = e;
      } else n = i = e;
      l = {
        baseState: a.baseState,
        firstBaseUpdate: n,
        lastBaseUpdate: i,
        shared: a.shared,
        callbacks: a.callbacks
      }, t.updateQueue = l;
      return;
    }
    t = l.lastBaseUpdate, t === null ? l.firstBaseUpdate = e : t.next = e, l.lastBaseUpdate = e;
  }
  var Jf = !1;
  function di() {
    if (Jf) {
      var t = xn;
      if (t !== null) throw t;
    }
  }
  function mi(t, e, l, a) {
    Jf = !1;
    var n = t.updateQueue;
    Pl = !1;
    var i = n.firstBaseUpdate, u = n.lastBaseUpdate, f = n.shared.pending;
    if (f !== null) {
      n.shared.pending = null;
      var o = f, y = o.next;
      o.next = null, u === null ? i = y : u.next = y, u = o;
      var T = t.alternate;
      T !== null && (T = T.updateQueue, f = T.lastBaseUpdate, f !== u && (f === null ? T.firstBaseUpdate = y : f.next = y, T.lastBaseUpdate = o));
    }
    if (i !== null) {
      var A = n.baseState;
      u = 0, T = y = o = null, f = i;
      do {
        var b = f.lane & -536870913, S = b !== f.lane;
        if (S ? (ot & b) === b : (a & b) === b) {
          b !== 0 && b === bn && (Jf = !0), T !== null && (T = T.next = {
            lane: 0,
            tag: f.tag,
            payload: f.payload,
            callback: null,
            next: null
          });
          t: {
            var j = t, J = f;
            b = e;
            var _t = l;
            switch (J.tag) {
              case 1:
                if (j = J.payload, typeof j == "function") {
                  A = j.call(_t, A, b);
                  break t;
                }
                A = j;
                break t;
              case 3:
                j.flags = j.flags & -65537 | 128;
              case 0:
                if (j = J.payload, b = typeof j == "function" ? j.call(_t, A, b) : j, b == null) break t;
                A = V({}, A, b);
                break t;
              case 2:
                Pl = !0;
            }
          }
          b = f.callback, b !== null && (t.flags |= 64, S && (t.flags |= 8192), S = n.callbacks, S === null ? n.callbacks = [b] : S.push(b));
        } else
          S = {
            lane: b,
            tag: f.tag,
            payload: f.payload,
            callback: f.callback,
            next: null
          }, T === null ? (y = T = S, o = A) : T = T.next = S, u |= b;
        if (f = f.next, f === null) {
          if (f = n.shared.pending, f === null)
            break;
          S = f, f = S.next, S.next = null, n.lastBaseUpdate = S, n.shared.pending = null;
        }
      } while (!0);
      T === null && (o = A), n.baseState = o, n.firstBaseUpdate = y, n.lastBaseUpdate = T, i === null && (n.shared.lanes = 0), ua |= u, t.lanes = u, t.memoizedState = A;
    }
  }
  function sr(t, e) {
    if (typeof t != "function")
      throw Error(g(191, t));
    t.call(e);
  }
  function dr(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        sr(l[t], e);
  }
  var zn = s(null), yu = s(0);
  function mr(t, e) {
    t = ql, N(yu, t), N(zn, e), ql = t | e.baseLanes;
  }
  function kf() {
    N(yu, ql), N(zn, zn.current);
  }
  function Ff() {
    ql = yu.current, M(zn), M(yu);
  }
  var Ne = s(null), Je = null;
  function la(t) {
    var e = t.alternate;
    N(Yt, Yt.current & 1), N(Ne, t), Je === null && (e === null || zn.current !== null || e.memoizedState !== null) && (Je = t);
  }
  function Wf(t) {
    N(Yt, Yt.current), N(Ne, t), Je === null && (Je = t);
  }
  function hr(t) {
    t.tag === 22 ? (N(Yt, Yt.current), N(Ne, t), Je === null && (Je = t)) : aa();
  }
  function aa() {
    N(Yt, Yt.current), N(Ne, Ne.current);
  }
  function Re(t) {
    M(Ne), Je === t && (Je = null), M(Yt);
  }
  var Yt = s(0);
  function vu(t) {
    for (var e = t; e !== null; ) {
      if (e.tag === 13) {
        var l = e.memoizedState;
        if (l !== null && (l = l.dehydrated, l === null || lo(l) || ao(l)))
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
  var Cl = 0, et = null, Et = null, Zt = null, bu = !1, Mn = !1, Za = !1, xu = 0, hi = 0, En = null, Jm = 0;
  function jt() {
    throw Error(g(321));
  }
  function $f(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!Ue(t[l], e[l])) return !1;
    return !0;
  }
  function If(t, e, l, a, n, i) {
    return Cl = i, et = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, m.H = t === null || t.memoizedState === null ? $r : mc, Za = !1, i = l(a, n), Za = !1, Mn && (i = pr(
      e,
      l,
      a,
      n
    )), gr(t), i;
  }
  function gr(t) {
    m.H = yi;
    var e = Et !== null && Et.next !== null;
    if (Cl = 0, Zt = Et = et = null, bu = !1, hi = 0, En = null, e) throw Error(g(300));
    t === null || Kt || (t = t.dependencies, t !== null && ru(t) && (Kt = !0));
  }
  function pr(t, e, l, a) {
    et = t;
    var n = 0;
    do {
      if (Mn && (En = null), hi = 0, Mn = !1, 25 <= n) throw Error(g(301));
      if (n += 1, Zt = Et = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      m.H = Ir, i = e(l, a);
    } while (Mn);
    return i;
  }
  function km() {
    var t = m.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? gi(e) : e, t = t.useState()[0], (Et !== null ? Et.memoizedState : null) !== t && (et.flags |= 1024), e;
  }
  function Pf() {
    var t = xu !== 0;
    return xu = 0, t;
  }
  function tc(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function ec(t) {
    if (bu) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      bu = !1;
    }
    Cl = 0, Zt = Et = et = null, Mn = !1, hi = xu = 0, En = null;
  }
  function ve() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return Zt === null ? et.memoizedState = Zt = t : Zt = Zt.next = t, Zt;
  }
  function Lt() {
    if (Et === null) {
      var t = et.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = Et.next;
    var e = Zt === null ? et.memoizedState : Zt.next;
    if (e !== null)
      Zt = e, Et = t;
    else {
      if (t === null)
        throw et.alternate === null ? Error(g(467)) : Error(g(310));
      Et = t, t = {
        memoizedState: Et.memoizedState,
        baseState: Et.baseState,
        baseQueue: Et.baseQueue,
        queue: Et.queue,
        next: null
      }, Zt === null ? et.memoizedState = Zt = t : Zt = Zt.next = t;
    }
    return Zt;
  }
  function Su() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function gi(t) {
    var e = hi;
    return hi += 1, En === null && (En = []), t = ur(En, t, e), e = et, (Zt === null ? e.memoizedState : Zt.next) === null && (e = e.alternate, m.H = e === null || e.memoizedState === null ? $r : mc), t;
  }
  function Tu(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return gi(t);
      if (t.$$typeof === Rt) return ue(t);
    }
    throw Error(g(438, String(t)));
  }
  function lc(t) {
    var e = null, l = et.updateQueue;
    if (l !== null && (e = l.memoCache), e == null) {
      var a = et.alternate;
      a !== null && (a = a.updateQueue, a !== null && (a = a.memoCache, a != null && (e = {
        data: a.data.map(function(n) {
          return n.slice();
        }),
        index: 0
      })));
    }
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Su(), et.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = be;
    return e.index++, l;
  }
  function Ul(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function zu(t) {
    var e = Lt();
    return ac(e, Et, t);
  }
  function ac(t, e, l) {
    var a = t.queue;
    if (a === null) throw Error(g(311));
    a.lastRenderedReducer = l;
    var n = t.baseQueue, i = a.pending;
    if (i !== null) {
      if (n !== null) {
        var u = n.next;
        n.next = i.next, i.next = u;
      }
      e.baseQueue = n = i, a.pending = null;
    }
    if (i = t.baseState, n === null) t.memoizedState = i;
    else {
      e = n.next;
      var f = u = null, o = null, y = e, T = !1;
      do {
        var A = y.lane & -536870913;
        if (A !== y.lane ? (ot & A) === A : (Cl & A) === A) {
          var b = y.revertLane;
          if (b === 0)
            o !== null && (o = o.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: y.action,
              hasEagerState: y.hasEagerState,
              eagerState: y.eagerState,
              next: null
            }), A === bn && (T = !0);
          else if ((Cl & b) === b) {
            y = y.next, b === bn && (T = !0);
            continue;
          } else
            A = {
              lane: 0,
              revertLane: y.revertLane,
              gesture: null,
              action: y.action,
              hasEagerState: y.hasEagerState,
              eagerState: y.eagerState,
              next: null
            }, o === null ? (f = o = A, u = i) : o = o.next = A, et.lanes |= b, ua |= b;
          A = y.action, Za && l(i, A), i = y.hasEagerState ? y.eagerState : l(i, A);
        } else
          b = {
            lane: A,
            revertLane: y.revertLane,
            gesture: y.gesture,
            action: y.action,
            hasEagerState: y.hasEagerState,
            eagerState: y.eagerState,
            next: null
          }, o === null ? (f = o = b, u = i) : o = o.next = b, et.lanes |= A, ua |= A;
        y = y.next;
      } while (y !== null && y !== e);
      if (o === null ? u = i : o.next = f, !Ue(i, t.memoizedState) && (Kt = !0, T && (l = xn, l !== null)))
        throw l;
      t.memoizedState = i, t.baseState = u, t.baseQueue = o, a.lastRenderedState = i;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function nc(t) {
    var e = Lt(), l = e.queue;
    if (l === null) throw Error(g(311));
    l.lastRenderedReducer = t;
    var a = l.dispatch, n = l.pending, i = e.memoizedState;
    if (n !== null) {
      l.pending = null;
      var u = n = n.next;
      do
        i = t(i, u.action), u = u.next;
      while (u !== n);
      Ue(i, e.memoizedState) || (Kt = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function yr(t, e, l) {
    var a = et, n = Lt(), i = dt;
    if (i) {
      if (l === void 0) throw Error(g(407));
      l = l();
    } else l = e();
    var u = !Ue(
      (Et || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, Kt = !0), n = n.queue, fc(xr.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || Zt !== null && Zt.memoizedState.tag & 1) {
      if (a.flags |= 2048, An(
        9,
        { destroy: void 0 },
        br.bind(
          null,
          a,
          n,
          l,
          e
        ),
        null
      ), Dt === null) throw Error(g(349));
      i || (Cl & 127) !== 0 || vr(a, e, l);
    }
    return l;
  }
  function vr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = et.updateQueue, e === null ? (e = Su(), et.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
  }
  function br(t, e, l, a) {
    e.value = l, e.getSnapshot = a, Sr(e) && Tr(t);
  }
  function xr(t, e, l) {
    return l(function() {
      Sr(e) && Tr(t);
    });
  }
  function Sr(t) {
    var e = t.getSnapshot;
    t = t.value;
    try {
      var l = e();
      return !Ue(t, l);
    } catch {
      return !0;
    }
  }
  function Tr(t) {
    var e = Ha(t, 2);
    e !== null && _e(e, t, 2);
  }
  function ic(t) {
    var e = ve();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Za) {
        nl(!0);
        try {
          l();
        } finally {
          nl(!1);
        }
      }
    }
    return e.memoizedState = e.baseState = t, e.queue = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Ul,
      lastRenderedState: t
    }, e;
  }
  function zr(t, e, l, a) {
    return t.baseState = l, ac(
      t,
      Et,
      typeof a == "function" ? a : Ul
    );
  }
  function Fm(t, e, l, a, n) {
    if (Au(t)) throw Error(g(485));
    if (t = e.action, t !== null) {
      var i = {
        payload: n,
        action: t,
        next: null,
        isTransition: !0,
        status: "pending",
        value: null,
        reason: null,
        listeners: [],
        then: function(u) {
          i.listeners.push(u);
        }
      };
      m.T !== null ? l(!0) : i.isTransition = !1, a(i), l = e.pending, l === null ? (i.next = e.pending = i, Mr(e, i)) : (i.next = l.next, e.pending = l.next = i);
    }
  }
  function Mr(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var i = m.T, u = {};
      m.T = u;
      try {
        var f = l(n, a), o = m.S;
        o !== null && o(u, f), Er(t, e, f);
      } catch (y) {
        uc(t, e, y);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), m.T = i;
      }
    } else
      try {
        i = l(n, a), Er(t, e, i);
      } catch (y) {
        uc(t, e, y);
      }
  }
  function Er(t, e, l) {
    l !== null && typeof l == "object" && typeof l.then == "function" ? l.then(
      function(a) {
        Ar(t, e, a);
      },
      function(a) {
        return uc(t, e, a);
      }
    ) : Ar(t, e, l);
  }
  function Ar(t, e, l) {
    e.status = "fulfilled", e.value = l, _r(e), t.state = l, e = t.pending, e !== null && (l = e.next, l === e ? t.pending = null : (l = l.next, e.next = l, Mr(t, l)));
  }
  function uc(t, e, l) {
    var a = t.pending;
    if (t.pending = null, a !== null) {
      a = a.next;
      do
        e.status = "rejected", e.reason = l, _r(e), e = e.next;
      while (e !== a);
    }
    t.action = null;
  }
  function _r(t) {
    t = t.listeners;
    for (var e = 0; e < t.length; e++) (0, t[e])();
  }
  function Dr(t, e) {
    return e;
  }
  function Or(t, e) {
    if (dt) {
      var l = Dt.formState;
      if (l !== null) {
        t: {
          var a = et;
          if (dt) {
            if (Ct) {
              e: {
                for (var n = Ct, i = Ke; n.nodeType !== 8; ) {
                  if (!i) {
                    n = null;
                    break e;
                  }
                  if (n = ke(
                    n.nextSibling
                  ), n === null) {
                    n = null;
                    break e;
                  }
                }
                i = n.data, n = i === "F!" || i === "F" ? n : null;
              }
              if (n) {
                Ct = ke(
                  n.nextSibling
                ), a = n.data === "F!";
                break t;
              }
            }
            $l(a);
          }
          a = !1;
        }
        a && (e = l[0]);
      }
    }
    return l = ve(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Dr,
      lastRenderedState: e
    }, l.queue = a, l = kr.bind(
      null,
      et,
      a
    ), a.dispatch = l, a = ic(!1), i = dc.bind(
      null,
      et,
      !1,
      a.queue
    ), a = ve(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = Fm.bind(
      null,
      et,
      n,
      i,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Cr(t) {
    var e = Lt();
    return Ur(e, Et, t);
  }
  function Ur(t, e, l) {
    if (e = ac(
      t,
      e,
      Dr
    )[0], t = zu(Ul)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = gi(e);
      } catch (u) {
        throw u === Sn ? mu : u;
      }
    else a = e;
    e = Lt();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (et.flags |= 2048, An(
      9,
      { destroy: void 0 },
      Wm.bind(null, n, l),
      null
    )), [a, i, t];
  }
  function Wm(t, e) {
    t.action = e;
  }
  function Br(t) {
    var e = Lt(), l = Et;
    if (l !== null)
      return Ur(e, l, t);
    Lt(), e = e.memoizedState, l = Lt();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function An(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = et.updateQueue, e === null && (e = Su(), et.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Nr() {
    return Lt().memoizedState;
  }
  function Mu(t, e, l, a) {
    var n = ve();
    et.flags |= t, n.memoizedState = An(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Eu(t, e, l, a) {
    var n = Lt();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    Et !== null && a !== null && $f(a, Et.memoizedState.deps) ? n.memoizedState = An(e, i, l, a) : (et.flags |= t, n.memoizedState = An(
      1 | e,
      i,
      l,
      a
    ));
  }
  function Rr(t, e) {
    Mu(8390656, 8, t, e);
  }
  function fc(t, e) {
    Eu(2048, 8, t, e);
  }
  function $m(t) {
    et.flags |= 4;
    var e = et.updateQueue;
    if (e === null)
      e = Su(), et.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function wr(t) {
    var e = Lt().memoizedState;
    return $m({ ref: e, nextImpl: t }), function() {
      if ((bt & 2) !== 0) throw Error(g(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function Hr(t, e) {
    return Eu(4, 2, t, e);
  }
  function jr(t, e) {
    return Eu(4, 4, t, e);
  }
  function qr(t, e) {
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
  function Gr(t, e, l) {
    l = l != null ? l.concat([t]) : null, Eu(4, 4, qr.bind(null, e, t), l);
  }
  function cc() {
  }
  function Yr(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && $f(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Lr(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && $f(e, a[1]))
      return a[0];
    if (a = t(), Za) {
      nl(!0);
      try {
        t();
      } finally {
        nl(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function oc(t, e, l) {
    return l === void 0 || (Cl & 1073741824) !== 0 && (ot & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Xs(), et.lanes |= t, ua |= t, l);
  }
  function Xr(t, e, l, a) {
    return Ue(l, e) ? l : zn.current !== null ? (t = oc(t, l, a), Ue(t, e) || (Kt = !0), t) : (Cl & 42) === 0 || (Cl & 1073741824) !== 0 && (ot & 261930) === 0 ? (Kt = !0, t.memoizedState = l) : (t = Xs(), et.lanes |= t, ua |= t, e);
  }
  function Qr(t, e, l, a, n) {
    var i = O.p;
    O.p = i !== 0 && 8 > i ? i : 8;
    var u = m.T, f = {};
    m.T = f, dc(t, !1, e, l);
    try {
      var o = n(), y = m.S;
      if (y !== null && y(f, o), o !== null && typeof o == "object" && typeof o.then == "function") {
        var T = Km(
          o,
          a
        );
        pi(
          t,
          e,
          T,
          je(t)
        );
      } else
        pi(
          t,
          e,
          a,
          je(t)
        );
    } catch (A) {
      pi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: A },
        je()
      );
    } finally {
      O.p = i, u !== null && f.types !== null && (u.types = f.types), m.T = u;
    }
  }
  function Im() {
  }
  function rc(t, e, l, a) {
    if (t.tag !== 5) throw Error(g(476));
    var n = Vr(t).queue;
    Qr(
      t,
      n,
      e,
      L,
      l === null ? Im : function() {
        return Zr(t), l(a);
      }
    );
  }
  function Vr(t) {
    var e = t.memoizedState;
    if (e !== null) return e;
    e = {
      memoizedState: L,
      baseState: L,
      baseQueue: null,
      queue: {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: Ul,
        lastRenderedState: L
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
        lastRenderedReducer: Ul,
        lastRenderedState: l
      },
      next: null
    }, t.memoizedState = e, t = t.alternate, t !== null && (t.memoizedState = e), e;
  }
  function Zr(t) {
    var e = Vr(t);
    e.next === null && (e = t.alternate.memoizedState), pi(
      t,
      e.next.queue,
      {},
      je()
    );
  }
  function sc() {
    return ue(Ni);
  }
  function Kr() {
    return Lt().memoizedState;
  }
  function Jr() {
    return Lt().memoizedState;
  }
  function Pm(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = je();
          t = ta(l);
          var a = ea(e, t, l);
          a !== null && (_e(a, e, l), si(a, e, l)), e = { cache: Yf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function th(t, e, l) {
    var a = je();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Au(t) ? Fr(e, l) : (l = Of(t, e, l, a), l !== null && (_e(l, t, a), Wr(l, e, a)));
  }
  function kr(t, e, l) {
    var a = je();
    pi(t, e, l, a);
  }
  function pi(t, e, l, a) {
    var n = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    };
    if (Au(t)) Fr(e, n);
    else {
      var i = t.alternate;
      if (t.lanes === 0 && (i === null || i.lanes === 0) && (i = e.lastRenderedReducer, i !== null))
        try {
          var u = e.lastRenderedState, f = i(u, l);
          if (n.hasEagerState = !0, n.eagerState = f, Ue(f, u))
            return uu(t, e, n, 0), Dt === null && iu(), !1;
        } catch {
        }
      if (l = Of(t, e, n, a), l !== null)
        return _e(l, t, a), Wr(l, e, a), !0;
    }
    return !1;
  }
  function dc(t, e, l, a) {
    if (a = {
      lane: 2,
      revertLane: Vc(),
      gesture: null,
      action: a,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Au(t)) {
      if (e) throw Error(g(479));
    } else
      e = Of(
        t,
        l,
        a,
        2
      ), e !== null && _e(e, t, 2);
  }
  function Au(t) {
    var e = t.alternate;
    return t === et || e !== null && e === et;
  }
  function Fr(t, e) {
    Mn = bu = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function Wr(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, ge(t, l);
    }
  }
  var yi = {
    readContext: ue,
    use: Tu,
    useCallback: jt,
    useContext: jt,
    useEffect: jt,
    useImperativeHandle: jt,
    useLayoutEffect: jt,
    useInsertionEffect: jt,
    useMemo: jt,
    useReducer: jt,
    useRef: jt,
    useState: jt,
    useDebugValue: jt,
    useDeferredValue: jt,
    useTransition: jt,
    useSyncExternalStore: jt,
    useId: jt,
    useHostTransitionStatus: jt,
    useFormState: jt,
    useActionState: jt,
    useOptimistic: jt,
    useMemoCache: jt,
    useCacheRefresh: jt
  };
  yi.useEffectEvent = jt;
  var $r = {
    readContext: ue,
    use: Tu,
    useCallback: function(t, e) {
      return ve().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: ue,
    useEffect: Rr,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, Mu(
        4194308,
        4,
        qr.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return Mu(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      Mu(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = ve();
      e = e === void 0 ? null : e;
      var a = t();
      if (Za) {
        nl(!0);
        try {
          t();
        } finally {
          nl(!1);
        }
      }
      return l.memoizedState = [a, e], a;
    },
    useReducer: function(t, e, l) {
      var a = ve();
      if (l !== void 0) {
        var n = l(e);
        if (Za) {
          nl(!0);
          try {
            l(e);
          } finally {
            nl(!1);
          }
        }
      } else n = e;
      return a.memoizedState = a.baseState = n, t = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: t,
        lastRenderedState: n
      }, a.queue = t, t = t.dispatch = th.bind(
        null,
        et,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = ve();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = ic(t);
      var e = t.queue, l = kr.bind(null, et, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: cc,
    useDeferredValue: function(t, e) {
      var l = ve();
      return oc(l, t, e);
    },
    useTransition: function() {
      var t = ic(!1);
      return t = Qr.bind(
        null,
        et,
        t.queue,
        !0,
        !1
      ), ve().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = et, n = ve();
      if (dt) {
        if (l === void 0)
          throw Error(g(407));
        l = l();
      } else {
        if (l = e(), Dt === null)
          throw Error(g(349));
        (ot & 127) !== 0 || vr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, Rr(xr.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, An(
        9,
        { destroy: void 0 },
        br.bind(
          null,
          a,
          i,
          l,
          e
        ),
        null
      ), l;
    },
    useId: function() {
      var t = ve(), e = Dt.identifierPrefix;
      if (dt) {
        var l = dl, a = sl;
        l = (a & ~(1 << 32 - Ft(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = xu++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Jm++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: sc,
    useFormState: Or,
    useActionState: Or,
    useOptimistic: function(t) {
      var e = ve();
      e.memoizedState = e.baseState = t;
      var l = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: null,
        lastRenderedState: null
      };
      return e.queue = l, e = dc.bind(
        null,
        et,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: lc,
    useCacheRefresh: function() {
      return ve().memoizedState = Pm.bind(
        null,
        et
      );
    },
    useEffectEvent: function(t) {
      var e = ve(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((bt & 2) !== 0)
          throw Error(g(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, mc = {
    readContext: ue,
    use: Tu,
    useCallback: Yr,
    useContext: ue,
    useEffect: fc,
    useImperativeHandle: Gr,
    useInsertionEffect: Hr,
    useLayoutEffect: jr,
    useMemo: Lr,
    useReducer: zu,
    useRef: Nr,
    useState: function() {
      return zu(Ul);
    },
    useDebugValue: cc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return Xr(
        l,
        Et.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = zu(Ul)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : gi(t),
        e
      ];
    },
    useSyncExternalStore: yr,
    useId: Kr,
    useHostTransitionStatus: sc,
    useFormState: Cr,
    useActionState: Cr,
    useOptimistic: function(t, e) {
      var l = Lt();
      return zr(l, Et, t, e);
    },
    useMemoCache: lc,
    useCacheRefresh: Jr
  };
  mc.useEffectEvent = wr;
  var Ir = {
    readContext: ue,
    use: Tu,
    useCallback: Yr,
    useContext: ue,
    useEffect: fc,
    useImperativeHandle: Gr,
    useInsertionEffect: Hr,
    useLayoutEffect: jr,
    useMemo: Lr,
    useReducer: nc,
    useRef: Nr,
    useState: function() {
      return nc(Ul);
    },
    useDebugValue: cc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return Et === null ? oc(l, t, e) : Xr(
        l,
        Et.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = nc(Ul)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : gi(t),
        e
      ];
    },
    useSyncExternalStore: yr,
    useId: Kr,
    useHostTransitionStatus: sc,
    useFormState: Br,
    useActionState: Br,
    useOptimistic: function(t, e) {
      var l = Lt();
      return Et !== null ? zr(l, Et, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: lc,
    useCacheRefresh: Jr
  };
  Ir.useEffectEvent = wr;
  function hc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : V({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var gc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = je(), n = ta(a);
      n.payload = e, l != null && (n.callback = l), e = ea(t, n, a), e !== null && (_e(e, t, a), si(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = je(), n = ta(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = ea(t, n, a), e !== null && (_e(e, t, a), si(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = je(), a = ta(l);
      a.tag = 2, e != null && (a.callback = e), e = ea(t, a, l), e !== null && (_e(e, t, l), si(e, t, l));
    }
  };
  function Pr(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ai(l, a) || !ai(n, i) : !0;
  }
  function ts(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && gc.enqueueReplaceState(e, e.state, null);
  }
  function Ka(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = V({}, l));
      for (var n in t)
        l[n] === void 0 && (l[n] = t[n]);
    }
    return l;
  }
  function es(t) {
    nu(t);
  }
  function ls(t) {
    console.error(t);
  }
  function as(t) {
    nu(t);
  }
  function _u(t, e) {
    try {
      var l = t.onUncaughtError;
      l(e.value, { componentStack: e.stack });
    } catch (a) {
      setTimeout(function() {
        throw a;
      });
    }
  }
  function ns(t, e, l) {
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
  function pc(t, e, l) {
    return l = ta(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      _u(t, e);
    }, l;
  }
  function is(t) {
    return t = ta(t), t.tag = 3, t;
  }
  function us(t, e, l, a) {
    var n = l.type.getDerivedStateFromError;
    if (typeof n == "function") {
      var i = a.value;
      t.payload = function() {
        return n(i);
      }, t.callback = function() {
        ns(e, l, a);
      };
    }
    var u = l.stateNode;
    u !== null && typeof u.componentDidCatch == "function" && (t.callback = function() {
      ns(e, l, a), typeof n != "function" && (fa === null ? fa = /* @__PURE__ */ new Set([this]) : fa.add(this));
      var f = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: f !== null ? f : ""
      });
    });
  }
  function eh(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && vn(
        e,
        l,
        n,
        !0
      ), l = Ne.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return Je === null ? Gu() : l.alternate === null && qt === 0 && (qt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === hu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Lc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === hu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Lc(t, a, n)), !1;
        }
        throw Error(g(435, l.tag));
      }
      return Lc(t, a, n), Gu(), !1;
    }
    if (dt)
      return e = Ne.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== wf && (t = Error(g(422), { cause: a }), ui(Qe(t, l)))) : (a !== wf && (e = Error(g(423), {
        cause: a
      }), ui(
        Qe(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Qe(a, l), n = pc(
        t.stateNode,
        a,
        n
      ), Kf(t, n), qt !== 4 && (qt = 2)), !1;
    var i = Error(g(520), { cause: a });
    if (i = Qe(i, l), Ei === null ? Ei = [i] : Ei.push(i), qt !== 4 && (qt = 2), e === null) return !0;
    a = Qe(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = pc(l.stateNode, a, t), Kf(l, t), !1;
        case 1:
          if (e = l.type, i = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || i !== null && typeof i.componentDidCatch == "function" && (fa === null || !fa.has(i))))
            return l.flags |= 65536, n &= -n, l.lanes |= n, n = is(n), us(
              n,
              t,
              l,
              a
            ), Kf(l, n), !1;
      }
      l = l.return;
    } while (l !== null);
    return !1;
  }
  var yc = Error(g(461)), Kt = !1;
  function fe(t, e, l, a) {
    e.child = t === null ? rr(e, null, l, a) : Va(
      e,
      t.child,
      l,
      a
    );
  }
  function fs(t, e, l, a, n) {
    l = l.render;
    var i = e.ref;
    if ("ref" in a) {
      var u = {};
      for (var f in a)
        f !== "ref" && (u[f] = a[f]);
    } else u = a;
    return Ya(e), a = If(
      t,
      e,
      l,
      u,
      i,
      n
    ), f = Pf(), t !== null && !Kt ? (tc(t, e, n), Bl(t, e, n)) : (dt && f && Nf(e), e.flags |= 1, fe(t, e, a, n), e.child);
  }
  function cs(t, e, l, a, n) {
    if (t === null) {
      var i = l.type;
      return typeof i == "function" && !Cf(i) && i.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = i, os(
        t,
        e,
        i,
        a,
        n
      )) : (t = cu(
        l.type,
        null,
        a,
        e,
        e.mode,
        n
      ), t.ref = e.ref, t.return = e, e.child = t);
    }
    if (i = t.child, !Ec(t, n)) {
      var u = i.memoizedProps;
      if (l = l.compare, l = l !== null ? l : ai, l(u, a) && t.ref === e.ref)
        return Bl(t, e, n);
    }
    return e.flags |= 1, t = Al(i, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function os(t, e, l, a, n) {
    if (t !== null) {
      var i = t.memoizedProps;
      if (ai(i, a) && t.ref === e.ref)
        if (Kt = !1, e.pendingProps = a = i, Ec(t, n))
          (t.flags & 131072) !== 0 && (Kt = !0);
        else
          return e.lanes = t.lanes, Bl(t, e, n);
    }
    return vc(
      t,
      e,
      l,
      a,
      n
    );
  }
  function rs(t, e, l, a) {
    var n = a.children, i = t !== null ? t.memoizedState : null;
    if (t === null && e.stateNode === null && (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), a.mode === "hidden") {
      if ((e.flags & 128) !== 0) {
        if (i = i !== null ? i.baseLanes | l : l, t !== null) {
          for (a = e.child = t.child, n = 0; a !== null; )
            n = n | a.lanes | a.childLanes, a = a.sibling;
          a = n & ~i;
        } else a = 0, e.child = null;
        return ss(
          t,
          e,
          i,
          l,
          a
        );
      }
      if ((l & 536870912) !== 0)
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && du(
          e,
          i !== null ? i.cachePool : null
        ), i !== null ? mr(e, i) : kf(), hr(e);
      else
        return a = e.lanes = 536870912, ss(
          t,
          e,
          i !== null ? i.baseLanes | l : l,
          l,
          a
        );
    } else
      i !== null ? (du(e, i.cachePool), mr(e, i), aa(), e.memoizedState = null) : (t !== null && du(e, null), kf(), aa());
    return fe(t, e, n, l), e.child;
  }
  function vi(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function ss(t, e, l, a, n) {
    var i = Xf();
    return i = i === null ? null : { parent: Vt._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && du(e, null), kf(), hr(e), t !== null && vn(t, e, a, !0), e.childLanes = n, null;
  }
  function Du(t, e) {
    return e = Cu(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function ds(t, e, l) {
    return Va(e, t.child, null, l), t = Du(e, e.pendingProps), t.flags |= 2, Re(e), e.memoizedState = null, t;
  }
  function lh(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (dt) {
        if (a.mode === "hidden")
          return t = Du(e, a), e.lanes = 536870912, vi(null, t);
        if (Wf(e), (t = Ct) ? (t = Md(
          t,
          Ke
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Fl !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ie = e, Ct = null)) : t = null, t === null) throw $l(e);
        return e.lanes = 536870912, null;
      }
      return Du(e, a);
    }
    var i = t.memoizedState;
    if (i !== null) {
      var u = i.dehydrated;
      if (Wf(e), n)
        if (e.flags & 256)
          e.flags &= -257, e = ds(
            t,
            e,
            l
          );
        else if (e.memoizedState !== null)
          e.child = t.child, e.flags |= 128, e = null;
        else throw Error(g(558));
      else if (Kt || vn(t, e, l, !1), n = (l & t.childLanes) !== 0, Kt || n) {
        if (a = Dt, a !== null && (u = tn(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, Ha(t, u), _e(a, t, u), yc;
        Gu(), e = ds(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, Ct = ke(u.nextSibling), ie = e, dt = !0, Wl = null, Ke = !1, t !== null && Io(e, t), e = Du(e, a), e.flags |= 4096;
      return e;
    }
    return t = Al(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Ou(t, e) {
    var l = e.ref;
    if (l === null)
      t !== null && t.ref !== null && (e.flags |= 4194816);
    else {
      if (typeof l != "function" && typeof l != "object")
        throw Error(g(284));
      (t === null || t.ref !== l) && (e.flags |= 4194816);
    }
  }
  function vc(t, e, l, a, n) {
    return Ya(e), l = If(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = Pf(), t !== null && !Kt ? (tc(t, e, n), Bl(t, e, n)) : (dt && a && Nf(e), e.flags |= 1, fe(t, e, l, n), e.child);
  }
  function ms(t, e, l, a, n, i) {
    return Ya(e), e.updateQueue = null, l = pr(
      e,
      a,
      l,
      n
    ), gr(t), a = Pf(), t !== null && !Kt ? (tc(t, e, i), Bl(t, e, i)) : (dt && a && Nf(e), e.flags |= 1, fe(t, e, l, i), e.child);
  }
  function hs(t, e, l, a, n) {
    if (Ya(e), e.stateNode === null) {
      var i = hn, u = l.contextType;
      typeof u == "object" && u !== null && (i = ue(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = gc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Vf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? ue(u) : hn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (hc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && gc.enqueueReplaceState(i, i.state, null), mi(e, a, i, n), di(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var f = e.memoizedProps, o = Ka(l, f);
      i.props = o;
      var y = i.context, T = l.contextType;
      u = hn, typeof T == "object" && T !== null && (u = ue(T));
      var A = l.getDerivedStateFromProps;
      T = typeof A == "function" || typeof i.getSnapshotBeforeUpdate == "function", f = e.pendingProps !== f, T || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (f || y !== u) && ts(
        e,
        i,
        a,
        u
      ), Pl = !1;
      var b = e.memoizedState;
      i.state = b, mi(e, a, i, n), di(), y = e.memoizedState, f || b !== y || Pl ? (typeof A == "function" && (hc(
        e,
        l,
        A,
        a
      ), y = e.memoizedState), (o = Pl || Pr(
        e,
        l,
        o,
        a,
        b,
        y,
        u
      )) ? (T || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = y), i.props = a, i.state = y, i.context = u, a = o) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, Zf(t, e), u = e.memoizedProps, T = Ka(l, u), i.props = T, A = e.pendingProps, b = i.context, y = l.contextType, o = hn, typeof y == "object" && y !== null && (o = ue(y)), f = l.getDerivedStateFromProps, (y = typeof f == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== A || b !== o) && ts(
        e,
        i,
        a,
        o
      ), Pl = !1, b = e.memoizedState, i.state = b, mi(e, a, i, n), di();
      var S = e.memoizedState;
      u !== A || b !== S || Pl || t !== null && t.dependencies !== null && ru(t.dependencies) ? (typeof f == "function" && (hc(
        e,
        l,
        f,
        a
      ), S = e.memoizedState), (T = Pl || Pr(
        e,
        l,
        T,
        a,
        b,
        S,
        o
      ) || t !== null && t.dependencies !== null && ru(t.dependencies)) ? (y || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, S, o), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        S,
        o
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = S), i.props = a, i.state = S, i.context = o, a = T) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return i = a, Ou(t, e), a = (e.flags & 128) !== 0, i || a ? (i = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : i.render(), e.flags |= 1, t !== null && a ? (e.child = Va(
      e,
      t.child,
      null,
      n
    ), e.child = Va(
      e,
      null,
      l,
      n
    )) : fe(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = Bl(
      t,
      e,
      n
    ), t;
  }
  function gs(t, e, l, a) {
    return qa(), e.flags |= 256, fe(t, e, l, a), e.child;
  }
  var bc = {
    dehydrated: null,
    treeContext: null,
    retryLane: 0,
    hydrationErrors: null
  };
  function xc(t) {
    return { baseLanes: t, cachePool: nr() };
  }
  function Sc(t, e, l) {
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= He), t;
  }
  function ps(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : (Yt.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (dt) {
        if (n ? la(e) : aa(), (t = Ct) ? (t = Md(
          t,
          Ke
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Fl !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ie = e, Ct = null)) : t = null, t === null) throw $l(e);
        return ao(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var f = a.children;
      return a = a.fallback, n ? (aa(), n = e.mode, f = Cu(
        { mode: "hidden", children: f },
        n
      ), a = ja(
        a,
        n,
        l,
        null
      ), f.return = e, a.return = e, f.sibling = a, e.child = f, a = e.child, a.memoizedState = xc(l), a.childLanes = Sc(
        t,
        u,
        l
      ), e.memoizedState = bc, vi(null, a)) : (la(e), Tc(e, f));
    }
    var o = t.memoizedState;
    if (o !== null && (f = o.dehydrated, f !== null)) {
      if (i)
        e.flags & 256 ? (la(e), e.flags &= -257, e = zc(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (aa(), e.child = t.child, e.flags |= 128, e = null) : (aa(), f = a.fallback, n = e.mode, a = Cu(
          { mode: "visible", children: a.children },
          n
        ), f = ja(
          f,
          n,
          l,
          null
        ), f.flags |= 2, a.return = e, f.return = e, a.sibling = f, e.child = a, Va(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = xc(l), a.childLanes = Sc(
          t,
          u,
          l
        ), e.memoizedState = bc, e = vi(null, a));
      else if (la(e), ao(f)) {
        if (u = f.nextSibling && f.nextSibling.dataset, u) var y = u.dgst;
        u = y, a = Error(g(419)), a.stack = "", a.digest = u, ui({ value: a, source: null, stack: null }), e = zc(
          t,
          e,
          l
        );
      } else if (Kt || vn(t, e, l, !1), u = (l & t.childLanes) !== 0, Kt || u) {
        if (u = Dt, u !== null && (a = tn(u, l), a !== 0 && a !== o.retryLane))
          throw o.retryLane = a, Ha(t, a), _e(u, t, a), yc;
        lo(f) || Gu(), e = zc(
          t,
          e,
          l
        );
      } else
        lo(f) ? (e.flags |= 192, e.child = t.child, e = null) : (t = o.treeContext, Ct = ke(
          f.nextSibling
        ), ie = e, dt = !0, Wl = null, Ke = !1, t !== null && Io(e, t), e = Tc(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (aa(), f = a.fallback, n = e.mode, o = t.child, y = o.sibling, a = Al(o, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = o.subtreeFlags & 65011712, y !== null ? f = Al(
      y,
      f
    ) : (f = ja(
      f,
      n,
      l,
      null
    ), f.flags |= 2), f.return = e, a.return = e, a.sibling = f, e.child = a, vi(null, a), a = e.child, f = t.child.memoizedState, f === null ? f = xc(l) : (n = f.cachePool, n !== null ? (o = Vt._currentValue, n = n.parent !== o ? { parent: o, pool: o } : n) : n = nr(), f = {
      baseLanes: f.baseLanes | l,
      cachePool: n
    }), a.memoizedState = f, a.childLanes = Sc(
      t,
      u,
      l
    ), e.memoizedState = bc, vi(t.child, a)) : (la(e), l = t.child, t = l.sibling, l = Al(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function Tc(t, e) {
    return e = Cu(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Cu(t, e) {
    return t = Be(22, t, null, e), t.lanes = 0, t;
  }
  function zc(t, e, l) {
    return Va(e, t.child, null, l), t = Tc(
      e,
      e.pendingProps.children
    ), t.flags |= 2, e.memoizedState = null, t;
  }
  function ys(t, e, l) {
    t.lanes |= e;
    var a = t.alternate;
    a !== null && (a.lanes |= e), qf(t.return, e, l);
  }
  function Mc(t, e, l, a, n, i) {
    var u = t.memoizedState;
    u === null ? t.memoizedState = {
      isBackwards: e,
      rendering: null,
      renderingStartTime: 0,
      last: a,
      tail: l,
      tailMode: n,
      treeForkCount: i
    } : (u.isBackwards = e, u.rendering = null, u.renderingStartTime = 0, u.last = a, u.tail = l, u.tailMode = n, u.treeForkCount = i);
  }
  function vs(t, e, l) {
    var a = e.pendingProps, n = a.revealOrder, i = a.tail;
    a = a.children;
    var u = Yt.current, f = (u & 2) !== 0;
    if (f ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, N(Yt, u), fe(t, e, a, l), a = dt ? ii : 0, !f && t !== null && (t.flags & 128) !== 0)
      t: for (t = e.child; t !== null; ) {
        if (t.tag === 13)
          t.memoizedState !== null && ys(t, l, e);
        else if (t.tag === 19)
          ys(t, l, e);
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
          t = l.alternate, t !== null && vu(t) === null && (n = l), l = l.sibling;
        l = n, l === null ? (n = e.child, e.child = null) : (n = l.sibling, l.sibling = null), Mc(
          e,
          !1,
          n,
          l,
          i,
          a
        );
        break;
      case "backwards":
      case "unstable_legacy-backwards":
        for (l = null, n = e.child, e.child = null; n !== null; ) {
          if (t = n.alternate, t !== null && vu(t) === null) {
            e.child = n;
            break;
          }
          t = n.sibling, n.sibling = l, l = n, n = t;
        }
        Mc(
          e,
          !0,
          l,
          null,
          i,
          a
        );
        break;
      case "together":
        Mc(
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
  function Bl(t, e, l) {
    if (t !== null && (e.dependencies = t.dependencies), ua |= e.lanes, (l & e.childLanes) === 0)
      if (t !== null) {
        if (vn(
          t,
          e,
          l,
          !1
        ), (l & e.childLanes) === 0)
          return null;
      } else return null;
    if (t !== null && e.child !== t.child)
      throw Error(g(153));
    if (e.child !== null) {
      for (t = e.child, l = Al(t, t.pendingProps), e.child = l, l.return = e; t.sibling !== null; )
        t = t.sibling, l = l.sibling = Al(t, t.pendingProps), l.return = e;
      l.sibling = null;
    }
    return e.child;
  }
  function Ec(t, e) {
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && ru(t)));
  }
  function ah(t, e, l) {
    switch (e.tag) {
      case 3:
        $t(e, e.stateNode.containerInfo), Il(e, Vt, t.memoizedState.cache), qa();
        break;
      case 27:
      case 5:
        gl(e);
        break;
      case 4:
        $t(e, e.stateNode.containerInfo);
        break;
      case 10:
        Il(
          e,
          e.type,
          e.memoizedProps.value
        );
        break;
      case 31:
        if (e.memoizedState !== null)
          return e.flags |= 128, Wf(e), null;
        break;
      case 13:
        var a = e.memoizedState;
        if (a !== null)
          return a.dehydrated !== null ? (la(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? ps(t, e, l) : (la(e), t = Bl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        la(e);
        break;
      case 19:
        var n = (t.flags & 128) !== 0;
        if (a = (l & e.childLanes) !== 0, a || (vn(
          t,
          e,
          l,
          !1
        ), a = (l & e.childLanes) !== 0), n) {
          if (a)
            return vs(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), N(Yt, Yt.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, rs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        Il(e, Vt, t.memoizedState.cache);
    }
    return Bl(t, e, l);
  }
  function bs(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        Kt = !0;
      else {
        if (!Ec(t, l) && (e.flags & 128) === 0)
          return Kt = !1, ah(
            t,
            e,
            l
          );
        Kt = (t.flags & 131072) !== 0;
      }
    else
      Kt = !1, dt && (e.flags & 1048576) !== 0 && $o(e, ii, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = Xa(e.elementType), e.type = t, typeof t == "function")
            Cf(t) ? (a = Ka(t, a), e.tag = 1, e = hs(
              null,
              e,
              t,
              a,
              l
            )) : (e.tag = 0, e = vc(
              null,
              e,
              t,
              a,
              l
            ));
          else {
            if (t != null) {
              var n = t.$$typeof;
              if (n === kt) {
                e.tag = 11, e = fs(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === at) {
                e.tag = 14, e = cs(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              }
            }
            throw e = Ye(t) || t, Error(g(306, e, ""));
          }
        }
        return e;
      case 0:
        return vc(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 1:
        return a = e.type, n = Ka(
          a,
          e.pendingProps
        ), hs(
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
          ), t === null) throw Error(g(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, Zf(t, e), mi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, Il(e, Vt, a), a !== i.cache && Gf(
            e,
            [Vt],
            l,
            !0
          ), di(), a = u.element, i.isDehydrated)
            if (i = {
              element: a,
              isDehydrated: !1,
              cache: u.cache
            }, e.updateQueue.baseState = i, e.memoizedState = i, e.flags & 256) {
              e = gs(
                t,
                e,
                a,
                l
              );
              break t;
            } else if (a !== n) {
              n = Qe(
                Error(g(424)),
                e
              ), ui(n), e = gs(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Ct = ke(t.firstChild), ie = e, dt = !0, Wl = null, Ke = !0, l = rr(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (qa(), a === n) {
              e = Bl(
                t,
                e,
                l
              );
              break t;
            }
            fe(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Ou(t, e), t === null ? (l = Cd(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : dt || (l = e.type, t = e.pendingProps, a = Ku(
          tt.current
        ).createElement(l), a[Qt] = e, a[ae] = t, ce(a, l, t), Gt(a), e.stateNode = a) : e.memoizedState = Cd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return gl(e), t === null && dt && (a = e.stateNode = _d(
          e.type,
          e.pendingProps,
          tt.current
        ), ie = e, Ke = !0, n = Ct, sa(e.type) ? (no = n, Ct = ke(a.firstChild)) : Ct = n), fe(
          t,
          e,
          e.pendingProps.children,
          l
        ), Ou(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && dt && ((n = a = Ct) && (a = Nh(
          a,
          e.type,
          e.pendingProps,
          Ke
        ), a !== null ? (e.stateNode = a, ie = e, Ct = ke(a.firstChild), Ke = !1, n = !0) : n = !1), n || $l(e)), gl(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, Pc(n, i) ? a = null : u !== null && Pc(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = If(
          t,
          e,
          km,
          null,
          null,
          l
        ), Ni._currentValue = n), Ou(t, e), fe(t, e, a, l), e.child;
      case 6:
        return t === null && dt && ((t = l = Ct) && (l = Rh(
          l,
          e.pendingProps,
          Ke
        ), l !== null ? (e.stateNode = l, ie = e, Ct = null, t = !0) : t = !1), t || $l(e)), null;
      case 13:
        return ps(t, e, l);
      case 4:
        return $t(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = Va(
          e,
          null,
          a,
          l
        ) : fe(t, e, a, l), e.child;
      case 11:
        return fs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return fe(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return fe(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return fe(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, Il(e, e.type, a.value), fe(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, Ya(e), n = ue(n), a = a(n), e.flags |= 1, fe(t, e, a, l), e.child;
      case 14:
        return cs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 15:
        return os(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 19:
        return vs(t, e, l);
      case 31:
        return lh(t, e, l);
      case 22:
        return rs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return Ya(e), a = ue(Vt), t === null ? (n = Xf(), n === null && (n = Dt, i = Yf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Vf(e), Il(e, Vt, n)) : ((t.lanes & l) !== 0 && (Zf(t, e), mi(e, null, null, l), di()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), Il(e, Vt, a)) : (a = i.cache, Il(e, Vt, a), a !== n.cache && Gf(
          e,
          [Vt],
          l,
          !0
        ))), fe(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 29:
        throw e.pendingProps;
    }
    throw Error(g(156, e.tag));
  }
  function Nl(t) {
    t.flags |= 4;
  }
  function Ac(t, e, l, a, n) {
    if ((e = (t.mode & 32) !== 0) && (e = !1), e) {
      if (t.flags |= 16777216, (n & 335544128) === n)
        if (t.stateNode.complete) t.flags |= 8192;
        else if (Ks()) t.flags |= 8192;
        else
          throw Qa = hu, Qf;
    } else t.flags &= -16777217;
  }
  function xs(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !wd(e))
      if (Ks()) t.flags |= 8192;
      else
        throw Qa = hu, Qf;
  }
  function Uu(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? Vn() : 536870912, t.lanes |= e, Cn |= e);
  }
  function bi(t, e) {
    if (!dt)
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
  function Ut(t) {
    var e = t.alternate !== null && t.alternate.child === t.child, l = 0, a = 0;
    if (e)
      for (var n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags & 65011712, a |= n.flags & 65011712, n.return = t, n = n.sibling;
    else
      for (n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags, a |= n.flags, n.return = t, n = n.sibling;
    return t.subtreeFlags |= a, t.childLanes = l, e;
  }
  function nh(t, e, l) {
    var a = e.pendingProps;
    switch (Rf(e), e.tag) {
      case 16:
      case 15:
      case 0:
      case 11:
      case 7:
      case 8:
      case 12:
      case 9:
      case 14:
        return Ut(e), null;
      case 1:
        return Ut(e), null;
      case 3:
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), Ol(Vt), Tt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (yn(e) ? Nl(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, Hf())), Ut(e), null;
      case 26:
        var n = e.type, i = e.memoizedState;
        return t === null ? (Nl(e), i !== null ? (Ut(e), xs(e, i)) : (Ut(e), Ac(
          e,
          n,
          null,
          a,
          l
        ))) : i ? i !== t.memoizedState ? (Nl(e), Ut(e), xs(e, i)) : (Ut(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Nl(e), Ut(e), Ac(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if (Le(e), l = tt.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Nl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(g(166));
            return Ut(e), null;
          }
          t = H.current, yn(e) ? Po(e) : (t = _d(n, a, l), e.stateNode = t, Nl(e));
        }
        return Ut(e), null;
      case 5:
        if (Le(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Nl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(g(166));
            return Ut(e), null;
          }
          if (i = H.current, yn(e))
            Po(e);
          else {
            var u = Ku(
              tt.current
            );
            switch (i) {
              case 1:
                i = u.createElementNS(
                  "http://www.w3.org/2000/svg",
                  n
                );
                break;
              case 2:
                i = u.createElementNS(
                  "http://www.w3.org/1998/Math/MathML",
                  n
                );
                break;
              default:
                switch (n) {
                  case "svg":
                    i = u.createElementNS(
                      "http://www.w3.org/2000/svg",
                      n
                    );
                    break;
                  case "math":
                    i = u.createElementNS(
                      "http://www.w3.org/1998/Math/MathML",
                      n
                    );
                    break;
                  case "script":
                    i = u.createElement("div"), i.innerHTML = "<script><\/script>", i = i.removeChild(
                      i.firstChild
                    );
                    break;
                  case "select":
                    i = typeof a.is == "string" ? u.createElement("select", {
                      is: a.is
                    }) : u.createElement("select"), a.multiple ? i.multiple = !0 : a.size && (i.size = a.size);
                    break;
                  default:
                    i = typeof a.is == "string" ? u.createElement(n, { is: a.is }) : u.createElement(n);
                }
            }
            i[Qt] = e, i[ae] = a;
            t: for (u = e.child; u !== null; ) {
              if (u.tag === 5 || u.tag === 6)
                i.appendChild(u.stateNode);
              else if (u.tag !== 4 && u.tag !== 27 && u.child !== null) {
                u.child.return = u, u = u.child;
                continue;
              }
              if (u === e) break t;
              for (; u.sibling === null; ) {
                if (u.return === null || u.return === e)
                  break t;
                u = u.return;
              }
              u.sibling.return = u.return, u = u.sibling;
            }
            e.stateNode = i;
            t: switch (ce(i, n, a), n) {
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
        return Ut(e), Ac(
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
            throw Error(g(166));
          if (t = tt.current, yn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = ie, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[Qt] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || pd(t.nodeValue, l)), t || $l(e, !0);
          } else
            t = Ku(t).createTextNode(
              a
            ), t[Qt] = e, e.stateNode = t;
        }
        return Ut(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = yn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(g(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(g(557));
              t[Qt] = e;
            } else
              qa(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ut(e), t = !1;
          } else
            l = Hf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (Re(e), e) : (Re(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(g(558));
        }
        return Ut(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = yn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(g(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(g(317));
              n[Qt] = e;
            } else
              qa(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ut(e), n = !1;
          } else
            n = Hf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (Re(e), e) : (Re(e), null);
        }
        return Re(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Uu(e, e.updateQueue), Ut(e), null);
      case 4:
        return Tt(), t === null && kc(e.stateNode.containerInfo), Ut(e), null;
      case 10:
        return Ol(e.type), Ut(e), null;
      case 19:
        if (M(Yt), a = e.memoizedState, a === null) return Ut(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) bi(a, !1);
          else {
            if (qt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = vu(t), i !== null) {
                  for (e.flags |= 128, bi(a, !1), t = i.updateQueue, e.updateQueue = t, Uu(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    ko(l, t), l = l.sibling;
                  return N(
                    Yt,
                    Yt.current & 1 | 2
                  ), dt && _l(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && le() > Hu && (e.flags |= 128, n = !0, bi(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = vu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Uu(e, t), bi(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !dt)
                return Ut(e), null;
            } else
              2 * le() - a.renderingStartTime > Hu && l !== 536870912 && (e.flags |= 128, n = !0, bi(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = le(), t.sibling = null, l = Yt.current, N(
          Yt,
          n ? l & 1 | 2 : l & 1
        ), dt && _l(e, a.treeForkCount), t) : (Ut(e), null);
      case 22:
      case 23:
        return Re(e), Ff(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Ut(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Ut(e), l = e.updateQueue, l !== null && Uu(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && M(La), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), Ol(Vt), Ut(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(g(156, e.tag));
  }
  function ih(t, e) {
    switch (Rf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return Ol(Vt), Tt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return Le(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (Re(e), e.alternate === null)
            throw Error(g(340));
          qa();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (Re(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(g(340));
          qa();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return M(Yt), null;
      case 4:
        return Tt(), null;
      case 10:
        return Ol(e.type), null;
      case 22:
      case 23:
        return Re(e), Ff(), t !== null && M(La), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return Ol(Vt), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function Ss(t, e) {
    switch (Rf(e), e.tag) {
      case 3:
        Ol(Vt), Tt();
        break;
      case 26:
      case 27:
      case 5:
        Le(e);
        break;
      case 4:
        Tt();
        break;
      case 31:
        e.memoizedState !== null && Re(e);
        break;
      case 13:
        Re(e);
        break;
      case 19:
        M(Yt);
        break;
      case 10:
        Ol(e.type);
        break;
      case 22:
      case 23:
        Re(e), Ff(), t !== null && M(La);
        break;
      case 24:
        Ol(Vt);
    }
  }
  function xi(t, e) {
    try {
      var l = e.updateQueue, a = l !== null ? l.lastEffect : null;
      if (a !== null) {
        var n = a.next;
        l = n;
        do {
          if ((l.tag & t) === t) {
            a = void 0;
            var i = l.create, u = l.inst;
            a = i(), u.destroy = a;
          }
          l = l.next;
        } while (l !== n);
      }
    } catch (f) {
      Mt(e, e.return, f);
    }
  }
  function na(t, e, l) {
    try {
      var a = e.updateQueue, n = a !== null ? a.lastEffect : null;
      if (n !== null) {
        var i = n.next;
        a = i;
        do {
          if ((a.tag & t) === t) {
            var u = a.inst, f = u.destroy;
            if (f !== void 0) {
              u.destroy = void 0, n = e;
              var o = l, y = f;
              try {
                y();
              } catch (T) {
                Mt(
                  n,
                  o,
                  T
                );
              }
            }
          }
          a = a.next;
        } while (a !== i);
      }
    } catch (T) {
      Mt(e, e.return, T);
    }
  }
  function Ts(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        dr(e, l);
      } catch (a) {
        Mt(t, t.return, a);
      }
    }
  }
  function zs(t, e, l) {
    l.props = Ka(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      Mt(t, e, a);
    }
  }
  function Si(t, e) {
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
      Mt(t, e, n);
    }
  }
  function ml(t, e) {
    var l = t.ref, a = t.refCleanup;
    if (l !== null)
      if (typeof a == "function")
        try {
          a();
        } catch (n) {
          Mt(t, e, n);
        } finally {
          t.refCleanup = null, t = t.alternate, t != null && (t.refCleanup = null);
        }
      else if (typeof l == "function")
        try {
          l(null);
        } catch (n) {
          Mt(t, e, n);
        }
      else l.current = null;
  }
  function Ms(t) {
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
      Mt(t, t.return, n);
    }
  }
  function _c(t, e, l) {
    try {
      var a = t.stateNode;
      _h(a, t.type, l, e), a[ae] = e;
    } catch (n) {
      Mt(t, t.return, n);
    }
  }
  function Es(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && sa(t.type) || t.tag === 4;
  }
  function Dc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || Es(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && sa(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Oc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = We));
    else if (a !== 4 && (a === 27 && sa(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Oc(t, e, l), t = t.sibling; t !== null; )
        Oc(t, e, l), t = t.sibling;
  }
  function Bu(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && sa(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (Bu(t, e, l), t = t.sibling; t !== null; )
        Bu(t, e, l), t = t.sibling;
  }
  function As(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      ce(e, a, l), e[Qt] = t, e[ae] = l;
    } catch (i) {
      Mt(t, t.return, i);
    }
  }
  var Rl = !1, Jt = !1, Cc = !1, _s = typeof WeakSet == "function" ? WeakSet : Set, It = null;
  function uh(t, e) {
    if (t = t.containerInfo, $c = Pu, t = Go(t), zf(t)) {
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
            var n = a.anchorOffset, i = a.focusNode;
            a = a.focusOffset;
            try {
              l.nodeType, i.nodeType;
            } catch {
              l = null;
              break t;
            }
            var u = 0, f = -1, o = -1, y = 0, T = 0, A = t, b = null;
            e: for (; ; ) {
              for (var S; A !== l || n !== 0 && A.nodeType !== 3 || (f = u + n), A !== i || a !== 0 && A.nodeType !== 3 || (o = u + a), A.nodeType === 3 && (u += A.nodeValue.length), (S = A.firstChild) !== null; )
                b = A, A = S;
              for (; ; ) {
                if (A === t) break e;
                if (b === l && ++y === n && (f = u), b === i && ++T === a && (o = u), (S = A.nextSibling) !== null) break;
                A = b, b = A.parentNode;
              }
              A = S;
            }
            l = f === -1 || o === -1 ? null : { start: f, end: o };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (Ic = { focusedElem: t, selectionRange: l }, Pu = !1, It = e; It !== null; )
      if (e = It, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, It = t;
      else
        for (; It !== null; ) {
          switch (e = It, i = e.alternate, t = e.flags, e.tag) {
            case 0:
              if ((t & 4) !== 0 && (t = e.updateQueue, t = t !== null ? t.events : null, t !== null))
                for (l = 0; l < t.length; l++)
                  n = t[l], n.ref.impl = n.nextImpl;
              break;
            case 11:
            case 15:
              break;
            case 1:
              if ((t & 1024) !== 0 && i !== null) {
                t = void 0, l = e, n = i.memoizedProps, i = i.memoizedState, a = l.stateNode;
                try {
                  var j = Ka(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    j,
                    i
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch (J) {
                  Mt(
                    l,
                    l.return,
                    J
                  );
                }
              }
              break;
            case 3:
              if ((t & 1024) !== 0) {
                if (t = e.stateNode.containerInfo, l = t.nodeType, l === 9)
                  eo(t);
                else if (l === 1)
                  switch (t.nodeName) {
                    case "HEAD":
                    case "HTML":
                    case "BODY":
                      eo(t);
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
              if ((t & 1024) !== 0) throw Error(g(163));
          }
          if (t = e.sibling, t !== null) {
            t.return = e.return, It = t;
            break;
          }
          It = e.return;
        }
  }
  function Ds(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        Hl(t, l), a & 4 && xi(5, l);
        break;
      case 1:
        if (Hl(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              Mt(l, l.return, u);
            }
          else {
            var n = Ka(
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
            } catch (u) {
              Mt(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && Ts(l), a & 512 && Si(l, l.return);
        break;
      case 3:
        if (Hl(t, l), a & 64 && (t = l.updateQueue, t !== null)) {
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
            dr(t, e);
          } catch (u) {
            Mt(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && As(l);
      case 26:
      case 5:
        Hl(t, l), e === null && a & 4 && Ms(l), a & 512 && Si(l, l.return);
        break;
      case 12:
        Hl(t, l);
        break;
      case 31:
        Hl(t, l), a & 4 && Us(t, l);
        break;
      case 13:
        Hl(t, l), a & 4 && Bs(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = gh.bind(
          null,
          l
        ), wh(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Rl, !a) {
          e = e !== null && e.memoizedState !== null || Jt, n = Rl;
          var i = Jt;
          Rl = a, (Jt = e) && !i ? jl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : Hl(t, l), Rl = n, Jt = i;
        }
        break;
      case 30:
        break;
      default:
        Hl(t, l);
    }
  }
  function Os(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Os(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && za(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Nt = null, ze = !1;
  function wl(t, e, l) {
    for (l = l.child; l !== null; )
      Cs(t, e, l), l = l.sibling;
  }
  function Cs(t, e, l) {
    if (he && typeof he.onCommitFiberUnmount == "function")
      try {
        he.onCommitFiberUnmount(ba, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        Jt || ml(l, e), wl(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        Jt || ml(l, e);
        var a = Nt, n = ze;
        sa(l.type) && (Nt = l.stateNode, ze = !1), wl(
          t,
          e,
          l
        ), Ci(l.stateNode), Nt = a, ze = n;
        break;
      case 5:
        Jt || ml(l, e);
      case 6:
        if (a = Nt, n = ze, Nt = null, wl(
          t,
          e,
          l
        ), Nt = a, ze = n, Nt !== null)
          if (ze)
            try {
              (Nt.nodeType === 9 ? Nt.body : Nt.nodeName === "HTML" ? Nt.ownerDocument.body : Nt).removeChild(l.stateNode);
            } catch (i) {
              Mt(
                l,
                e,
                i
              );
            }
          else
            try {
              Nt.removeChild(l.stateNode);
            } catch (i) {
              Mt(
                l,
                e,
                i
              );
            }
        break;
      case 18:
        Nt !== null && (ze ? (t = Nt, Td(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), qn(t)) : Td(Nt, l.stateNode));
        break;
      case 4:
        a = Nt, n = ze, Nt = l.stateNode.containerInfo, ze = !0, wl(
          t,
          e,
          l
        ), Nt = a, ze = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        na(2, l, e), Jt || na(4, l, e), wl(
          t,
          e,
          l
        );
        break;
      case 1:
        Jt || (ml(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && zs(
          l,
          e,
          a
        )), wl(
          t,
          e,
          l
        );
        break;
      case 21:
        wl(
          t,
          e,
          l
        );
        break;
      case 22:
        Jt = (a = Jt) || l.memoizedState !== null, wl(
          t,
          e,
          l
        ), Jt = a;
        break;
      default:
        wl(
          t,
          e,
          l
        );
    }
  }
  function Us(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null))) {
      t = t.dehydrated;
      try {
        qn(t);
      } catch (l) {
        Mt(e, e.return, l);
      }
    }
  }
  function Bs(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        qn(t);
      } catch (l) {
        Mt(e, e.return, l);
      }
  }
  function fh(t) {
    switch (t.tag) {
      case 31:
      case 13:
      case 19:
        var e = t.stateNode;
        return e === null && (e = t.stateNode = new _s()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new _s()), e;
      default:
        throw Error(g(435, t.tag));
    }
  }
  function Nu(t, e) {
    var l = fh(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = ph.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function Me(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], i = t, u = e, f = u;
        t: for (; f !== null; ) {
          switch (f.tag) {
            case 27:
              if (sa(f.type)) {
                Nt = f.stateNode, ze = !1;
                break t;
              }
              break;
            case 5:
              Nt = f.stateNode, ze = !1;
              break t;
            case 3:
            case 4:
              Nt = f.stateNode.containerInfo, ze = !0;
              break t;
          }
          f = f.return;
        }
        if (Nt === null) throw Error(g(160));
        Cs(i, u, n), Nt = null, ze = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Ns(e, t), e = e.sibling;
  }
  var tl = null;
  function Ns(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Me(e, t), Ee(t), a & 4 && (na(3, t, t.return), xi(3, t), na(5, t, t.return));
        break;
      case 1:
        Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), a & 64 && Rl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = tl;
        if (Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[Ql] || i[Qt] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), ce(i, a, l), i[Qt] = t, Gt(i), a = i;
                      break t;
                    case "link":
                      var u = Nd(
                        "link",
                        "href",
                        n
                      ).get(a + (l.href || ""));
                      if (u) {
                        for (var f = 0; f < u.length; f++)
                          if (i = u[f], i.getAttribute("href") === (l.href == null || l.href === "" ? null : l.href) && i.getAttribute("rel") === (l.rel == null ? null : l.rel) && i.getAttribute("title") === (l.title == null ? null : l.title) && i.getAttribute("crossorigin") === (l.crossOrigin == null ? null : l.crossOrigin)) {
                            u.splice(f, 1);
                            break e;
                          }
                      }
                      i = n.createElement(a), ce(i, a, l), n.head.appendChild(i);
                      break;
                    case "meta":
                      if (u = Nd(
                        "meta",
                        "content",
                        n
                      ).get(a + (l.content || ""))) {
                        for (f = 0; f < u.length; f++)
                          if (i = u[f], i.getAttribute("content") === (l.content == null ? null : "" + l.content) && i.getAttribute("name") === (l.name == null ? null : l.name) && i.getAttribute("property") === (l.property == null ? null : l.property) && i.getAttribute("http-equiv") === (l.httpEquiv == null ? null : l.httpEquiv) && i.getAttribute("charset") === (l.charSet == null ? null : l.charSet)) {
                            u.splice(f, 1);
                            break e;
                          }
                      }
                      i = n.createElement(a), ce(i, a, l), n.head.appendChild(i);
                      break;
                    default:
                      throw Error(g(468, a));
                  }
                  i[Qt] = t, Gt(i), a = i;
                }
                t.stateNode = a;
              } else
                Rd(
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
            i !== a ? (i === null ? l.stateNode !== null && (l = l.stateNode, l.parentNode.removeChild(l)) : i.count--, a === null ? Rd(
              n,
              t.type,
              t.stateNode
            ) : Bd(
              n,
              a,
              t.memoizedProps
            )) : a === null && t.stateNode !== null && _c(
              t,
              t.memoizedProps,
              l.memoizedProps
            );
        }
        break;
      case 27:
        Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), l !== null && a & 4 && _c(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            w(n, "");
          } catch (j) {
            Mt(t, t.return, j);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, _c(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Cc = !0);
        break;
      case 6:
        if (Me(e, t), Ee(t), a & 4) {
          if (t.stateNode === null)
            throw Error(g(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (j) {
            Mt(t, t.return, j);
          }
        }
        break;
      case 3:
        if (Fu = null, n = tl, tl = Ju(e.containerInfo), Me(e, t), tl = n, Ee(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            qn(e.containerInfo);
          } catch (j) {
            Mt(t, t.return, j);
          }
        Cc && (Cc = !1, Rs(t));
        break;
      case 4:
        a = tl, tl = Ju(
          t.stateNode.containerInfo
        ), Me(e, t), Ee(t), tl = a;
        break;
      case 12:
        Me(e, t), Ee(t);
        break;
      case 31:
        Me(e, t), Ee(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 13:
        Me(e, t), Ee(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (wu = le()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var o = l !== null && l.memoizedState !== null, y = Rl, T = Jt;
        if (Rl = y || n, Jt = T || o, Me(e, t), Jt = T, Rl = y, Ee(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || o || Rl || Jt || Ja(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                o = l = e;
                try {
                  if (i = o.stateNode, n)
                    u = i.style, typeof u.setProperty == "function" ? u.setProperty("display", "none", "important") : u.display = "none";
                  else {
                    f = o.stateNode;
                    var A = o.memoizedProps.style, b = A != null && A.hasOwnProperty("display") ? A.display : null;
                    f.style.display = b == null || typeof b == "boolean" ? "" : ("" + b).trim();
                  }
                } catch (j) {
                  Mt(o, o.return, j);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                o = e;
                try {
                  o.stateNode.nodeValue = n ? "" : o.memoizedProps;
                } catch (j) {
                  Mt(o, o.return, j);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                o = e;
                try {
                  var S = o.stateNode;
                  n ? zd(S, !0) : zd(o.stateNode, !1);
                } catch (j) {
                  Mt(o, o.return, j);
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
        a & 4 && (a = t.updateQueue, a !== null && (l = a.retryQueue, l !== null && (a.retryQueue = null, Nu(t, l))));
        break;
      case 19:
        Me(e, t), Ee(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
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
          if (Es(a)) {
            l = a;
            break;
          }
          a = a.return;
        }
        if (l == null) throw Error(g(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, i = Dc(t);
            Bu(t, i, n);
            break;
          case 5:
            var u = l.stateNode;
            l.flags & 32 && (w(u, ""), l.flags &= -33);
            var f = Dc(t);
            Bu(t, f, u);
            break;
          case 3:
          case 4:
            var o = l.stateNode.containerInfo, y = Dc(t);
            Oc(
              t,
              y,
              o
            );
            break;
          default:
            throw Error(g(161));
        }
      } catch (T) {
        Mt(t, t.return, T);
      }
      t.flags &= -3;
    }
    e & 4096 && (t.flags &= -4097);
  }
  function Rs(t) {
    if (t.subtreeFlags & 1024)
      for (t = t.child; t !== null; ) {
        var e = t;
        Rs(e), e.tag === 5 && e.flags & 1024 && e.stateNode.reset(), t = t.sibling;
      }
  }
  function Hl(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        Ds(t, e.alternate, e), e = e.sibling;
  }
  function Ja(t) {
    for (t = t.child; t !== null; ) {
      var e = t;
      switch (e.tag) {
        case 0:
        case 11:
        case 14:
        case 15:
          na(4, e, e.return), Ja(e);
          break;
        case 1:
          ml(e, e.return);
          var l = e.stateNode;
          typeof l.componentWillUnmount == "function" && zs(
            e,
            e.return,
            l
          ), Ja(e);
          break;
        case 27:
          Ci(e.stateNode);
        case 26:
        case 5:
          ml(e, e.return), Ja(e);
          break;
        case 22:
          e.memoizedState === null && Ja(e);
          break;
        case 30:
          Ja(e);
          break;
        default:
          Ja(e);
      }
      t = t.sibling;
    }
  }
  function jl(t, e, l) {
    for (l = l && (e.subtreeFlags & 8772) !== 0, e = e.child; e !== null; ) {
      var a = e.alternate, n = t, i = e, u = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          jl(
            n,
            i,
            l
          ), xi(4, i);
          break;
        case 1:
          if (jl(
            n,
            i,
            l
          ), a = i, n = a.stateNode, typeof n.componentDidMount == "function")
            try {
              n.componentDidMount();
            } catch (y) {
              Mt(a, a.return, y);
            }
          if (a = i, n = a.updateQueue, n !== null) {
            var f = a.stateNode;
            try {
              var o = n.shared.hiddenCallbacks;
              if (o !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < o.length; n++)
                  sr(o[n], f);
            } catch (y) {
              Mt(a, a.return, y);
            }
          }
          l && u & 64 && Ts(i), Si(i, i.return);
          break;
        case 27:
          As(i);
        case 26:
        case 5:
          jl(
            n,
            i,
            l
          ), l && a === null && u & 4 && Ms(i), Si(i, i.return);
          break;
        case 12:
          jl(
            n,
            i,
            l
          );
          break;
        case 31:
          jl(
            n,
            i,
            l
          ), l && u & 4 && Us(n, i);
          break;
        case 13:
          jl(
            n,
            i,
            l
          ), l && u & 4 && Bs(n, i);
          break;
        case 22:
          i.memoizedState === null && jl(
            n,
            i,
            l
          ), Si(i, i.return);
          break;
        case 30:
          break;
        default:
          jl(
            n,
            i,
            l
          );
      }
      e = e.sibling;
    }
  }
  function Uc(t, e) {
    var l = null;
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && fi(l));
  }
  function Bc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && fi(t));
  }
  function el(t, e, l, a) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; )
        ws(
          t,
          e,
          l,
          a
        ), e = e.sibling;
  }
  function ws(t, e, l, a) {
    var n = e.flags;
    switch (e.tag) {
      case 0:
      case 11:
      case 15:
        el(
          t,
          e,
          l,
          a
        ), n & 2048 && xi(9, e);
        break;
      case 1:
        el(
          t,
          e,
          l,
          a
        );
        break;
      case 3:
        el(
          t,
          e,
          l,
          a
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && fi(t)));
        break;
      case 12:
        if (n & 2048) {
          el(
            t,
            e,
            l,
            a
          ), t = e.stateNode;
          try {
            var i = e.memoizedProps, u = i.id, f = i.onPostCommit;
            typeof f == "function" && f(
              u,
              e.alternate === null ? "mount" : "update",
              t.passiveEffectDuration,
              -0
            );
          } catch (o) {
            Mt(e, e.return, o);
          }
        } else
          el(
            t,
            e,
            l,
            a
          );
        break;
      case 31:
        el(
          t,
          e,
          l,
          a
        );
        break;
      case 13:
        el(
          t,
          e,
          l,
          a
        );
        break;
      case 23:
        break;
      case 22:
        i = e.stateNode, u = e.alternate, e.memoizedState !== null ? i._visibility & 2 ? el(
          t,
          e,
          l,
          a
        ) : Ti(t, e) : i._visibility & 2 ? el(
          t,
          e,
          l,
          a
        ) : (i._visibility |= 2, _n(
          t,
          e,
          l,
          a,
          (e.subtreeFlags & 10256) !== 0 || !1
        )), n & 2048 && Uc(u, e);
        break;
      case 24:
        el(
          t,
          e,
          l,
          a
        ), n & 2048 && Bc(e.alternate, e);
        break;
      default:
        el(
          t,
          e,
          l,
          a
        );
    }
  }
  function _n(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var i = t, u = e, f = l, o = a, y = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          _n(
            i,
            u,
            f,
            o,
            n
          ), xi(8, u);
          break;
        case 23:
          break;
        case 22:
          var T = u.stateNode;
          u.memoizedState !== null ? T._visibility & 2 ? _n(
            i,
            u,
            f,
            o,
            n
          ) : Ti(
            i,
            u
          ) : (T._visibility |= 2, _n(
            i,
            u,
            f,
            o,
            n
          )), n && y & 2048 && Uc(
            u.alternate,
            u
          );
          break;
        case 24:
          _n(
            i,
            u,
            f,
            o,
            n
          ), n && y & 2048 && Bc(u.alternate, u);
          break;
        default:
          _n(
            i,
            u,
            f,
            o,
            n
          );
      }
      e = e.sibling;
    }
  }
  function Ti(t, e) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; ) {
        var l = t, a = e, n = a.flags;
        switch (a.tag) {
          case 22:
            Ti(l, a), n & 2048 && Uc(
              a.alternate,
              a
            );
            break;
          case 24:
            Ti(l, a), n & 2048 && Bc(a.alternate, a);
            break;
          default:
            Ti(l, a);
        }
        e = e.sibling;
      }
  }
  var zi = 8192;
  function Dn(t, e, l) {
    if (t.subtreeFlags & zi)
      for (t = t.child; t !== null; )
        Hs(
          t,
          e,
          l
        ), t = t.sibling;
  }
  function Hs(t, e, l) {
    switch (t.tag) {
      case 26:
        Dn(
          t,
          e,
          l
        ), t.flags & zi && t.memoizedState !== null && Jh(
          l,
          tl,
          t.memoizedState,
          t.memoizedProps
        );
        break;
      case 5:
        Dn(
          t,
          e,
          l
        );
        break;
      case 3:
      case 4:
        var a = tl;
        tl = Ju(t.stateNode.containerInfo), Dn(
          t,
          e,
          l
        ), tl = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = zi, zi = 16777216, Dn(
          t,
          e,
          l
        ), zi = a) : Dn(
          t,
          e,
          l
        ));
        break;
      default:
        Dn(
          t,
          e,
          l
        );
    }
  }
  function js(t) {
    var e = t.alternate;
    if (e !== null && (t = e.child, t !== null)) {
      e.child = null;
      do
        e = t.sibling, t.sibling = null, t = e;
      while (t !== null);
    }
  }
  function Mi(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          It = a, Gs(
            a,
            t
          );
        }
      js(t);
    }
    if (t.subtreeFlags & 10256)
      for (t = t.child; t !== null; )
        qs(t), t = t.sibling;
  }
  function qs(t) {
    switch (t.tag) {
      case 0:
      case 11:
      case 15:
        Mi(t), t.flags & 2048 && na(9, t, t.return);
        break;
      case 3:
        Mi(t);
        break;
      case 12:
        Mi(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, Ru(t)) : Mi(t);
        break;
      default:
        Mi(t);
    }
  }
  function Ru(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          It = a, Gs(
            a,
            t
          );
        }
      js(t);
    }
    for (t = t.child; t !== null; ) {
      switch (e = t, e.tag) {
        case 0:
        case 11:
        case 15:
          na(8, e, e.return), Ru(e);
          break;
        case 22:
          l = e.stateNode, l._visibility & 2 && (l._visibility &= -3, Ru(e));
          break;
        default:
          Ru(e);
      }
      t = t.sibling;
    }
  }
  function Gs(t, e) {
    for (; It !== null; ) {
      var l = It;
      switch (l.tag) {
        case 0:
        case 11:
        case 15:
          na(8, l, e);
          break;
        case 23:
        case 22:
          if (l.memoizedState !== null && l.memoizedState.cachePool !== null) {
            var a = l.memoizedState.cachePool.pool;
            a != null && a.refCount++;
          }
          break;
        case 24:
          fi(l.memoizedState.cache);
      }
      if (a = l.child, a !== null) a.return = l, It = a;
      else
        t: for (l = t; It !== null; ) {
          a = It;
          var n = a.sibling, i = a.return;
          if (Os(a), a === l) {
            It = null;
            break t;
          }
          if (n !== null) {
            n.return = i, It = n;
            break t;
          }
          It = i;
        }
    }
  }
  var ch = {
    getCacheForType: function(t) {
      var e = ue(Vt), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return ue(Vt).controller.signal;
    }
  }, oh = typeof WeakMap == "function" ? WeakMap : Map, bt = 0, Dt = null, ft = null, ot = 0, zt = 0, we = null, ia = !1, On = !1, Nc = !1, ql = 0, qt = 0, ua = 0, ka = 0, Rc = 0, He = 0, Cn = 0, Ei = null, Ae = null, wc = !1, wu = 0, Ys = 0, Hu = 1 / 0, ju = null, fa = null, Wt = 0, ca = null, Un = null, Gl = 0, Hc = 0, jc = null, Ls = null, Ai = 0, qc = null;
  function je() {
    return (bt & 2) !== 0 && ot !== 0 ? ot & -ot : m.T !== null ? Vc() : ki();
  }
  function Xs() {
    if (He === 0)
      if ((ot & 536870912) === 0 || dt) {
        var t = Ia;
        Ia <<= 1, (Ia & 3932160) === 0 && (Ia = 262144), He = t;
      } else He = 536870912;
    return t = Ne.current, t !== null && (t.flags |= 32), He;
  }
  function _e(t, e, l) {
    (t === Dt && (zt === 2 || zt === 9) || t.cancelPendingCommit !== null) && (Bn(t, 0), oa(
      t,
      ot,
      He,
      !1
    )), ul(t, l), ((bt & 2) === 0 || t !== Dt) && (t === Dt && ((bt & 2) === 0 && (ka |= l), qt === 4 && oa(
      t,
      ot,
      He,
      !1
    )), hl(t));
  }
  function Qs(t, e, l) {
    if ((bt & 6) !== 0) throw Error(g(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Sa(t, e), n = a ? dh(t, e) : Yc(t, e, !0), i = a;
    do {
      if (n === 0) {
        On && !a && oa(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, i && !rh(l)) {
          n = Yc(t, e, !1), i = !1;
          continue;
        }
        if (n === 2) {
          if (i = e, t.errorRecoveryDisabledLanes & i)
            var u = 0;
          else
            u = t.pendingLanes & -536870913, u = u !== 0 ? u : u & 536870912 ? 536870912 : 0;
          if (u !== 0) {
            e = u;
            t: {
              var f = t;
              n = Ei;
              var o = f.current.memoizedState.isDehydrated;
              if (o && (Bn(f, u).flags |= 256), u = Yc(
                f,
                u,
                !1
              ), u !== 2) {
                if (Nc && !o) {
                  f.errorRecoveryDisabledLanes |= i, ka |= i, n = 4;
                  break t;
                }
                i = Ae, Ae = n, i !== null && (Ae === null ? Ae = i : Ae.push.apply(
                  Ae,
                  i
                ));
              }
              n = u;
            }
            if (i = !1, n !== 2) continue;
          }
        }
        if (n === 1) {
          Bn(t, 0), oa(t, e, 0, !0);
          break;
        }
        t: {
          switch (a = t, i = n, i) {
            case 0:
            case 1:
              throw Error(g(345));
            case 4:
              if ((e & 4194048) !== e) break;
            case 6:
              oa(
                a,
                e,
                He,
                !ia
              );
              break t;
            case 2:
              Ae = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(g(329));
          }
          if ((e & 62914560) === e && (n = wu + 300 - le(), 10 < n)) {
            if (oa(
              a,
              e,
              He,
              !ia
            ), xa(a, 0, !0) !== 0) break t;
            Gl = e, a.timeoutHandle = xd(
              Vs.bind(
                null,
                a,
                l,
                Ae,
                ju,
                wc,
                e,
                He,
                ka,
                Cn,
                ia,
                i,
                "Throttled",
                -0,
                0
              ),
              n
            );
            break t;
          }
          Vs(
            a,
            l,
            Ae,
            ju,
            wc,
            e,
            He,
            ka,
            Cn,
            ia,
            i,
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
  function Vs(t, e, l, a, n, i, u, f, o, y, T, A, b, S) {
    if (t.timeoutHandle = -1, A = e.subtreeFlags, A & 8192 || (A & 16785408) === 16785408) {
      A = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: We
      }, Hs(
        e,
        i,
        A
      );
      var j = (i & 62914560) === i ? wu - le() : (i & 4194048) === i ? Ys - le() : 0;
      if (j = kh(
        A,
        j
      ), j !== null) {
        Gl = i, t.cancelPendingCommit = j(
          Is.bind(
            null,
            t,
            e,
            i,
            l,
            a,
            n,
            u,
            f,
            o,
            T,
            A,
            null,
            b,
            S
          )
        ), oa(t, i, u, !y);
        return;
      }
    }
    Is(
      t,
      e,
      i,
      l,
      a,
      n,
      u,
      f,
      o
    );
  }
  function rh(t) {
    for (var e = t; ; ) {
      var l = e.tag;
      if ((l === 0 || l === 11 || l === 15) && e.flags & 16384 && (l = e.updateQueue, l !== null && (l = l.stores, l !== null)))
        for (var a = 0; a < l.length; a++) {
          var n = l[a], i = n.getSnapshot;
          n = n.value;
          try {
            if (!Ue(i(), n)) return !1;
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
  function oa(t, e, l, a) {
    e &= ~Rc, e &= ~ka, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var i = 31 - Ft(n), u = 1 << i;
      a[i] = -1, n &= ~u;
    }
    l !== 0 && Ji(t, l, e);
  }
  function qu() {
    return (bt & 6) === 0 ? (_i(0), !1) : !0;
  }
  function Gc() {
    if (ft !== null) {
      if (zt === 0)
        var t = ft.return;
      else
        t = ft, Dl = Ga = null, ec(t), Tn = null, oi = 0, t = ft;
      for (; t !== null; )
        Ss(t.alternate, t), t = t.return;
      ft = null;
    }
  }
  function Bn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Ch(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), Gl = 0, Gc(), Dt = t, ft = l = Al(t.current, null), ot = e, zt = 0, we = null, ia = !1, On = Sa(t, e), Nc = !1, Cn = He = Rc = ka = ua = qt = 0, Ae = Ei = null, wc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - Ft(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return ql = e, iu(), l;
  }
  function Zs(t, e) {
    et = null, m.H = yi, e === Sn || e === mu ? (e = fr(), zt = 3) : e === Qf ? (e = fr(), zt = 4) : zt = e === yc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, we = e, ft === null && (qt = 1, _u(
      t,
      Qe(e, t.current)
    ));
  }
  function Ks() {
    var t = Ne.current;
    return t === null ? !0 : (ot & 4194048) === ot ? Je === null : (ot & 62914560) === ot || (ot & 536870912) !== 0 ? t === Je : !1;
  }
  function Js() {
    var t = m.H;
    return m.H = yi, t === null ? yi : t;
  }
  function ks() {
    var t = m.A;
    return m.A = ch, t;
  }
  function Gu() {
    qt = 4, ia || (ot & 4194048) !== ot && Ne.current !== null || (On = !0), (ua & 134217727) === 0 && (ka & 134217727) === 0 || Dt === null || oa(
      Dt,
      ot,
      He,
      !1
    );
  }
  function Yc(t, e, l) {
    var a = bt;
    bt |= 2;
    var n = Js(), i = ks();
    (Dt !== t || ot !== e) && (ju = null, Bn(t, e)), e = !1;
    var u = qt;
    t: do
      try {
        if (zt !== 0 && ft !== null) {
          var f = ft, o = we;
          switch (zt) {
            case 8:
              Gc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              Ne.current === null && (e = !0);
              var y = zt;
              if (zt = 0, we = null, Nn(t, f, o, y), l && On) {
                u = 0;
                break t;
              }
              break;
            default:
              y = zt, zt = 0, we = null, Nn(t, f, o, y);
          }
        }
        sh(), u = qt;
        break;
      } catch (T) {
        Zs(t, T);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Dl = Ga = null, bt = a, m.H = n, m.A = i, ft === null && (Dt = null, ot = 0, iu()), u;
  }
  function sh() {
    for (; ft !== null; ) Fs(ft);
  }
  function dh(t, e) {
    var l = bt;
    bt |= 2;
    var a = Js(), n = ks();
    Dt !== t || ot !== e ? (ju = null, Hu = le() + 500, Bn(t, e)) : On = Sa(
      t,
      e
    );
    t: do
      try {
        if (zt !== 0 && ft !== null) {
          e = ft;
          var i = we;
          e: switch (zt) {
            case 1:
              zt = 0, we = null, Nn(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (ir(i)) {
                zt = 0, we = null, Ws(e);
                break;
              }
              e = function() {
                zt !== 2 && zt !== 9 || Dt !== t || (zt = 7), hl(t);
              }, i.then(e, e);
              break t;
            case 3:
              zt = 7;
              break t;
            case 4:
              zt = 5;
              break t;
            case 7:
              ir(i) ? (zt = 0, we = null, Ws(e)) : (zt = 0, we = null, Nn(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (ft.tag) {
                case 26:
                  u = ft.memoizedState;
                case 5:
                case 27:
                  var f = ft;
                  if (u ? wd(u) : f.stateNode.complete) {
                    zt = 0, we = null;
                    var o = f.sibling;
                    if (o !== null) ft = o;
                    else {
                      var y = f.return;
                      y !== null ? (ft = y, Yu(y)) : ft = null;
                    }
                    break e;
                  }
              }
              zt = 0, we = null, Nn(t, e, i, 5);
              break;
            case 6:
              zt = 0, we = null, Nn(t, e, i, 6);
              break;
            case 8:
              Gc(), qt = 6;
              break t;
            default:
              throw Error(g(462));
          }
        }
        mh();
        break;
      } catch (T) {
        Zs(t, T);
      }
    while (!0);
    return Dl = Ga = null, m.H = a, m.A = n, bt = l, ft !== null ? 0 : (Dt = null, ot = 0, iu(), qt);
  }
  function mh() {
    for (; ft !== null && !Qn(); )
      Fs(ft);
  }
  function Fs(t) {
    var e = bs(t.alternate, t, ql);
    t.memoizedProps = t.pendingProps, e === null ? Yu(t) : ft = e;
  }
  function Ws(t) {
    var e = t, l = e.alternate;
    switch (e.tag) {
      case 15:
      case 0:
        e = ms(
          l,
          e,
          e.pendingProps,
          e.type,
          void 0,
          ot
        );
        break;
      case 11:
        e = ms(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          ot
        );
        break;
      case 5:
        ec(e);
      default:
        Ss(l, e), e = ft = ko(e, ql), e = bs(l, e, ql);
    }
    t.memoizedProps = t.pendingProps, e === null ? Yu(t) : ft = e;
  }
  function Nn(t, e, l, a) {
    Dl = Ga = null, ec(e), Tn = null, oi = 0;
    var n = e.return;
    try {
      if (eh(
        t,
        n,
        e,
        l,
        ot
      )) {
        qt = 1, _u(
          t,
          Qe(l, t.current)
        ), ft = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw ft = n, i;
      qt = 1, _u(
        t,
        Qe(l, t.current)
      ), ft = null;
      return;
    }
    e.flags & 32768 ? (dt || a === 1 ? t = !0 : On || (ot & 536870912) !== 0 ? t = !1 : (ia = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = Ne.current, a !== null && a.tag === 13 && (a.flags |= 16384))), $s(e, t)) : Yu(e);
  }
  function Yu(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        $s(
          e,
          ia
        );
        return;
      }
      t = e.return;
      var l = nh(
        e.alternate,
        e,
        ql
      );
      if (l !== null) {
        ft = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        ft = e;
        return;
      }
      ft = e = t;
    } while (e !== null);
    qt === 0 && (qt = 5);
  }
  function $s(t, e) {
    do {
      var l = ih(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, ft = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        ft = t;
        return;
      }
      ft = t = l;
    } while (t !== null);
    qt = 6, ft = null;
  }
  function Is(t, e, l, a, n, i, u, f, o) {
    t.cancelPendingCommit = null;
    do
      Lu();
    while (Wt !== 0);
    if ((bt & 6) !== 0) throw Error(g(327));
    if (e !== null) {
      if (e === t.current) throw Error(g(177));
      if (i = e.lanes | e.childLanes, i |= Df, Ki(
        t,
        l,
        i,
        u,
        f,
        o
      ), t === Dt && (ft = Dt = null, ot = 0), Un = e, ca = t, Gl = l, Hc = i, jc = n, Ls = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, yh(va, function() {
        return ad(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = m.T, m.T = null, n = O.p, O.p = 2, u = bt, bt |= 4;
        try {
          uh(t, e, l);
        } finally {
          bt = u, O.p = n, m.T = a;
        }
      }
      Wt = 1, Ps(), td(), ed();
    }
  }
  function Ps() {
    if (Wt === 1) {
      Wt = 0;
      var t = ca, e = Un, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = m.T, m.T = null;
        var a = O.p;
        O.p = 2;
        var n = bt;
        bt |= 4;
        try {
          Ns(e, t);
          var i = Ic, u = Go(t.containerInfo), f = i.focusedElem, o = i.selectionRange;
          if (u !== f && f && f.ownerDocument && qo(
            f.ownerDocument.documentElement,
            f
          )) {
            if (o !== null && zf(f)) {
              var y = o.start, T = o.end;
              if (T === void 0 && (T = y), "selectionStart" in f)
                f.selectionStart = y, f.selectionEnd = Math.min(
                  T,
                  f.value.length
                );
              else {
                var A = f.ownerDocument || document, b = A && A.defaultView || window;
                if (b.getSelection) {
                  var S = b.getSelection(), j = f.textContent.length, J = Math.min(o.start, j), _t = o.end === void 0 ? J : Math.min(o.end, j);
                  !S.extend && J > _t && (u = _t, _t = J, J = u);
                  var h = jo(
                    f,
                    J
                  ), d = jo(
                    f,
                    _t
                  );
                  if (h && d && (S.rangeCount !== 1 || S.anchorNode !== h.node || S.anchorOffset !== h.offset || S.focusNode !== d.node || S.focusOffset !== d.offset)) {
                    var p = A.createRange();
                    p.setStart(h.node, h.offset), S.removeAllRanges(), J > _t ? (S.addRange(p), S.extend(d.node, d.offset)) : (p.setEnd(d.node, d.offset), S.addRange(p));
                  }
                }
              }
            }
            for (A = [], S = f; S = S.parentNode; )
              S.nodeType === 1 && A.push({
                element: S,
                left: S.scrollLeft,
                top: S.scrollTop
              });
            for (typeof f.focus == "function" && f.focus(), f = 0; f < A.length; f++) {
              var z = A[f];
              z.element.scrollLeft = z.left, z.element.scrollTop = z.top;
            }
          }
          Pu = !!$c, Ic = $c = null;
        } finally {
          bt = n, O.p = a, m.T = l;
        }
      }
      t.current = e, Wt = 2;
    }
  }
  function td() {
    if (Wt === 2) {
      Wt = 0;
      var t = ca, e = Un, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = m.T, m.T = null;
        var a = O.p;
        O.p = 2;
        var n = bt;
        bt |= 4;
        try {
          Ds(t, e.alternate, e);
        } finally {
          bt = n, O.p = a, m.T = l;
        }
      }
      Wt = 3;
    }
  }
  function ed() {
    if (Wt === 4 || Wt === 3) {
      Wt = 0, Yi();
      var t = ca, e = Un, l = Gl, a = Ls;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? Wt = 5 : (Wt = 0, Un = ca = null, ld(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (fa = null), Kn(l), e = e.stateNode, he && typeof he.onCommitFiberRoot == "function")
        try {
          he.onCommitFiberRoot(
            ba,
            e,
            void 0,
            (e.current.flags & 128) === 128
          );
        } catch {
        }
      if (a !== null) {
        e = m.T, n = O.p, O.p = 2, m.T = null;
        try {
          for (var i = t.onRecoverableError, u = 0; u < a.length; u++) {
            var f = a[u];
            i(f.value, {
              componentStack: f.stack
            });
          }
        } finally {
          m.T = e, O.p = n;
        }
      }
      (Gl & 3) !== 0 && Lu(), hl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === qc ? Ai++ : (Ai = 0, qc = t) : Ai = 0, _i(0);
    }
  }
  function ld(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, fi(e)));
  }
  function Lu() {
    return Ps(), td(), ed(), ad();
  }
  function ad() {
    if (Wt !== 5) return !1;
    var t = ca, e = Hc;
    Hc = 0;
    var l = Kn(Gl), a = m.T, n = O.p;
    try {
      O.p = 32 > l ? 32 : l, m.T = null, l = jc, jc = null;
      var i = ca, u = Gl;
      if (Wt = 0, Un = ca = null, Gl = 0, (bt & 6) !== 0) throw Error(g(331));
      var f = bt;
      if (bt |= 4, qs(i.current), ws(
        i,
        i.current,
        u,
        l
      ), bt = f, _i(0, !1), he && typeof he.onPostCommitFiberRoot == "function")
        try {
          he.onPostCommitFiberRoot(ba, i);
        } catch {
        }
      return !0;
    } finally {
      O.p = n, m.T = a, ld(t, e);
    }
  }
  function nd(t, e, l) {
    e = Qe(l, e), e = pc(t.stateNode, e, 2), t = ea(t, e, 2), t !== null && (ul(t, 2), hl(t));
  }
  function Mt(t, e, l) {
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
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (fa === null || !fa.has(a))) {
            t = Qe(l, t), l = is(2), a = ea(e, l, 2), a !== null && (us(
              l,
              a,
              e,
              t
            ), ul(a, 2), hl(a));
            break;
          }
        }
        e = e.return;
      }
  }
  function Lc(t, e, l) {
    var a = t.pingCache;
    if (a === null) {
      a = t.pingCache = new oh();
      var n = /* @__PURE__ */ new Set();
      a.set(e, n);
    } else
      n = a.get(e), n === void 0 && (n = /* @__PURE__ */ new Set(), a.set(e, n));
    n.has(l) || (Nc = !0, n.add(l), t = hh.bind(null, t, e, l), e.then(t, t));
  }
  function hh(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, Dt === t && (ot & l) === l && (qt === 4 || qt === 3 && (ot & 62914560) === ot && 300 > le() - wu ? (bt & 2) === 0 && Bn(t, 0) : Rc |= l, Cn === ot && (Cn = 0)), hl(t);
  }
  function id(t, e) {
    e === 0 && (e = Vn()), t = Ha(t, e), t !== null && (ul(t, e), hl(t));
  }
  function gh(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), id(t, l);
  }
  function ph(t, e) {
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
        throw Error(g(314));
    }
    a !== null && a.delete(e), id(t, l);
  }
  function yh(t, e) {
    return Xn(t, e);
  }
  var Xu = null, Rn = null, Xc = !1, Qu = !1, Qc = !1, ra = 0;
  function hl(t) {
    t !== Rn && t.next === null && (Rn === null ? Xu = Rn = t : Rn = Rn.next = t), Qu = !0, Xc || (Xc = !0, bh());
  }
  function _i(t, e) {
    if (!Qc && Qu) {
      Qc = !0;
      do
        for (var l = !1, a = Xu; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var i = 0;
            else {
              var u = a.suspendedLanes, f = a.pingedLanes;
              i = (1 << 31 - Ft(42 | t) + 1) - 1, i &= n & ~(u & ~f), i = i & 201326741 ? i & 201326741 | 1 : i ? i | 2 : 0;
            }
            i !== 0 && (l = !0, od(a, i));
          } else
            i = ot, i = xa(
              a,
              a === Dt ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || Sa(a, i) || (l = !0, od(a, i));
          a = a.next;
        }
      while (l);
      Qc = !1;
    }
  }
  function vh() {
    ud();
  }
  function ud() {
    Qu = Xc = !1;
    var t = 0;
    ra !== 0 && Oh() && (t = ra);
    for (var e = le(), l = null, a = Xu; a !== null; ) {
      var n = a.next, i = fd(a, e);
      i === 0 ? (a.next = null, l === null ? Xu = n : l.next = n, n === null && (Rn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (Qu = !0)), a = n;
    }
    Wt !== 0 && Wt !== 5 || _i(t), ra !== 0 && (ra = 0);
  }
  function fd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - Ft(i), f = 1 << u, o = n[u];
      o === -1 ? ((f & l) === 0 || (f & a) !== 0) && (n[u] = vl(f, e)) : o <= e && (t.expiredLanes |= f), i &= ~f;
    }
    if (e = Dt, l = ot, l = xa(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (zt === 2 || zt === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && ya(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Sa(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && ya(a), Kn(l)) {
        case 2:
        case 8:
          l = Wa;
          break;
        case 32:
          l = va;
          break;
        case 268435456:
          l = Qi;
          break;
        default:
          l = va;
      }
      return a = cd.bind(null, t), l = Xn(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && ya(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function cd(t, e) {
    if (Wt !== 0 && Wt !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Lu() && t.callbackNode !== l)
      return null;
    var a = ot;
    return a = xa(
      t,
      t === Dt ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Qs(t, a, e), fd(t, le()), t.callbackNode != null && t.callbackNode === l ? cd.bind(null, t) : null);
  }
  function od(t, e) {
    if (Lu()) return null;
    Qs(t, e, !0);
  }
  function bh() {
    Uh(function() {
      (bt & 6) !== 0 ? Xn(
        Xi,
        vh
      ) : ud();
    });
  }
  function Vc() {
    if (ra === 0) {
      var t = bn;
      t === 0 && (t = yl, yl <<= 1, (yl & 261888) === 0 && (yl = 256)), ra = t;
    }
    return ra;
  }
  function rd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : nn("" + t);
  }
  function sd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function xh(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = rd(
        (n[ae] || null).action
      ), u = a.submitter;
      u && (e = (e = u[ae] || null) ? rd(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
      var f = new on(
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
                if (ra !== 0) {
                  var o = u ? sd(n, u) : new FormData(n);
                  rc(
                    l,
                    {
                      pending: !0,
                      data: o,
                      method: n.method,
                      action: i
                    },
                    null,
                    o
                  );
                }
              } else
                typeof i == "function" && (f.preventDefault(), o = u ? sd(n, u) : new FormData(n), rc(
                  l,
                  {
                    pending: !0,
                    data: o,
                    method: n.method,
                    action: i
                  },
                  i,
                  o
                ));
            },
            currentTarget: n
          }
        ]
      });
    }
  }
  for (var Zc = 0; Zc < _f.length; Zc++) {
    var Kc = _f[Zc], Sh = Kc.toLowerCase(), Th = Kc[0].toUpperCase() + Kc.slice(1);
    Pe(
      Sh,
      "on" + Th
    );
  }
  Pe(Xo, "onAnimationEnd"), Pe(Qo, "onAnimationIteration"), Pe(Vo, "onAnimationStart"), Pe("dblclick", "onDoubleClick"), Pe("focusin", "onFocus"), Pe("focusout", "onBlur"), Pe(qm, "onTransitionRun"), Pe(Gm, "onTransitionStart"), Pe(Ym, "onTransitionCancel"), Pe(Zo, "onTransitionEnd"), Tl("onMouseEnter", ["mouseout", "mouseover"]), Tl("onMouseLeave", ["mouseout", "mouseover"]), Tl("onPointerEnter", ["pointerout", "pointerover"]), Tl("onPointerLeave", ["pointerout", "pointerover"]), Sl(
    "onChange",
    "change click focusin focusout input keydown keyup selectionchange".split(" ")
  ), Sl(
    "onSelect",
    "focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(
      " "
    )
  ), Sl("onBeforeInput", [
    "compositionend",
    "keypress",
    "textInput",
    "paste"
  ]), Sl(
    "onCompositionEnd",
    "compositionend focusout keydown keypress keyup mousedown".split(" ")
  ), Sl(
    "onCompositionStart",
    "compositionstart focusout keydown keypress keyup mousedown".split(" ")
  ), Sl(
    "onCompositionUpdate",
    "compositionupdate focusout keydown keypress keyup mousedown".split(" ")
  );
  var Di = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), zh = new Set(
    "beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(Di)
  );
  function dd(t, e) {
    e = (e & 4) !== 0;
    for (var l = 0; l < t.length; l++) {
      var a = t[l], n = a.event;
      a = a.listeners;
      t: {
        var i = void 0;
        if (e)
          for (var u = a.length - 1; 0 <= u; u--) {
            var f = a[u], o = f.instance, y = f.currentTarget;
            if (f = f.listener, o !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = y;
            try {
              i(n);
            } catch (T) {
              nu(T);
            }
            n.currentTarget = null, i = o;
          }
        else
          for (u = 0; u < a.length; u++) {
            if (f = a[u], o = f.instance, y = f.currentTarget, f = f.listener, o !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = y;
            try {
              i(n);
            } catch (T) {
              nu(T);
            }
            n.currentTarget = null, i = o;
          }
      }
    }
  }
  function ct(t, e) {
    var l = e[kn];
    l === void 0 && (l = e[kn] = /* @__PURE__ */ new Set());
    var a = t + "__bubble";
    l.has(a) || (md(e, t, 2, !1), l.add(a));
  }
  function Jc(t, e, l) {
    var a = 0;
    e && (a |= 4), md(
      l,
      t,
      a,
      e
    );
  }
  var Vu = "_reactListening" + Math.random().toString(36).slice(2);
  function kc(t) {
    if (!t[Vu]) {
      t[Vu] = !0, Wi.forEach(function(l) {
        l !== "selectionchange" && (zh.has(l) || Jc(l, !1, t), Jc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[Vu] || (e[Vu] = !0, Jc("selectionchange", !1, e));
    }
  }
  function md(t, e, l, a) {
    switch (Xd(e)) {
      case 2:
        var n = $h;
        break;
      case 8:
        n = Ih;
        break;
      default:
        n = oo;
    }
    l = n.bind(
      null,
      e,
      l,
      t
    ), n = void 0, !Aa || e !== "touchstart" && e !== "touchmove" && e !== "wheel" || (n = !0), a ? n !== void 0 ? t.addEventListener(e, l, {
      capture: !0,
      passive: n
    }) : t.addEventListener(e, l, !0) : n !== void 0 ? t.addEventListener(e, l, {
      passive: n
    }) : t.addEventListener(e, l, !1);
  }
  function Fc(t, e, l, a, n) {
    var i = a;
    if ((e & 1) === 0 && (e & 2) === 0 && a !== null)
      t: for (; ; ) {
        if (a === null) return;
        var u = a.tag;
        if (u === 3 || u === 4) {
          var f = a.stateNode.containerInfo;
          if (f === n) break;
          if (u === 4)
            for (u = a.return; u !== null; ) {
              var o = u.tag;
              if ((o === 3 || o === 4) && u.stateNode.containerInfo === n)
                return;
              u = u.return;
            }
          for (; f !== null; ) {
            if (u = cl(f), u === null) return;
            if (o = u.tag, o === 5 || o === 6 || o === 26 || o === 27) {
              a = i = u;
              continue t;
            }
            f = f.parentNode;
          }
        }
        a = a.return;
      }
    eu(function() {
      var y = i, T = $n(l), A = [];
      t: {
        var b = Ko.get(t);
        if (b !== void 0) {
          var S = on, j = t;
          switch (t) {
            case "keypress":
              if (cn(l) === 0) break t;
            case "keydown":
            case "keyup":
              S = pm;
              break;
            case "focusin":
              j = "focus", S = I;
              break;
            case "focusout":
              j = "blur", S = I;
              break;
            case "beforeblur":
            case "afterblur":
              S = I;
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
              S = Ba;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              S = C;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              S = bm;
              break;
            case Xo:
            case Qo:
            case Vo:
              S = pt;
              break;
            case Zo:
              S = Sm;
              break;
            case "scroll":
            case "scrollend":
              S = yf;
              break;
            case "wheel":
              S = zm;
              break;
            case "copy":
            case "cut":
            case "paste":
              S = ye;
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
              S = Em;
          }
          var J = (e & 4) !== 0, _t = !J && (t === "scroll" || t === "scrollend"), h = J ? b !== null ? b + "Capture" : null : b;
          J = [];
          for (var d = y, p; d !== null; ) {
            var z = d;
            if (p = z.stateNode, z = z.tag, z !== 5 && z !== 26 && z !== 27 || p === null || h === null || (z = Kl(d, h), z != null && J.push(
              Oi(d, z, p)
            )), _t) break;
            d = d.return;
          }
          0 < J.length && (b = new S(
            b,
            j,
            null,
            l,
            T
          ), A.push({ event: b, listeners: J }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (b = t === "mouseover" || t === "pointerover", S = t === "mouseout" || t === "pointerout", b && l !== un && (j = l.relatedTarget || l.fromElement) && (cl(j) || j[Xl]))
            break t;
          if ((S || b) && (b = T.window === T ? T : (b = T.ownerDocument) ? b.defaultView || b.parentWindow : window, S ? (j = l.relatedTarget || l.toElement, S = y, j = j ? cl(j) : null, j !== null && (_t = xt(j), J = j.tag, j !== _t || J !== 5 && J !== 27 && J !== 6) && (j = null)) : (S = null, j = y), S !== j)) {
            if (J = Ba, z = "onMouseLeave", h = "onMouseEnter", d = "mouse", (t === "pointerout" || t === "pointerover") && (J = zo, z = "onPointerLeave", h = "onPointerEnter", d = "pointer"), _t = S == null ? b : ol(S), p = j == null ? b : ol(j), b = new J(
              z,
              d + "leave",
              S,
              l,
              T
            ), b.target = _t, b.relatedTarget = p, z = null, cl(T) === y && (J = new J(
              h,
              d + "enter",
              j,
              l,
              T
            ), J.target = p, J.relatedTarget = _t, z = J), _t = z, S && j)
              e: {
                for (J = Mh, h = S, d = j, p = 0, z = h; z; z = J(z))
                  p++;
                z = 0;
                for (var Z = d; Z; Z = J(Z))
                  z++;
                for (; 0 < p - z; )
                  h = J(h), p--;
                for (; 0 < z - p; )
                  d = J(d), z--;
                for (; p--; ) {
                  if (h === d || d !== null && h === d.alternate) {
                    J = h;
                    break e;
                  }
                  h = J(h), d = J(d);
                }
                J = null;
              }
            else J = null;
            S !== null && hd(
              A,
              b,
              S,
              J,
              !1
            ), j !== null && _t !== null && hd(
              A,
              _t,
              j,
              J,
              !0
            );
          }
        }
        t: {
          if (b = y ? ol(y) : window, S = b.nodeName && b.nodeName.toLowerCase(), S === "select" || S === "input" && b.type === "file")
            var yt = Uo;
          else if (Oo(b))
            if (Bo)
              yt = wm;
            else {
              yt = Nm;
              var G = Bm;
            }
          else
            S = b.nodeName, !S || S.toLowerCase() !== "input" || b.type !== "checkbox" && b.type !== "radio" ? y && ht(y.elementType) && (yt = Uo) : yt = Rm;
          if (yt && (yt = yt(t, y))) {
            Co(
              A,
              yt,
              l,
              T
            );
            break t;
          }
          G && G(t, b, y), t === "focusout" && y && b.type === "number" && y.memoizedProps.value != null && r(b, "number", b.value);
        }
        switch (G = y ? ol(y) : window, t) {
          case "focusin":
            (Oo(G) || G.contentEditable === "true") && (sn = G, Mf = y, ni = null);
            break;
          case "focusout":
            ni = Mf = sn = null;
            break;
          case "mousedown":
            Ef = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Ef = !1, Yo(A, l, T);
            break;
          case "selectionchange":
            if (jm) break;
          case "keydown":
          case "keyup":
            Yo(A, l, T);
        }
        var lt;
        if (xf)
          t: {
            switch (t) {
              case "compositionstart":
                var rt = "onCompositionStart";
                break t;
              case "compositionend":
                rt = "onCompositionEnd";
                break t;
              case "compositionupdate":
                rt = "onCompositionUpdate";
                break t;
            }
            rt = void 0;
          }
        else
          rn ? _o(t, l) && (rt = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (rt = "onCompositionStart");
        rt && (Mo && l.locale !== "ko" && (rn || rt !== "onCompositionStart" ? rt === "onCompositionEnd" && rn && (lt = Pn()) : (Ie = T, In = "value" in Ie ? Ie.value : Ie.textContent, rn = !0)), G = Zu(y, rt), 0 < G.length && (rt = new Te(
          rt,
          t,
          null,
          l,
          T
        ), A.push({ event: rt, listeners: G }), lt ? rt.data = lt : (lt = Do(l), lt !== null && (rt.data = lt)))), (lt = _m ? Dm(t, l) : Om(t, l)) && (rt = Zu(y, "onBeforeInput"), 0 < rt.length && (G = new Te(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          T
        ), A.push({
          event: G,
          listeners: rt
        }), G.data = lt)), xh(
          A,
          t,
          y,
          l,
          T
        );
      }
      dd(A, e);
    });
  }
  function Oi(t, e, l) {
    return {
      instance: t,
      listener: e,
      currentTarget: l
    };
  }
  function Zu(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, i = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = Kl(t, l), n != null && a.unshift(
        Oi(t, n, i)
      ), n = Kl(t, e), n != null && a.push(
        Oi(t, n, i)
      )), t.tag === 3) return a;
      t = t.return;
    }
    return [];
  }
  function Mh(t) {
    if (t === null) return null;
    do
      t = t.return;
    while (t && t.tag !== 5 && t.tag !== 27);
    return t || null;
  }
  function hd(t, e, l, a, n) {
    for (var i = e._reactName, u = []; l !== null && l !== a; ) {
      var f = l, o = f.alternate, y = f.stateNode;
      if (f = f.tag, o !== null && o === a) break;
      f !== 5 && f !== 26 && f !== 27 || y === null || (o = y, n ? (y = Kl(l, i), y != null && u.unshift(
        Oi(l, y, o)
      )) : n || (y = Kl(l, i), y != null && u.push(
        Oi(l, y, o)
      ))), l = l.return;
    }
    u.length !== 0 && t.push({ event: e, listeners: u });
  }
  var Eh = /\r\n?/g, Ah = /\u0000|\uFFFD/g;
  function gd(t) {
    return (typeof t == "string" ? t : "" + t).replace(Eh, `
`).replace(Ah, "");
  }
  function pd(t, e) {
    return e = gd(e), gd(t) === e;
  }
  function At(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || w(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && w(t, "" + a);
        break;
      case "className":
        ln(t, "class", a);
        break;
      case "tabIndex":
        ln(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        ln(t, l, a);
        break;
      case "style":
        st(t, a, i);
        break;
      case "data":
        if (e !== "object") {
          ln(t, "data", a);
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
        a = nn("" + a), t.setAttribute(l, a);
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
          typeof i == "function" && (l === "formAction" ? (e !== "input" && At(t, e, "name", n.name, n, null), At(
            t,
            e,
            "formEncType",
            n.formEncType,
            n,
            null
          ), At(
            t,
            e,
            "formMethod",
            n.formMethod,
            n,
            null
          ), At(
            t,
            e,
            "formTarget",
            n.formTarget,
            n,
            null
          )) : (At(t, e, "encType", n.encType, n, null), At(t, e, "method", n.method, n, null), At(t, e, "target", n.target, n, null)));
        if (a == null || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = nn("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = We);
        break;
      case "onScroll":
        a != null && ct("scroll", t);
        break;
      case "onScrollEnd":
        a != null && ct("scrollend", t);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(g(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(g(60));
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
        l = nn("" + a), t.setAttributeNS(
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
        ct("beforetoggle", t), ct("toggle", t), Ma(t, "popover", a);
        break;
      case "xlinkActuate":
        pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:actuate",
          a
        );
        break;
      case "xlinkArcrole":
        pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:arcrole",
          a
        );
        break;
      case "xlinkRole":
        pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:role",
          a
        );
        break;
      case "xlinkShow":
        pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:show",
          a
        );
        break;
      case "xlinkTitle":
        pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:title",
          a
        );
        break;
      case "xlinkType":
        pe(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:type",
          a
        );
        break;
      case "xmlBase":
        pe(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:base",
          a
        );
        break;
      case "xmlLang":
        pe(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:lang",
          a
        );
        break;
      case "xmlSpace":
        pe(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:space",
          a
        );
        break;
      case "is":
        Ma(t, "is", a);
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = Vl.get(l) || l, Ma(t, l, a));
    }
  }
  function Wc(t, e, l, a, n, i) {
    switch (l) {
      case "style":
        st(t, a, i);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(g(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(g(60));
            t.innerHTML = l;
          }
        }
        break;
      case "children":
        typeof a == "string" ? w(t, a) : (typeof a == "number" || typeof a == "bigint") && w(t, "" + a);
        break;
      case "onScroll":
        a != null && ct("scroll", t);
        break;
      case "onScrollEnd":
        a != null && ct("scrollend", t);
        break;
      case "onClick":
        a != null && (t.onclick = We);
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
        if (!Fn.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[ae] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : Ma(t, l, a);
          }
    }
  }
  function ce(t, e, l) {
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
        ct("error", t), ct("load", t);
        var a = !1, n = !1, i;
        for (i in l)
          if (l.hasOwnProperty(i)) {
            var u = l[i];
            if (u != null)
              switch (i) {
                case "src":
                  a = !0;
                  break;
                case "srcSet":
                  n = !0;
                  break;
                case "children":
                case "dangerouslySetInnerHTML":
                  throw Error(g(137, e));
                default:
                  At(t, e, i, u, l, null);
              }
          }
        n && At(t, e, "srcSet", l.srcSet, l, null), a && At(t, e, "src", l.src, l, null);
        return;
      case "input":
        ct("invalid", t);
        var f = i = u = n = null, o = null, y = null;
        for (a in l)
          if (l.hasOwnProperty(a)) {
            var T = l[a];
            if (T != null)
              switch (a) {
                case "name":
                  n = T;
                  break;
                case "type":
                  u = T;
                  break;
                case "checked":
                  o = T;
                  break;
                case "defaultChecked":
                  y = T;
                  break;
                case "value":
                  i = T;
                  break;
                case "defaultValue":
                  f = T;
                  break;
                case "children":
                case "dangerouslySetInnerHTML":
                  if (T != null)
                    throw Error(g(137, e));
                  break;
                default:
                  At(t, e, a, T, l, null);
              }
          }
        c(
          t,
          i,
          f,
          o,
          y,
          u,
          n,
          !1
        );
        return;
      case "select":
        ct("invalid", t), a = u = i = null;
        for (n in l)
          if (l.hasOwnProperty(n) && (f = l[n], f != null))
            switch (n) {
              case "value":
                i = f;
                break;
              case "defaultValue":
                u = f;
                break;
              case "multiple":
                a = f;
              default:
                At(t, e, n, f, l, null);
            }
        e = i, l = u, t.multiple = !!a, e != null ? x(t, !!a, e, !1) : l != null && x(t, !!a, l, !0);
        return;
      case "textarea":
        ct("invalid", t), i = n = a = null;
        for (u in l)
          if (l.hasOwnProperty(u) && (f = l[u], f != null))
            switch (u) {
              case "value":
                a = f;
                break;
              case "defaultValue":
                n = f;
                break;
              case "children":
                i = f;
                break;
              case "dangerouslySetInnerHTML":
                if (f != null) throw Error(g(91));
                break;
              default:
                At(t, e, u, f, l, null);
            }
        R(t, a, n, i);
        return;
      case "option":
        for (o in l)
          l.hasOwnProperty(o) && (a = l[o], a != null) && (o === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : At(t, e, o, a, l, null));
        return;
      case "dialog":
        ct("beforetoggle", t), ct("toggle", t), ct("cancel", t), ct("close", t);
        break;
      case "iframe":
      case "object":
        ct("load", t);
        break;
      case "video":
      case "audio":
        for (a = 0; a < Di.length; a++)
          ct(Di[a], t);
        break;
      case "image":
        ct("error", t), ct("load", t);
        break;
      case "details":
        ct("toggle", t);
        break;
      case "embed":
      case "source":
      case "link":
        ct("error", t), ct("load", t);
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
        for (y in l)
          if (l.hasOwnProperty(y) && (a = l[y], a != null))
            switch (y) {
              case "children":
              case "dangerouslySetInnerHTML":
                throw Error(g(137, e));
              default:
                At(t, e, y, a, l, null);
            }
        return;
      default:
        if (ht(e)) {
          for (T in l)
            l.hasOwnProperty(T) && (a = l[T], a !== void 0 && Wc(
              t,
              e,
              T,
              a,
              l,
              void 0
            ));
          return;
        }
    }
    for (f in l)
      l.hasOwnProperty(f) && (a = l[f], a != null && At(t, e, f, a, l, null));
  }
  function _h(t, e, l, a) {
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
        var n = null, i = null, u = null, f = null, o = null, y = null, T = null;
        for (S in l) {
          var A = l[S];
          if (l.hasOwnProperty(S) && A != null)
            switch (S) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                o = A;
              default:
                a.hasOwnProperty(S) || At(t, e, S, null, a, A);
            }
        }
        for (var b in a) {
          var S = a[b];
          if (A = l[b], a.hasOwnProperty(b) && (S != null || A != null))
            switch (b) {
              case "type":
                i = S;
                break;
              case "name":
                n = S;
                break;
              case "checked":
                y = S;
                break;
              case "defaultChecked":
                T = S;
                break;
              case "value":
                u = S;
                break;
              case "defaultValue":
                f = S;
                break;
              case "children":
              case "dangerouslySetInnerHTML":
                if (S != null)
                  throw Error(g(137, e));
                break;
              default:
                S !== A && At(
                  t,
                  e,
                  b,
                  S,
                  a,
                  A
                );
            }
        }
        Wn(
          t,
          u,
          f,
          o,
          y,
          T,
          i,
          n
        );
        return;
      case "select":
        S = u = f = b = null;
        for (i in l)
          if (o = l[i], l.hasOwnProperty(i) && o != null)
            switch (i) {
              case "value":
                break;
              case "multiple":
                S = o;
              default:
                a.hasOwnProperty(i) || At(
                  t,
                  e,
                  i,
                  null,
                  a,
                  o
                );
            }
        for (n in a)
          if (i = a[n], o = l[n], a.hasOwnProperty(n) && (i != null || o != null))
            switch (n) {
              case "value":
                b = i;
                break;
              case "defaultValue":
                f = i;
                break;
              case "multiple":
                u = i;
              default:
                i !== o && At(
                  t,
                  e,
                  n,
                  i,
                  a,
                  o
                );
            }
        e = f, l = u, a = S, b != null ? x(t, !!l, b, !1) : !!a != !!l && (e != null ? x(t, !!l, e, !0) : x(t, !!l, l ? [] : "", !1));
        return;
      case "textarea":
        S = b = null;
        for (f in l)
          if (n = l[f], l.hasOwnProperty(f) && n != null && !a.hasOwnProperty(f))
            switch (f) {
              case "value":
                break;
              case "children":
                break;
              default:
                At(t, e, f, null, a, n);
            }
        for (u in a)
          if (n = a[u], i = l[u], a.hasOwnProperty(u) && (n != null || i != null))
            switch (u) {
              case "value":
                b = n;
                break;
              case "defaultValue":
                S = n;
                break;
              case "children":
                break;
              case "dangerouslySetInnerHTML":
                if (n != null) throw Error(g(91));
                break;
              default:
                n !== i && At(t, e, u, n, a, i);
            }
        U(t, b, S);
        return;
      case "option":
        for (var j in l)
          b = l[j], l.hasOwnProperty(j) && b != null && !a.hasOwnProperty(j) && (j === "selected" ? t.selected = !1 : At(
            t,
            e,
            j,
            null,
            a,
            b
          ));
        for (o in a)
          b = a[o], S = l[o], a.hasOwnProperty(o) && b !== S && (b != null || S != null) && (o === "selected" ? t.selected = b && typeof b != "function" && typeof b != "symbol" : At(
            t,
            e,
            o,
            b,
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
        for (var J in l)
          b = l[J], l.hasOwnProperty(J) && b != null && !a.hasOwnProperty(J) && At(t, e, J, null, a, b);
        for (y in a)
          if (b = a[y], S = l[y], a.hasOwnProperty(y) && b !== S && (b != null || S != null))
            switch (y) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (b != null)
                  throw Error(g(137, e));
                break;
              default:
                At(
                  t,
                  e,
                  y,
                  b,
                  a,
                  S
                );
            }
        return;
      default:
        if (ht(e)) {
          for (var _t in l)
            b = l[_t], l.hasOwnProperty(_t) && b !== void 0 && !a.hasOwnProperty(_t) && Wc(
              t,
              e,
              _t,
              void 0,
              a,
              b
            );
          for (T in a)
            b = a[T], S = l[T], !a.hasOwnProperty(T) || b === S || b === void 0 && S === void 0 || Wc(
              t,
              e,
              T,
              b,
              a,
              S
            );
          return;
        }
    }
    for (var h in l)
      b = l[h], l.hasOwnProperty(h) && b != null && !a.hasOwnProperty(h) && At(t, e, h, null, a, b);
    for (A in a)
      b = a[A], S = l[A], !a.hasOwnProperty(A) || b === S || b == null && S == null || At(t, e, A, b, a, S);
  }
  function yd(t) {
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
  function Dh() {
    if (typeof performance.getEntriesByType == "function") {
      for (var t = 0, e = 0, l = performance.getEntriesByType("resource"), a = 0; a < l.length; a++) {
        var n = l[a], i = n.transferSize, u = n.initiatorType, f = n.duration;
        if (i && f && yd(u)) {
          for (u = 0, f = n.responseEnd, a += 1; a < l.length; a++) {
            var o = l[a], y = o.startTime;
            if (y > f) break;
            var T = o.transferSize, A = o.initiatorType;
            T && yd(A) && (o = o.responseEnd, u += T * (o < f ? 1 : (f - y) / (o - y)));
          }
          if (--a, e += 8 * (i + u) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var $c = null, Ic = null;
  function Ku(t) {
    return t.nodeType === 9 ? t : t.ownerDocument;
  }
  function vd(t) {
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
  function Pc(t, e) {
    return t === "textarea" || t === "noscript" || typeof e.children == "string" || typeof e.children == "number" || typeof e.children == "bigint" || typeof e.dangerouslySetInnerHTML == "object" && e.dangerouslySetInnerHTML !== null && e.dangerouslySetInnerHTML.__html != null;
  }
  var to = null;
  function Oh() {
    var t = window.event;
    return t && t.type === "popstate" ? t === to ? !1 : (to = t, !0) : (to = null, !1);
  }
  var xd = typeof setTimeout == "function" ? setTimeout : void 0, Ch = typeof clearTimeout == "function" ? clearTimeout : void 0, Sd = typeof Promise == "function" ? Promise : void 0, Uh = typeof queueMicrotask == "function" ? queueMicrotask : typeof Sd < "u" ? function(t) {
    return Sd.resolve(null).then(t).catch(Bh);
  } : xd;
  function Bh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function sa(t) {
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
          Ci(t.ownerDocument.documentElement);
        else if (l === "head") {
          l = t.ownerDocument.head, Ci(l);
          for (var i = l.firstChild; i; ) {
            var u = i.nextSibling, f = i.nodeName;
            i[Ql] || f === "SCRIPT" || f === "STYLE" || f === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && Ci(t.ownerDocument.body);
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
  function eo(t) {
    var e = t.firstChild;
    for (e && e.nodeType === 10 && (e = e.nextSibling); e; ) {
      var l = e;
      switch (e = e.nextSibling, l.nodeName) {
        case "HTML":
        case "HEAD":
        case "BODY":
          eo(l), za(l);
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
  function Nh(t, e, l, a) {
    for (; t.nodeType === 1; ) {
      var n = l;
      if (t.nodeName.toLowerCase() !== e.toLowerCase()) {
        if (!a && (t.nodeName !== "INPUT" || t.type !== "hidden"))
          break;
      } else if (a) {
        if (!t[Ql])
          switch (e) {
            case "meta":
              if (!t.hasAttribute("itemprop")) break;
              return t;
            case "link":
              if (i = t.getAttribute("rel"), i === "stylesheet" && t.hasAttribute("data-precedence"))
                break;
              if (i !== n.rel || t.getAttribute("href") !== (n.href == null || n.href === "" ? null : n.href) || t.getAttribute("crossorigin") !== (n.crossOrigin == null ? null : n.crossOrigin) || t.getAttribute("title") !== (n.title == null ? null : n.title))
                break;
              return t;
            case "style":
              if (t.hasAttribute("data-precedence")) break;
              return t;
            case "script":
              if (i = t.getAttribute("src"), (i !== (n.src == null ? null : n.src) || t.getAttribute("type") !== (n.type == null ? null : n.type) || t.getAttribute("crossorigin") !== (n.crossOrigin == null ? null : n.crossOrigin)) && i && t.hasAttribute("async") && !t.hasAttribute("itemprop"))
                break;
              return t;
            default:
              return t;
          }
      } else if (e === "input" && t.type === "hidden") {
        var i = n.name == null ? null : "" + n.name;
        if (n.type === "hidden" && t.getAttribute("name") === i)
          return t;
      } else return t;
      if (t = ke(t.nextSibling), t === null) break;
    }
    return null;
  }
  function Rh(t, e, l) {
    if (e === "") return null;
    for (; t.nodeType !== 3; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !l || (t = ke(t.nextSibling), t === null)) return null;
    return t;
  }
  function Md(t, e) {
    for (; t.nodeType !== 8; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !e || (t = ke(t.nextSibling), t === null)) return null;
    return t;
  }
  function lo(t) {
    return t.data === "$?" || t.data === "$~";
  }
  function ao(t) {
    return t.data === "$!" || t.data === "$?" && t.ownerDocument.readyState !== "loading";
  }
  function wh(t, e) {
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
  function ke(t) {
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
  var no = null;
  function Ed(t) {
    t = t.nextSibling;
    for (var e = 0; t; ) {
      if (t.nodeType === 8) {
        var l = t.data;
        if (l === "/$" || l === "/&") {
          if (e === 0)
            return ke(t.nextSibling);
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
    switch (e = Ku(l), t) {
      case "html":
        if (t = e.documentElement, !t) throw Error(g(452));
        return t;
      case "head":
        if (t = e.head, !t) throw Error(g(453));
        return t;
      case "body":
        if (t = e.body, !t) throw Error(g(454));
        return t;
      default:
        throw Error(g(451));
    }
  }
  function Ci(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    za(t);
  }
  var Fe = /* @__PURE__ */ new Map(), Dd = /* @__PURE__ */ new Set();
  function Ju(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var Yl = O.d;
  O.d = {
    f: Hh,
    r: jh,
    D: qh,
    C: Gh,
    L: Yh,
    m: Lh,
    X: Qh,
    S: Xh,
    M: Vh
  };
  function Hh() {
    var t = Yl.f(), e = qu();
    return t || e;
  }
  function jh(t) {
    var e = bl(t);
    e !== null && e.tag === 5 && e.type === "form" ? Zr(e) : Yl.r(t);
  }
  var wn = typeof document > "u" ? null : document;
  function Od(t, e, l) {
    var a = wn;
    if (a && typeof e == "string" && e) {
      var n = Se(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Dd.has(n) || (Dd.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), ce(e, "link", t), Gt(e), a.head.appendChild(e)));
    }
  }
  function qh(t) {
    Yl.D(t), Od("dns-prefetch", t, null);
  }
  function Gh(t, e) {
    Yl.C(t, e), Od("preconnect", t, e);
  }
  function Yh(t, e, l) {
    Yl.L(t, e, l);
    var a = wn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + Se(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + Se(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + Se(
        l.imageSizes
      ) + '"]')) : n += '[href="' + Se(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = Hn(t);
          break;
        case "script":
          i = jn(t);
      }
      Fe.has(i) || (t = V(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), Fe.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Ui(i)) || e === "script" && a.querySelector(Bi(i)) || (e = a.createElement("link"), ce(e, "link", t), Gt(e), a.head.appendChild(e)));
    }
  }
  function Lh(t, e) {
    Yl.m(t, e);
    var l = wn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + Se(a) + '"][href="' + Se(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = jn(t);
      }
      if (!Fe.has(i) && (t = V({ rel: "modulepreload", href: t }, e), Fe.set(i, t), l.querySelector(n) === null)) {
        switch (a) {
          case "audioworklet":
          case "paintworklet":
          case "serviceworker":
          case "sharedworker":
          case "worker":
          case "script":
            if (l.querySelector(Bi(i)))
              return;
        }
        a = l.createElement("link"), ce(a, "link", t), Gt(a), l.head.appendChild(a);
      }
    }
  }
  function Xh(t, e, l) {
    Yl.S(t, e, l);
    var a = wn;
    if (a && t) {
      var n = xl(a).hoistableStyles, i = Hn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var f = { loading: 0, preload: null };
        if (u = a.querySelector(
          Ui(i)
        ))
          f.loading = 5;
        else {
          t = V(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = Fe.get(i)) && io(t, l);
          var o = u = a.createElement("link");
          Gt(o), ce(o, "link", t), o._p = new Promise(function(y, T) {
            o.onload = y, o.onerror = T;
          }), o.addEventListener("load", function() {
            f.loading |= 1;
          }), o.addEventListener("error", function() {
            f.loading |= 2;
          }), f.loading |= 4, ku(u, e, a);
        }
        u = {
          type: "stylesheet",
          instance: u,
          count: 1,
          state: f
        }, n.set(i, u);
      }
    }
  }
  function Qh(t, e) {
    Yl.X(t, e);
    var l = wn;
    if (l && t) {
      var a = xl(l).hoistableScripts, n = jn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = V({ src: t, async: !0 }, e), (e = Fe.get(n)) && uo(t, e), i = l.createElement("script"), Gt(i), ce(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Vh(t, e) {
    Yl.M(t, e);
    var l = wn;
    if (l && t) {
      var a = xl(l).hoistableScripts, n = jn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = V({ src: t, async: !0, type: "module" }, e), (e = Fe.get(n)) && uo(t, e), i = l.createElement("script"), Gt(i), ce(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Cd(t, e, l, a) {
    var n = (n = tt.current) ? Ju(n) : null;
    if (!n) throw Error(g(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = Hn(l.href), l = xl(
          n
        ).hoistableStyles, a = l.get(e), a || (a = {
          type: "style",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      case "link":
        if (l.rel === "stylesheet" && typeof l.href == "string" && typeof l.precedence == "string") {
          t = Hn(l.href);
          var i = xl(
            n
          ).hoistableStyles, u = i.get(t);
          if (u || (n = n.ownerDocument || n, u = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, i.set(t, u), (i = n.querySelector(
            Ui(t)
          )) && !i._p && (u.instance = i, u.state.loading = 5), Fe.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, Fe.set(t, l), i || Zh(
            n,
            t,
            l,
            u.state
          ))), e && a === null)
            throw Error(g(528, ""));
          return u;
        }
        if (e && a !== null)
          throw Error(g(529, ""));
        return null;
      case "script":
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = jn(l), l = xl(
          n
        ).hoistableScripts, a = l.get(e), a || (a = {
          type: "script",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      default:
        throw Error(g(444, t));
    }
  }
  function Hn(t) {
    return 'href="' + Se(t) + '"';
  }
  function Ui(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Ud(t) {
    return V({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function Zh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), ce(e, "link", l), Gt(e), t.head.appendChild(e));
  }
  function jn(t) {
    return '[src="' + Se(t) + '"]';
  }
  function Bi(t) {
    return "script[async]" + t;
  }
  function Bd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + Se(l.href) + '"]'
          );
          if (a)
            return e.instance = a, Gt(a), a;
          var n = V({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), Gt(a), ce(a, "style", n), ku(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = Hn(l.href);
          var i = t.querySelector(
            Ui(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, Gt(i), i;
          a = Ud(l), (n = Fe.get(n)) && io(a, n), i = (t.ownerDocument || t).createElement("link"), Gt(i);
          var u = i;
          return u._p = new Promise(function(f, o) {
            u.onload = f, u.onerror = o;
          }), ce(i, "link", a), e.state.loading |= 4, ku(i, l.precedence, t), e.instance = i;
        case "script":
          return i = jn(l.src), (n = t.querySelector(
            Bi(i)
          )) ? (e.instance = n, Gt(n), n) : (a = l, (n = Fe.get(i)) && (a = V({}, l), uo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Gt(n), ce(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(g(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, ku(a, l.precedence, t));
    return e.instance;
  }
  function ku(t, e, l) {
    for (var a = l.querySelectorAll(
      'link[rel="stylesheet"][data-precedence],style[data-precedence]'
    ), n = a.length ? a[a.length - 1] : null, i = n, u = 0; u < a.length; u++) {
      var f = a[u];
      if (f.dataset.precedence === e) i = f;
      else if (i !== n) break;
    }
    i ? i.parentNode.insertBefore(t, i.nextSibling) : (e = l.nodeType === 9 ? l.head : l, e.insertBefore(t, e.firstChild));
  }
  function io(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.title == null && (t.title = e.title);
  }
  function uo(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.integrity == null && (t.integrity = e.integrity);
  }
  var Fu = null;
  function Nd(t, e, l) {
    if (Fu === null) {
      var a = /* @__PURE__ */ new Map(), n = Fu = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = Fu, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var i = l[n];
      if (!(i[Ql] || i[Qt] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
        var u = i.getAttribute(e) || "";
        u = t + u;
        var f = a.get(u);
        f ? f.push(i) : a.set(u, [i]);
      }
    }
    return a;
  }
  function Rd(t, e, l) {
    t = t.ownerDocument || t, t.head.insertBefore(
      l,
      e === "title" ? t.querySelector("head > title") : null
    );
  }
  function Kh(t, e, l) {
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
  function wd(t) {
    return !(t.type === "stylesheet" && (t.state.loading & 3) === 0);
  }
  function Jh(t, e, l, a) {
    if (l.type === "stylesheet" && (typeof a.media != "string" || matchMedia(a.media).matches !== !1) && (l.state.loading & 4) === 0) {
      if (l.instance === null) {
        var n = Hn(a.href), i = e.querySelector(
          Ui(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = Wu.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, Gt(i);
          return;
        }
        i = e.ownerDocument || e, a = Ud(a), (n = Fe.get(n)) && io(a, n), i = i.createElement("link"), Gt(i);
        var u = i;
        u._p = new Promise(function(f, o) {
          u.onload = f, u.onerror = o;
        }), ce(i, "link", a), l.instance = i;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = Wu.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var fo = 0;
  function kh(t, e) {
    return t.stylesheets && t.count === 0 && Iu(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && Iu(t, t.stylesheets), t.unsuspend) {
          var i = t.unsuspend;
          t.unsuspend = null, i();
        }
      }, 6e4 + e);
      0 < t.imgBytes && fo === 0 && (fo = 62500 * Dh());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && Iu(t, t.stylesheets), t.unsuspend)) {
            var i = t.unsuspend;
            t.unsuspend = null, i();
          }
        },
        (t.imgBytes > fo ? 50 : 800) + e
      );
      return t.unsuspend = l, function() {
        t.unsuspend = null, clearTimeout(a), clearTimeout(n);
      };
    } : null;
  }
  function Wu() {
    if (this.count--, this.count === 0 && (this.imgCount === 0 || !this.waitingForImages)) {
      if (this.stylesheets) Iu(this, this.stylesheets);
      else if (this.unsuspend) {
        var t = this.unsuspend;
        this.unsuspend = null, t();
      }
    }
  }
  var $u = null;
  function Iu(t, e) {
    t.stylesheets = null, t.unsuspend !== null && (t.count++, $u = /* @__PURE__ */ new Map(), e.forEach(Fh, t), $u = null, Wu.call(t));
  }
  function Fh(t, e) {
    if (!(e.state.loading & 4)) {
      var l = $u.get(t);
      if (l) var a = l.get(null);
      else {
        l = /* @__PURE__ */ new Map(), $u.set(t, l);
        for (var n = t.querySelectorAll(
          "link[data-precedence],style[data-precedence]"
        ), i = 0; i < n.length; i++) {
          var u = n[i];
          (u.nodeName === "LINK" || u.getAttribute("media") !== "not all") && (l.set(u.dataset.precedence, u), a = u);
        }
        a && l.set(null, a);
      }
      n = e.instance, u = n.getAttribute("data-precedence"), i = l.get(u) || a, i === a && l.set(null, n), l.set(u, n), this.count++, a = Wu.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), i ? i.parentNode.insertBefore(n, i.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Ni = {
    $$typeof: Rt,
    Provider: null,
    Consumer: null,
    _currentValue: L,
    _currentValue2: L,
    _threadCount: 0
  };
  function Wh(t, e, l, a, n, i, u, f, o) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Zn(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Zn(0), this.hiddenUpdates = Zn(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = o, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function Hd(t, e, l, a, n, i, u, f, o, y, T, A) {
    return t = new Wh(
      t,
      e,
      l,
      u,
      o,
      y,
      T,
      A,
      f
    ), e = 1, i === !0 && (e |= 24), i = Be(3, null, null, e), t.current = i, i.stateNode = t, e = Yf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Vf(i), t;
  }
  function jd(t) {
    return t ? (t = hn, t) : hn;
  }
  function qd(t, e, l, a, n, i) {
    n = jd(n), a.context === null ? a.context = n : a.pendingContext = n, a = ta(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = ea(t, a, e), l !== null && (_e(l, t, e), si(l, t, e));
  }
  function Gd(t, e) {
    if (t = t.memoizedState, t !== null && t.dehydrated !== null) {
      var l = t.retryLane;
      t.retryLane = l !== 0 && l < e ? l : e;
    }
  }
  function co(t, e) {
    Gd(t, e), (t = t.alternate) && Gd(t, e);
  }
  function Yd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Ha(t, 67108864);
      e !== null && _e(e, t, 67108864), co(t, 67108864);
    }
  }
  function Ld(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = je();
      e = Ta(e);
      var l = Ha(t, e);
      l !== null && _e(l, t, e), co(t, e);
    }
  }
  var Pu = !0;
  function $h(t, e, l, a) {
    var n = m.T;
    m.T = null;
    var i = O.p;
    try {
      O.p = 2, oo(t, e, l, a);
    } finally {
      O.p = i, m.T = n;
    }
  }
  function Ih(t, e, l, a) {
    var n = m.T;
    m.T = null;
    var i = O.p;
    try {
      O.p = 8, oo(t, e, l, a);
    } finally {
      O.p = i, m.T = n;
    }
  }
  function oo(t, e, l, a) {
    if (Pu) {
      var n = ro(a);
      if (n === null)
        Fc(
          t,
          e,
          a,
          tf,
          l
        ), Qd(t, a);
      else if (tg(
        n,
        t,
        e,
        l,
        a
      ))
        a.stopPropagation();
      else if (Qd(t, a), e & 4 && -1 < Ph.indexOf(t)) {
        for (; n !== null; ) {
          var i = bl(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = il(i.pendingLanes);
                  if (u !== 0) {
                    var f = i;
                    for (f.pendingLanes |= 2, f.entangledLanes |= 2; u; ) {
                      var o = 1 << 31 - Ft(u);
                      f.entanglements[1] |= o, u &= ~o;
                    }
                    hl(i), (bt & 6) === 0 && (Hu = le() + 500, _i(0));
                  }
                }
                break;
              case 31:
              case 13:
                f = Ha(i, 2), f !== null && _e(f, i, 2), qu(), co(i, 2);
            }
          if (i = ro(a), i === null && Fc(
            t,
            e,
            a,
            tf,
            l
          ), i === n) break;
          n = i;
        }
        n !== null && a.stopPropagation();
      } else
        Fc(
          t,
          e,
          a,
          null,
          l
        );
    }
  }
  function ro(t) {
    return t = $n(t), so(t);
  }
  var tf = null;
  function so(t) {
    if (tf = null, t = cl(t), t !== null) {
      var e = xt(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = it(e), t !== null) return t;
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
    return tf = t, null;
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
        switch (Li()) {
          case Xi:
            return 2;
          case Wa:
            return 8;
          case va:
          case of:
            return 32;
          case Qi:
            return 268435456;
          default:
            return 32;
        }
      default:
        return 32;
    }
  }
  var mo = !1, da = null, ma = null, ha = null, Ri = /* @__PURE__ */ new Map(), wi = /* @__PURE__ */ new Map(), ga = [], Ph = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Qd(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        da = null;
        break;
      case "dragenter":
      case "dragleave":
        ma = null;
        break;
      case "mouseover":
      case "mouseout":
        ha = null;
        break;
      case "pointerover":
      case "pointerout":
        Ri.delete(e.pointerId);
        break;
      case "gotpointercapture":
      case "lostpointercapture":
        wi.delete(e.pointerId);
    }
  }
  function Hi(t, e, l, a, n, i) {
    return t === null || t.nativeEvent !== i ? (t = {
      blockedOn: e,
      domEventName: l,
      eventSystemFlags: a,
      nativeEvent: i,
      targetContainers: [n]
    }, e !== null && (e = bl(e), e !== null && Yd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function tg(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return da = Hi(
          da,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return ma = Hi(
          ma,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return ha = Hi(
          ha,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "pointerover":
        var i = n.pointerId;
        return Ri.set(
          i,
          Hi(
            Ri.get(i) || null,
            t,
            e,
            l,
            a,
            n
          )
        ), !0;
      case "gotpointercapture":
        return i = n.pointerId, wi.set(
          i,
          Hi(
            wi.get(i) || null,
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
    var e = cl(t.target);
    if (e !== null) {
      var l = xt(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = it(l), e !== null) {
            t.blockedOn = e, Jn(t.priority, function() {
              Ld(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = Pt(l), e !== null) {
            t.blockedOn = e, Jn(t.priority, function() {
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
  function ef(t) {
    if (t.blockedOn !== null) return !1;
    for (var e = t.targetContainers; 0 < e.length; ) {
      var l = ro(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        un = a, l.target.dispatchEvent(a), un = null;
      } else
        return e = bl(l), e !== null && Yd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function Zd(t, e, l) {
    ef(t) && l.delete(e);
  }
  function eg() {
    mo = !1, da !== null && ef(da) && (da = null), ma !== null && ef(ma) && (ma = null), ha !== null && ef(ha) && (ha = null), Ri.forEach(Zd), wi.forEach(Zd);
  }
  function lf(t, e) {
    t.blockedOn === e && (t.blockedOn = null, mo || (mo = !0, v.unstable_scheduleCallback(
      v.unstable_NormalPriority,
      eg
    )));
  }
  var af = null;
  function Kd(t) {
    af !== t && (af = t, v.unstable_scheduleCallback(
      v.unstable_NormalPriority,
      function() {
        af === t && (af = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (so(a || l) === null)
              continue;
            break;
          }
          var i = bl(l);
          i !== null && (t.splice(e, 3), e -= 3, rc(
            i,
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
    function e(o) {
      return lf(o, t);
    }
    da !== null && lf(da, t), ma !== null && lf(ma, t), ha !== null && lf(ha, t), Ri.forEach(e), wi.forEach(e);
    for (var l = 0; l < ga.length; l++) {
      var a = ga[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < ga.length && (l = ga[0], l.blockedOn === null); )
      Vd(l), l.blockedOn === null && ga.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[ae] || null;
        if (typeof i == "function")
          u || Kd(l);
        else if (u) {
          var f = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[ae] || null)
              f = u.formAction;
            else if (so(n) !== null) continue;
          } else f = u.action;
          typeof f == "function" ? l[a + 1] = f : (l.splice(a, 3), a -= 3), Kd(l);
        }
      }
  }
  function Jd() {
    function t(i) {
      i.canIntercept && i.info === "react-transition" && i.intercept({
        handler: function() {
          return new Promise(function(u) {
            return n = u;
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
        var i = navigation.currentEntry;
        i && i.url != null && navigation.navigate(i.url, {
          state: i.getState(),
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
  function ho(t) {
    this._internalRoot = t;
  }
  nf.prototype.render = ho.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(g(409));
    var l = e.current, a = je();
    qd(l, a, t, e, null, null);
  }, nf.prototype.unmount = ho.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      qd(t.current, 2, null, t, null, null), qu(), e[Xl] = null;
    }
  };
  function nf(t) {
    this._internalRoot = t;
  }
  nf.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = ki();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < ga.length && e !== 0 && e < ga[l].priority; l++) ;
      ga.splice(l, 0, t), l === 0 && Vd(t);
    }
  };
  var kd = D.version;
  if (kd !== "19.2.3")
    throw Error(
      g(
        527,
        kd,
        "19.2.3"
      )
    );
  O.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(g(188)) : (t = Object.keys(t).join(","), Error(g(268, t)));
    return t = _(e), t = t !== null ? ut(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var lg = {
    bundleType: 0,
    version: "19.2.3",
    rendererPackageName: "react-dom",
    currentDispatcherRef: m,
    reconcilerVersion: "19.2.3"
  };
  if (typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ < "u") {
    var uf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!uf.isDisabled && uf.supportsFiber)
      try {
        ba = uf.inject(
          lg
        ), he = uf;
      } catch {
      }
  }
  return qi.createRoot = function(t, e) {
    if (!nt(t)) throw Error(g(299));
    var l = !1, a = "", n = es, i = ls, u = as;
    return e != null && (e.unstable_strictMode === !0 && (l = !0), e.identifierPrefix !== void 0 && (a = e.identifierPrefix), e.onUncaughtError !== void 0 && (n = e.onUncaughtError), e.onCaughtError !== void 0 && (i = e.onCaughtError), e.onRecoverableError !== void 0 && (u = e.onRecoverableError)), e = Hd(
      t,
      1,
      !1,
      null,
      null,
      l,
      a,
      null,
      n,
      i,
      u,
      Jd
    ), t[Xl] = e.current, kc(t), new ho(e);
  }, qi.hydrateRoot = function(t, e, l) {
    if (!nt(t)) throw Error(g(299));
    var a = !1, n = "", i = es, u = ls, f = as, o = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (i = l.onUncaughtError), l.onCaughtError !== void 0 && (u = l.onCaughtError), l.onRecoverableError !== void 0 && (f = l.onRecoverableError), l.formState !== void 0 && (o = l.formState)), e = Hd(
      t,
      1,
      !0,
      e,
      l ?? null,
      a,
      n,
      o,
      i,
      u,
      f,
      Jd
    ), e.context = jd(null), l = e.current, a = je(), a = Ta(a), n = ta(a), n.callback = null, ea(l, n, a), l = a, e.current.lanes = l, ul(e, l), hl(e), t[Xl] = e.current, kc(t), new nf(e);
  }, qi.version = "19.2.3", qi;
}
var nm;
function dg() {
  if (nm) return po.exports;
  nm = 1;
  function v() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(v);
      } catch (D) {
        console.error(D);
      }
  }
  return v(), po.exports = sg(), po.exports;
}
var mg = dg(), im = To();
const hg = {
  additions: "Additions",
  bars: "Bars",
  branchBase: "Branch base",
  changedFiles: "Changed files",
  classic: "Classic",
  collapseAllDiffs: "Collapse all diffs",
  collapseUnchangedContext: "Collapse unchanged context",
  commit: "Commit",
  copiedGitApplyCommand: "Copied git apply command",
  copyGitApplyCommand: "Copy git apply command",
  deletions: "Deletions",
  diffStats: "Diff stats",
  diffTarget: "Diff target",
  diffViewer: "Diff viewer",
  disableWordDiffs: "Disable word diffs",
  disableWordWrap: "Disable word wrap",
  enableWordDiffs: "Enable word diffs",
  enableWordWrap: "Enable word wrap",
  expandAllDiffs: "Expand all diffs",
  expandUnchangedContext: "Expand unchanged context",
  files: "Files",
  hideBackgrounds: "Hide backgrounds",
  hideFiles: "Hide files",
  hideFileSearch: "Hide file search",
  hideLineNumbers: "Hide line numbers",
  indicatorStyle: "Indicator style",
  jumpToFile: "Jump to file",
  loadingDiff: "Loading diff...",
  loadingRenderer: "Loading renderer...",
  noFileDiffs: "No file diffs found in patch input.",
  none: "None",
  openSourceURL: "Open source URL",
  options: "Options",
  parsingDiff: "Parsing diff...",
  refresh: "Refresh",
  renderFailed: "Could not render this diff. Check the patch input and try again.",
  renderingDiff: "Rendering diff...",
  repoPath: "Repository path",
  showBackgrounds: "Show backgrounds",
  showFiles: "Show files",
  showFileSearch: "Show file search",
  showLineNumbers: "Show line numbers",
  switchToSplitDiff: "Switch to split diff",
  switchToUnifiedDiff: "Switch to unified diff",
  untitled: "Untitled"
};
function fm() {
  return !1;
}
function cm(v, D = {}) {
  const q = /* @__PURE__ */ new Set();
  return (g) => {
    const nt = v?.[g];
    if (typeof nt == "string" && nt.trim() !== "")
      return nt;
    if (D.assertMissing && !q.has(g))
      throw q.add(g), new Error(`Missing cmux diff viewer label: ${g}`);
    return hg[g];
  };
}
const gg = {
  background: "#ffffff",
  foreground: "#000000",
  ghosttyName: "Apple System Colors Light",
  name: "cmux-ghostty-light",
  palette: {},
  selectionBackground: "#abd8ff",
  selectionForeground: "#000000",
  type: "light"
}, pg = {
  background: "#000000",
  foreground: "#ffffff",
  ghosttyName: "Apple System Colors",
  name: "cmux-ghostty-dark",
  palette: {},
  selectionBackground: "#3f638b",
  selectionForeground: "#ffffff",
  type: "dark"
};
function om(v) {
  const D = { ...gg, ...v?.themes?.light }, q = { ...pg, ...v?.themes?.dark };
  return {
    backgroundOpacity: v?.backgroundOpacity ?? 1,
    fontFamily: v?.fontFamily ?? "Menlo",
    fontSize: v?.fontSize ?? 10,
    lineHeight: v?.lineHeight ?? 20,
    theme: {
      light: v?.theme?.light ?? D.name ?? "cmux-ghostty-light",
      dark: v?.theme?.dark ?? q.name ?? "cmux-ghostty-dark"
    },
    themes: {
      light: D,
      dark: q
    }
  };
}
function rm(v) {
  if (!v)
    return;
  const D = v.themes?.light ?? {}, q = v.themes?.dark ?? {}, g = Fa(D.background, "#ffffff"), nt = Fa(q.background, "#000000"), xt = sm(v.backgroundOpacity), it = document.documentElement.style;
  it.setProperty("--cmux-diff-bg-opacity", ff(xt)), it.setProperty("--cmux-diff-bg-opacity-percent", `${ff(xt * 100)}%`), it.setProperty("--cmux-diff-bg-base-light", g), it.setProperty("--cmux-diff-bg-base-dark", nt), it.setProperty("--cmux-diff-bg-light", So(g, xt)), it.setProperty("--cmux-diff-bg-dark", So(nt, xt)), it.setProperty("--cmux-diff-fg-light", Fa(D.foreground, "#000000")), it.setProperty("--cmux-diff-fg-dark", Fa(q.foreground, "#ffffff")), it.setProperty("--cmux-diff-selection-bg-light", Fa(D.selectionBackground, "#abd8ff")), it.setProperty("--cmux-diff-selection-bg-dark", Fa(q.selectionBackground, "#3f638b")), it.setProperty("--cmux-diff-code-font-family", vg(v.fontFamily)), it.setProperty("--cmux-diff-font-size", `${um(v.fontSize, 10)}px`), it.setProperty("--cmux-diff-line-height", `${um(v.lineHeight, 20)}px`);
}
function yg(v, D) {
  return So(Fa(v, "#000000"), sm(D?.backgroundOpacity));
}
function So(v, D) {
  const q = bg(v);
  return q ? `rgb(${q.red} ${q.green} ${q.blue} / ${ff(D)})` : `color-mix(in srgb, ${v} ${ff(D * 100)}%, transparent)`;
}
function Fa(v, D) {
  return typeof v == "string" && v.trim() !== "" ? v.trim() : D;
}
function vg(v) {
  const D = typeof v == "string" && v.trim() !== "" ? v.trim() : "Menlo";
  return `${JSON.stringify(D)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
}
function bg(v) {
  let D = v.trim();
  if (!D.startsWith("#") || (D = D.slice(1), D.length === 3 && (D = D.split("").map((g) => `${g}${g}`).join("")), !/^[\da-f]{6}$/i.test(D)))
    return null;
  const q = Number.parseInt(D, 16);
  return {
    blue: q & 255,
    green: q >> 8 & 255,
    red: q >> 16 & 255
  };
}
function um(v, D) {
  return typeof v == "number" && Number.isFinite(v) && v > 0 ? v : D;
}
function sm(v) {
  return typeof v != "number" || !Number.isFinite(v) ? 1 : Math.max(0, Math.min(1, v));
}
function ff(v) {
  return Number(v.toFixed(4)).toString();
}
function xg(v, D, q) {
  if (!v)
    return { kind: "reset" };
  const g = v.pathCount ?? v.paths?.length ?? 0, nt = D.pathCount ?? q.length;
  return !(D.previousSource === v || Sg(v, D)) || nt < g ? { kind: "reset" } : {
    addedPaths: q.slice(g, nt),
    kind: "append"
  };
}
function Sg(v, D) {
  const q = v.paths, g = D.paths, nt = v.pathCount ?? q?.length ?? 0, xt = D.pathCount ?? g?.length ?? 0;
  if (!Array.isArray(q) || !Array.isArray(g) || nt > xt)
    return !1;
  for (let it = 0; it < nt; it += 1)
    if (q[it] !== g[it])
      return !1;
  return !0;
}
function Tg(v) {
  const D = (c) => {
    const r = document.getElementById(c);
    if (!r)
      throw new Error(`Missing cmux diff viewer element: ${c}`);
    return r;
  }, q = v.assets ?? {}, g = (c, r) => {
    if (typeof c != "string" || c.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${r}`);
    return new URL(c, window.location.href).href;
  }, nt = g(q.diffsModuleURL, "diffsModuleURL"), xt = g(q.treesModuleURL, "treesModuleURL"), it = g(q.workerPoolModuleURL, "workerPoolModuleURL"), Pt = g(q.workerModuleURL, "workerModuleURL"), B = v.payload ?? {}, _ = om(B.appearance), ut = D("viewer"), V = D("status"), Ot = D("toolbar"), Xt = D("source-select"), oe = D("repo-select"), te = D("base-select"), qe = D("source-detail"), St = D("jump-select"), Ge = D("external-link"), Rt = D("files-toggle"), kt = D("layout-toggle"), re = D("options-button"), wt = D("options-menu"), at = D("files-sidebar"), Bt = D("file-list"), De = D("files-count"), be = D("file-search-toggle"), se = D("file-collapse-toggle"), ee = D("stats-files"), ll = D("stats-added"), Ye = D("stats-deleted"), Y = cm(B.labels, {
    assertMissing: fm()
  }), m = {
    layout: B.layout === "unified" ? "unified" : "split",
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
  let O, L, K;
  const F = [], s = [], M = /* @__PURE__ */ new Map();
  let N = /* @__PURE__ */ new Set(), H = null, W = null, tt = /* @__PURE__ */ new Map(), mt = { value: null }, $t = "", Tt = "", gl = !1, Le = /* @__PURE__ */ new Map(), al = /* @__PURE__ */ new Map();
  typeof B.title == "string" && B.title.trim() !== "" && (document.title = B.title), rm(_), he(), fl(B.sourceOptions ?? []), ae(oe, B.repoOptions ?? [], B.repoRoot ?? "", Y("repoPath")), ae(te, B.baseOptions ?? [], B.branchBaseRef ?? "", Y("branchBase"));
  const Gn = globalThis.queueMicrotask ?? ((c) => setTimeout(c, 0));
  B.pendingReplacement === !0 ? (Oe(B.statusMessage ?? Y("loadingDiff"), { loading: !0, pending: !0 }), Gi()) : typeof B.statusMessage == "string" && B.statusMessage.length > 0 ? Oe(B.statusMessage, { error: B.statusIsError === !0, loading: !1, statusOnly: !0 }) : Gn(() => {
    pl().catch((c) => {
      console.error("cmux diff viewer render failed", c), Oe(Y("renderFailed"), { error: !0, loading: !1, statusOnly: !0 });
    });
  });
  async function pl() {
    Oe(Y("loadingRenderer"), { loading: !0 });
    const [
      {
        CodeView: c,
        getFiletypeFromFileName: r,
        parsePatchFiles: x,
        preloadHighlighter: U,
        processFile: R,
        registerCustomTheme: w
      },
      Q
    ] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(nt),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(xt).catch((st) => (console.warn("cmux diff file tree import failed", st), null))
    ]);
    if (an(w, _.themes.light), an(w, _.themes.dark), Oe(Y("parsingDiff"), { loading: !0 }), ya("loading"), L = await Ln(), Tl(F), ge(), window.__cmuxDiffViewer = { codeView: O, items: F, state: m, workerPool: L }, Xn(L), L?.initialize?.()?.then?.(() => Qn(L?.getStats?.()))?.catch?.((st) => console.warn("cmux diff worker pool initialization failed", st)), window.addEventListener("pagehide", () => L?.terminate?.(), { once: !0 }), await Xi({
      CodeView: c,
      parsePatchFiles: x,
      processFile: R,
      treesModule: Q
    }), F.length === 0)
      throw new Error(Y("noFileDiffs"));
    L || Se(_, s.length > 0 ? s : F, r, U).catch((st) => console.warn("cmux diff highlighter preload failed", st));
  }
  function Oe(c, r = {}) {
    V.isConnected || ut.replaceChildren(V), document.body.dataset.loading = r.loading === !0 || r.pending === !0 ? "true" : "false", document.body.dataset.statusOnly = r.statusOnly === !0 ? "true" : "false", V.dataset.error = r.error === !0 ? "true" : "false", V.dataset.pending = r.pending === !0 ? "true" : "false", V.textContent = c;
  }
  function Yn(c) {
    document.open(), document.write(c), document.close();
  }
  async function cf(c) {
    if (!c.ok)
      return Oe(Y("renderFailed"), { error: !0, loading: !1, statusOnly: !0 }), !1;
    const r = await c.text();
    return r.includes('data-cmux-diff-pending="true"') ? !1 : (Yn(r), !0);
  }
  async function Gi() {
    try {
      const c = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
      await cf(c);
    } catch (c) {
      document.documentElement.dataset.cmuxDiffWait = "failed", Oe(Y("renderFailed"), { error: !0, loading: !1, statusOnly: !0 }), console.warn("cmux diff viewer deferred load failed", c);
    }
  }
  async function Ln() {
    if (typeof Worker > "u")
      return null;
    try {
      const c = await import(it);
      an(c.registerCustomTheme, _.themes.light), an(c.registerCustomTheme, _.themes.dark);
      const r = new URL(Pt, window.location.href).href;
      return c.createDiffWorkerPool({
        workerURL: r,
        highlighterOptions: Yi()
      }) ?? null;
    } catch (c) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", c), null;
    }
  }
  function Xn(c) {
    if (!c) {
      ya("fallback");
      return;
    }
    ya("enabled"), Qn(c.getStats?.());
    const r = c.subscribeToStatChanges?.((x) => {
      Qn(x);
    });
    typeof r == "function" && window.addEventListener("pagehide", r, { once: !0 });
  }
  function ya(c) {
    document.body.dataset.workerPool = c;
  }
  function Qn(c) {
    !c || typeof c != "object" || (typeof c.managerState == "string" && (document.body.dataset.workerPoolState = c.managerState), Number.isFinite(c.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(c.totalWorkers)), typeof c.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(c.workersFailed)));
  }
  function Yi() {
    return {
      theme: _.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: m.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const le = /^From\s+([a-f0-9]+)\s/im;
  function Li(c, r) {
    const x = c?.match(le);
    return x?.[1] ? new TextDecoder().decode(new TextEncoder().encode(x[1].slice(0, 5))) : `${Y("commit")} ${r + 1}`;
  }
  async function Xi({ CodeView: c, parsePatchFiles: r, processFile: x, treesModule: U }) {
    const R = of(), w = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, Q = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let $ = performance.now(), st = performance.now(), ht = !0;
    const Vl = {
      initialBatchSize: Gt(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function pf(E, C) {
      const k = nn(R, E, C);
      return k?.renamedItem && Zl(k.renamedItem), k?.item;
    }
    function nn(E, C, k) {
      if (!C)
        return null;
      const I = pe(C), gt = k == null ? I : `${k}/${I}`, pt = I.length === 0 ? void 0 : E.pathStateByTreePath.get(gt), Ht = pt == null ? void 0 : We(E, gt, pt), ye = zl(C), Te = {
        id: E.itemIdToFile.has(gt) ? un(E, `${gt}?2`) : gt,
        type: "diff",
        fileDiff: C,
        version: 0
      }, lu = E.items.length;
      E.fileIndex += 1, E.items.push(Te), E.pendingItems.push(Te), E.pendingItemById.set(Te.id, Te), E.itemIdToFile.set(Te.id, { fileOrder: lu, path: I }), E.itemIdByTreePath.set(gt, Te.id), E.treePathByItemId.set(Te.id, gt), E.diffStats.addedLines += ye.added, E.diffStats.deletedLines += ye.deleted, E.diffStats.fileCount += 1, E.diffStats.totalLinesOfCode += C.unifiedLineCount ?? C.splitLineCount ?? 0;
      const vf = E.statsByPath.get(gt);
      return E.statsByPath.set(gt, ye), pt != null && !tu(vf, ye) && (E.pendingStatsChanged = !0), I.length > 0 && (pt == null && E.paths.push(gt), E.pathToItemId.set(gt, Te.id), $n(E, gt, C.type, pt?.sawDeleted === !0), E.pathStateByTreePath.set(gt, {
        currentItem: Te,
        currentItemId: Te.id,
        currentType: C.type,
        fileOrder: lu,
        sawDeleted: pt?.sawDeleted === !0 || C.type === "deleted"
      })), { item: Te, renamedItem: Ht };
    }
    function We(E, C, k) {
      const I = k.currentItemId, gt = k.currentType === "deleted" ? "?deleted" : "?previous", pt = un(E, `${C}${gt}`);
      if (k.currentItem.id = pt, k.currentItemId = pt, E.itemIdToFile.has(I)) {
        const Ht = E.itemIdToFile.get(I);
        E.itemIdToFile.delete(I), E.itemIdToFile.set(pt, Ht);
      }
      if (E.treePathByItemId.has(I) && (E.treePathByItemId.delete(I), E.treePathByItemId.set(pt, C)), E.pendingItemById.has(I)) {
        const Ht = E.pendingItemById.get(I);
        E.pendingItemById.delete(I), E.pendingItemById.set(pt, Ht);
        return;
      }
      return { oldId: I, newId: pt };
    }
    function un(E, C) {
      if (!E.itemIdToFile.has(C))
        return C;
      let k = E.nextCollisionSuffixByBase.get(C) ?? 2, I = `${C}-${k}`;
      for (; E.itemIdToFile.has(I); )
        k += 1, I = `${C}-${k}`;
      return E.nextCollisionSuffixByBase.set(C, k + 1), I;
    }
    function $n(E, C, k, I) {
      if (I && k !== "deleted") {
        E.gitStatusByPath.delete(C) && Ml(E, C);
        return;
      }
      const gt = Pi(k);
      if (gt === "modified") {
        E.gitStatusByPath.delete(C) && Ml(E, C);
        return;
      }
      if (E.gitStatusByPath.get(C)?.status === gt)
        return;
      const Ht = { path: C, status: gt };
      E.gitStatusByPath.set(C, Ht), E.pendingGitStatusRemovePaths.delete(C), E.pendingGitStatusSetByPath.set(C, Ht);
    }
    function Ml(E, C) {
      E.pendingGitStatusSetByPath.delete(C), E.pendingGitStatusRemovePaths.add(C);
    }
    function Zl(E) {
      if (N.delete(E.oldId) && N.add(E.newId), M.has(E.oldId)) {
        const C = M.get(E.oldId);
        M.delete(E.oldId), C && M.set(E.newId, C);
      }
      $i(E.oldId, E.newId), O?.updateItemId?.(E.oldId, E.newId);
    }
    async function fn(E, C) {
      pf(E, C) && await Ea(!1);
    }
    async function Ea(E) {
      if (R.pendingItems.length === 0)
        return;
      const C = performance.now();
      if (!E && ht && C - $ >= 8 && R.pendingItems.length < Vl.initialBatchSize && C - st < Vl.initialMaxWait) {
        await Vi(), $ = performance.now();
        return;
      }
      const k = ht ? Vl.initialBatchSize : Vl.incrementalBatchSize, I = ht ? Vl.initialMaxWait : Vl.incrementalMaxWait;
      if (E || R.pendingItems.length >= k || C - st >= I) {
        eu(), await Vi(), $ = performance.now();
        return;
      }
    }
    function eu() {
      if (R.pendingItems.length === 0)
        return;
      const E = R.pendingItems.splice(0, R.pendingItems.length);
      R.pendingItemById.clear();
      const C = E, k = s.length > 0;
      F.push(...E);
      for (const I of E)
        M.set(I.id, I);
      if (C.length > 0) {
        s.push(...C);
        for (const I of C)
          N.add(I.id);
        O ? O.addItems(C) : (O = new c(xa(), L ?? void 0), O.setup(ut), O.setItems(s), O.render(!0), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.codeView = O));
      }
      hf(E), Ce(U, !1, E.length), Q.flushCount += 1, Q.maxBatchSize = Math.max(Q.maxBatchSize, E.length), Q.fileCount = F.length, Q.renderableFileCount = s.length, Wa(Q), st = performance.now(), ht && (ht = !1, document.body.dataset.loading = "false", V.remove()), k || Ma(s[0]?.id ?? F[0]?.id ?? ""), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.items = F, window.__cmuxDiffViewer.codeViewItems = s, window.__cmuxDiffViewer.streamMetrics = Q);
    }
    function Kl() {
      O && (O.syncContainerHeight?.(), O.render(!0));
    }
    function Ce(E, C, k = 1) {
      if (w.treesModule = E, w.dirtyCount += k, C || w.lastRefreshAt === 0) {
        Aa(w.treesModule);
        return;
      }
      const I = performance.now() - w.lastRefreshAt;
      if (w.dirtyCount >= 1e3 || I >= 1e3) {
        Aa(w.treesModule);
        return;
      }
      if (w.timeout !== 0)
        return;
      const gt = Math.max(0, 1e3 - I);
      w.timeout = window.setTimeout(() => {
        w.timeout = 0, Aa(w.treesModule);
      }, gt);
    }
    function Aa(E) {
      w.timeout !== 0 && (window.clearTimeout(w.timeout), w.timeout = 0), w.dirtyCount = 0, w.lastRefreshAt = performance.now(), Q.treeRefreshCount += 1, W = Qi(R), kn(W, E), ge(), Wa(Q);
    }
    const $e = await fetch(B.patchURL, { cache: "no-store" });
    if (!$e.ok)
      throw new Error(`${Y("loadingDiff")} (${$e.status})`);
    if (!$e.body?.getReader) {
      const E = await $e.text();
      await va(E, r, fn), await Ea(!0), Kl(), Ce(U, !0), Q.completedAt = performance.now();
      return;
    }
    const Ie = new TextDecoder(), In = $e.body.getReader(), _a = "diff --git ", Pn = `
` + _a, cn = Pn.length - 1, Da = /\S/;
    function Oa(E, C) {
      const k = Math.max(C, 0);
      if (k === 0 && E.startsWith(_a))
        return 0;
      const I = E.indexOf(Pn, k);
      return I === -1 ? void 0 : I + 1;
    }
    function ne(E, C) {
      return Math.max(C, E.length - cn);
    }
    function El(E, C, k) {
      const I = Math.max(C, 0), gt = Math.min(k, E.length);
      if (I >= gt)
        return;
      let pt = E.lastIndexOf(`
From `, gt - 1);
      for (; pt !== -1; ) {
        const Ht = pt + 1;
        if (Ht < I)
          return;
        if (Ht >= gt) {
          pt = E.lastIndexOf(`
From `, pt - 1);
          continue;
        }
        const ye = E.indexOf(`
`, Ht + 1), Na = E.slice(Ht, ye === -1 || ye > gt ? gt : ye);
        if (le.test(Na))
          return Ht;
        pt = E.lastIndexOf(`
From `, pt - 1);
      }
    }
    function on(E) {
      const C = Oa(E, 0);
      if (C == null || C <= 0)
        return;
      const k = E.slice(0, C);
      return le.test(k) ? k : void 0;
    }
    async function Jl(E) {
      if (E.trim() === "")
        return;
      const C = on(E);
      C != null && (kl = Li(C, Ua), Ua += 1);
      const k = `cmux-diff-file-${R.fileIndex}`;
      await fn(x(E, {
        cacheKey: k,
        isGitDiff: !0
      }), kl);
    }
    function yf() {
      let E, C = "", k = 0, I = !1;
      function gt() {
        if (E == null) {
          if (E = Oa(C, k), E == null)
            return k = ne(C, 0), null;
          I = !0, k = E + 1;
        }
        for (; ; ) {
          const pt = E;
          if (pt == null)
            return null;
          const Ht = Oa(C, k);
          if (Ht == null)
            return k = ne(C, pt + 1), null;
          const ye = El(C, pt + 1, Ht) ?? Ht, Na = C.slice(0, ye);
          if (C = C.slice(ye), E = Oa(C, 0), k = E == null ? 0 : E + 1, Da.test(Na))
            return Na;
        }
      }
      return {
        push(pt) {
          pt.length > 0 && (C += pt);
        },
        takeAvailableFile: gt,
        finish() {
          const pt = gt();
          if (pt != null)
            return { fileText: pt };
          if (!Da.test(C))
            return C = "", {};
          if (!I) {
            const ye = C;
            return C = "", { fallbackPatchContent: ye };
          }
          const Ht = C;
          return C = "", { fileText: Ht };
        }
      };
    }
    async function Ca(E) {
      let C;
      for (; (C = E.takeAvailableFile()) != null; )
        await Jl(C);
    }
    const rl = yf();
    let kl, Ua = 0;
    for (; ; ) {
      const { done: E, value: C } = await In.read();
      if (E) {
        const k = Ie.decode();
        k.length > 0 && (rl.push(k), await Ca(rl));
        break;
      }
      rl.push(Ie.decode(C, { stream: !0 })), await Ca(rl);
    }
    const Ba = rl.finish();
    Ba.fileText != null ? (await Jl(Ba.fileText), await Ca(rl)) : Ba.fallbackPatchContent != null && await va(Ba.fallbackPatchContent, r, fn), await Ea(!0), Kl(), Ce(U, !0), Q.completedAt = performance.now(), Wa(Q);
  }
  function Wa(c) {
    document.body.dataset.streamFileCount = String(c.fileCount ?? F.length), document.body.dataset.streamRenderableFileCount = String(c.renderableFileCount ?? s.length), document.body.dataset.streamFlushCount = String(c.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(c.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(c.treeRefreshCount ?? 0), Number.isFinite(c.completedAt) && c.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(c.completedAt - c.startedAt)));
  }
  async function va(c, r, x) {
    const U = r(c, "cmux-diff"), R = U.length > 1;
    for (const [w, Q] of U.entries()) {
      const $ = R ? Li(Q.patchMetadata, w) : void 0;
      for (const st of Q.files ?? [])
        await x(st, $);
    }
  }
  function of() {
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
  function Qi(c) {
    const r = c.lastTreeSource, x = rf(c), U = {
      diffStats: { ...c.diffStats },
      gitStatus: Array.from(c.gitStatusByPath.values()),
      gitStatusPatch: x,
      pathCount: c.paths.length,
      paths: c.paths,
      pathToItemId: c.pathToItemId,
      previousSource: r,
      statsChanged: c.pendingStatsChanged,
      statsByPath: c.statsByPath,
      treePathByItemId: c.treePathByItemId
    };
    return c.pendingStatsChanged = !1, c.lastTreeSource = U, U;
  }
  function rf(c) {
    if (c.pendingGitStatusRemovePaths.size === 0 && c.pendingGitStatusSetByPath.size === 0)
      return;
    const r = {};
    return c.pendingGitStatusRemovePaths.size > 0 && (r.remove = Array.from(c.pendingGitStatusRemovePaths), c.pendingGitStatusRemovePaths.clear()), c.pendingGitStatusSetByPath.size > 0 && (r.set = Array.from(c.pendingGitStatusSetByPath.values()), c.pendingGitStatusSetByPath.clear()), r;
  }
  function Vi() {
    return new Promise((c) => {
      let r = !1, x = 0;
      const U = () => {
        r || (r = !0, x !== 0 && window.clearTimeout(x), c());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        x = window.setTimeout(U, 50), window.requestAnimationFrame(U);
      else if (typeof MessageChannel < "u") {
        const R = new MessageChannel();
        R.port1.onmessage = U, R.port2.postMessage(void 0);
      } else
        queueMicrotask(U);
    });
  }
  async function ba() {
    return mt.value == null && (mt.value = fetch(B.patchURL, { cache: "no-store" }).then(async (c) => {
      if (!c.ok)
        throw new Error(`${Y("loadingDiff")} (${c.status})`);
      return c.text();
    })), mt.value;
  }
  function he() {
    Rt.innerHTML = de("files"), be.innerHTML = de("search"), se.innerHTML = de("sidebarCollapse"), kt.innerHTML = de(m.layout), re.innerHTML = de("dots"), typeof B.externalURL == "string" && B.externalURL.length > 0 && (Ge.href = B.externalURL, Ge.innerHTML = de("external"), Ge.hidden = !1), Rt.addEventListener("click", () => ul(!m.filesVisible)), se.addEventListener("click", () => ul(!1)), be.addEventListener("click", () => Ki(!m.fileSearchOpen)), kt.addEventListener("click", () => Zn(m.layout === "split" ? "unified" : "split")), re.addEventListener("click", () => tn(wt.hidden)), document.addEventListener("click", (c) => {
      wt.hidden || c.target instanceof Node && Ot.contains(c.target) || tn(!1);
    }), document.addEventListener("keydown", (c) => {
      c.key === "Escape" && tn(!1);
    }), nl(), ge();
  }
  function nl() {
    const c = B.shortcuts ?? {}, r = Ft(c.diffViewerScrollDown), x = Ft(c.diffViewerScrollUp), U = Ft(c.diffViewerScrollToBottom), R = Ft(c.diffViewerScrollToTop), w = Ft(c.diffViewerOpenFileSearch);
    let Q = null, $ = 0;
    document.addEventListener("keydown", (ht) => {
      if (!(ht.defaultPrevented || Pa(ht.target))) {
        if (Q && !yl(Q.shortcut.second, ht) && st(), Q && yl(Q.shortcut.second, ht)) {
          ht.preventDefault(), Q.action(), st();
          return;
        }
        if ($a(r, ht)) {
          ht.preventDefault(), il(1);
          return;
        }
        if ($a(x, ht)) {
          ht.preventDefault(), il(-1);
          return;
        }
        if ($a(U, ht)) {
          ht.preventDefault(), ut.scrollTo({ top: ut.scrollHeight, behavior: "auto" });
          return;
        }
        if ($a(w, ht) && K) {
          ht.preventDefault(), ul(!0), Ki(!0);
          return;
        }
        R && sf(R, ht) && (ht.preventDefault(), Q = {
          shortcut: R,
          action: () => ut.scrollTo({ top: 0, behavior: "auto" })
        }, $ = setTimeout(st, 700));
      }
    });
    function st() {
      Q = null, $ !== 0 && (clearTimeout($), $ = 0);
    }
  }
  function Ft(c) {
    return !c || c.unbound === !0 || !c.first ? null : {
      first: Zi(c.first),
      second: c.second ? Zi(c.second) : null
    };
  }
  function Zi(c) {
    return {
      key: String(c?.key ?? "").toLowerCase(),
      command: c?.command === !0,
      shift: c?.shift === !0,
      option: c?.option === !0,
      control: c?.control === !0
    };
  }
  function $a(c, r) {
    return c && !c.second && yl(c.first, r);
  }
  function sf(c, r) {
    return c && c.second && yl(c.first, r);
  }
  function yl(c, r) {
    return !c || r.metaKey !== c.command || r.ctrlKey !== c.control || r.altKey !== c.option || r.shiftKey !== c.shift ? !1 : Ia(r) === c.key;
  }
  function Ia(c) {
    return c.code === "Space" ? "space" : typeof c.key != "string" || c.key.length === 0 ? "" : (c.key.length === 1, c.key.toLowerCase());
  }
  function Pa(c) {
    const r = c instanceof Element ? c : null;
    return r ? !!r.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function il(c) {
    const r = Math.max(80, Math.floor(ut.clientHeight * 0.38));
    ut.scrollBy({ top: c * r, behavior: "auto" });
  }
  function xa() {
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
      unsafeCSS: Sa(),
      theme: _.theme,
      themeType: "system"
    };
  }
  function Sa() {
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
  function vl() {
    const c = xa();
    if (!O) {
      Vn();
      return;
    }
    O.setOptions(c), Vn(), O.render(!0);
  }
  function Vn() {
    L?.setRenderOptions && L.setRenderOptions(Yi()).then(() => O?.render(!0)).catch((c) => console.warn("cmux diff worker render options update failed", c));
  }
  function Zn(c) {
    m.layout = c === "unified" ? "unified" : "split", ge(), vl();
  }
  function ul(c) {
    m.filesVisible = c, document.body.dataset.filesHidden = c ? "false" : "true", at.setAttribute("aria-hidden", String(!c)), c ? at.removeAttribute("inert") : at.setAttribute("inert", ""), ge();
  }
  function Ki(c) {
    m.fileSearchOpen = !!c, K && (m.fileSearchOpen ? K.openSearch("") : K.closeSearch()), ge();
  }
  function Ji(c) {
    m.collapsed = c;
    const r = s.map((R) => ({
      ...R,
      collapsed: c,
      version: (R.version ?? 0) + 1
    })), x = new Map(r.map((R) => [R.id, R])), U = F.map((R) => x.get(R.id) ?? {
      ...R,
      collapsed: c,
      version: (R.version ?? 0) + 1
    });
    s.splice(0, s.length, ...r), F.splice(0, F.length, ...U), O && (O.setItems(s), O.render(!0)), ge();
  }
  function ge() {
    Rt.setAttribute("aria-pressed", String(m.filesVisible)), Rt.title = m.filesVisible ? Y("hideFiles") : Y("showFiles"), Rt.setAttribute("aria-label", Rt.title), se.title = Y("hideFiles"), se.setAttribute("aria-label", se.title), kt.innerHTML = de(m.layout), kt.title = m.layout === "split" ? Y("switchToUnifiedDiff") : Y("switchToSplitDiff"), kt.setAttribute("aria-label", kt.title), re.setAttribute("aria-expanded", String(!wt.hidden)), document.documentElement.dataset.layout = m.layout, document.documentElement.dataset.wordWrap = String(m.wordWrap), document.documentElement.dataset.diffIndicators = m.diffIndicators, be.disabled = !K, be.setAttribute("aria-pressed", String(m.fileSearchOpen)), be.title = m.fileSearchOpen ? Y("hideFileSearch") : Y("showFileSearch"), be.setAttribute("aria-label", be.title);
  }
  function tn(c) {
    c && Ta(), wt.hidden = !c, ge();
  }
  function Ta() {
    wt.textContent = "";
    const c = [
      { label: Y("refresh"), icon: "refresh", action: () => window.location.reload() },
      { label: m.wordWrap ? Y("disableWordWrap") : Y("enableWordWrap"), icon: "wrap", checked: m.wordWrap, action: () => {
        m.wordWrap = !m.wordWrap, vl();
      } },
      { label: m.collapsed ? Y("expandAllDiffs") : Y("collapseAllDiffs"), icon: "collapse", checked: m.collapsed, action: () => Ji(!m.collapsed) },
      "separator",
      { label: m.filesVisible ? Y("hideFiles") : Y("showFiles"), icon: "files", checked: m.filesVisible, action: () => ul(!m.filesVisible) },
      { label: m.expandUnchanged ? Y("collapseUnchangedContext") : Y("expandUnchangedContext"), icon: "document", checked: m.expandUnchanged, action: () => {
        m.expandUnchanged = !m.expandUnchanged, vl();
      } },
      { label: m.showBackgrounds ? Y("hideBackgrounds") : Y("showBackgrounds"), icon: "background", checked: m.showBackgrounds, action: () => {
        m.showBackgrounds = !m.showBackgrounds, vl();
      } },
      { label: m.lineNumbers ? Y("hideLineNumbers") : Y("showLineNumbers"), icon: "numbers", checked: m.lineNumbers, action: () => {
        m.lineNumbers = !m.lineNumbers, vl();
      } },
      { label: m.wordDiffs ? Y("disableWordDiffs") : Y("enableWordDiffs"), icon: "word", checked: m.wordDiffs, action: () => {
        m.wordDiffs = !m.wordDiffs, vl();
      } },
      { kind: "segment", label: Y("indicatorStyle"), icon: "bars", options: [
        { value: "bars", icon: "bars", label: Y("bars") },
        { value: "classic", icon: "classic", label: Y("classic") },
        { value: "none", icon: "eye", label: Y("none") }
      ] },
      "separator",
      { label: Y("copyGitApplyCommand"), icon: "clipboard", action: ki }
    ];
    for (const r of c) {
      if (r === "separator") {
        const R = document.createElement("div");
        R.className = "menu-separator", wt.append(R);
        continue;
      }
      if (r.kind === "segment") {
        const R = document.createElement("div");
        R.className = "menu-item menu-segment", R.setAttribute("role", "presentation"), R.innerHTML = `${de(r.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
        const w = R.querySelector(".menu-label");
        w && (w.textContent = r.label);
        const Q = R.querySelector(".menu-segment-controls");
        if (!Q)
          continue;
        for (const $ of r.options) {
          const st = document.createElement("button");
          st.type = "button", st.className = "segment-button", st.title = $.label, st.setAttribute("aria-label", $.label), st.setAttribute("aria-pressed", String(m.diffIndicators === $.value)), st.innerHTML = de($.icon), st.addEventListener("click", () => {
            m.diffIndicators = $.value, vl(), Ta(), ge();
          }), Q.append(st);
        }
        wt.append(R);
        continue;
      }
      const x = document.createElement("button");
      x.type = "button", x.className = "menu-item", x.setAttribute("role", r.checked == null ? "menuitem" : "menuitemcheckbox"), r.checked != null && x.setAttribute("aria-checked", String(!!r.checked)), x.disabled = !!r.disabled, x.innerHTML = `${de(r.icon)}<span class="menu-label"></span><span class="menu-check">${r.checked ? de("check") : ""}</span>`;
      const U = x.querySelector(".menu-label");
      U && (U.textContent = r.label), x.addEventListener("click", () => {
        x.disabled || (r.action?.(), Ta(), ge());
      }), wt.append(x);
    }
  }
  function Kn(c) {
    const r = new Set(c.split(/\r?\n/));
    let x = "CMUX_DIFF_PATCH", U = 0;
    for (; r.has(x); )
      U += 1, x = `CMUX_DIFF_PATCH_${U}`;
    return x;
  }
  async function ki() {
    const r = await ba(), x = r.endsWith(`
`) ? r : `${r}
`, U = Kn(x), R = `git apply <<'${U}'
${x}${U}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(R);
      } catch {
        Jn(R);
      }
    else
      Jn(R);
    re.title = Y("copiedGitApplyCommand"), re.setAttribute("aria-label", Y("copiedGitApplyCommand"));
  }
  function Jn(c) {
    const r = document.createElement("textarea");
    r.value = c, r.setAttribute("readonly", ""), r.style.position = "fixed", r.style.left = "-9999px", document.body.append(r), r.select(), document.execCommand("copy"), r.remove();
  }
  function fl(c) {
    if (qe.textContent = Qt(), !Array.isArray(c) || c.length < 2)
      return;
    Xt.textContent = "";
    const r = c.find((x) => x.selected) ?? c.find((x) => !x.disabled);
    for (const x of c) {
      const U = document.createElement("option");
      U.value = x.value, U.textContent = x.label, U.disabled = x.disabled || !x.url, U.selected = x.value === r?.value, x.message && (U.title = x.message), Xt.append(U);
    }
    qe.textContent = r?.sourceLabel ?? Qt(), Xt.hidden = !1, Xt.addEventListener("change", () => {
      const x = c.find((U) => U.value === Xt.value);
      if (!x?.url) {
        Xt.value = r?.value ?? "";
        return;
      }
      Oe(Y("loadingDiff"), { pending: !0 }), window.location.href = x.url;
    });
  }
  function Qt() {
    return [B.sourceLabel, B.repoRoot, B.branchBaseRef].filter((r) => typeof r == "string" && r.trim() !== "").join(" | ");
  }
  function ae(c, r, x, U) {
    if (!c || !Array.isArray(r) || r.length < 2)
      return;
    c.textContent = "";
    const R = r.find((w) => w.selected) ?? r.find((w) => !w.disabled);
    for (const w of r) {
      const Q = document.createElement("option");
      Q.value = w.value, Q.textContent = w.label, Q.disabled = w.disabled || !w.url, Q.selected = w.value === R?.value, w.message && (Q.title = w.message), c.append(Q);
    }
    c.hidden = !1, c.title = U, c.addEventListener("change", () => {
      const w = r.find((Q) => Q.value === c.value);
      if (!w?.url) {
        c.value = R?.value ?? x ?? "";
        return;
      }
      Oe(Y("loadingDiff"), { pending: !0 }), window.location.href = w.url;
    });
  }
  function Xl(c, r) {
    const x = Ql(c), U = Fi(r);
    if (ol(c, []), K && (K.cleanUp?.(), K = null), H = null, m.fileSearchOpen = !1, Bt.textContent = "", De.textContent = `${x}`, Fn(c), U)
      try {
        df(c, r), ge();
        return;
      } catch (w) {
        console.warn("cmux diff file tree setup failed", w);
      }
    const R = za(c);
    ol(c, R), xl(R), ge();
  }
  function kn(c, r) {
    const x = Ql(c);
    if (ol(c, []), De.textContent = `${x}`, Fn(c), K && Bt.dataset.treeMode === "pierre" && r?.preparePresortedFileTreeInput) {
      mf(c, r);
      return;
    }
    if (K || Bt.childElementCount === 0) {
      Xl(c, r);
      return;
    }
    const U = za(c);
    ol(c, U), Bt.textContent = "", xl(U);
  }
  function df(c, r) {
    const { FileTree: x, preparePresortedFileTreeInput: U } = r, R = cl(c);
    H = c;
    const w = R[0];
    bl(c), Bt.dataset.treeMode = "pierre", K = new x({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: w ? [w] : [],
      initialVisibleRowCount: Gt(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: U(R),
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: c.gitStatus,
      renderRowDecoration(Q) {
        if (Q.item.kind !== "file")
          return null;
        const $ = tt.get(Q.item.path);
        return $ == null || $.added === 0 && $.deleted === 0 ? null : {
          text: `+${$.added} -${$.deleted}`,
          title: `${$.added} ${Y("additions")}, ${$.deleted} ${Y("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Wi(),
      onSelectionChange(Q) {
        if (gl)
          return;
        const $ = Q[Q.length - 1], st = Le.get($);
        st && en(st);
      }
    }), K.render({ containerWrapper: Bt });
  }
  function mf(c, r) {
    const x = H, U = cl(c);
    H = c, bl(c);
    let R = !1;
    const w = xg(x, c, U);
    if (w.kind === "append") {
      const Q = w.addedPaths;
      if (Q.length > 0)
        try {
          K.batch(Q.map(($) => ({ type: "add", path: $ })));
        } catch ($) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", $), K.resetPaths(U, {
            preparedInput: r.preparePresortedFileTreeInput(U)
          }), R = !0;
        }
    } else
      K.resetPaths(U, {
        preparedInput: r.preparePresortedFileTreeInput(U)
      }), R = !0;
    c.gitStatusPatch ? typeof K.applyGitStatusPatch == "function" ? K.applyGitStatusPatch(c.gitStatusPatch) : K.setGitStatus(c.gitStatus) : (R || c.statsChanged === !0) && K.setGitStatus(c.gitStatus);
  }
  function Fi(c) {
    return !!(c?.FileTree && c?.preparePresortedFileTreeInput);
  }
  function Ql(c) {
    return c?.pathCount ?? c?.entries?.length ?? 0;
  }
  function za(c) {
    const r = c?.pathCount ?? c?.entries?.length ?? 0, x = c?.entries ?? [];
    if (x.length > 0)
      return x.length === r ? x : x.slice(0, r);
    const U = cl(c), R = c?.pathToItemId, w = c?.statsByPath;
    return U.map((Q) => {
      const $ = R instanceof Map ? R.get(Q) : void 0, st = $ ? M.get($) : void 0, ht = st?.fileDiff ?? {};
      return {
        item: st ?? { id: $ ?? Q, fileDiff: ht },
        path: Q,
        status: Ii(ht),
        stats: w instanceof Map ? w.get(Q) ?? zl(ht) : zl(ht)
      };
    });
  }
  function cl(c) {
    const r = c?.pathCount ?? c?.paths?.length ?? 0, x = c?.paths ?? [];
    return x.length === r ? x : x.slice(0, r);
  }
  function bl(c) {
    if (c?.statsByPath instanceof Map) {
      tt = c.statsByPath;
      return;
    }
    tt = /* @__PURE__ */ new Map();
    const r = za(c);
    for (const x of r)
      tt.set(x.path, x.stats);
  }
  function ol(c, r) {
    if (c?.pathToItemId instanceof Map && c?.treePathByItemId instanceof Map)
      Le = c.pathToItemId, al = c.treePathByItemId;
    else if (c?.pathToItemId instanceof Map) {
      Le = c.pathToItemId, al = /* @__PURE__ */ new Map();
      for (const [x, U] of Le)
        al.set(U, x);
    } else {
      Le = /* @__PURE__ */ new Map(), al = /* @__PURE__ */ new Map();
      for (const x of r) {
        const U = x.item?.id;
        U && (Le.set(x.path, U), al.set(U, x.path));
      }
    }
    Tt && !Le.has(Tt) && (Tt = "");
  }
  function xl(c) {
    delete Bt.dataset.treeMode;
    for (const r of c) {
      const x = r.item, U = x.fileDiff ?? {}, R = r.stats ?? zl(U), w = document.createElement("button");
      w.type = "button", w.className = "file-entry", w.dataset.itemId = x.id, w.title = pe(U), w.innerHTML = `
      <span class="file-status">${xe(U)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${R.added}</span>
        <span class="stat-del">-${R.deleted}</span>
      </span>
    `;
      const Q = w.querySelector(".file-name");
      Q && (Q.textContent = pe(U)), w.addEventListener("click", () => en(x.id)), Bt.append(w);
    }
  }
  function Gt() {
    const c = window.visualViewport?.height ?? window.innerHeight;
    return !Number.isFinite(c) || c <= 0 ? 25 : Math.min(96, Math.max(25, Math.ceil(c / 24)));
  }
  function Wi() {
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
  function Fn(c) {
    const r = c?.diffStats;
    if (r && Number.isFinite(r.addedLines) && Number.isFinite(r.deletedLines) && Number.isFinite(r.fileCount)) {
      ee.textContent = `${r.fileCount}`, ll.textContent = `+${r.addedLines}`, Ye.textContent = `-${r.deletedLines}`;
      return;
    }
    Sl(c?.entries ?? []);
  }
  function Sl(c) {
    const r = c.reduce((x, U) => {
      const R = U.stats ?? zl(U.item?.fileDiff ?? {});
      return x.added += R.added, x.deleted += R.deleted, x;
    }, { added: 0, deleted: 0 });
    ee.textContent = `${c.length}`, ll.textContent = `+${r.added}`, Ye.textContent = `-${r.deleted}`;
  }
  function Tl(c) {
    St.textContent = "";
    const r = document.createElement("option");
    r.value = "", r.textContent = Y("jumpToFile"), St.append(r), St.dataset.initialized = "true";
    for (const x of c) {
      const U = document.createElement("option");
      U.value = x.id, U.textContent = pe(x.fileDiff ?? {}), St.append(U);
    }
    St.hidden = c.length === 0, St.onchange = () => {
      St.value && en(St.value);
    };
  }
  function hf(c) {
    if (c.length === 0)
      return;
    St.dataset.initialized !== "true" && Tl([]);
    const r = document.createDocumentFragment();
    for (const x of c) {
      const U = document.createElement("option");
      U.value = x.id, U.textContent = pe(x.fileDiff ?? {}), r.append(U);
    }
    St.append(r), St.hidden = !1;
  }
  function $i(c, r) {
    if (St.dataset.initialized === "true") {
      for (const x of St.options)
        if (x.value === c) {
          x.value = r;
          return;
        }
    }
  }
  function en(c) {
    if (!O)
      return;
    const r = gf(c);
    r && (O.scrollTo({ type: "item", id: r, align: "start", behavior: "smooth-auto" }), Ma(r));
  }
  function gf(c) {
    if (N.has(c))
      return c;
    const r = F.findIndex((x) => x.id === c);
    if (r === -1)
      return s[0]?.id ?? "";
    for (let x = r + 1; x < F.length; x += 1)
      if (N.has(F[x].id))
        return F[x].id;
    for (let x = r - 1; x >= 0; x -= 1)
      if (N.has(F[x].id))
        return F[x].id;
    return "";
  }
  function Ma(c) {
    if (!(!c || $t === c)) {
      $t = c, ln(c);
      for (const r of Bt.querySelectorAll(".file-entry"))
        r.setAttribute("aria-current", r.dataset.itemId === c ? "true" : "false");
      St.value !== c && (St.value = c);
    }
  }
  function ln(c) {
    if (!K)
      return;
    const r = al.get(c);
    if (!(!r || r === Tt)) {
      gl = !0;
      try {
        Tt && K.getItem(Tt)?.deselect(), K.getItem(r)?.select(), K.scrollToPath(r, { focus: !1, offset: "nearest" }), Tt = r;
      } finally {
        Gn(() => {
          gl = !1;
        });
      }
    }
  }
  function pe(c) {
    return c.name ?? c.newName ?? c.oldName ?? c.prevName ?? Y("untitled");
  }
  function xe(c) {
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
  function Ii(c) {
    return Pi(c.type);
  }
  function Pi(c) {
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
  function zl(c) {
    const r = { added: 0, deleted: 0 };
    for (const x of c.hunks ?? [])
      r.added += x.additionLines ?? 0, r.deleted += x.deletionLines ?? 0;
    return r;
  }
  function tu(c, r) {
    return c?.added === r.added && c?.deleted === r.deleted;
  }
  function de(c) {
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
  function an(c, r) {
    c(r.name, () => Promise.resolve(Wn(r)));
  }
  function Se(c, r, x, U) {
    const R = Array.from(new Set([
      c.theme?.light,
      c.theme?.dark
    ].filter(Boolean))), w = Array.from(new Set(r.flatMap((Q) => {
      const $ = Q.fileDiff ?? {}, st = $.name ?? $.newName ?? $.oldName ?? $.prevName ?? "", ht = $.lang ?? x(st) ?? "text";
      return ht ? [ht] : [];
    })));
    return U({
      themes: R,
      langs: w.length > 0 ? w : ["text"]
    });
  }
  function Wn(c) {
    const r = c.palette ?? {}, x = c.foreground, U = yg(c.background, _);
    return {
      name: c.name,
      displayName: c.ghosttyName,
      type: c.type,
      colors: {
        "editor.background": U,
        "editor.foreground": x,
        "terminal.background": U,
        "terminal.foreground": x,
        "terminal.ansiBlack": r[0] ?? x,
        "terminal.ansiRed": r[1] ?? x,
        "terminal.ansiGreen": r[2] ?? x,
        "terminal.ansiYellow": r[3] ?? x,
        "terminal.ansiBlue": r[4] ?? x,
        "terminal.ansiMagenta": r[5] ?? x,
        "terminal.ansiCyan": r[6] ?? x,
        "terminal.ansiWhite": r[7] ?? x,
        "terminal.ansiBrightBlack": r[8] ?? x,
        "terminal.ansiBrightRed": r[9] ?? r[1] ?? x,
        "terminal.ansiBrightGreen": r[10] ?? r[2] ?? x,
        "terminal.ansiBrightYellow": r[11] ?? r[3] ?? x,
        "terminal.ansiBrightBlue": r[12] ?? r[4] ?? x,
        "terminal.ansiBrightMagenta": r[13] ?? r[5] ?? x,
        "terminal.ansiBrightCyan": r[14] ?? r[6] ?? x,
        "terminal.ansiBrightWhite": r[15] ?? x,
        "gitDecoration.addedResourceForeground": r[10] ?? r[2] ?? "#32d74b",
        "gitDecoration.deletedResourceForeground": r[9] ?? r[1] ?? "#ff453a",
        "gitDecoration.modifiedResourceForeground": r[12] ?? r[4] ?? "#0a84ff",
        "editor.selectionBackground": c.selectionBackground,
        "editor.selectionForeground": c.selectionForeground
      },
      tokenColors: [
        { settings: { foreground: x, background: U } },
        { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: r[8] ?? x, fontStyle: "italic" } },
        { scope: ["string", "constant.other.symbol"], settings: { foreground: r[2] ?? x } },
        { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: r[3] ?? x } },
        { scope: ["keyword", "storage", "storage.type"], settings: { foreground: r[5] ?? x } },
        { scope: ["entity.name.function", "support.function"], settings: { foreground: r[4] ?? x } },
        { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: r[6] ?? x } },
        { scope: ["variable", "meta.definition.variable"], settings: { foreground: x } },
        { scope: ["invalid", "message.error"], settings: { foreground: r[9] ?? r[1] ?? x } }
      ]
    };
  }
}
const zg = ["82%", "64%", "76%", "58%", "70%", "46%"], Mg = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
function Eg() {
  return /* @__PURE__ */ X.jsx("div", { className: "diff-loading-placeholder", "aria-hidden": "true", children: zg.map((v, D) => /* @__PURE__ */ X.jsxs("div", { className: "grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]", children: [
    /* @__PURE__ */ X.jsx("span", { className: "size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ X.jsx("span", { className: "h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: v } }),
    /* @__PURE__ */ X.jsx("span", { className: "h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: { width: D % 2 === 0 ? "34px" : "24px" } })
  ] }, `${v}-${D}`)) });
}
function Ag() {
  return /* @__PURE__ */ X.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    /* @__PURE__ */ X.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
      /* @__PURE__ */ X.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ X.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ X.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
    ] }),
    /* @__PURE__ */ X.jsx("div", { className: "space-y-[13px] px-3 py-1", children: Mg.map((v, D) => /* @__PURE__ */ X.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
      /* @__PURE__ */ X.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
      /* @__PURE__ */ X.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: v } })
    ] }, `${v}-${D}`)) })
  ] });
}
function _g({ config: v, label: D }) {
  return /* @__PURE__ */ X.jsxs("div", { id: "loading-layer", "aria-live": "polite", children: [
    /* @__PURE__ */ X.jsx("div", { id: "status", children: v.payload?.statusMessage ?? D("loadingDiff") }),
    /* @__PURE__ */ X.jsx(Ag, {})
  ] });
}
function Dg({ label: v }) {
  return /* @__PURE__ */ X.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    /* @__PURE__ */ X.jsx("select", { id: "source-select", "aria-label": v("diffTarget"), hidden: !0 }),
    /* @__PURE__ */ X.jsx("select", { id: "repo-select", "aria-label": v("repoPath"), hidden: !0 }),
    /* @__PURE__ */ X.jsx("select", { id: "base-select", "aria-label": v("branchBase"), hidden: !0 }),
    /* @__PURE__ */ X.jsx("span", { id: "source-detail" })
  ] });
}
function Og({ config: v, label: D }) {
  return /* @__PURE__ */ X.jsxs("header", { id: "toolbar", children: [
    /* @__PURE__ */ X.jsx(Dg, { config: v, label: D }),
    /* @__PURE__ */ X.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ X.jsx("select", { id: "jump-select", "aria-label": D("jumpToFile"), hidden: !0 }) }),
    /* @__PURE__ */ X.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
      /* @__PURE__ */ X.jsx(
        "a",
        {
          id: "external-link",
          className: "toolbar-icon",
          href: v.payload?.externalURL ?? "#",
          target: "_blank",
          rel: "noreferrer",
          title: D("openSourceURL"),
          "aria-label": D("openSourceURL"),
          hidden: !0
        }
      ),
      /* @__PURE__ */ X.jsx(
        "button",
        {
          id: "files-toggle",
          className: "toolbar-icon",
          type: "button",
          title: D("hideFiles"),
          "aria-label": D("hideFiles"),
          "aria-pressed": "true"
        }
      ),
      /* @__PURE__ */ X.jsx(
        "button",
        {
          id: "layout-toggle",
          className: "toolbar-icon",
          type: "button",
          title: D("switchToUnifiedDiff"),
          "aria-label": D("switchToUnifiedDiff")
        }
      ),
      /* @__PURE__ */ X.jsx(
        "button",
        {
          id: "options-button",
          className: "toolbar-icon",
          type: "button",
          title: D("options"),
          "aria-label": D("options"),
          "aria-expanded": "false",
          "aria-haspopup": "menu"
        }
      )
    ] }),
    /* @__PURE__ */ X.jsx("div", { id: "options-menu", role: "menu", "aria-label": D("options"), hidden: !0 })
  ] });
}
function Cg({ label: v }) {
  return /* @__PURE__ */ X.jsxs("aside", { id: "files-sidebar", "aria-label": v("changedFiles"), children: [
    /* @__PURE__ */ X.jsxs("div", { id: "files-header", children: [
      /* @__PURE__ */ X.jsxs("span", { id: "files-title", children: [
        /* @__PURE__ */ X.jsx("span", { children: v("files") }),
        /* @__PURE__ */ X.jsx("span", { id: "files-count" })
      ] }),
      /* @__PURE__ */ X.jsxs("span", { id: "files-header-actions", children: [
        /* @__PURE__ */ X.jsx(
          "button",
          {
            id: "file-search-toggle",
            type: "button",
            title: v("showFileSearch"),
            "aria-label": v("showFileSearch"),
            "aria-pressed": "false"
          }
        ),
        /* @__PURE__ */ X.jsx(
          "button",
          {
            id: "file-collapse-toggle",
            type: "button",
            title: v("hideFiles"),
            "aria-label": v("hideFiles")
          }
        )
      ] })
    ] }),
    /* @__PURE__ */ X.jsx("div", { id: "file-list", children: /* @__PURE__ */ X.jsx(Eg, {}) }),
    /* @__PURE__ */ X.jsxs("div", { id: "files-footer", "aria-label": v("diffStats"), children: [
      /* @__PURE__ */ X.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ X.jsx("span", { children: v("files") }),
        /* @__PURE__ */ X.jsx("strong", { id: "stats-files", children: "0" })
      ] }),
      /* @__PURE__ */ X.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ X.jsx("span", { children: v("additions") }),
        /* @__PURE__ */ X.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" })
      ] }),
      /* @__PURE__ */ X.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ X.jsx("span", { children: v("deletions") }),
        /* @__PURE__ */ X.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" })
      ] })
    ] })
  ] });
}
function Ug({ config: v }) {
  const D = im.useRef(!1), q = cm(v.payload?.labels, {
    assertMissing: fm()
  }), g = im.useCallback((nt) => {
    !nt || D.current || (D.current = !0, Tg(v));
  }, [v]);
  return /* @__PURE__ */ X.jsxs("div", { id: "app", ref: g, children: [
    /* @__PURE__ */ X.jsx(Og, { config: v, label: q }),
    /* @__PURE__ */ X.jsxs("section", { id: "content", children: [
      /* @__PURE__ */ X.jsx(Cg, { config: v, label: q }),
      /* @__PURE__ */ X.jsx("main", { id: "viewer", "aria-label": q("diffViewer"), children: /* @__PURE__ */ X.jsx(_g, { config: v, label: q }) })
    ] })
  ] });
}
const Bg = '@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-space-y-reverse:0;--tw-border-style:solid}}}@layer theme{:root,:host{--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--spacing:.25rem;--radius-md:.375rem;--default-font-family:var(--font-sans);--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab,red,red)){::placeholder{color:color-mix(in oklab,currentcolor 50%,transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}}@layer components;@layer utilities{.\\@container{container-type:inline-size}.collapse{visibility:collapse}.visible{visibility:visible}.fixed{position:fixed}.static{position:static}.mx-3\\.5{margin-inline:calc(var(--spacing) * 3.5)}.mt-3\\.5{margin-top:calc(var(--spacing) * 3.5)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.flex{display:flex}.grid{display:grid}.hidden{display:none}.size-4{width:calc(var(--spacing) * 4);height:calc(var(--spacing) * 4)}.h-3{height:calc(var(--spacing) * 3)}.h-6{height:calc(var(--spacing) * 6)}.h-9{height:calc(var(--spacing) * 9)}.h-\\[11px\\]{height:11px}.h-px{height:1px}.w-2\\/5{width:40%}.min-w-0{min-width:calc(var(--spacing) * 0)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.grid-cols-\\[16px_minmax\\(0\\,1fr\\)_44px\\]{grid-template-columns:16px minmax(0,1fr) 44px}.grid-cols-\\[42px_minmax\\(0\\,1fr\\)\\]{grid-template-columns:42px minmax(0,1fr)}.grid-cols-\\[72px_minmax\\(0\\,1fr\\)_96px\\]{grid-template-columns:72px minmax(0,1fr) 96px}.items-center{align-items:center}.justify-center{justify-content:center}.gap-1\\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}:where(.space-y-\\[13px\\]>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(13px * var(--tw-space-y-reverse));margin-block-end:calc(13px * calc(1 - var(--tw-space-y-reverse)))}.justify-self-end{justify-self:flex-end}.rounded{border-radius:.25rem}.rounded-\\[5px\\]{border-radius:5px}.rounded-md{border-radius:var(--radius-md)}.border{border-style:var(--tw-border-style);border-width:1px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:color-mix(in lab,var(--cmux-diff-fg) 18%,transparent)}}.border-\\[var\\(--cmux-diff-border\\)\\]{border-color:var(--cmux-diff-border)}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.bg-\\[var\\(--cmux-diff-muted-bg\\)\\]{background-color:var(--cmux-diff-muted-bg)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-\\[7px\\]{padding-inline:7px}.py-1{padding-block:calc(var(--spacing) * 1)}.pt-3{padding-top:calc(var(--spacing) * 3)}.italic{font-style:italic}.opacity-70{opacity:.7}}:root{color-scheme:light dark;--cmux-diff-bg-opacity:1;--cmux-diff-bg-opacity-percent:100%;--cmux-diff-bg-base-light:#fff;--cmux-diff-bg-base-dark:#000;--cmux-diff-bg-light:#fff;--cmux-diff-bg-dark:#000;--cmux-diff-fg-light:#000;--cmux-diff-fg-dark:#fff;--cmux-diff-selection-bg-light:#abd8ff;--cmux-diff-selection-bg-dark:#3f638b;--cmux-diff-ui-font-family:system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size:12px;--cmux-diff-ui-line-height:16px;--cmux-diff-code-font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size:10px;--cmux-diff-line-height:20px;--cmux-diff-bg:var(--cmux-diff-bg-light);--cmux-diff-fg:var(--cmux-diff-fg-light);--cmux-diff-border:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-border:color-mix(in lab, var(--cmux-diff-fg) 12%, transparent)}}:root{--cmux-diff-sidebar-bg:transparent;--cmux-diff-muted-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-muted-bg:color-mix(in lab, var(--cmux-diff-fg) 8%, transparent)}}:root{--cmux-diff-hover-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-hover-bg:color-mix(in lab, var(--cmux-diff-fg) 10%, transparent)}}:root{--cmux-diff-accent:light-dark(#0a84ff,#7ab7ff);color:var(--cmux-diff-fg);background:0 0}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg:var(--cmux-diff-bg-dark);--cmux-diff-fg:var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{background:0 0;height:100%;overflow:hidden}body{background:var(--cmux-diff-bg);height:100vh;min-height:0;color:var(--cmux-diff-fg);font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height);flex-direction:column;margin:0;display:flex;overflow:hidden}#root{background:0 0;height:100%;min-height:0}#app{overscroll-behavior:contain;contain:strict;height:100vh;min-height:0;color:inherit;background:0 0;grid-template-rows:auto minmax(0,1fr);display:grid;overflow:hidden}#toolbar{border-bottom:1px solid var(--cmux-diff-fg);flex:none;align-items:center;gap:7px;min-height:32px;padding:3px 8px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#toolbar{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}#toolbar{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#toolbar{color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg))}}#toolbar{z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{align-items:center;gap:6px;min-width:0;display:flex}.toolbar-left{flex:0 36%}.toolbar-middle{flex:auto;justify-content:center}.toolbar-actions{flex:none}#source-select,#repo-select,#base-select,#jump-select{appearance:none;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,var(--cmux-diff-fg);border:1px solid #0000;border-radius:6px;min-width:118px;max-width:min(30vw,320px);height:24px;padding:0 24px 0 9px}@supports (color:color-mix(in lab,red,red)){#source-select,#repo-select,#base-select,#jump-select{background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent)}}#source-select,#repo-select,#base-select,#jump-select{color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent)}}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent)}}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline-offset:1px}#source-detail{text-overflow:ellipsis;white-space:nowrap;min-width:0;color:var(--cmux-diff-fg);overflow:hidden}@supports (color:color-mix(in lab,red,red)){#source-detail{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}.toolbar-icon{width:28px;height:26px;color:var(--cmux-diff-fg);background:0 0;border:1px solid #0000;border-radius:6px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.toolbar-icon{color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg))}}.toolbar-icon{cursor:pointer;padding:0}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true],.toolbar-icon[aria-pressed=true]{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:16px;height:16px;display:block}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{border:1px solid var(--cmux-diff-fg);min-width:246px;padding:8px;position:absolute;top:calc(100% + 7px);right:10px}@supports (color:color-mix(in lab,red,red)){#options-menu{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent)}}#options-menu{background:var(--cmux-diff-bg);z-index:100;border-radius:8px;box-shadow:0 16px 34px lab(0% none none/.28)}#options-menu[hidden]{display:none}.menu-separator{background:var(--cmux-diff-fg);height:1px;margin:7px 6px}@supports (color:color-mix(in lab,red,red)){.menu-separator{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.menu-item{width:100%;min-height:31px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:6px;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;display:grid}@supports (color:color-mix(in lab,red,red)){.menu-item{color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg))}}.menu-item{font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.menu-item:hover:not(:disabled){color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:0 0}.menu-segment-controls{background:0 0;border-radius:7px;justify-self:end;align-items:center;gap:2px;padding:2px;display:inline-flex}.segment-button{width:27px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.segment-button{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.segment-button{padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.segment-button:hover,.segment-button[aria-pressed=true],.menu-item:disabled{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}}.menu-label{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.menu-check{justify-self:end}#content{--cmux-diff-files-width:clamp(190px, 22vw, 252px);grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);overscroll-behavior:contain;contain:strict;background:0 0;flex:auto;grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";min-width:0;min-height:0;display:grid;position:relative;overflow:hidden}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{border-left:1px solid var(--cmux-diff-border);contain:strict;opacity:1;background:0 0;flex-direction:column;grid-area:files;width:100%;min-width:0;height:100%;min-height:0;transition:opacity .1s,visibility linear;display:flex;position:relative;overflow:hidden}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s,visibility 0s linear .1s}body[data-status-only=true] #files-sidebar{display:none}#files-header{z-index:1;border-bottom:1px solid var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:8px;min-height:30px;padding:0 7px 0 10px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#files-header{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-header{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#files-header{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}#files-title{align-items:center;gap:6px;min-width:0;display:inline-flex}#files-header-actions{flex:none;align-items:center;gap:2px;display:inline-flex}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;flex:none;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){#file-search-toggle,#file-collapse-toggle{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}#file-search-toggle,#file-collapse-toggle{padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:15px;height:15px}#file-list{--trees-bg-override:var(--cmux-diff-sidebar-bg);--trees-fg-override:var(--cmux-diff-fg);flex:auto;min-height:0;padding:6px 4px 6px 6px;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-override:color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg))}}#file-list{--trees-fg-muted-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-muted-override:color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg))}}#file-list{--trees-bg-muted-override:var(--cmux-diff-hover-bg);--trees-selected-bg-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-selected-bg-override:color-mix(in lab, var(--cmux-diff-fg) 11%, transparent)}}#file-list{--trees-selected-fg-override:var(--cmux-diff-fg);--trees-selected-focused-border-color-override:transparent;--trees-border-color-override:var(--cmux-diff-border);--trees-focus-ring-color-override:var(--cmux-diff-accent)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-focus-ring-color-override:color-mix(in lab, var(--cmux-diff-accent) 72%, transparent)}}#file-list{--trees-font-family-override:var(--cmux-diff-ui-font-family);--trees-font-size-override:var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override:500;--trees-density-override:.78;--trees-border-radius-override:5px;--trees-item-padding-x-override:7px;--trees-item-margin-x-override:0;--trees-padding-inline-override:0;--trees-search-bg-override:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-search-bg-override:color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))}}#file-list{--trees-status-added-override:light-dark(#257a3e,#8fd88f);--trees-status-modified-override:var(--cmux-diff-accent);--trees-status-renamed-override:light-dark(#a26300,#ffd166);--trees-status-deleted-override:light-dark(#b42318,#ff8a80)}body[data-loading=false] .diff-loading-placeholder,body[data-loading=false]:not([data-status-only=true]) #loading-layer{display:none}body[data-loading=true] #viewer diffs-container{visibility:hidden}#file-list file-tree-container{width:100%;height:100%}#files-footer{border-top:1px solid var(--cmux-diff-fg);flex:none;padding:7px 10px 8px}@supports (color:color-mix(in lab,red,red)){#files-footer{border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-footer{background:0 0}.stats-row{min-height:19px;color:var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:10px;display:flex}@supports (color:color-mix(in lab,red,red)){.stats-row{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}.stats-row strong{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg))}}.stats-row strong{font-weight:600}.file-entry{width:100%;min-height:30px;color:inherit;font:inherit;text-align:left;background:0 0;border:0;border-radius:6px;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;padding:3px 7px;display:grid}.file-entry:hover,.file-entry[aria-current=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.file-status{width:17px;height:17px;color:var(--cmux-diff-fg);border:1px solid;border-radius:5px;justify-content:center;align-items:center;font-size:9px;line-height:1;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-status{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.file-name{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.file-stats{color:var(--cmux-diff-fg);gap:5px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-stats{color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));overscroll-behavior:contain;overflow-anchor:none;contain:strict;border-bottom:1px solid var(--cmux-diff-border);background:0 0;grid-area:viewer;width:100%;min-width:0;height:100%;min-height:0;position:relative;overflow:clip auto}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border);display:block;overflow:clip}#loading-layer{z-index:4;pointer-events:none;contain:strict;background:0 0;position:absolute;inset:0;overflow:hidden}body[data-status-only=true] #loading-layer{pointer-events:auto;width:100%;height:100%;display:flex;position:static}#status{z-index:5;border:1px solid var(--cmux-diff-fg);align-items:center;gap:10px;max-width:calc(100% - 24px);min-height:32px;padding:8px 12px;display:flex;position:absolute;top:10px;left:12px}@supports (color:color-mix(in lab,red,red)){#status{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#status{background:var(--cmux-diff-bg);font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:var(--cmux-diff-fg);border-radius:7px}@supports (color:color-mix(in lab,red,red)){#status{color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}body[data-status-only=true] #status{border:0;border-bottom:1px solid var(--cmux-diff-fg);width:100%;max-width:none;min-height:40px;position:static}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}body[data-status-only=true] #status{border-radius:0;padding:10px 14px}#status[data-pending=true]:before,body[data-loading=true] #status:before{content:"";border:2px solid var(--cmux-diff-fg);flex:none;width:14px;height:14px}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent)}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-radius:50%;animation:.8s linear infinite cmuxDiffPendingSpin}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before,body[data-loading=true] #status:before{animation:none}}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}';
function Ng() {
  const v = document.getElementById("cmux-diff-viewer-config");
  if (!v?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(v.textContent);
}
function Rg() {
  const v = document.createElement("style");
  v.dataset.cmuxDiffViewerStyle = "true", v.textContent = Bg, document.head.append(v);
}
const Ll = Ng();
Rg();
rm(om(Ll.payload?.appearance));
typeof Ll.payload?.title == "string" && Ll.payload.title.trim() !== "" && (document.title = Ll.payload.title);
document.body.dataset.filesHidden = "false";
document.body.dataset.loading = Ll.payload?.pendingReplacement || !Ll.payload?.statusMessage ? "true" : "false";
document.body.dataset.statusOnly = Ll.payload?.statusMessage && !Ll.payload.pendingReplacement ? "true" : "false";
const dm = document.getElementById("root");
if (!dm)
  throw new Error("Missing cmux diff viewer root");
mg.createRoot(dm).render(/* @__PURE__ */ X.jsx(Ug, { config: Ll }));
