var vo = { exports: {} }, Yi = {};
var Id;
function ug() {
  if (Id) return Yi;
  Id = 1;
  var S = /* @__PURE__ */ Symbol.for("react.transitional.element"), f = /* @__PURE__ */ Symbol.for("react.fragment");
  function D(s, G, k) {
    var Q = null;
    if (k !== void 0 && (Q = "" + k), G.key !== void 0 && (Q = "" + G.key), "key" in G) {
      k = {};
      for (var lt in G)
        lt !== "key" && (k[lt] = G[lt]);
    } else k = G;
    return G = k.ref, {
      $$typeof: S,
      type: s,
      key: Q,
      ref: G !== void 0 ? G : null,
      props: k
    };
  }
  return Yi.Fragment = f, Yi.jsx = D, Yi.jsxs = D, Yi;
}
var Pd;
function fg() {
  return Pd || (Pd = 1, vo.exports = ug()), vo.exports;
}
var J = fg(), bo = { exports: {} }, Li = {}, xo = { exports: {} }, So = {};
var tm;
function cg() {
  return tm || (tm = 1, (function(S) {
    function f(g, U) {
      var Z = g.length;
      g.push(U);
      t: for (; 0 < Z; ) {
        var W = Z - 1 >>> 1, et = g[W];
        if (0 < G(et, U))
          g[W] = U, g[Z] = et, Z = W;
        else break t;
      }
    }
    function D(g) {
      return g.length === 0 ? null : g[0];
    }
    function s(g) {
      if (g.length === 0) return null;
      var U = g[0], Z = g.pop();
      if (Z !== U) {
        g[0] = Z;
        t: for (var W = 0, et = g.length, m = et >>> 1; W < m; ) {
          var A = 2 * (W + 1) - 1, N = g[A], j = A + 1, at = g[j];
          if (0 > G(N, Z))
            j < et && 0 > G(at, N) ? (g[W] = at, g[j] = Z, W = j) : (g[W] = N, g[A] = Z, W = A);
          else if (j < et && 0 > G(at, Z))
            g[W] = at, g[j] = Z, W = j;
          else break t;
        }
      }
      return U;
    }
    function G(g, U) {
      var Z = g.sortIndex - U.sortIndex;
      return Z !== 0 ? Z : g.id - U.id;
    }
    if (S.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var k = performance;
      S.unstable_now = function() {
        return k.now();
      };
    } else {
      var Q = Date, lt = Q.now();
      S.unstable_now = function() {
        return Q.now() - lt;
      };
    }
    var C = [], z = [], L = 1, w = null, tt = 3, rt = !1, dt = !1, yt = !1, Gt = !1, ut = typeof setTimeout == "function" ? setTimeout : null, Yt = typeof clearTimeout == "function" ? clearTimeout : null, mt = typeof setImmediate < "u" ? setImmediate : null;
    function _t(g) {
      for (var U = D(z); U !== null; ) {
        if (U.callback === null) s(z);
        else if (U.startTime <= g)
          s(z), U.sortIndex = U.expirationTime, f(C, U);
        else break;
        U = D(z);
      }
    }
    function Ct(g) {
      if (yt = !1, _t(g), !dt)
        if (D(C) !== null)
          dt = !0, ht || (ht = !0, Zt());
        else {
          var U = D(z);
          U !== null && X(Ct, U.startTime - g);
        }
    }
    var ht = !1, $ = -1, Ut = 5, Pt = -1;
    function Ft() {
      return Gt ? !0 : !(S.unstable_now() - Pt < Ut);
    }
    function Vt() {
      if (Gt = !1, ht) {
        var g = S.unstable_now();
        Pt = g;
        var U = !0;
        try {
          t: {
            dt = !1, yt && (yt = !1, Yt($), $ = -1), rt = !0;
            var Z = tt;
            try {
              e: {
                for (_t(g), w = D(C); w !== null && !(w.expirationTime > g && Ft()); ) {
                  var W = w.callback;
                  if (typeof W == "function") {
                    w.callback = null, tt = w.priorityLevel;
                    var et = W(
                      w.expirationTime <= g
                    );
                    if (g = S.unstable_now(), typeof et == "function") {
                      w.callback = et, _t(g), U = !0;
                      break e;
                    }
                    w === D(C) && s(C), _t(g);
                  } else s(C);
                  w = D(C);
                }
                if (w !== null) U = !0;
                else {
                  var m = D(z);
                  m !== null && X(
                    Ct,
                    m.startTime - g
                  ), U = !1;
                }
              }
              break t;
            } finally {
              w = null, tt = Z, rt = !1;
            }
            U = void 0;
          }
        } finally {
          U ? Zt() : ht = !1;
        }
      }
    }
    var Zt;
    if (typeof mt == "function")
      Zt = function() {
        mt(Vt);
      };
    else if (typeof MessageChannel < "u") {
      var de = new MessageChannel(), ie = de.port2;
      de.port1.onmessage = Vt, Zt = function() {
        ie.postMessage(null);
      };
    } else
      Zt = function() {
        ut(Vt, 0);
      };
    function X(g, U) {
      $ = ut(function() {
        g(S.unstable_now());
      }, U);
    }
    S.unstable_IdlePriority = 5, S.unstable_ImmediatePriority = 1, S.unstable_LowPriority = 4, S.unstable_NormalPriority = 3, S.unstable_Profiling = null, S.unstable_UserBlockingPriority = 2, S.unstable_cancelCallback = function(g) {
      g.callback = null;
    }, S.unstable_forceFrameRate = function(g) {
      0 > g || 125 < g ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : Ut = 0 < g ? Math.floor(1e3 / g) : 5;
    }, S.unstable_getCurrentPriorityLevel = function() {
      return tt;
    }, S.unstable_next = function(g) {
      switch (tt) {
        case 1:
        case 2:
        case 3:
          var U = 3;
          break;
        default:
          U = tt;
      }
      var Z = tt;
      tt = U;
      try {
        return g();
      } finally {
        tt = Z;
      }
    }, S.unstable_requestPaint = function() {
      Gt = !0;
    }, S.unstable_runWithPriority = function(g, U) {
      switch (g) {
        case 1:
        case 2:
        case 3:
        case 4:
        case 5:
          break;
        default:
          g = 3;
      }
      var Z = tt;
      tt = g;
      try {
        return U();
      } finally {
        tt = Z;
      }
    }, S.unstable_scheduleCallback = function(g, U, Z) {
      var W = S.unstable_now();
      switch (typeof Z == "object" && Z !== null ? (Z = Z.delay, Z = typeof Z == "number" && 0 < Z ? W + Z : W) : Z = W, g) {
        case 1:
          var et = -1;
          break;
        case 2:
          et = 250;
          break;
        case 5:
          et = 1073741823;
          break;
        case 4:
          et = 1e4;
          break;
        default:
          et = 5e3;
      }
      return et = Z + et, g = {
        id: L++,
        callback: U,
        priorityLevel: g,
        startTime: Z,
        expirationTime: et,
        sortIndex: -1
      }, Z > W ? (g.sortIndex = Z, f(z, g), D(C) === null && g === D(z) && (yt ? (Yt($), $ = -1) : yt = !0, X(Ct, Z - W))) : (g.sortIndex = et, f(C, g), dt || rt || (dt = !0, ht || (ht = !0, Zt()))), g;
    }, S.unstable_shouldYield = Ft, S.unstable_wrapCallback = function(g) {
      var U = tt;
      return function() {
        var Z = tt;
        tt = U;
        try {
          return g.apply(this, arguments);
        } finally {
          tt = Z;
        }
      };
    };
  })(So)), So;
}
var em;
function og() {
  return em || (em = 1, xo.exports = cg()), xo.exports;
}
var To = { exports: {} }, it = {};
var lm;
function rg() {
  if (lm) return it;
  lm = 1;
  var S = /* @__PURE__ */ Symbol.for("react.transitional.element"), f = /* @__PURE__ */ Symbol.for("react.portal"), D = /* @__PURE__ */ Symbol.for("react.fragment"), s = /* @__PURE__ */ Symbol.for("react.strict_mode"), G = /* @__PURE__ */ Symbol.for("react.profiler"), k = /* @__PURE__ */ Symbol.for("react.consumer"), Q = /* @__PURE__ */ Symbol.for("react.context"), lt = /* @__PURE__ */ Symbol.for("react.forward_ref"), C = /* @__PURE__ */ Symbol.for("react.suspense"), z = /* @__PURE__ */ Symbol.for("react.memo"), L = /* @__PURE__ */ Symbol.for("react.lazy"), w = /* @__PURE__ */ Symbol.for("react.activity"), tt = Symbol.iterator;
  function rt(m) {
    return m === null || typeof m != "object" ? null : (m = tt && m[tt] || m["@@iterator"], typeof m == "function" ? m : null);
  }
  var dt = {
    isMounted: function() {
      return !1;
    },
    enqueueForceUpdate: function() {
    },
    enqueueReplaceState: function() {
    },
    enqueueSetState: function() {
    }
  }, yt = Object.assign, Gt = {};
  function ut(m, A, N) {
    this.props = m, this.context = A, this.refs = Gt, this.updater = N || dt;
  }
  ut.prototype.isReactComponent = {}, ut.prototype.setState = function(m, A) {
    if (typeof m != "object" && typeof m != "function" && m != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, m, A, "setState");
  }, ut.prototype.forceUpdate = function(m) {
    this.updater.enqueueForceUpdate(this, m, "forceUpdate");
  };
  function Yt() {
  }
  Yt.prototype = ut.prototype;
  function mt(m, A, N) {
    this.props = m, this.context = A, this.refs = Gt, this.updater = N || dt;
  }
  var _t = mt.prototype = new Yt();
  _t.constructor = mt, yt(_t, ut.prototype), _t.isPureReactComponent = !0;
  var Ct = Array.isArray;
  function ht() {
  }
  var $ = { H: null, A: null, T: null, S: null }, Ut = Object.prototype.hasOwnProperty;
  function Pt(m, A, N) {
    var j = N.ref;
    return {
      $$typeof: S,
      type: m,
      key: A,
      ref: j !== void 0 ? j : null,
      props: N
    };
  }
  function Ft(m, A) {
    return Pt(m.type, A, m.props);
  }
  function Vt(m) {
    return typeof m == "object" && m !== null && m.$$typeof === S;
  }
  function Zt(m) {
    var A = { "=": "=0", ":": "=2" };
    return "$" + m.replace(/[=:]/g, function(N) {
      return A[N];
    });
  }
  var de = /\/+/g;
  function ie(m, A) {
    return typeof m == "object" && m !== null && m.key != null ? Zt("" + m.key) : A.toString(36);
  }
  function X(m) {
    switch (m.status) {
      case "fulfilled":
        return m.value;
      case "rejected":
        throw m.reason;
      default:
        switch (typeof m.status == "string" ? m.then(ht, ht) : (m.status = "pending", m.then(
          function(A) {
            m.status === "pending" && (m.status = "fulfilled", m.value = A);
          },
          function(A) {
            m.status === "pending" && (m.status = "rejected", m.reason = A);
          }
        )), m.status) {
          case "fulfilled":
            return m.value;
          case "rejected":
            throw m.reason;
        }
    }
    throw m;
  }
  function g(m, A, N, j, at) {
    var ft = typeof m;
    (ft === "undefined" || ft === "boolean") && (m = null);
    var Tt = !1;
    if (m === null) Tt = !0;
    else
      switch (ft) {
        case "bigint":
        case "string":
        case "number":
          Tt = !0;
          break;
        case "object":
          switch (m.$$typeof) {
            case S:
            case f:
              Tt = !0;
              break;
            case L:
              return Tt = m._init, g(
                Tt(m._payload),
                A,
                N,
                j,
                at
              );
          }
      }
    if (Tt)
      return at = at(m), Tt = j === "" ? "." + ie(m, 0) : j, Ct(at) ? (N = "", Tt != null && (N = Tt.replace(de, "$&/") + "/"), g(at, A, N, "", function(yl) {
        return yl;
      })) : at != null && (Vt(at) && (at = Ft(
        at,
        N + (at.key == null || m && m.key === at.key ? "" : ("" + at.key).replace(
          de,
          "$&/"
        ) + "/") + Tt
      )), A.push(at)), 1;
    Tt = 0;
    var oe = j === "" ? "." : j + ":";
    if (Ct(m))
      for (var Rt = 0; Rt < m.length; Rt++)
        j = m[Rt], ft = oe + ie(j, Rt), Tt += g(
          j,
          A,
          N,
          ft,
          at
        );
    else if (Rt = rt(m), typeof Rt == "function")
      for (m = Rt.call(m), Rt = 0; !(j = m.next()).done; )
        j = j.value, ft = oe + ie(j, Rt++), Tt += g(
          j,
          A,
          N,
          ft,
          at
        );
    else if (ft === "object") {
      if (typeof m.then == "function")
        return g(
          X(m),
          A,
          N,
          j,
          at
        );
      throw A = String(m), Error(
        "Objects are not valid as a React child (found: " + (A === "[object Object]" ? "object with keys {" + Object.keys(m).join(", ") + "}" : A) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return Tt;
  }
  function U(m, A, N) {
    if (m == null) return m;
    var j = [], at = 0;
    return g(m, j, "", "", function(ft) {
      return A.call(N, ft, at++);
    }), j;
  }
  function Z(m) {
    if (m._status === -1) {
      var A = m._result;
      A = A(), A.then(
        function(N) {
          (m._status === 0 || m._status === -1) && (m._status = 1, m._result = N);
        },
        function(N) {
          (m._status === 0 || m._status === -1) && (m._status = 2, m._result = N);
        }
      ), m._status === -1 && (m._status = 0, m._result = A);
    }
    if (m._status === 1) return m._result.default;
    throw m._result;
  }
  var W = typeof reportError == "function" ? reportError : function(m) {
    if (typeof window == "object" && typeof window.ErrorEvent == "function") {
      var A = new window.ErrorEvent("error", {
        bubbles: !0,
        cancelable: !0,
        message: typeof m == "object" && m !== null && typeof m.message == "string" ? String(m.message) : String(m),
        error: m
      });
      if (!window.dispatchEvent(A)) return;
    } else if (typeof process == "object" && typeof process.emit == "function") {
      process.emit("uncaughtException", m);
      return;
    }
    console.error(m);
  }, et = {
    map: U,
    forEach: function(m, A, N) {
      U(
        m,
        function() {
          A.apply(this, arguments);
        },
        N
      );
    },
    count: function(m) {
      var A = 0;
      return U(m, function() {
        A++;
      }), A;
    },
    toArray: function(m) {
      return U(m, function(A) {
        return A;
      }) || [];
    },
    only: function(m) {
      if (!Vt(m))
        throw Error(
          "React.Children.only expected to receive a single React element child."
        );
      return m;
    }
  };
  return it.Activity = w, it.Children = et, it.Component = ut, it.Fragment = D, it.Profiler = G, it.PureComponent = mt, it.StrictMode = s, it.Suspense = C, it.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = $, it.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(m) {
      return $.H.useMemoCache(m);
    }
  }, it.cache = function(m) {
    return function() {
      return m.apply(null, arguments);
    };
  }, it.cacheSignal = function() {
    return null;
  }, it.cloneElement = function(m, A, N) {
    if (m == null)
      throw Error(
        "The argument must be a React element, but you passed " + m + "."
      );
    var j = yt({}, m.props), at = m.key;
    if (A != null)
      for (ft in A.key !== void 0 && (at = "" + A.key), A)
        !Ut.call(A, ft) || ft === "key" || ft === "__self" || ft === "__source" || ft === "ref" && A.ref === void 0 || (j[ft] = A[ft]);
    var ft = arguments.length - 2;
    if (ft === 1) j.children = N;
    else if (1 < ft) {
      for (var Tt = Array(ft), oe = 0; oe < ft; oe++)
        Tt[oe] = arguments[oe + 2];
      j.children = Tt;
    }
    return Pt(m.type, at, j);
  }, it.createContext = function(m) {
    return m = {
      $$typeof: Q,
      _currentValue: m,
      _currentValue2: m,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, m.Provider = m, m.Consumer = {
      $$typeof: k,
      _context: m
    }, m;
  }, it.createElement = function(m, A, N) {
    var j, at = {}, ft = null;
    if (A != null)
      for (j in A.key !== void 0 && (ft = "" + A.key), A)
        Ut.call(A, j) && j !== "key" && j !== "__self" && j !== "__source" && (at[j] = A[j]);
    var Tt = arguments.length - 2;
    if (Tt === 1) at.children = N;
    else if (1 < Tt) {
      for (var oe = Array(Tt), Rt = 0; Rt < Tt; Rt++)
        oe[Rt] = arguments[Rt + 2];
      at.children = oe;
    }
    if (m && m.defaultProps)
      for (j in Tt = m.defaultProps, Tt)
        at[j] === void 0 && (at[j] = Tt[j]);
    return Pt(m, ft, at);
  }, it.createRef = function() {
    return { current: null };
  }, it.forwardRef = function(m) {
    return { $$typeof: lt, render: m };
  }, it.isValidElement = Vt, it.lazy = function(m) {
    return {
      $$typeof: L,
      _payload: { _status: -1, _result: m },
      _init: Z
    };
  }, it.memo = function(m, A) {
    return {
      $$typeof: z,
      type: m,
      compare: A === void 0 ? null : A
    };
  }, it.startTransition = function(m) {
    var A = $.T, N = {};
    $.T = N;
    try {
      var j = m(), at = $.S;
      at !== null && at(N, j), typeof j == "object" && j !== null && typeof j.then == "function" && j.then(ht, W);
    } catch (ft) {
      W(ft);
    } finally {
      A !== null && N.types !== null && (A.types = N.types), $.T = A;
    }
  }, it.unstable_useCacheRefresh = function() {
    return $.H.useCacheRefresh();
  }, it.use = function(m) {
    return $.H.use(m);
  }, it.useActionState = function(m, A, N) {
    return $.H.useActionState(m, A, N);
  }, it.useCallback = function(m, A) {
    return $.H.useCallback(m, A);
  }, it.useContext = function(m) {
    return $.H.useContext(m);
  }, it.useDebugValue = function() {
  }, it.useDeferredValue = function(m, A) {
    return $.H.useDeferredValue(m, A);
  }, it.useEffect = function(m, A) {
    return $.H.useEffect(m, A);
  }, it.useEffectEvent = function(m) {
    return $.H.useEffectEvent(m);
  }, it.useId = function() {
    return $.H.useId();
  }, it.useImperativeHandle = function(m, A, N) {
    return $.H.useImperativeHandle(m, A, N);
  }, it.useInsertionEffect = function(m, A) {
    return $.H.useInsertionEffect(m, A);
  }, it.useLayoutEffect = function(m, A) {
    return $.H.useLayoutEffect(m, A);
  }, it.useMemo = function(m, A) {
    return $.H.useMemo(m, A);
  }, it.useOptimistic = function(m, A) {
    return $.H.useOptimistic(m, A);
  }, it.useReducer = function(m, A, N) {
    return $.H.useReducer(m, A, N);
  }, it.useRef = function(m) {
    return $.H.useRef(m);
  }, it.useState = function(m) {
    return $.H.useState(m);
  }, it.useSyncExternalStore = function(m, A, N) {
    return $.H.useSyncExternalStore(
      m,
      A,
      N
    );
  }, it.useTransition = function() {
    return $.H.useTransition();
  }, it.version = "19.2.3", it;
}
var am;
function mf() {
  return am || (am = 1, To.exports = rg()), To.exports;
}
var zo = { exports: {} }, xe = {};
var nm;
function sg() {
  if (nm) return xe;
  nm = 1;
  var S = mf();
  function f(C) {
    var z = "https://react.dev/errors/" + C;
    if (1 < arguments.length) {
      z += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var L = 2; L < arguments.length; L++)
        z += "&args[]=" + encodeURIComponent(arguments[L]);
    }
    return "Minified React error #" + C + "; visit " + z + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function D() {
  }
  var s = {
    d: {
      f: D,
      r: function() {
        throw Error(f(522));
      },
      D,
      C: D,
      L: D,
      m: D,
      X: D,
      S: D,
      M: D
    },
    p: 0,
    findDOMNode: null
  }, G = /* @__PURE__ */ Symbol.for("react.portal");
  function k(C, z, L) {
    var w = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: G,
      key: w == null ? null : "" + w,
      children: C,
      containerInfo: z,
      implementation: L
    };
  }
  var Q = S.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function lt(C, z) {
    if (C === "font") return "";
    if (typeof z == "string")
      return z === "use-credentials" ? z : "";
  }
  return xe.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = s, xe.createPortal = function(C, z) {
    var L = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!z || z.nodeType !== 1 && z.nodeType !== 9 && z.nodeType !== 11)
      throw Error(f(299));
    return k(C, z, null, L);
  }, xe.flushSync = function(C) {
    var z = Q.T, L = s.p;
    try {
      if (Q.T = null, s.p = 2, C) return C();
    } finally {
      Q.T = z, s.p = L, s.d.f();
    }
  }, xe.preconnect = function(C, z) {
    typeof C == "string" && (z ? (z = z.crossOrigin, z = typeof z == "string" ? z === "use-credentials" ? z : "" : void 0) : z = null, s.d.C(C, z));
  }, xe.prefetchDNS = function(C) {
    typeof C == "string" && s.d.D(C);
  }, xe.preinit = function(C, z) {
    if (typeof C == "string" && z && typeof z.as == "string") {
      var L = z.as, w = lt(L, z.crossOrigin), tt = typeof z.integrity == "string" ? z.integrity : void 0, rt = typeof z.fetchPriority == "string" ? z.fetchPriority : void 0;
      L === "style" ? s.d.S(
        C,
        typeof z.precedence == "string" ? z.precedence : void 0,
        {
          crossOrigin: w,
          integrity: tt,
          fetchPriority: rt
        }
      ) : L === "script" && s.d.X(C, {
        crossOrigin: w,
        integrity: tt,
        fetchPriority: rt,
        nonce: typeof z.nonce == "string" ? z.nonce : void 0
      });
    }
  }, xe.preinitModule = function(C, z) {
    if (typeof C == "string")
      if (typeof z == "object" && z !== null) {
        if (z.as == null || z.as === "script") {
          var L = lt(
            z.as,
            z.crossOrigin
          );
          s.d.M(C, {
            crossOrigin: L,
            integrity: typeof z.integrity == "string" ? z.integrity : void 0,
            nonce: typeof z.nonce == "string" ? z.nonce : void 0
          });
        }
      } else z == null && s.d.M(C);
  }, xe.preload = function(C, z) {
    if (typeof C == "string" && typeof z == "object" && z !== null && typeof z.as == "string") {
      var L = z.as, w = lt(L, z.crossOrigin);
      s.d.L(C, L, {
        crossOrigin: w,
        integrity: typeof z.integrity == "string" ? z.integrity : void 0,
        nonce: typeof z.nonce == "string" ? z.nonce : void 0,
        type: typeof z.type == "string" ? z.type : void 0,
        fetchPriority: typeof z.fetchPriority == "string" ? z.fetchPriority : void 0,
        referrerPolicy: typeof z.referrerPolicy == "string" ? z.referrerPolicy : void 0,
        imageSrcSet: typeof z.imageSrcSet == "string" ? z.imageSrcSet : void 0,
        imageSizes: typeof z.imageSizes == "string" ? z.imageSizes : void 0,
        media: typeof z.media == "string" ? z.media : void 0
      });
    }
  }, xe.preloadModule = function(C, z) {
    if (typeof C == "string")
      if (z) {
        var L = lt(z.as, z.crossOrigin);
        s.d.m(C, {
          as: typeof z.as == "string" && z.as !== "script" ? z.as : void 0,
          crossOrigin: L,
          integrity: typeof z.integrity == "string" ? z.integrity : void 0
        });
      } else s.d.m(C);
  }, xe.requestFormReset = function(C) {
    s.d.r(C);
  }, xe.unstable_batchedUpdates = function(C, z) {
    return C(z);
  }, xe.useFormState = function(C, z, L) {
    return Q.H.useFormState(C, z, L);
  }, xe.useFormStatus = function() {
    return Q.H.useHostTransitionStatus();
  }, xe.version = "19.2.3", xe;
}
var im;
function dg() {
  if (im) return zo.exports;
  im = 1;
  function S() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(S);
      } catch (f) {
        console.error(f);
      }
  }
  return S(), zo.exports = sg(), zo.exports;
}
var um;
function mg() {
  if (um) return Li;
  um = 1;
  var S = og(), f = mf(), D = dg();
  function s(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function G(t) {
    return !(!t || t.nodeType !== 1 && t.nodeType !== 9 && t.nodeType !== 11);
  }
  function k(t) {
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
  function Q(t) {
    if (t.tag === 13) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function lt(t) {
    if (t.tag === 31) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function C(t) {
    if (k(t) !== t)
      throw Error(s(188));
  }
  function z(t) {
    var e = t.alternate;
    if (!e) {
      if (e = k(t), e === null) throw Error(s(188));
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
          if (i === l) return C(n), t;
          if (i === a) return C(n), e;
          i = i.sibling;
        }
        throw Error(s(188));
      }
      if (l.return !== a.return) l = n, a = i;
      else {
        for (var u = !1, c = n.child; c; ) {
          if (c === l) {
            u = !0, l = n, a = i;
            break;
          }
          if (c === a) {
            u = !0, a = n, l = i;
            break;
          }
          c = c.sibling;
        }
        if (!u) {
          for (c = i.child; c; ) {
            if (c === l) {
              u = !0, l = i, a = n;
              break;
            }
            if (c === a) {
              u = !0, a = i, l = n;
              break;
            }
            c = c.sibling;
          }
          if (!u) throw Error(s(189));
        }
      }
      if (l.alternate !== a) throw Error(s(190));
    }
    if (l.tag !== 3) throw Error(s(188));
    return l.stateNode.current === l ? t : e;
  }
  function L(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t;
    for (t = t.child; t !== null; ) {
      if (e = L(t), e !== null) return e;
      t = t.sibling;
    }
    return null;
  }
  var w = Object.assign, tt = /* @__PURE__ */ Symbol.for("react.element"), rt = /* @__PURE__ */ Symbol.for("react.transitional.element"), dt = /* @__PURE__ */ Symbol.for("react.portal"), yt = /* @__PURE__ */ Symbol.for("react.fragment"), Gt = /* @__PURE__ */ Symbol.for("react.strict_mode"), ut = /* @__PURE__ */ Symbol.for("react.profiler"), Yt = /* @__PURE__ */ Symbol.for("react.consumer"), mt = /* @__PURE__ */ Symbol.for("react.context"), _t = /* @__PURE__ */ Symbol.for("react.forward_ref"), Ct = /* @__PURE__ */ Symbol.for("react.suspense"), ht = /* @__PURE__ */ Symbol.for("react.suspense_list"), $ = /* @__PURE__ */ Symbol.for("react.memo"), Ut = /* @__PURE__ */ Symbol.for("react.lazy"), Pt = /* @__PURE__ */ Symbol.for("react.activity"), Ft = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), Vt = Symbol.iterator;
  function Zt(t) {
    return t === null || typeof t != "object" ? null : (t = Vt && t[Vt] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var de = /* @__PURE__ */ Symbol.for("react.client.reference");
  function ie(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === de ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case yt:
        return "Fragment";
      case ut:
        return "Profiler";
      case Gt:
        return "StrictMode";
      case Ct:
        return "Suspense";
      case ht:
        return "SuspenseList";
      case Pt:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case dt:
          return "Portal";
        case mt:
          return t.displayName || "Context";
        case Yt:
          return (t._context.displayName || "Context") + ".Consumer";
        case _t:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case $:
          return e = t.displayName || null, e !== null ? e : ie(t.type) || "Memo";
        case Ut:
          e = t._payload, t = t._init;
          try {
            return ie(t(e));
          } catch {
          }
      }
    return null;
  }
  var X = Array.isArray, g = f.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, U = D.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, Z = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, W = [], et = -1;
  function m(t) {
    return { current: t };
  }
  function A(t) {
    0 > et || (t.current = W[et], W[et] = null, et--);
  }
  function N(t, e) {
    et++, W[et] = t.current, t.current = e;
  }
  var j = m(null), at = m(null), ft = m(null), Tt = m(null);
  function oe(t, e) {
    switch (N(ft, e), N(at, t), N(j, null), e.nodeType) {
      case 9:
      case 11:
        t = (t = e.documentElement) && (t = t.namespaceURI) ? Sd(t) : 0;
        break;
      default:
        if (t = e.tagName, e = e.namespaceURI)
          e = Sd(e), t = Td(e, t);
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
    A(j), N(j, t);
  }
  function Rt() {
    A(j), A(at), A(ft);
  }
  function yl(t) {
    t.memoizedState !== null && N(Tt, t);
    var e = j.current, l = Td(e, t.type);
    e !== l && (N(at, t), N(j, l));
  }
  function Le(t) {
    at.current === t && (A(j), A(at)), Tt.current === t && (A(Tt), Hi._currentValue = Z);
  }
  var nl, Gn;
  function vl(t) {
    if (nl === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        nl = e && e[1] || "", Gn = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + nl + t + Gn;
  }
  var Ue = !1;
  function Yn(t, e) {
    if (!t || Ue) return "";
    Ue = !0;
    var l = Error.prepareStackTrace;
    Error.prepareStackTrace = void 0;
    try {
      var a = {
        DetermineComponentFrameRoot: function() {
          try {
            if (e) {
              var O = function() {
                throw Error();
              };
              if (Object.defineProperty(O.prototype, "props", {
                set: function() {
                  throw Error();
                }
              }), typeof Reflect == "object" && Reflect.construct) {
                try {
                  Reflect.construct(O, []);
                } catch (T) {
                  var b = T;
                }
                Reflect.construct(t, [], O);
              } else {
                try {
                  O.call();
                } catch (T) {
                  b = T;
                }
                t.call(O.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (T) {
                b = T;
              }
              (O = t()) && typeof O.catch == "function" && O.catch(function() {
              });
            }
          } catch (T) {
            if (T && b && typeof T.stack == "string")
              return [T.stack, b.stack];
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
      var i = a.DetermineComponentFrameRoot(), u = i[0], c = i[1];
      if (u && c) {
        var r = u.split(`
`), v = c.split(`
`);
        for (n = a = 0; a < r.length && !r[a].includes("DetermineComponentFrameRoot"); )
          a++;
        for (; n < v.length && !v[n].includes(
          "DetermineComponentFrameRoot"
        ); )
          n++;
        if (a === r.length || n === v.length)
          for (a = r.length - 1, n = v.length - 1; 1 <= a && 0 <= n && r[a] !== v[n]; )
            n--;
        for (; 1 <= a && 0 <= n; a--, n--)
          if (r[a] !== v[n]) {
            if (a !== 1 || n !== 1)
              do
                if (a--, n--, 0 > n || r[a] !== v[n]) {
                  var M = `
` + r[a].replace(" at new ", " at ");
                  return t.displayName && M.includes("<anonymous>") && (M = M.replace("<anonymous>", t.displayName)), M;
                }
              while (1 <= a && 0 <= n);
            break;
          }
      }
    } finally {
      Ue = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? vl(l) : "";
  }
  function hf(t, e) {
    switch (t.tag) {
      case 26:
      case 27:
      case 5:
        return vl(t.type);
      case 16:
        return vl("Lazy");
      case 13:
        return t.child !== e && e !== null ? vl("Suspense Fallback") : vl("Suspense");
      case 19:
        return vl("SuspenseList");
      case 0:
      case 15:
        return Yn(t.type, !1);
      case 11:
        return Yn(t.type.render, !1);
      case 1:
        return Yn(t.type, !0);
      case 31:
        return vl("Activity");
      default:
        return "";
    }
  }
  function Xi(t) {
    try {
      var e = "", l = null;
      do
        e += hf(t, l), l = t, t = t.return;
      while (t);
      return e;
    } catch (a) {
      return `
Error generating stack: ` + a.message + `
` + a.stack;
    }
  }
  var Ln = Object.prototype.hasOwnProperty, Xn = S.unstable_scheduleCallback, ha = S.unstable_cancelCallback, Qn = S.unstable_shouldYield, Qi = S.unstable_requestPaint, me = S.unstable_now, Vi = S.unstable_getCurrentPriorityLevel, Zi = S.unstable_ImmediatePriority, Ka = S.unstable_UserBlockingPriority, ga = S.unstable_NormalPriority, gf = S.unstable_LowPriority, Ki = S.unstable_IdlePriority, pf = S.log, Ji = S.unstable_setDisableYieldValue, pa = null, Se = null;
  function il(t) {
    if (typeof pf == "function" && Ji(t), Se && typeof Se.setStrictMode == "function")
      try {
        Se.setStrictMode(pa, t);
      } catch {
      }
  }
  var ue = Math.clz32 ? Math.clz32 : yf, ki = Math.log, Ja = Math.LN2;
  function yf(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (ki(t) / Ja | 0) | 0;
  }
  var bl = 256, ka = 262144, Fa = 4194304;
  function ul(t) {
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
  function ya(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, i = t.suspendedLanes, u = t.pingedLanes;
    t = t.warmLanes;
    var c = a & 134217727;
    return c !== 0 ? (a = c & ~i, a !== 0 ? n = ul(a) : (u &= c, u !== 0 ? n = ul(u) : l || (l = c & ~t, l !== 0 && (n = ul(l))))) : (c = a & ~i, c !== 0 ? n = ul(c) : u !== 0 ? n = ul(u) : l || (l = a & ~t, l !== 0 && (n = ul(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function va(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function xl(t, e) {
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
    var t = Fa;
    return Fa <<= 1, (Fa & 62914560) === 0 && (Fa = 4194304), t;
  }
  function Zn(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function fl(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function Fi(t, e, l, a, n, i) {
    var u = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var c = t.entanglements, r = t.expirationTimes, v = t.hiddenUpdates;
    for (l = u & ~l; 0 < l; ) {
      var M = 31 - ue(l), O = 1 << M;
      c[M] = 0, r[M] = -1;
      var b = v[M];
      if (b !== null)
        for (v[M] = null, M = 0; M < b.length; M++) {
          var T = b[M];
          T !== null && (T.lane &= -536870913);
        }
      l &= ~O;
    }
    a !== 0 && Wi(t, a, 0), i !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= i & ~(u & ~e));
  }
  function Wi(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - ue(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function Te(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - ue(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function Wa(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : ba(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function ba(t) {
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
  function $i() {
    var t = U.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Zd(t.type));
  }
  function Jn(t, e) {
    var l = U.p;
    try {
      return U.p = t, e();
    } finally {
      U.p = l;
    }
  }
  var cl = Math.random().toString(36).slice(2), te = "__reactFiber$" + cl, he = "__reactProps$" + cl, Sl = "__reactContainer$" + cl, kn = "__reactEvents$" + cl, vf = "__reactListeners$" + cl, bf = "__reactHandles$" + cl, Ii = "__reactResources$" + cl, xa = "__reactMarker$" + cl;
  function $a(t) {
    delete t[te], delete t[he], delete t[kn], delete t[vf], delete t[bf];
  }
  function ol(t) {
    var e = t[te];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[Sl] || l[te]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Od(t); t !== null; ) {
            if (l = t[te]) return l;
            t = Od(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function rl(t) {
    if (t = t[te] || t[Sl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function Yl(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(s(33));
  }
  function Ie(t) {
    var e = t[Ii];
    return e || (e = t[Ii] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function Wt(t) {
    t[xa] = !0;
  }
  var Fn = /* @__PURE__ */ new Set(), Pi = {};
  function sl(t, e) {
    Ll(t, e), Ll(t + "Capture", e);
  }
  function Ll(t, e) {
    for (Pi[t] = e, t = 0; t < e.length; t++)
      Fn.add(e[t]);
  }
  var tu = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), eu = {}, lu = {};
  function Wn(t) {
    return Ln.call(lu, t) ? !0 : Ln.call(eu, t) ? !1 : tu.test(t) ? lu[t] = !0 : (eu[t] = !0, !1);
  }
  function Ia(t, e, l) {
    if (Wn(e))
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
  function Sa(t, e, l) {
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
  function re(t) {
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
  function au(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function xf(t, e, l) {
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
  function Pa(t) {
    if (!t._valueTracker) {
      var e = au(t) ? "checked" : "value";
      t._valueTracker = xf(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function Xl(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = au(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function tn(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var Re = /[\n"\\]/g;
  function ge(t) {
    return t.replace(
      Re,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function $n(t, e, l, a, n, i, u, c) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + re(e)) : t.value !== "" + re(e) && (t.value = "" + re(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? o(t, u, re(e)) : l != null ? o(t, u, re(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), c != null && typeof c != "function" && typeof c != "symbol" && typeof c != "boolean" ? t.name = "" + re(c) : t.removeAttribute("name");
  }
  function nu(t, e, l, a, n, i, u, c) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        Pa(t);
        return;
      }
      l = l != null ? "" + re(l) : "", e = e != null ? "" + re(e) : l, c || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = c ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), Pa(t);
  }
  function o(t, e, l) {
    e === "number" && tn(t.ownerDocument) === t || t.defaultValue === "" + l || (t.defaultValue = "" + l);
  }
  function d(t, e, l, a) {
    if (t = t.options, e) {
      e = {};
      for (var n = 0; n < l.length; n++)
        e["$" + l[n]] = !0;
      for (l = 0; l < t.length; l++)
        n = e.hasOwnProperty("$" + t[l].value), t[l].selected !== n && (t[l].selected = n), n && a && (t[l].defaultSelected = !0);
    } else {
      for (l = "" + re(l), e = null, n = 0; n < t.length; n++) {
        if (t[n].value === l) {
          t[n].selected = !0, a && (t[n].defaultSelected = !0);
          return;
        }
        e !== null || t[n].disabled || (e = t[n]);
      }
      e !== null && (e.selected = !0);
    }
  }
  function x(t, e, l) {
    if (e != null && (e = "" + re(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + re(l) : "";
  }
  function B(t, e, l, a) {
    if (e == null) {
      if (a != null) {
        if (l != null) throw Error(s(92));
        if (X(a)) {
          if (1 < a.length) throw Error(s(93));
          a = a[0];
        }
        l = a;
      }
      l == null && (l = ""), e = l;
    }
    l = re(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), Pa(t);
  }
  function H(t, e) {
    if (e) {
      var l = t.firstChild;
      if (l && l === t.lastChild && l.nodeType === 3) {
        l.nodeValue = e;
        return;
      }
    }
    t.textContent = e;
  }
  var q = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function K(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || q.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function nt(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(s(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && K(t, n, a);
    } else
      for (var i in e)
        e.hasOwnProperty(i) && K(t, i, e[i]);
  }
  function vt(t) {
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
  var Dt = /* @__PURE__ */ new Map([
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
  ]), Ql = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function en(t) {
    return Ql.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function tl() {
  }
  var In = null;
  function ln(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Vl = null, Tl = null;
  function iu(t) {
    var e = rl(t);
    if (e && (t = e.stateNode)) {
      var l = t[he] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if ($n(
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
              'input[name="' + ge(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[he] || null;
                if (!n) throw Error(s(90));
                $n(
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
              a = l[e], a.form === t.form && Xl(a);
          }
          break t;
        case "textarea":
          x(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && d(t, !!l.multiple, e, !1);
      }
    }
  }
  var Ta = !1;
  function an(t, e, l) {
    if (Ta) return t(e, l);
    Ta = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (Ta = !1, (Vl !== null || Tl !== null) && (Qu(), Vl && (e = Vl, t = Tl, Tl = Vl = null, iu(e), t)))
        for (e = 0; e < t.length; e++) iu(t[e]);
    }
  }
  function za(t, e) {
    var l = t.stateNode;
    if (l === null) return null;
    var a = l[he] || null;
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
        s(231, e, typeof l)
      );
    return l;
  }
  var Xe = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), Ma = !1;
  if (Xe)
    try {
      var zl = {};
      Object.defineProperty(zl, "passive", {
        get: function() {
          Ma = !0;
        }
      }), window.addEventListener("test", zl, zl), window.removeEventListener("test", zl, zl);
    } catch {
      Ma = !1;
    }
  var Ee = null, nn = null, un = null;
  function Pn() {
    if (un) return un;
    var t, e = nn, l = e.length, a, n = "value" in Ee ? Ee.value : Ee.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return un = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function Ea(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function fn() {
    return !0;
  }
  function ti() {
    return !1;
  }
  function fe(t) {
    function e(l, a, n, i, u) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = i, this.target = u, this.currentTarget = null;
      for (var c in t)
        t.hasOwnProperty(c) && (l = t[c], this[c] = l ? l(i) : i[c]);
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? fn : ti, this.isPropagationStopped = ti, this;
    }
    return w(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = fn);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = fn);
      },
      persist: function() {
      },
      isPersistent: fn
    }), e;
  }
  var dl = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, cn = fe(dl), Aa = w({}, dl, { view: 0, detail: 0 }), uu = fe(Aa), ei, _a, Qe, Da = w({}, Aa, {
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
    getModifierState: Tf,
    button: 0,
    buttons: 0,
    relatedTarget: function(t) {
      return t.relatedTarget === void 0 ? t.fromElement === t.srcElement ? t.toElement : t.fromElement : t.relatedTarget;
    },
    movementX: function(t) {
      return "movementX" in t ? t.movementX : (t !== Qe && (Qe && t.type === "mousemove" ? (ei = t.screenX - Qe.screenX, _a = t.screenY - Qe.screenY) : _a = ei = 0, Qe = t), ei);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : _a;
    }
  }), li = fe(Da), on = w({}, Da, { dataTransfer: 0 }), _ = fe(on), R = w({}, Aa, { relatedTarget: 0 }), P = fe(R), ct = w({}, dl, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), zt = fe(ct), Mt = w({}, dl, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), Kt = fe(Mt), ze = w({}, dl, { data: 0 }), Zl = fe(ze), Be = {
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
  }, fu = {
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
  }, Sf = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function pm(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = Sf[t]) ? !!e[t] : !1;
  }
  function Tf() {
    return pm;
  }
  var ym = w({}, Aa, {
    key: function(t) {
      if (t.key) {
        var e = Be[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = Ea(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? fu[t.keyCode] || "Unidentified" : "";
    },
    code: 0,
    location: 0,
    ctrlKey: 0,
    shiftKey: 0,
    altKey: 0,
    metaKey: 0,
    repeat: 0,
    locale: 0,
    getModifierState: Tf,
    charCode: function(t) {
      return t.type === "keypress" ? Ea(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? Ea(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), vm = fe(ym), bm = w({}, Da, {
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
  }), Ao = fe(bm), xm = w({}, Aa, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: Tf
  }), Sm = fe(xm), Tm = w({}, dl, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), zm = fe(Tm), Mm = w({}, Da, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), Em = fe(Mm), Am = w({}, dl, {
    newState: 0,
    oldState: 0
  }), _m = fe(Am), Dm = [9, 13, 27, 32], zf = Xe && "CompositionEvent" in window, ai = null;
  Xe && "documentMode" in document && (ai = document.documentMode);
  var Om = Xe && "TextEvent" in window && !ai, _o = Xe && (!zf || ai && 8 < ai && 11 >= ai), Do = " ", Oo = !1;
  function Co(t, e) {
    switch (t) {
      case "keyup":
        return Dm.indexOf(e.keyCode) !== -1;
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
  function Uo(t) {
    return t = t.detail, typeof t == "object" && "data" in t ? t.data : null;
  }
  var rn = !1;
  function Cm(t, e) {
    switch (t) {
      case "compositionend":
        return Uo(e);
      case "keypress":
        return e.which !== 32 ? null : (Oo = !0, Do);
      case "textInput":
        return t = e.data, t === Do && Oo ? null : t;
      default:
        return null;
    }
  }
  function Um(t, e) {
    if (rn)
      return t === "compositionend" || !zf && Co(t, e) ? (t = Pn(), un = nn = Ee = null, rn = !1, t) : null;
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
        return _o && e.locale !== "ko" ? null : e.data;
      default:
        return null;
    }
  }
  var Rm = {
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
  function Ro(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e === "input" ? !!Rm[t.type] : e === "textarea";
  }
  function Bo(t, e, l, a) {
    Vl ? Tl ? Tl.push(a) : Tl = [a] : Vl = a, e = Wu(e, "onChange"), 0 < e.length && (l = new cn(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var ni = null, ii = null;
  function Bm(t) {
    gd(t, 0);
  }
  function cu(t) {
    var e = Yl(t);
    if (Xl(e)) return t;
  }
  function No(t, e) {
    if (t === "change") return e;
  }
  var wo = !1;
  if (Xe) {
    var Mf;
    if (Xe) {
      var Ef = "oninput" in document;
      if (!Ef) {
        var Ho = document.createElement("div");
        Ho.setAttribute("oninput", "return;"), Ef = typeof Ho.oninput == "function";
      }
      Mf = Ef;
    } else Mf = !1;
    wo = Mf && (!document.documentMode || 9 < document.documentMode);
  }
  function jo() {
    ni && (ni.detachEvent("onpropertychange", qo), ii = ni = null);
  }
  function qo(t) {
    if (t.propertyName === "value" && cu(ii)) {
      var e = [];
      Bo(
        e,
        ii,
        t,
        ln(t)
      ), an(Bm, e);
    }
  }
  function Nm(t, e, l) {
    t === "focusin" ? (jo(), ni = e, ii = l, ni.attachEvent("onpropertychange", qo)) : t === "focusout" && jo();
  }
  function wm(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return cu(ii);
  }
  function Hm(t, e) {
    if (t === "click") return cu(e);
  }
  function jm(t, e) {
    if (t === "input" || t === "change")
      return cu(e);
  }
  function qm(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var Ne = typeof Object.is == "function" ? Object.is : qm;
  function ui(t, e) {
    if (Ne(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!Ln.call(e, n) || !Ne(t[n], e[n]))
        return !1;
    }
    return !0;
  }
  function Go(t) {
    for (; t && t.firstChild; ) t = t.firstChild;
    return t;
  }
  function Yo(t, e) {
    var l = Go(t);
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
      l = Go(l);
    }
  }
  function Lo(t, e) {
    return t && e ? t === e ? !0 : t && t.nodeType === 3 ? !1 : e && e.nodeType === 3 ? Lo(t, e.parentNode) : "contains" in t ? t.contains(e) : t.compareDocumentPosition ? !!(t.compareDocumentPosition(e) & 16) : !1 : !1;
  }
  function Xo(t) {
    t = t != null && t.ownerDocument != null && t.ownerDocument.defaultView != null ? t.ownerDocument.defaultView : window;
    for (var e = tn(t.document); e instanceof t.HTMLIFrameElement; ) {
      try {
        var l = typeof e.contentWindow.location.href == "string";
      } catch {
        l = !1;
      }
      if (l) t = e.contentWindow;
      else break;
      e = tn(t.document);
    }
    return e;
  }
  function Af(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var Gm = Xe && "documentMode" in document && 11 >= document.documentMode, sn = null, _f = null, fi = null, Df = !1;
  function Qo(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Df || sn == null || sn !== tn(a) || (a = sn, "selectionStart" in a && Af(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), fi && ui(fi, a) || (fi = a, a = Wu(_f, "onSelect"), 0 < a.length && (e = new cn(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = sn)));
  }
  function Oa(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var dn = {
    animationend: Oa("Animation", "AnimationEnd"),
    animationiteration: Oa("Animation", "AnimationIteration"),
    animationstart: Oa("Animation", "AnimationStart"),
    transitionrun: Oa("Transition", "TransitionRun"),
    transitionstart: Oa("Transition", "TransitionStart"),
    transitioncancel: Oa("Transition", "TransitionCancel"),
    transitionend: Oa("Transition", "TransitionEnd")
  }, Of = {}, Vo = {};
  Xe && (Vo = document.createElement("div").style, "AnimationEvent" in window || (delete dn.animationend.animation, delete dn.animationiteration.animation, delete dn.animationstart.animation), "TransitionEvent" in window || delete dn.transitionend.transition);
  function Ca(t) {
    if (Of[t]) return Of[t];
    if (!dn[t]) return t;
    var e = dn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Vo)
        return Of[t] = e[l];
    return t;
  }
  var Zo = Ca("animationend"), Ko = Ca("animationiteration"), Jo = Ca("animationstart"), Ym = Ca("transitionrun"), Lm = Ca("transitionstart"), Xm = Ca("transitioncancel"), ko = Ca("transitionend"), Fo = /* @__PURE__ */ new Map(), Cf = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Cf.push("scrollEnd");
  function el(t, e) {
    Fo.set(t, e), sl(e, [t]);
  }
  var ou = typeof reportError == "function" ? reportError : function(t) {
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
  }, Ve = [], mn = 0, Uf = 0;
  function ru() {
    for (var t = mn, e = Uf = mn = 0; e < t; ) {
      var l = Ve[e];
      Ve[e++] = null;
      var a = Ve[e];
      Ve[e++] = null;
      var n = Ve[e];
      Ve[e++] = null;
      var i = Ve[e];
      if (Ve[e++] = null, a !== null && n !== null) {
        var u = a.pending;
        u === null ? n.next = n : (n.next = u.next, u.next = n), a.pending = n;
      }
      i !== 0 && Wo(l, n, i);
    }
  }
  function su(t, e, l, a) {
    Ve[mn++] = t, Ve[mn++] = e, Ve[mn++] = l, Ve[mn++] = a, Uf |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Rf(t, e, l, a) {
    return su(t, e, l, a), du(t);
  }
  function Ua(t, e) {
    return su(t, null, null, e), du(t);
  }
  function Wo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, i = t.return; i !== null; )
      i.childLanes |= l, a = i.alternate, a !== null && (a.childLanes |= l), i.tag === 22 && (t = i.stateNode, t === null || t._visibility & 1 || (n = !0)), t = i, i = i.return;
    return t.tag === 3 ? (i = t.stateNode, n && e !== null && (n = 31 - ue(l), t = i.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), i) : null;
  }
  function du(t) {
    if (50 < Oi)
      throw Oi = 0, Lc = null, Error(s(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var hn = {};
  function Qm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function we(t, e, l, a) {
    return new Qm(t, e, l, a);
  }
  function Bf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function Ml(t, e) {
    var l = t.alternate;
    return l === null ? (l = we(
      t.tag,
      e,
      t.key,
      t.mode
    ), l.elementType = t.elementType, l.type = t.type, l.stateNode = t.stateNode, l.alternate = t, t.alternate = l) : (l.pendingProps = e, l.type = t.type, l.flags = 0, l.subtreeFlags = 0, l.deletions = null), l.flags = t.flags & 65011712, l.childLanes = t.childLanes, l.lanes = t.lanes, l.child = t.child, l.memoizedProps = t.memoizedProps, l.memoizedState = t.memoizedState, l.updateQueue = t.updateQueue, e = t.dependencies, l.dependencies = e === null ? null : { lanes: e.lanes, firstContext: e.firstContext }, l.sibling = t.sibling, l.index = t.index, l.ref = t.ref, l.refCleanup = t.refCleanup, l;
  }
  function $o(t, e) {
    t.flags &= 65011714;
    var l = t.alternate;
    return l === null ? (t.childLanes = 0, t.lanes = e, t.child = null, t.subtreeFlags = 0, t.memoizedProps = null, t.memoizedState = null, t.updateQueue = null, t.dependencies = null, t.stateNode = null) : (t.childLanes = l.childLanes, t.lanes = l.lanes, t.child = l.child, t.subtreeFlags = 0, t.deletions = null, t.memoizedProps = l.memoizedProps, t.memoizedState = l.memoizedState, t.updateQueue = l.updateQueue, t.type = l.type, e = l.dependencies, t.dependencies = e === null ? null : {
      lanes: e.lanes,
      firstContext: e.firstContext
    }), t;
  }
  function mu(t, e, l, a, n, i) {
    var u = 0;
    if (a = t, typeof t == "function") Bf(t) && (u = 1);
    else if (typeof t == "string")
      u = kh(
        t,
        l,
        j.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case Pt:
          return t = we(31, l, e, n), t.elementType = Pt, t.lanes = i, t;
        case yt:
          return Ra(l.children, n, i, e);
        case Gt:
          u = 8, n |= 24;
          break;
        case ut:
          return t = we(12, l, e, n | 2), t.elementType = ut, t.lanes = i, t;
        case Ct:
          return t = we(13, l, e, n), t.elementType = Ct, t.lanes = i, t;
        case ht:
          return t = we(19, l, e, n), t.elementType = ht, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case mt:
                u = 10;
                break t;
              case Yt:
                u = 9;
                break t;
              case _t:
                u = 11;
                break t;
              case $:
                u = 14;
                break t;
              case Ut:
                u = 16, a = null;
                break t;
            }
          u = 29, l = Error(
            s(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = we(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function Ra(t, e, l, a) {
    return t = we(7, t, a, e), t.lanes = l, t;
  }
  function Nf(t, e, l) {
    return t = we(6, t, null, e), t.lanes = l, t;
  }
  function Io(t) {
    var e = we(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function wf(t, e, l) {
    return e = we(
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
  var Po = /* @__PURE__ */ new WeakMap();
  function Ze(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = Po.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Xi(e)
      }, Po.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Xi(e)
    };
  }
  var gn = [], pn = 0, hu = null, ci = 0, Ke = [], Je = 0, Kl = null, ml = 1, hl = "";
  function El(t, e) {
    gn[pn++] = ci, gn[pn++] = hu, hu = t, ci = e;
  }
  function tr(t, e, l) {
    Ke[Je++] = ml, Ke[Je++] = hl, Ke[Je++] = Kl, Kl = t;
    var a = ml;
    t = hl;
    var n = 32 - ue(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - ue(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, ml = 1 << 32 - ue(e) + n | l << n | a, hl = i + t;
    } else
      ml = 1 << i | l << n | a, hl = t;
  }
  function Hf(t) {
    t.return !== null && (El(t, 1), tr(t, 1, 0));
  }
  function jf(t) {
    for (; t === hu; )
      hu = gn[--pn], gn[pn] = null, ci = gn[--pn], gn[pn] = null;
    for (; t === Kl; )
      Kl = Ke[--Je], Ke[Je] = null, hl = Ke[--Je], Ke[Je] = null, ml = Ke[--Je], Ke[Je] = null;
  }
  function er(t, e) {
    Ke[Je++] = ml, Ke[Je++] = hl, Ke[Je++] = Kl, ml = e.id, hl = e.overflow, Kl = t;
  }
  var pe = null, Lt = null, St = !1, Jl = null, ke = !1, qf = Error(s(519));
  function kl(t) {
    var e = Error(
      s(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw oi(Ze(e, t)), qf;
  }
  function lr(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[te] = t, e[he] = a, l) {
      case "dialog":
        pt("cancel", e), pt("close", e);
        break;
      case "iframe":
      case "object":
      case "embed":
        pt("load", e);
        break;
      case "video":
      case "audio":
        for (l = 0; l < Ui.length; l++)
          pt(Ui[l], e);
        break;
      case "source":
        pt("error", e);
        break;
      case "img":
      case "image":
      case "link":
        pt("error", e), pt("load", e);
        break;
      case "details":
        pt("toggle", e);
        break;
      case "input":
        pt("invalid", e), nu(
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
        pt("invalid", e);
        break;
      case "textarea":
        pt("invalid", e), B(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || bd(e.textContent, l) ? (a.popover != null && (pt("beforetoggle", e), pt("toggle", e)), a.onScroll != null && pt("scroll", e), a.onScrollEnd != null && pt("scrollend", e), a.onClick != null && (e.onclick = tl), e = !0) : e = !1, e || kl(t, !0);
  }
  function ar(t) {
    for (pe = t.return; pe; )
      switch (pe.tag) {
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
          pe = pe.return;
      }
  }
  function yn(t) {
    if (t !== pe) return !1;
    if (!St) return ar(t), St = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || lo(t.type, t.memoizedProps)), l = !l), l && Lt && kl(t), ar(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = Dd(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = Dd(t);
    } else
      e === 27 ? (e = Lt, ca(t.type) ? (t = fo, fo = null, Lt = t) : Lt = e) : Lt = pe ? We(t.stateNode.nextSibling) : null;
    return !0;
  }
  function Ba() {
    Lt = pe = null, St = !1;
  }
  function Gf() {
    var t = Jl;
    return t !== null && (Oe === null ? Oe = t : Oe.push.apply(
      Oe,
      t
    ), Jl = null), t;
  }
  function oi(t) {
    Jl === null ? Jl = [t] : Jl.push(t);
  }
  var Yf = m(null), Na = null, Al = null;
  function Fl(t, e, l) {
    N(Yf, e._currentValue), e._currentValue = l;
  }
  function _l(t) {
    t._currentValue = Yf.current, A(Yf);
  }
  function Lf(t, e, l) {
    for (; t !== null; ) {
      var a = t.alternate;
      if ((t.childLanes & e) !== e ? (t.childLanes |= e, a !== null && (a.childLanes |= e)) : a !== null && (a.childLanes & e) !== e && (a.childLanes |= e), t === l) break;
      t = t.return;
    }
  }
  function Xf(t, e, l, a) {
    var n = t.child;
    for (n !== null && (n.return = t); n !== null; ) {
      var i = n.dependencies;
      if (i !== null) {
        var u = n.child;
        i = i.firstContext;
        t: for (; i !== null; ) {
          var c = i;
          i = n;
          for (var r = 0; r < e.length; r++)
            if (c.context === e[r]) {
              i.lanes |= l, c = i.alternate, c !== null && (c.lanes |= l), Lf(
                i.return,
                l,
                t
              ), a || (u = null);
              break t;
            }
          i = c.next;
        }
      } else if (n.tag === 18) {
        if (u = n.return, u === null) throw Error(s(341));
        u.lanes |= l, i = u.alternate, i !== null && (i.lanes |= l), Lf(u, l, t), u = null;
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
        if (u === null) throw Error(s(387));
        if (u = u.memoizedProps, u !== null) {
          var c = n.type;
          Ne(n.pendingProps.value, u.value) || (t !== null ? t.push(c) : t = [c]);
        }
      } else if (n === Tt.current) {
        if (u = n.alternate, u === null) throw Error(s(387));
        u.memoizedState.memoizedState !== n.memoizedState.memoizedState && (t !== null ? t.push(Hi) : t = [Hi]);
      }
      n = n.return;
    }
    t !== null && Xf(
      e,
      t,
      l,
      a
    ), e.flags |= 262144;
  }
  function gu(t) {
    for (t = t.firstContext; t !== null; ) {
      if (!Ne(
        t.context._currentValue,
        t.memoizedValue
      ))
        return !0;
      t = t.next;
    }
    return !1;
  }
  function wa(t) {
    Na = t, Al = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function ye(t) {
    return nr(Na, t);
  }
  function pu(t, e) {
    return Na === null && wa(t), nr(t, e);
  }
  function nr(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Al === null) {
      if (t === null) throw Error(s(308));
      Al = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else Al = Al.next = e;
    return l;
  }
  var Vm = typeof AbortController < "u" ? AbortController : function() {
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
  }, Zm = S.unstable_scheduleCallback, Km = S.unstable_NormalPriority, ee = {
    $$typeof: mt,
    Consumer: null,
    Provider: null,
    _currentValue: null,
    _currentValue2: null,
    _threadCount: 0
  };
  function Qf() {
    return {
      controller: new Vm(),
      data: /* @__PURE__ */ new Map(),
      refCount: 0
    };
  }
  function ri(t) {
    t.refCount--, t.refCount === 0 && Zm(Km, function() {
      t.controller.abort();
    });
  }
  var si = null, Vf = 0, bn = 0, xn = null;
  function Jm(t, e) {
    if (si === null) {
      var l = si = [];
      Vf = 0, bn = Jc(), xn = {
        status: "pending",
        value: void 0,
        then: function(a) {
          l.push(a);
        }
      };
    }
    return Vf++, e.then(ir, ir), e;
  }
  function ir() {
    if (--Vf === 0 && si !== null) {
      xn !== null && (xn.status = "fulfilled");
      var t = si;
      si = null, bn = 0, xn = null;
      for (var e = 0; e < t.length; e++) (0, t[e])();
    }
  }
  function km(t, e) {
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
  var ur = g.S;
  g.S = function(t, e) {
    Qs = me(), typeof e == "object" && e !== null && typeof e.then == "function" && Jm(t, e), ur !== null && ur(t, e);
  };
  var Ha = m(null);
  function Zf() {
    var t = Ha.current;
    return t !== null ? t : qt.pooledCache;
  }
  function yu(t, e) {
    e === null ? N(Ha, Ha.current) : N(Ha, e.pool);
  }
  function fr() {
    var t = Zf();
    return t === null ? null : { parent: ee._currentValue, pool: t };
  }
  var Sn = Error(s(460)), Kf = Error(s(474)), vu = Error(s(542)), bu = { then: function() {
  } };
  function cr(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function or(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(tl, tl), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, sr(t), t;
      default:
        if (typeof e.status == "string") e.then(tl, tl);
        else {
          if (t = qt, t !== null && 100 < t.shellSuspendCounter)
            throw Error(s(482));
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
            throw t = e.reason, sr(t), t;
        }
        throw qa = e, Sn;
    }
  }
  function ja(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (qa = l, Sn) : l;
    }
  }
  var qa = null;
  function rr() {
    if (qa === null) throw Error(s(459));
    var t = qa;
    return qa = null, t;
  }
  function sr(t) {
    if (t === Sn || t === vu)
      throw Error(s(483));
  }
  var Tn = null, di = 0;
  function xu(t) {
    var e = di;
    return di += 1, Tn === null && (Tn = []), or(Tn, t, e);
  }
  function mi(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function Su(t, e) {
    throw e.$$typeof === tt ? Error(s(525)) : (t = Object.prototype.toString.call(e), Error(
      s(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function dr(t) {
    function e(p, h) {
      if (t) {
        var y = p.deletions;
        y === null ? (p.deletions = [h], p.flags |= 16) : y.push(h);
      }
    }
    function l(p, h) {
      if (!t) return null;
      for (; h !== null; )
        e(p, h), h = h.sibling;
      return null;
    }
    function a(p) {
      for (var h = /* @__PURE__ */ new Map(); p !== null; )
        p.key !== null ? h.set(p.key, p) : h.set(p.index, p), p = p.sibling;
      return h;
    }
    function n(p, h) {
      return p = Ml(p, h), p.index = 0, p.sibling = null, p;
    }
    function i(p, h, y) {
      return p.index = y, t ? (y = p.alternate, y !== null ? (y = y.index, y < h ? (p.flags |= 67108866, h) : y) : (p.flags |= 67108866, h)) : (p.flags |= 1048576, h);
    }
    function u(p) {
      return t && p.alternate === null && (p.flags |= 67108866), p;
    }
    function c(p, h, y, E) {
      return h === null || h.tag !== 6 ? (h = Nf(y, p.mode, E), h.return = p, h) : (h = n(h, y), h.return = p, h);
    }
    function r(p, h, y, E) {
      var F = y.type;
      return F === yt ? M(
        p,
        h,
        y.props.children,
        E,
        y.key
      ) : h !== null && (h.elementType === F || typeof F == "object" && F !== null && F.$$typeof === Ut && ja(F) === h.type) ? (h = n(h, y.props), mi(h, y), h.return = p, h) : (h = mu(
        y.type,
        y.key,
        y.props,
        null,
        p.mode,
        E
      ), mi(h, y), h.return = p, h);
    }
    function v(p, h, y, E) {
      return h === null || h.tag !== 4 || h.stateNode.containerInfo !== y.containerInfo || h.stateNode.implementation !== y.implementation ? (h = wf(y, p.mode, E), h.return = p, h) : (h = n(h, y.children || []), h.return = p, h);
    }
    function M(p, h, y, E, F) {
      return h === null || h.tag !== 7 ? (h = Ra(
        y,
        p.mode,
        E,
        F
      ), h.return = p, h) : (h = n(h, y), h.return = p, h);
    }
    function O(p, h, y) {
      if (typeof h == "string" && h !== "" || typeof h == "number" || typeof h == "bigint")
        return h = Nf(
          "" + h,
          p.mode,
          y
        ), h.return = p, h;
      if (typeof h == "object" && h !== null) {
        switch (h.$$typeof) {
          case rt:
            return y = mu(
              h.type,
              h.key,
              h.props,
              null,
              p.mode,
              y
            ), mi(y, h), y.return = p, y;
          case dt:
            return h = wf(
              h,
              p.mode,
              y
            ), h.return = p, h;
          case Ut:
            return h = ja(h), O(p, h, y);
        }
        if (X(h) || Zt(h))
          return h = Ra(
            h,
            p.mode,
            y,
            null
          ), h.return = p, h;
        if (typeof h.then == "function")
          return O(p, xu(h), y);
        if (h.$$typeof === mt)
          return O(
            p,
            pu(p, h),
            y
          );
        Su(p, h);
      }
      return null;
    }
    function b(p, h, y, E) {
      var F = h !== null ? h.key : null;
      if (typeof y == "string" && y !== "" || typeof y == "number" || typeof y == "bigint")
        return F !== null ? null : c(p, h, "" + y, E);
      if (typeof y == "object" && y !== null) {
        switch (y.$$typeof) {
          case rt:
            return y.key === F ? r(p, h, y, E) : null;
          case dt:
            return y.key === F ? v(p, h, y, E) : null;
          case Ut:
            return y = ja(y), b(p, h, y, E);
        }
        if (X(y) || Zt(y))
          return F !== null ? null : M(p, h, y, E, null);
        if (typeof y.then == "function")
          return b(
            p,
            h,
            xu(y),
            E
          );
        if (y.$$typeof === mt)
          return b(
            p,
            h,
            pu(p, y),
            E
          );
        Su(p, y);
      }
      return null;
    }
    function T(p, h, y, E, F) {
      if (typeof E == "string" && E !== "" || typeof E == "number" || typeof E == "bigint")
        return p = p.get(y) || null, c(h, p, "" + E, F);
      if (typeof E == "object" && E !== null) {
        switch (E.$$typeof) {
          case rt:
            return p = p.get(
              E.key === null ? y : E.key
            ) || null, r(h, p, E, F);
          case dt:
            return p = p.get(
              E.key === null ? y : E.key
            ) || null, v(h, p, E, F);
          case Ut:
            return E = ja(E), T(
              p,
              h,
              y,
              E,
              F
            );
        }
        if (X(E) || Zt(E))
          return p = p.get(y) || null, M(h, p, E, F, null);
        if (typeof E.then == "function")
          return T(
            p,
            h,
            y,
            xu(E),
            F
          );
        if (E.$$typeof === mt)
          return T(
            p,
            h,
            y,
            pu(h, E),
            F
          );
        Su(h, E);
      }
      return null;
    }
    function Y(p, h, y, E) {
      for (var F = null, Et = null, V = h, st = h = 0, xt = null; V !== null && st < y.length; st++) {
        V.index > st ? (xt = V, V = null) : xt = V.sibling;
        var At = b(
          p,
          V,
          y[st],
          E
        );
        if (At === null) {
          V === null && (V = xt);
          break;
        }
        t && V && At.alternate === null && e(p, V), h = i(At, h, st), Et === null ? F = At : Et.sibling = At, Et = At, V = xt;
      }
      if (st === y.length)
        return l(p, V), St && El(p, st), F;
      if (V === null) {
        for (; st < y.length; st++)
          V = O(p, y[st], E), V !== null && (h = i(
            V,
            h,
            st
          ), Et === null ? F = V : Et.sibling = V, Et = V);
        return St && El(p, st), F;
      }
      for (V = a(V); st < y.length; st++)
        xt = T(
          V,
          p,
          st,
          y[st],
          E
        ), xt !== null && (t && xt.alternate !== null && V.delete(
          xt.key === null ? st : xt.key
        ), h = i(
          xt,
          h,
          st
        ), Et === null ? F = xt : Et.sibling = xt, Et = xt);
      return t && V.forEach(function(ma) {
        return e(p, ma);
      }), St && El(p, st), F;
    }
    function I(p, h, y, E) {
      if (y == null) throw Error(s(151));
      for (var F = null, Et = null, V = h, st = h = 0, xt = null, At = y.next(); V !== null && !At.done; st++, At = y.next()) {
        V.index > st ? (xt = V, V = null) : xt = V.sibling;
        var ma = b(p, V, At.value, E);
        if (ma === null) {
          V === null && (V = xt);
          break;
        }
        t && V && ma.alternate === null && e(p, V), h = i(ma, h, st), Et === null ? F = ma : Et.sibling = ma, Et = ma, V = xt;
      }
      if (At.done)
        return l(p, V), St && El(p, st), F;
      if (V === null) {
        for (; !At.done; st++, At = y.next())
          At = O(p, At.value, E), At !== null && (h = i(At, h, st), Et === null ? F = At : Et.sibling = At, Et = At);
        return St && El(p, st), F;
      }
      for (V = a(V); !At.done; st++, At = y.next())
        At = T(V, p, st, At.value, E), At !== null && (t && At.alternate !== null && V.delete(At.key === null ? st : At.key), h = i(At, h, st), Et === null ? F = At : Et.sibling = At, Et = At);
      return t && V.forEach(function(ig) {
        return e(p, ig);
      }), St && El(p, st), F;
    }
    function jt(p, h, y, E) {
      if (typeof y == "object" && y !== null && y.type === yt && y.key === null && (y = y.props.children), typeof y == "object" && y !== null) {
        switch (y.$$typeof) {
          case rt:
            t: {
              for (var F = y.key; h !== null; ) {
                if (h.key === F) {
                  if (F = y.type, F === yt) {
                    if (h.tag === 7) {
                      l(
                        p,
                        h.sibling
                      ), E = n(
                        h,
                        y.props.children
                      ), E.return = p, p = E;
                      break t;
                    }
                  } else if (h.elementType === F || typeof F == "object" && F !== null && F.$$typeof === Ut && ja(F) === h.type) {
                    l(
                      p,
                      h.sibling
                    ), E = n(h, y.props), mi(E, y), E.return = p, p = E;
                    break t;
                  }
                  l(p, h);
                  break;
                } else e(p, h);
                h = h.sibling;
              }
              y.type === yt ? (E = Ra(
                y.props.children,
                p.mode,
                E,
                y.key
              ), E.return = p, p = E) : (E = mu(
                y.type,
                y.key,
                y.props,
                null,
                p.mode,
                E
              ), mi(E, y), E.return = p, p = E);
            }
            return u(p);
          case dt:
            t: {
              for (F = y.key; h !== null; ) {
                if (h.key === F)
                  if (h.tag === 4 && h.stateNode.containerInfo === y.containerInfo && h.stateNode.implementation === y.implementation) {
                    l(
                      p,
                      h.sibling
                    ), E = n(h, y.children || []), E.return = p, p = E;
                    break t;
                  } else {
                    l(p, h);
                    break;
                  }
                else e(p, h);
                h = h.sibling;
              }
              E = wf(y, p.mode, E), E.return = p, p = E;
            }
            return u(p);
          case Ut:
            return y = ja(y), jt(
              p,
              h,
              y,
              E
            );
        }
        if (X(y))
          return Y(
            p,
            h,
            y,
            E
          );
        if (Zt(y)) {
          if (F = Zt(y), typeof F != "function") throw Error(s(150));
          return y = F.call(y), I(
            p,
            h,
            y,
            E
          );
        }
        if (typeof y.then == "function")
          return jt(
            p,
            h,
            xu(y),
            E
          );
        if (y.$$typeof === mt)
          return jt(
            p,
            h,
            pu(p, y),
            E
          );
        Su(p, y);
      }
      return typeof y == "string" && y !== "" || typeof y == "number" || typeof y == "bigint" ? (y = "" + y, h !== null && h.tag === 6 ? (l(p, h.sibling), E = n(h, y), E.return = p, p = E) : (l(p, h), E = Nf(y, p.mode, E), E.return = p, p = E), u(p)) : l(p, h);
    }
    return function(p, h, y, E) {
      try {
        di = 0;
        var F = jt(
          p,
          h,
          y,
          E
        );
        return Tn = null, F;
      } catch (V) {
        if (V === Sn || V === vu) throw V;
        var Et = we(29, V, null, p.mode);
        return Et.lanes = E, Et.return = p, Et;
      }
    };
  }
  var Ga = dr(!0), mr = dr(!1), Wl = !1;
  function Jf(t) {
    t.updateQueue = {
      baseState: t.memoizedState,
      firstBaseUpdate: null,
      lastBaseUpdate: null,
      shared: { pending: null, lanes: 0, hiddenCallbacks: null },
      callbacks: null
    };
  }
  function kf(t, e) {
    t = t.updateQueue, e.updateQueue === t && (e.updateQueue = {
      baseState: t.baseState,
      firstBaseUpdate: t.firstBaseUpdate,
      lastBaseUpdate: t.lastBaseUpdate,
      shared: t.shared,
      callbacks: null
    });
  }
  function $l(t) {
    return { lane: t, tag: 0, payload: null, callback: null, next: null };
  }
  function Il(t, e, l) {
    var a = t.updateQueue;
    if (a === null) return null;
    if (a = a.shared, (Ot & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = du(t), Wo(t, null, l), e;
    }
    return su(t, a, e, l), du(t);
  }
  function hi(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Te(t, l);
    }
  }
  function Ff(t, e) {
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
  var Wf = !1;
  function gi() {
    if (Wf) {
      var t = xn;
      if (t !== null) throw t;
    }
  }
  function pi(t, e, l, a) {
    Wf = !1;
    var n = t.updateQueue;
    Wl = !1;
    var i = n.firstBaseUpdate, u = n.lastBaseUpdate, c = n.shared.pending;
    if (c !== null) {
      n.shared.pending = null;
      var r = c, v = r.next;
      r.next = null, u === null ? i = v : u.next = v, u = r;
      var M = t.alternate;
      M !== null && (M = M.updateQueue, c = M.lastBaseUpdate, c !== u && (c === null ? M.firstBaseUpdate = v : c.next = v, M.lastBaseUpdate = r));
    }
    if (i !== null) {
      var O = n.baseState;
      u = 0, M = v = r = null, c = i;
      do {
        var b = c.lane & -536870913, T = b !== c.lane;
        if (T ? (bt & b) === b : (a & b) === b) {
          b !== 0 && b === bn && (Wf = !0), M !== null && (M = M.next = {
            lane: 0,
            tag: c.tag,
            payload: c.payload,
            callback: null,
            next: null
          });
          t: {
            var Y = t, I = c;
            b = e;
            var jt = l;
            switch (I.tag) {
              case 1:
                if (Y = I.payload, typeof Y == "function") {
                  O = Y.call(jt, O, b);
                  break t;
                }
                O = Y;
                break t;
              case 3:
                Y.flags = Y.flags & -65537 | 128;
              case 0:
                if (Y = I.payload, b = typeof Y == "function" ? Y.call(jt, O, b) : Y, b == null) break t;
                O = w({}, O, b);
                break t;
              case 2:
                Wl = !0;
            }
          }
          b = c.callback, b !== null && (t.flags |= 64, T && (t.flags |= 8192), T = n.callbacks, T === null ? n.callbacks = [b] : T.push(b));
        } else
          T = {
            lane: b,
            tag: c.tag,
            payload: c.payload,
            callback: c.callback,
            next: null
          }, M === null ? (v = M = T, r = O) : M = M.next = T, u |= b;
        if (c = c.next, c === null) {
          if (c = n.shared.pending, c === null)
            break;
          T = c, c = T.next, T.next = null, n.lastBaseUpdate = T, n.shared.pending = null;
        }
      } while (!0);
      M === null && (r = O), n.baseState = r, n.firstBaseUpdate = v, n.lastBaseUpdate = M, i === null && (n.shared.lanes = 0), aa |= u, t.lanes = u, t.memoizedState = O;
    }
  }
  function hr(t, e) {
    if (typeof t != "function")
      throw Error(s(191, t));
    t.call(e);
  }
  function gr(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        hr(l[t], e);
  }
  var zn = m(null), Tu = m(0);
  function pr(t, e) {
    t = Hl, N(Tu, t), N(zn, e), Hl = t | e.baseLanes;
  }
  function $f() {
    N(Tu, Hl), N(zn, zn.current);
  }
  function If() {
    Hl = Tu.current, A(zn), A(Tu);
  }
  var He = m(null), Fe = null;
  function Pl(t) {
    var e = t.alternate;
    N($t, $t.current & 1), N(He, t), Fe === null && (e === null || zn.current !== null || e.memoizedState !== null) && (Fe = t);
  }
  function Pf(t) {
    N($t, $t.current), N(He, t), Fe === null && (Fe = t);
  }
  function yr(t) {
    t.tag === 22 ? (N($t, $t.current), N(He, t), Fe === null && (Fe = t)) : ta();
  }
  function ta() {
    N($t, $t.current), N(He, He.current);
  }
  function je(t) {
    A(He), Fe === t && (Fe = null), A($t);
  }
  var $t = m(0);
  function zu(t) {
    for (var e = t; e !== null; ) {
      if (e.tag === 13) {
        var l = e.memoizedState;
        if (l !== null && (l = l.dehydrated, l === null || io(l) || uo(l)))
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
  var Dl = 0, ot = null, wt = null, le = null, Mu = !1, Mn = !1, Ya = !1, Eu = 0, yi = 0, En = null, Fm = 0;
  function Jt() {
    throw Error(s(321));
  }
  function tc(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!Ne(t[l], e[l])) return !1;
    return !0;
  }
  function ec(t, e, l, a, n, i) {
    return Dl = i, ot = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, g.H = t === null || t.memoizedState === null ? ts : pc, Ya = !1, i = l(a, n), Ya = !1, Mn && (i = br(
      e,
      l,
      a,
      n
    )), vr(t), i;
  }
  function vr(t) {
    g.H = xi;
    var e = wt !== null && wt.next !== null;
    if (Dl = 0, le = wt = ot = null, Mu = !1, yi = 0, En = null, e) throw Error(s(300));
    t === null || ae || (t = t.dependencies, t !== null && gu(t) && (ae = !0));
  }
  function br(t, e, l, a) {
    ot = t;
    var n = 0;
    do {
      if (Mn && (En = null), yi = 0, Mn = !1, 25 <= n) throw Error(s(301));
      if (n += 1, le = wt = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      g.H = es, i = e(l, a);
    } while (Mn);
    return i;
  }
  function Wm() {
    var t = g.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? vi(e) : e, t = t.useState()[0], (wt !== null ? wt.memoizedState : null) !== t && (ot.flags |= 1024), e;
  }
  function lc() {
    var t = Eu !== 0;
    return Eu = 0, t;
  }
  function ac(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function nc(t) {
    if (Mu) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      Mu = !1;
    }
    Dl = 0, le = wt = ot = null, Mn = !1, yi = Eu = 0, En = null;
  }
  function Me() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return le === null ? ot.memoizedState = le = t : le = le.next = t, le;
  }
  function It() {
    if (wt === null) {
      var t = ot.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = wt.next;
    var e = le === null ? ot.memoizedState : le.next;
    if (e !== null)
      le = e, wt = t;
    else {
      if (t === null)
        throw ot.alternate === null ? Error(s(467)) : Error(s(310));
      wt = t, t = {
        memoizedState: wt.memoizedState,
        baseState: wt.baseState,
        baseQueue: wt.baseQueue,
        queue: wt.queue,
        next: null
      }, le === null ? ot.memoizedState = le = t : le = le.next = t;
    }
    return le;
  }
  function Au() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function vi(t) {
    var e = yi;
    return yi += 1, En === null && (En = []), t = or(En, t, e), e = ot, (le === null ? e.memoizedState : le.next) === null && (e = e.alternate, g.H = e === null || e.memoizedState === null ? ts : pc), t;
  }
  function _u(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return vi(t);
      if (t.$$typeof === mt) return ye(t);
    }
    throw Error(s(438, String(t)));
  }
  function ic(t) {
    var e = null, l = ot.updateQueue;
    if (l !== null && (e = l.memoCache), e == null) {
      var a = ot.alternate;
      a !== null && (a = a.updateQueue, a !== null && (a = a.memoCache, a != null && (e = {
        data: a.data.map(function(n) {
          return n.slice();
        }),
        index: 0
      })));
    }
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Au(), ot.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = Ft;
    return e.index++, l;
  }
  function Ol(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function Du(t) {
    var e = It();
    return uc(e, wt, t);
  }
  function uc(t, e, l) {
    var a = t.queue;
    if (a === null) throw Error(s(311));
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
      var c = u = null, r = null, v = e, M = !1;
      do {
        var O = v.lane & -536870913;
        if (O !== v.lane ? (bt & O) === O : (Dl & O) === O) {
          var b = v.revertLane;
          if (b === 0)
            r !== null && (r = r.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: v.action,
              hasEagerState: v.hasEagerState,
              eagerState: v.eagerState,
              next: null
            }), O === bn && (M = !0);
          else if ((Dl & b) === b) {
            v = v.next, b === bn && (M = !0);
            continue;
          } else
            O = {
              lane: 0,
              revertLane: v.revertLane,
              gesture: null,
              action: v.action,
              hasEagerState: v.hasEagerState,
              eagerState: v.eagerState,
              next: null
            }, r === null ? (c = r = O, u = i) : r = r.next = O, ot.lanes |= b, aa |= b;
          O = v.action, Ya && l(i, O), i = v.hasEagerState ? v.eagerState : l(i, O);
        } else
          b = {
            lane: O,
            revertLane: v.revertLane,
            gesture: v.gesture,
            action: v.action,
            hasEagerState: v.hasEagerState,
            eagerState: v.eagerState,
            next: null
          }, r === null ? (c = r = b, u = i) : r = r.next = b, ot.lanes |= O, aa |= O;
        v = v.next;
      } while (v !== null && v !== e);
      if (r === null ? u = i : r.next = c, !Ne(i, t.memoizedState) && (ae = !0, M && (l = xn, l !== null)))
        throw l;
      t.memoizedState = i, t.baseState = u, t.baseQueue = r, a.lastRenderedState = i;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function fc(t) {
    var e = It(), l = e.queue;
    if (l === null) throw Error(s(311));
    l.lastRenderedReducer = t;
    var a = l.dispatch, n = l.pending, i = e.memoizedState;
    if (n !== null) {
      l.pending = null;
      var u = n = n.next;
      do
        i = t(i, u.action), u = u.next;
      while (u !== n);
      Ne(i, e.memoizedState) || (ae = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function xr(t, e, l) {
    var a = ot, n = It(), i = St;
    if (i) {
      if (l === void 0) throw Error(s(407));
      l = l();
    } else l = e();
    var u = !Ne(
      (wt || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, ae = !0), n = n.queue, rc(zr.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || le !== null && le.memoizedState.tag & 1) {
      if (a.flags |= 2048, An(
        9,
        { destroy: void 0 },
        Tr.bind(
          null,
          a,
          n,
          l,
          e
        ),
        null
      ), qt === null) throw Error(s(349));
      i || (Dl & 127) !== 0 || Sr(a, e, l);
    }
    return l;
  }
  function Sr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = ot.updateQueue, e === null ? (e = Au(), ot.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
  }
  function Tr(t, e, l, a) {
    e.value = l, e.getSnapshot = a, Mr(e) && Er(t);
  }
  function zr(t, e, l) {
    return l(function() {
      Mr(e) && Er(t);
    });
  }
  function Mr(t) {
    var e = t.getSnapshot;
    t = t.value;
    try {
      var l = e();
      return !Ne(t, l);
    } catch {
      return !0;
    }
  }
  function Er(t) {
    var e = Ua(t, 2);
    e !== null && Ce(e, t, 2);
  }
  function cc(t) {
    var e = Me();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Ya) {
        il(!0);
        try {
          l();
        } finally {
          il(!1);
        }
      }
    }
    return e.memoizedState = e.baseState = t, e.queue = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Ol,
      lastRenderedState: t
    }, e;
  }
  function Ar(t, e, l, a) {
    return t.baseState = l, uc(
      t,
      wt,
      typeof a == "function" ? a : Ol
    );
  }
  function $m(t, e, l, a, n) {
    if (Uu(t)) throw Error(s(485));
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
      g.T !== null ? l(!0) : i.isTransition = !1, a(i), l = e.pending, l === null ? (i.next = e.pending = i, _r(e, i)) : (i.next = l.next, e.pending = l.next = i);
    }
  }
  function _r(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var i = g.T, u = {};
      g.T = u;
      try {
        var c = l(n, a), r = g.S;
        r !== null && r(u, c), Dr(t, e, c);
      } catch (v) {
        oc(t, e, v);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), g.T = i;
      }
    } else
      try {
        i = l(n, a), Dr(t, e, i);
      } catch (v) {
        oc(t, e, v);
      }
  }
  function Dr(t, e, l) {
    l !== null && typeof l == "object" && typeof l.then == "function" ? l.then(
      function(a) {
        Or(t, e, a);
      },
      function(a) {
        return oc(t, e, a);
      }
    ) : Or(t, e, l);
  }
  function Or(t, e, l) {
    e.status = "fulfilled", e.value = l, Cr(e), t.state = l, e = t.pending, e !== null && (l = e.next, l === e ? t.pending = null : (l = l.next, e.next = l, _r(t, l)));
  }
  function oc(t, e, l) {
    var a = t.pending;
    if (t.pending = null, a !== null) {
      a = a.next;
      do
        e.status = "rejected", e.reason = l, Cr(e), e = e.next;
      while (e !== a);
    }
    t.action = null;
  }
  function Cr(t) {
    t = t.listeners;
    for (var e = 0; e < t.length; e++) (0, t[e])();
  }
  function Ur(t, e) {
    return e;
  }
  function Rr(t, e) {
    if (St) {
      var l = qt.formState;
      if (l !== null) {
        t: {
          var a = ot;
          if (St) {
            if (Lt) {
              e: {
                for (var n = Lt, i = ke; n.nodeType !== 8; ) {
                  if (!i) {
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
                i = n.data, n = i === "F!" || i === "F" ? n : null;
              }
              if (n) {
                Lt = We(
                  n.nextSibling
                ), a = n.data === "F!";
                break t;
              }
            }
            kl(a);
          }
          a = !1;
        }
        a && (e = l[0]);
      }
    }
    return l = Me(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Ur,
      lastRenderedState: e
    }, l.queue = a, l = $r.bind(
      null,
      ot,
      a
    ), a.dispatch = l, a = cc(!1), i = gc.bind(
      null,
      ot,
      !1,
      a.queue
    ), a = Me(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = $m.bind(
      null,
      ot,
      n,
      i,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Br(t) {
    var e = It();
    return Nr(e, wt, t);
  }
  function Nr(t, e, l) {
    if (e = uc(
      t,
      e,
      Ur
    )[0], t = Du(Ol)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = vi(e);
      } catch (u) {
        throw u === Sn ? vu : u;
      }
    else a = e;
    e = It();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (ot.flags |= 2048, An(
      9,
      { destroy: void 0 },
      Im.bind(null, n, l),
      null
    )), [a, i, t];
  }
  function Im(t, e) {
    t.action = e;
  }
  function wr(t) {
    var e = It(), l = wt;
    if (l !== null)
      return Nr(e, l, t);
    It(), e = e.memoizedState, l = It();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function An(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = ot.updateQueue, e === null && (e = Au(), ot.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Hr() {
    return It().memoizedState;
  }
  function Ou(t, e, l, a) {
    var n = Me();
    ot.flags |= t, n.memoizedState = An(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Cu(t, e, l, a) {
    var n = It();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    wt !== null && a !== null && tc(a, wt.memoizedState.deps) ? n.memoizedState = An(e, i, l, a) : (ot.flags |= t, n.memoizedState = An(
      1 | e,
      i,
      l,
      a
    ));
  }
  function jr(t, e) {
    Ou(8390656, 8, t, e);
  }
  function rc(t, e) {
    Cu(2048, 8, t, e);
  }
  function Pm(t) {
    ot.flags |= 4;
    var e = ot.updateQueue;
    if (e === null)
      e = Au(), ot.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function qr(t) {
    var e = It().memoizedState;
    return Pm({ ref: e, nextImpl: t }), function() {
      if ((Ot & 2) !== 0) throw Error(s(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function Gr(t, e) {
    return Cu(4, 2, t, e);
  }
  function Yr(t, e) {
    return Cu(4, 4, t, e);
  }
  function Lr(t, e) {
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
  function Xr(t, e, l) {
    l = l != null ? l.concat([t]) : null, Cu(4, 4, Lr.bind(null, e, t), l);
  }
  function sc() {
  }
  function Qr(t, e) {
    var l = It();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && tc(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Vr(t, e) {
    var l = It();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && tc(e, a[1]))
      return a[0];
    if (a = t(), Ya) {
      il(!0);
      try {
        t();
      } finally {
        il(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function dc(t, e, l) {
    return l === void 0 || (Dl & 1073741824) !== 0 && (bt & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Zs(), ot.lanes |= t, aa |= t, l);
  }
  function Zr(t, e, l, a) {
    return Ne(l, e) ? l : zn.current !== null ? (t = dc(t, l, a), Ne(t, e) || (ae = !0), t) : (Dl & 42) === 0 || (Dl & 1073741824) !== 0 && (bt & 261930) === 0 ? (ae = !0, t.memoizedState = l) : (t = Zs(), ot.lanes |= t, aa |= t, e);
  }
  function Kr(t, e, l, a, n) {
    var i = U.p;
    U.p = i !== 0 && 8 > i ? i : 8;
    var u = g.T, c = {};
    g.T = c, gc(t, !1, e, l);
    try {
      var r = n(), v = g.S;
      if (v !== null && v(c, r), r !== null && typeof r == "object" && typeof r.then == "function") {
        var M = km(
          r,
          a
        );
        bi(
          t,
          e,
          M,
          Ye(t)
        );
      } else
        bi(
          t,
          e,
          a,
          Ye(t)
        );
    } catch (O) {
      bi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: O },
        Ye()
      );
    } finally {
      U.p = i, u !== null && c.types !== null && (u.types = c.types), g.T = u;
    }
  }
  function th() {
  }
  function mc(t, e, l, a) {
    if (t.tag !== 5) throw Error(s(476));
    var n = Jr(t).queue;
    Kr(
      t,
      n,
      e,
      Z,
      l === null ? th : function() {
        return kr(t), l(a);
      }
    );
  }
  function Jr(t) {
    var e = t.memoizedState;
    if (e !== null) return e;
    e = {
      memoizedState: Z,
      baseState: Z,
      baseQueue: null,
      queue: {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: Ol,
        lastRenderedState: Z
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
        lastRenderedReducer: Ol,
        lastRenderedState: l
      },
      next: null
    }, t.memoizedState = e, t = t.alternate, t !== null && (t.memoizedState = e), e;
  }
  function kr(t) {
    var e = Jr(t);
    e.next === null && (e = t.alternate.memoizedState), bi(
      t,
      e.next.queue,
      {},
      Ye()
    );
  }
  function hc() {
    return ye(Hi);
  }
  function Fr() {
    return It().memoizedState;
  }
  function Wr() {
    return It().memoizedState;
  }
  function eh(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = Ye();
          t = $l(l);
          var a = Il(e, t, l);
          a !== null && (Ce(a, e, l), hi(a, e, l)), e = { cache: Qf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function lh(t, e, l) {
    var a = Ye();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Uu(t) ? Ir(e, l) : (l = Rf(t, e, l, a), l !== null && (Ce(l, t, a), Pr(l, e, a)));
  }
  function $r(t, e, l) {
    var a = Ye();
    bi(t, e, l, a);
  }
  function bi(t, e, l, a) {
    var n = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    };
    if (Uu(t)) Ir(e, n);
    else {
      var i = t.alternate;
      if (t.lanes === 0 && (i === null || i.lanes === 0) && (i = e.lastRenderedReducer, i !== null))
        try {
          var u = e.lastRenderedState, c = i(u, l);
          if (n.hasEagerState = !0, n.eagerState = c, Ne(c, u))
            return su(t, e, n, 0), qt === null && ru(), !1;
        } catch {
        }
      if (l = Rf(t, e, n, a), l !== null)
        return Ce(l, t, a), Pr(l, e, a), !0;
    }
    return !1;
  }
  function gc(t, e, l, a) {
    if (a = {
      lane: 2,
      revertLane: Jc(),
      gesture: null,
      action: a,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Uu(t)) {
      if (e) throw Error(s(479));
    } else
      e = Rf(
        t,
        l,
        a,
        2
      ), e !== null && Ce(e, t, 2);
  }
  function Uu(t) {
    var e = t.alternate;
    return t === ot || e !== null && e === ot;
  }
  function Ir(t, e) {
    Mn = Mu = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function Pr(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Te(t, l);
    }
  }
  var xi = {
    readContext: ye,
    use: _u,
    useCallback: Jt,
    useContext: Jt,
    useEffect: Jt,
    useImperativeHandle: Jt,
    useLayoutEffect: Jt,
    useInsertionEffect: Jt,
    useMemo: Jt,
    useReducer: Jt,
    useRef: Jt,
    useState: Jt,
    useDebugValue: Jt,
    useDeferredValue: Jt,
    useTransition: Jt,
    useSyncExternalStore: Jt,
    useId: Jt,
    useHostTransitionStatus: Jt,
    useFormState: Jt,
    useActionState: Jt,
    useOptimistic: Jt,
    useMemoCache: Jt,
    useCacheRefresh: Jt
  };
  xi.useEffectEvent = Jt;
  var ts = {
    readContext: ye,
    use: _u,
    useCallback: function(t, e) {
      return Me().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: ye,
    useEffect: jr,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, Ou(
        4194308,
        4,
        Lr.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return Ou(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      Ou(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = Me();
      e = e === void 0 ? null : e;
      var a = t();
      if (Ya) {
        il(!0);
        try {
          t();
        } finally {
          il(!1);
        }
      }
      return l.memoizedState = [a, e], a;
    },
    useReducer: function(t, e, l) {
      var a = Me();
      if (l !== void 0) {
        var n = l(e);
        if (Ya) {
          il(!0);
          try {
            l(e);
          } finally {
            il(!1);
          }
        }
      } else n = e;
      return a.memoizedState = a.baseState = n, t = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: t,
        lastRenderedState: n
      }, a.queue = t, t = t.dispatch = lh.bind(
        null,
        ot,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = Me();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = cc(t);
      var e = t.queue, l = $r.bind(null, ot, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: sc,
    useDeferredValue: function(t, e) {
      var l = Me();
      return dc(l, t, e);
    },
    useTransition: function() {
      var t = cc(!1);
      return t = Kr.bind(
        null,
        ot,
        t.queue,
        !0,
        !1
      ), Me().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = ot, n = Me();
      if (St) {
        if (l === void 0)
          throw Error(s(407));
        l = l();
      } else {
        if (l = e(), qt === null)
          throw Error(s(349));
        (bt & 127) !== 0 || Sr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, jr(zr.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, An(
        9,
        { destroy: void 0 },
        Tr.bind(
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
      var t = Me(), e = qt.identifierPrefix;
      if (St) {
        var l = hl, a = ml;
        l = (a & ~(1 << 32 - ue(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = Eu++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Fm++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: hc,
    useFormState: Rr,
    useActionState: Rr,
    useOptimistic: function(t) {
      var e = Me();
      e.memoizedState = e.baseState = t;
      var l = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: null,
        lastRenderedState: null
      };
      return e.queue = l, e = gc.bind(
        null,
        ot,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: ic,
    useCacheRefresh: function() {
      return Me().memoizedState = eh.bind(
        null,
        ot
      );
    },
    useEffectEvent: function(t) {
      var e = Me(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((Ot & 2) !== 0)
          throw Error(s(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, pc = {
    readContext: ye,
    use: _u,
    useCallback: Qr,
    useContext: ye,
    useEffect: rc,
    useImperativeHandle: Xr,
    useInsertionEffect: Gr,
    useLayoutEffect: Yr,
    useMemo: Vr,
    useReducer: Du,
    useRef: Hr,
    useState: function() {
      return Du(Ol);
    },
    useDebugValue: sc,
    useDeferredValue: function(t, e) {
      var l = It();
      return Zr(
        l,
        wt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = Du(Ol)[0], e = It().memoizedState;
      return [
        typeof t == "boolean" ? t : vi(t),
        e
      ];
    },
    useSyncExternalStore: xr,
    useId: Fr,
    useHostTransitionStatus: hc,
    useFormState: Br,
    useActionState: Br,
    useOptimistic: function(t, e) {
      var l = It();
      return Ar(l, wt, t, e);
    },
    useMemoCache: ic,
    useCacheRefresh: Wr
  };
  pc.useEffectEvent = qr;
  var es = {
    readContext: ye,
    use: _u,
    useCallback: Qr,
    useContext: ye,
    useEffect: rc,
    useImperativeHandle: Xr,
    useInsertionEffect: Gr,
    useLayoutEffect: Yr,
    useMemo: Vr,
    useReducer: fc,
    useRef: Hr,
    useState: function() {
      return fc(Ol);
    },
    useDebugValue: sc,
    useDeferredValue: function(t, e) {
      var l = It();
      return wt === null ? dc(l, t, e) : Zr(
        l,
        wt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = fc(Ol)[0], e = It().memoizedState;
      return [
        typeof t == "boolean" ? t : vi(t),
        e
      ];
    },
    useSyncExternalStore: xr,
    useId: Fr,
    useHostTransitionStatus: hc,
    useFormState: wr,
    useActionState: wr,
    useOptimistic: function(t, e) {
      var l = It();
      return wt !== null ? Ar(l, wt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ic,
    useCacheRefresh: Wr
  };
  es.useEffectEvent = qr;
  function yc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : w({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var vc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = Ye(), n = $l(a);
      n.payload = e, l != null && (n.callback = l), e = Il(t, n, a), e !== null && (Ce(e, t, a), hi(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = Ye(), n = $l(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = Il(t, n, a), e !== null && (Ce(e, t, a), hi(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = Ye(), a = $l(l);
      a.tag = 2, e != null && (a.callback = e), e = Il(t, a, l), e !== null && (Ce(e, t, l), hi(e, t, l));
    }
  };
  function ls(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ui(l, a) || !ui(n, i) : !0;
  }
  function as(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && vc.enqueueReplaceState(e, e.state, null);
  }
  function La(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = w({}, l));
      for (var n in t)
        l[n] === void 0 && (l[n] = t[n]);
    }
    return l;
  }
  function ns(t) {
    ou(t);
  }
  function is(t) {
    console.error(t);
  }
  function us(t) {
    ou(t);
  }
  function Ru(t, e) {
    try {
      var l = t.onUncaughtError;
      l(e.value, { componentStack: e.stack });
    } catch (a) {
      setTimeout(function() {
        throw a;
      });
    }
  }
  function fs(t, e, l) {
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
  function bc(t, e, l) {
    return l = $l(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Ru(t, e);
    }, l;
  }
  function cs(t) {
    return t = $l(t), t.tag = 3, t;
  }
  function os(t, e, l, a) {
    var n = l.type.getDerivedStateFromError;
    if (typeof n == "function") {
      var i = a.value;
      t.payload = function() {
        return n(i);
      }, t.callback = function() {
        fs(e, l, a);
      };
    }
    var u = l.stateNode;
    u !== null && typeof u.componentDidCatch == "function" && (t.callback = function() {
      fs(e, l, a), typeof n != "function" && (na === null ? na = /* @__PURE__ */ new Set([this]) : na.add(this));
      var c = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: c !== null ? c : ""
      });
    });
  }
  function ah(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && vn(
        e,
        l,
        n,
        !0
      ), l = He.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return Fe === null ? Vu() : l.alternate === null && kt === 0 && (kt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === bu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Vc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === bu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Vc(t, a, n)), !1;
        }
        throw Error(s(435, l.tag));
      }
      return Vc(t, a, n), Vu(), !1;
    }
    if (St)
      return e = He.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== qf && (t = Error(s(422), { cause: a }), oi(Ze(t, l)))) : (a !== qf && (e = Error(s(423), {
        cause: a
      }), oi(
        Ze(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ze(a, l), n = bc(
        t.stateNode,
        a,
        n
      ), Ff(t, n), kt !== 4 && (kt = 2)), !1;
    var i = Error(s(520), { cause: a });
    if (i = Ze(i, l), Di === null ? Di = [i] : Di.push(i), kt !== 4 && (kt = 2), e === null) return !0;
    a = Ze(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = bc(l.stateNode, a, t), Ff(l, t), !1;
        case 1:
          if (e = l.type, i = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || i !== null && typeof i.componentDidCatch == "function" && (na === null || !na.has(i))))
            return l.flags |= 65536, n &= -n, l.lanes |= n, n = cs(n), os(
              n,
              t,
              l,
              a
            ), Ff(l, n), !1;
      }
      l = l.return;
    } while (l !== null);
    return !1;
  }
  var xc = Error(s(461)), ae = !1;
  function ve(t, e, l, a) {
    e.child = t === null ? mr(e, null, l, a) : Ga(
      e,
      t.child,
      l,
      a
    );
  }
  function rs(t, e, l, a, n) {
    l = l.render;
    var i = e.ref;
    if ("ref" in a) {
      var u = {};
      for (var c in a)
        c !== "ref" && (u[c] = a[c]);
    } else u = a;
    return wa(e), a = ec(
      t,
      e,
      l,
      u,
      i,
      n
    ), c = lc(), t !== null && !ae ? (ac(t, e, n), Cl(t, e, n)) : (St && c && Hf(e), e.flags |= 1, ve(t, e, a, n), e.child);
  }
  function ss(t, e, l, a, n) {
    if (t === null) {
      var i = l.type;
      return typeof i == "function" && !Bf(i) && i.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = i, ds(
        t,
        e,
        i,
        a,
        n
      )) : (t = mu(
        l.type,
        null,
        a,
        e,
        e.mode,
        n
      ), t.ref = e.ref, t.return = e, e.child = t);
    }
    if (i = t.child, !Dc(t, n)) {
      var u = i.memoizedProps;
      if (l = l.compare, l = l !== null ? l : ui, l(u, a) && t.ref === e.ref)
        return Cl(t, e, n);
    }
    return e.flags |= 1, t = Ml(i, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function ds(t, e, l, a, n) {
    if (t !== null) {
      var i = t.memoizedProps;
      if (ui(i, a) && t.ref === e.ref)
        if (ae = !1, e.pendingProps = a = i, Dc(t, n))
          (t.flags & 131072) !== 0 && (ae = !0);
        else
          return e.lanes = t.lanes, Cl(t, e, n);
    }
    return Sc(
      t,
      e,
      l,
      a,
      n
    );
  }
  function ms(t, e, l, a) {
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
        return hs(
          t,
          e,
          i,
          l,
          a
        );
      }
      if ((l & 536870912) !== 0)
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && yu(
          e,
          i !== null ? i.cachePool : null
        ), i !== null ? pr(e, i) : $f(), yr(e);
      else
        return a = e.lanes = 536870912, hs(
          t,
          e,
          i !== null ? i.baseLanes | l : l,
          l,
          a
        );
    } else
      i !== null ? (yu(e, i.cachePool), pr(e, i), ta(), e.memoizedState = null) : (t !== null && yu(e, null), $f(), ta());
    return ve(t, e, n, l), e.child;
  }
  function Si(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function hs(t, e, l, a, n) {
    var i = Zf();
    return i = i === null ? null : { parent: ee._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && yu(e, null), $f(), yr(e), t !== null && vn(t, e, a, !0), e.childLanes = n, null;
  }
  function Bu(t, e) {
    return e = wu(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function gs(t, e, l) {
    return Ga(e, t.child, null, l), t = Bu(e, e.pendingProps), t.flags |= 2, je(e), e.memoizedState = null, t;
  }
  function nh(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (St) {
        if (a.mode === "hidden")
          return t = Bu(e, a), e.lanes = 536870912, Si(null, t);
        if (Pf(e), (t = Lt) ? (t = _d(
          t,
          ke
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Kl !== null ? { id: ml, overflow: hl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Io(t), l.return = e, e.child = l, pe = e, Lt = null)) : t = null, t === null) throw kl(e);
        return e.lanes = 536870912, null;
      }
      return Bu(e, a);
    }
    var i = t.memoizedState;
    if (i !== null) {
      var u = i.dehydrated;
      if (Pf(e), n)
        if (e.flags & 256)
          e.flags &= -257, e = gs(
            t,
            e,
            l
          );
        else if (e.memoizedState !== null)
          e.child = t.child, e.flags |= 128, e = null;
        else throw Error(s(558));
      else if (ae || vn(t, e, l, !1), n = (l & t.childLanes) !== 0, ae || n) {
        if (a = qt, a !== null && (u = Wa(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, Ua(t, u), Ce(a, t, u), xc;
        Vu(), e = gs(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, Lt = We(u.nextSibling), pe = e, St = !0, Jl = null, ke = !1, t !== null && er(e, t), e = Bu(e, a), e.flags |= 4096;
      return e;
    }
    return t = Ml(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Nu(t, e) {
    var l = e.ref;
    if (l === null)
      t !== null && t.ref !== null && (e.flags |= 4194816);
    else {
      if (typeof l != "function" && typeof l != "object")
        throw Error(s(284));
      (t === null || t.ref !== l) && (e.flags |= 4194816);
    }
  }
  function Sc(t, e, l, a, n) {
    return wa(e), l = ec(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = lc(), t !== null && !ae ? (ac(t, e, n), Cl(t, e, n)) : (St && a && Hf(e), e.flags |= 1, ve(t, e, l, n), e.child);
  }
  function ps(t, e, l, a, n, i) {
    return wa(e), e.updateQueue = null, l = br(
      e,
      a,
      l,
      n
    ), vr(t), a = lc(), t !== null && !ae ? (ac(t, e, i), Cl(t, e, i)) : (St && a && Hf(e), e.flags |= 1, ve(t, e, l, i), e.child);
  }
  function ys(t, e, l, a, n) {
    if (wa(e), e.stateNode === null) {
      var i = hn, u = l.contextType;
      typeof u == "object" && u !== null && (i = ye(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = vc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Jf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? ye(u) : hn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (yc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && vc.enqueueReplaceState(i, i.state, null), pi(e, a, i, n), gi(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var c = e.memoizedProps, r = La(l, c);
      i.props = r;
      var v = i.context, M = l.contextType;
      u = hn, typeof M == "object" && M !== null && (u = ye(M));
      var O = l.getDerivedStateFromProps;
      M = typeof O == "function" || typeof i.getSnapshotBeforeUpdate == "function", c = e.pendingProps !== c, M || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (c || v !== u) && as(
        e,
        i,
        a,
        u
      ), Wl = !1;
      var b = e.memoizedState;
      i.state = b, pi(e, a, i, n), gi(), v = e.memoizedState, c || b !== v || Wl ? (typeof O == "function" && (yc(
        e,
        l,
        O,
        a
      ), v = e.memoizedState), (r = Wl || ls(
        e,
        l,
        r,
        a,
        b,
        v,
        u
      )) ? (M || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = v), i.props = a, i.state = v, i.context = u, a = r) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, kf(t, e), u = e.memoizedProps, M = La(l, u), i.props = M, O = e.pendingProps, b = i.context, v = l.contextType, r = hn, typeof v == "object" && v !== null && (r = ye(v)), c = l.getDerivedStateFromProps, (v = typeof c == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== O || b !== r) && as(
        e,
        i,
        a,
        r
      ), Wl = !1, b = e.memoizedState, i.state = b, pi(e, a, i, n), gi();
      var T = e.memoizedState;
      u !== O || b !== T || Wl || t !== null && t.dependencies !== null && gu(t.dependencies) ? (typeof c == "function" && (yc(
        e,
        l,
        c,
        a
      ), T = e.memoizedState), (M = Wl || ls(
        e,
        l,
        M,
        a,
        b,
        T,
        r
      ) || t !== null && t.dependencies !== null && gu(t.dependencies)) ? (v || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, T, r), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        T,
        r
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = T), i.props = a, i.state = T, i.context = r, a = M) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return i = a, Nu(t, e), a = (e.flags & 128) !== 0, i || a ? (i = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : i.render(), e.flags |= 1, t !== null && a ? (e.child = Ga(
      e,
      t.child,
      null,
      n
    ), e.child = Ga(
      e,
      null,
      l,
      n
    )) : ve(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = Cl(
      t,
      e,
      n
    ), t;
  }
  function vs(t, e, l, a) {
    return Ba(), e.flags |= 256, ve(t, e, l, a), e.child;
  }
  var Tc = {
    dehydrated: null,
    treeContext: null,
    retryLane: 0,
    hydrationErrors: null
  };
  function zc(t) {
    return { baseLanes: t, cachePool: fr() };
  }
  function Mc(t, e, l) {
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= Ge), t;
  }
  function bs(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : ($t.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (St) {
        if (n ? Pl(e) : ta(), (t = Lt) ? (t = _d(
          t,
          ke
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Kl !== null ? { id: ml, overflow: hl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Io(t), l.return = e, e.child = l, pe = e, Lt = null)) : t = null, t === null) throw kl(e);
        return uo(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var c = a.children;
      return a = a.fallback, n ? (ta(), n = e.mode, c = wu(
        { mode: "hidden", children: c },
        n
      ), a = Ra(
        a,
        n,
        l,
        null
      ), c.return = e, a.return = e, c.sibling = a, e.child = c, a = e.child, a.memoizedState = zc(l), a.childLanes = Mc(
        t,
        u,
        l
      ), e.memoizedState = Tc, Si(null, a)) : (Pl(e), Ec(e, c));
    }
    var r = t.memoizedState;
    if (r !== null && (c = r.dehydrated, c !== null)) {
      if (i)
        e.flags & 256 ? (Pl(e), e.flags &= -257, e = Ac(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (ta(), e.child = t.child, e.flags |= 128, e = null) : (ta(), c = a.fallback, n = e.mode, a = wu(
          { mode: "visible", children: a.children },
          n
        ), c = Ra(
          c,
          n,
          l,
          null
        ), c.flags |= 2, a.return = e, c.return = e, a.sibling = c, e.child = a, Ga(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = zc(l), a.childLanes = Mc(
          t,
          u,
          l
        ), e.memoizedState = Tc, e = Si(null, a));
      else if (Pl(e), uo(c)) {
        if (u = c.nextSibling && c.nextSibling.dataset, u) var v = u.dgst;
        u = v, a = Error(s(419)), a.stack = "", a.digest = u, oi({ value: a, source: null, stack: null }), e = Ac(
          t,
          e,
          l
        );
      } else if (ae || vn(t, e, l, !1), u = (l & t.childLanes) !== 0, ae || u) {
        if (u = qt, u !== null && (a = Wa(u, l), a !== 0 && a !== r.retryLane))
          throw r.retryLane = a, Ua(t, a), Ce(u, t, a), xc;
        io(c) || Vu(), e = Ac(
          t,
          e,
          l
        );
      } else
        io(c) ? (e.flags |= 192, e.child = t.child, e = null) : (t = r.treeContext, Lt = We(
          c.nextSibling
        ), pe = e, St = !0, Jl = null, ke = !1, t !== null && er(e, t), e = Ec(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (ta(), c = a.fallback, n = e.mode, r = t.child, v = r.sibling, a = Ml(r, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = r.subtreeFlags & 65011712, v !== null ? c = Ml(
      v,
      c
    ) : (c = Ra(
      c,
      n,
      l,
      null
    ), c.flags |= 2), c.return = e, a.return = e, a.sibling = c, e.child = a, Si(null, a), a = e.child, c = t.child.memoizedState, c === null ? c = zc(l) : (n = c.cachePool, n !== null ? (r = ee._currentValue, n = n.parent !== r ? { parent: r, pool: r } : n) : n = fr(), c = {
      baseLanes: c.baseLanes | l,
      cachePool: n
    }), a.memoizedState = c, a.childLanes = Mc(
      t,
      u,
      l
    ), e.memoizedState = Tc, Si(t.child, a)) : (Pl(e), l = t.child, t = l.sibling, l = Ml(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function Ec(t, e) {
    return e = wu(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function wu(t, e) {
    return t = we(22, t, null, e), t.lanes = 0, t;
  }
  function Ac(t, e, l) {
    return Ga(e, t.child, null, l), t = Ec(
      e,
      e.pendingProps.children
    ), t.flags |= 2, e.memoizedState = null, t;
  }
  function xs(t, e, l) {
    t.lanes |= e;
    var a = t.alternate;
    a !== null && (a.lanes |= e), Lf(t.return, e, l);
  }
  function _c(t, e, l, a, n, i) {
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
  function Ss(t, e, l) {
    var a = e.pendingProps, n = a.revealOrder, i = a.tail;
    a = a.children;
    var u = $t.current, c = (u & 2) !== 0;
    if (c ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, N($t, u), ve(t, e, a, l), a = St ? ci : 0, !c && t !== null && (t.flags & 128) !== 0)
      t: for (t = e.child; t !== null; ) {
        if (t.tag === 13)
          t.memoizedState !== null && xs(t, l, e);
        else if (t.tag === 19)
          xs(t, l, e);
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
          t = l.alternate, t !== null && zu(t) === null && (n = l), l = l.sibling;
        l = n, l === null ? (n = e.child, e.child = null) : (n = l.sibling, l.sibling = null), _c(
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
          if (t = n.alternate, t !== null && zu(t) === null) {
            e.child = n;
            break;
          }
          t = n.sibling, n.sibling = l, l = n, n = t;
        }
        _c(
          e,
          !0,
          l,
          null,
          i,
          a
        );
        break;
      case "together":
        _c(
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
  function Cl(t, e, l) {
    if (t !== null && (e.dependencies = t.dependencies), aa |= e.lanes, (l & e.childLanes) === 0)
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
      throw Error(s(153));
    if (e.child !== null) {
      for (t = e.child, l = Ml(t, t.pendingProps), e.child = l, l.return = e; t.sibling !== null; )
        t = t.sibling, l = l.sibling = Ml(t, t.pendingProps), l.return = e;
      l.sibling = null;
    }
    return e.child;
  }
  function Dc(t, e) {
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && gu(t)));
  }
  function ih(t, e, l) {
    switch (e.tag) {
      case 3:
        oe(e, e.stateNode.containerInfo), Fl(e, ee, t.memoizedState.cache), Ba();
        break;
      case 27:
      case 5:
        yl(e);
        break;
      case 4:
        oe(e, e.stateNode.containerInfo);
        break;
      case 10:
        Fl(
          e,
          e.type,
          e.memoizedProps.value
        );
        break;
      case 31:
        if (e.memoizedState !== null)
          return e.flags |= 128, Pf(e), null;
        break;
      case 13:
        var a = e.memoizedState;
        if (a !== null)
          return a.dehydrated !== null ? (Pl(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? bs(t, e, l) : (Pl(e), t = Cl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        Pl(e);
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
            return Ss(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), N($t, $t.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, ms(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        Fl(e, ee, t.memoizedState.cache);
    }
    return Cl(t, e, l);
  }
  function Ts(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        ae = !0;
      else {
        if (!Dc(t, l) && (e.flags & 128) === 0)
          return ae = !1, ih(
            t,
            e,
            l
          );
        ae = (t.flags & 131072) !== 0;
      }
    else
      ae = !1, St && (e.flags & 1048576) !== 0 && tr(e, ci, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = ja(e.elementType), e.type = t, typeof t == "function")
            Bf(t) ? (a = La(t, a), e.tag = 1, e = ys(
              null,
              e,
              t,
              a,
              l
            )) : (e.tag = 0, e = Sc(
              null,
              e,
              t,
              a,
              l
            ));
          else {
            if (t != null) {
              var n = t.$$typeof;
              if (n === _t) {
                e.tag = 11, e = rs(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === $) {
                e.tag = 14, e = ss(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              }
            }
            throw e = ie(t) || t, Error(s(306, e, ""));
          }
        }
        return e;
      case 0:
        return Sc(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 1:
        return a = e.type, n = La(
          a,
          e.pendingProps
        ), ys(
          t,
          e,
          a,
          n,
          l
        );
      case 3:
        t: {
          if (oe(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(s(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, kf(t, e), pi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, Fl(e, ee, a), a !== i.cache && Xf(
            e,
            [ee],
            l,
            !0
          ), gi(), a = u.element, i.isDehydrated)
            if (i = {
              element: a,
              isDehydrated: !1,
              cache: u.cache
            }, e.updateQueue.baseState = i, e.memoizedState = i, e.flags & 256) {
              e = vs(
                t,
                e,
                a,
                l
              );
              break t;
            } else if (a !== n) {
              n = Ze(
                Error(s(424)),
                e
              ), oi(n), e = vs(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Lt = We(t.firstChild), pe = e, St = !0, Jl = null, ke = !0, l = mr(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (Ba(), a === n) {
              e = Cl(
                t,
                e,
                l
              );
              break t;
            }
            ve(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Nu(t, e), t === null ? (l = Bd(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : St || (l = e.type, t = e.pendingProps, a = $u(
          ft.current
        ).createElement(l), a[te] = e, a[he] = t, be(a, l, t), Wt(a), e.stateNode = a) : e.memoizedState = Bd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return yl(e), t === null && St && (a = e.stateNode = Cd(
          e.type,
          e.pendingProps,
          ft.current
        ), pe = e, ke = !0, n = Lt, ca(e.type) ? (fo = n, Lt = We(a.firstChild)) : Lt = n), ve(
          t,
          e,
          e.pendingProps.children,
          l
        ), Nu(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && St && ((n = a = Lt) && (a = wh(
          a,
          e.type,
          e.pendingProps,
          ke
        ), a !== null ? (e.stateNode = a, pe = e, Lt = We(a.firstChild), ke = !1, n = !0) : n = !1), n || kl(e)), yl(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, lo(n, i) ? a = null : u !== null && lo(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = ec(
          t,
          e,
          Wm,
          null,
          null,
          l
        ), Hi._currentValue = n), Nu(t, e), ve(t, e, a, l), e.child;
      case 6:
        return t === null && St && ((t = l = Lt) && (l = Hh(
          l,
          e.pendingProps,
          ke
        ), l !== null ? (e.stateNode = l, pe = e, Lt = null, t = !0) : t = !1), t || kl(e)), null;
      case 13:
        return bs(t, e, l);
      case 4:
        return oe(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = Ga(
          e,
          null,
          a,
          l
        ) : ve(t, e, a, l), e.child;
      case 11:
        return rs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return ve(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return ve(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return ve(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, Fl(e, e.type, a.value), ve(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, wa(e), n = ye(n), a = a(n), e.flags |= 1, ve(t, e, a, l), e.child;
      case 14:
        return ss(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 15:
        return ds(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 19:
        return Ss(t, e, l);
      case 31:
        return nh(t, e, l);
      case 22:
        return ms(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return wa(e), a = ye(ee), t === null ? (n = Zf(), n === null && (n = qt, i = Qf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Jf(e), Fl(e, ee, n)) : ((t.lanes & l) !== 0 && (kf(t, e), pi(e, null, null, l), gi()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), Fl(e, ee, a)) : (a = i.cache, Fl(e, ee, a), a !== n.cache && Xf(
          e,
          [ee],
          l,
          !0
        ))), ve(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 29:
        throw e.pendingProps;
    }
    throw Error(s(156, e.tag));
  }
  function Ul(t) {
    t.flags |= 4;
  }
  function Oc(t, e, l, a, n) {
    if ((e = (t.mode & 32) !== 0) && (e = !1), e) {
      if (t.flags |= 16777216, (n & 335544128) === n)
        if (t.stateNode.complete) t.flags |= 8192;
        else if (Fs()) t.flags |= 8192;
        else
          throw qa = bu, Kf;
    } else t.flags &= -16777217;
  }
  function zs(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !qd(e))
      if (Fs()) t.flags |= 8192;
      else
        throw qa = bu, Kf;
  }
  function Hu(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? Vn() : 536870912, t.lanes |= e, Cn |= e);
  }
  function Ti(t, e) {
    if (!St)
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
  function Xt(t) {
    var e = t.alternate !== null && t.alternate.child === t.child, l = 0, a = 0;
    if (e)
      for (var n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags & 65011712, a |= n.flags & 65011712, n.return = t, n = n.sibling;
    else
      for (n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags, a |= n.flags, n.return = t, n = n.sibling;
    return t.subtreeFlags |= a, t.childLanes = l, e;
  }
  function uh(t, e, l) {
    var a = e.pendingProps;
    switch (jf(e), e.tag) {
      case 16:
      case 15:
      case 0:
      case 11:
      case 7:
      case 8:
      case 12:
      case 9:
      case 14:
        return Xt(e), null;
      case 1:
        return Xt(e), null;
      case 3:
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), _l(ee), Rt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (yn(e) ? Ul(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, Gf())), Xt(e), null;
      case 26:
        var n = e.type, i = e.memoizedState;
        return t === null ? (Ul(e), i !== null ? (Xt(e), zs(e, i)) : (Xt(e), Oc(
          e,
          n,
          null,
          a,
          l
        ))) : i ? i !== t.memoizedState ? (Ul(e), Xt(e), zs(e, i)) : (Xt(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Ul(e), Xt(e), Oc(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if (Le(e), l = ft.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Ul(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          t = j.current, yn(e) ? lr(e) : (t = Cd(n, a, l), e.stateNode = t, Ul(e));
        }
        return Xt(e), null;
      case 5:
        if (Le(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Ul(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          if (i = j.current, yn(e))
            lr(e);
          else {
            var u = $u(
              ft.current
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
            i[te] = e, i[he] = a;
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
            t: switch (be(i, n, a), n) {
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
            a && Ul(e);
          }
        }
        return Xt(e), Oc(
          e,
          e.type,
          t === null ? null : t.memoizedProps,
          e.pendingProps,
          l
        ), null;
      case 6:
        if (t && e.stateNode != null)
          t.memoizedProps !== a && Ul(e);
        else {
          if (typeof a != "string" && e.stateNode === null)
            throw Error(s(166));
          if (t = ft.current, yn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = pe, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[te] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || bd(t.nodeValue, l)), t || kl(e, !0);
          } else
            t = $u(t).createTextNode(
              a
            ), t[te] = e, e.stateNode = t;
        }
        return Xt(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = yn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(s(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(557));
              t[te] = e;
            } else
              Ba(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), t = !1;
          } else
            l = Gf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (je(e), e) : (je(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(s(558));
        }
        return Xt(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = yn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(s(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(s(317));
              n[te] = e;
            } else
              Ba(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), n = !1;
          } else
            n = Gf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (je(e), e) : (je(e), null);
        }
        return je(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Hu(e, e.updateQueue), Xt(e), null);
      case 4:
        return Rt(), t === null && $c(e.stateNode.containerInfo), Xt(e), null;
      case 10:
        return _l(e.type), Xt(e), null;
      case 19:
        if (A($t), a = e.memoizedState, a === null) return Xt(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) Ti(a, !1);
          else {
            if (kt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = zu(t), i !== null) {
                  for (e.flags |= 128, Ti(a, !1), t = i.updateQueue, e.updateQueue = t, Hu(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    $o(l, t), l = l.sibling;
                  return N(
                    $t,
                    $t.current & 1 | 2
                  ), St && El(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && me() > Lu && (e.flags |= 128, n = !0, Ti(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = zu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Hu(e, t), Ti(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !St)
                return Xt(e), null;
            } else
              2 * me() - a.renderingStartTime > Lu && l !== 536870912 && (e.flags |= 128, n = !0, Ti(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = me(), t.sibling = null, l = $t.current, N(
          $t,
          n ? l & 1 | 2 : l & 1
        ), St && El(e, a.treeForkCount), t) : (Xt(e), null);
      case 22:
      case 23:
        return je(e), If(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Xt(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Xt(e), l = e.updateQueue, l !== null && Hu(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && A(Ha), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), _l(ee), Xt(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(s(156, e.tag));
  }
  function fh(t, e) {
    switch (jf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return _l(ee), Rt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return Le(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (je(e), e.alternate === null)
            throw Error(s(340));
          Ba();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (je(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(s(340));
          Ba();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return A($t), null;
      case 4:
        return Rt(), null;
      case 10:
        return _l(e.type), null;
      case 22:
      case 23:
        return je(e), If(), t !== null && A(Ha), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return _l(ee), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function Ms(t, e) {
    switch (jf(e), e.tag) {
      case 3:
        _l(ee), Rt();
        break;
      case 26:
      case 27:
      case 5:
        Le(e);
        break;
      case 4:
        Rt();
        break;
      case 31:
        e.memoizedState !== null && je(e);
        break;
      case 13:
        je(e);
        break;
      case 19:
        A($t);
        break;
      case 10:
        _l(e.type);
        break;
      case 22:
      case 23:
        je(e), If(), t !== null && A(Ha);
        break;
      case 24:
        _l(ee);
    }
  }
  function zi(t, e) {
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
    } catch (c) {
      Nt(e, e.return, c);
    }
  }
  function ea(t, e, l) {
    try {
      var a = e.updateQueue, n = a !== null ? a.lastEffect : null;
      if (n !== null) {
        var i = n.next;
        a = i;
        do {
          if ((a.tag & t) === t) {
            var u = a.inst, c = u.destroy;
            if (c !== void 0) {
              u.destroy = void 0, n = e;
              var r = l, v = c;
              try {
                v();
              } catch (M) {
                Nt(
                  n,
                  r,
                  M
                );
              }
            }
          }
          a = a.next;
        } while (a !== i);
      }
    } catch (M) {
      Nt(e, e.return, M);
    }
  }
  function Es(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        gr(e, l);
      } catch (a) {
        Nt(t, t.return, a);
      }
    }
  }
  function As(t, e, l) {
    l.props = La(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      Nt(t, e, a);
    }
  }
  function Mi(t, e) {
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
      Nt(t, e, n);
    }
  }
  function gl(t, e) {
    var l = t.ref, a = t.refCleanup;
    if (l !== null)
      if (typeof a == "function")
        try {
          a();
        } catch (n) {
          Nt(t, e, n);
        } finally {
          t.refCleanup = null, t = t.alternate, t != null && (t.refCleanup = null);
        }
      else if (typeof l == "function")
        try {
          l(null);
        } catch (n) {
          Nt(t, e, n);
        }
      else l.current = null;
  }
  function _s(t) {
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
      Nt(t, t.return, n);
    }
  }
  function Cc(t, e, l) {
    try {
      var a = t.stateNode;
      Oh(a, t.type, l, e), a[he] = e;
    } catch (n) {
      Nt(t, t.return, n);
    }
  }
  function Ds(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && ca(t.type) || t.tag === 4;
  }
  function Uc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || Ds(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && ca(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Rc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = tl));
    else if (a !== 4 && (a === 27 && ca(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Rc(t, e, l), t = t.sibling; t !== null; )
        Rc(t, e, l), t = t.sibling;
  }
  function ju(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && ca(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (ju(t, e, l), t = t.sibling; t !== null; )
        ju(t, e, l), t = t.sibling;
  }
  function Os(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      be(e, a, l), e[te] = t, e[he] = l;
    } catch (i) {
      Nt(t, t.return, i);
    }
  }
  var Rl = !1, ne = !1, Bc = !1, Cs = typeof WeakSet == "function" ? WeakSet : Set, se = null;
  function ch(t, e) {
    if (t = t.containerInfo, to = nf, t = Xo(t), Af(t)) {
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
            var u = 0, c = -1, r = -1, v = 0, M = 0, O = t, b = null;
            e: for (; ; ) {
              for (var T; O !== l || n !== 0 && O.nodeType !== 3 || (c = u + n), O !== i || a !== 0 && O.nodeType !== 3 || (r = u + a), O.nodeType === 3 && (u += O.nodeValue.length), (T = O.firstChild) !== null; )
                b = O, O = T;
              for (; ; ) {
                if (O === t) break e;
                if (b === l && ++v === n && (c = u), b === i && ++M === a && (r = u), (T = O.nextSibling) !== null) break;
                O = b, b = O.parentNode;
              }
              O = T;
            }
            l = c === -1 || r === -1 ? null : { start: c, end: r };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (eo = { focusedElem: t, selectionRange: l }, nf = !1, se = e; se !== null; )
      if (e = se, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, se = t;
      else
        for (; se !== null; ) {
          switch (e = se, i = e.alternate, t = e.flags, e.tag) {
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
                  var Y = La(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    Y,
                    i
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch (I) {
                  Nt(
                    l,
                    l.return,
                    I
                  );
                }
              }
              break;
            case 3:
              if ((t & 1024) !== 0) {
                if (t = e.stateNode.containerInfo, l = t.nodeType, l === 9)
                  no(t);
                else if (l === 1)
                  switch (t.nodeName) {
                    case "HEAD":
                    case "HTML":
                    case "BODY":
                      no(t);
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
              if ((t & 1024) !== 0) throw Error(s(163));
          }
          if (t = e.sibling, t !== null) {
            t.return = e.return, se = t;
            break;
          }
          se = e.return;
        }
  }
  function Us(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        Nl(t, l), a & 4 && zi(5, l);
        break;
      case 1:
        if (Nl(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              Nt(l, l.return, u);
            }
          else {
            var n = La(
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
              Nt(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && Es(l), a & 512 && Mi(l, l.return);
        break;
      case 3:
        if (Nl(t, l), a & 64 && (t = l.updateQueue, t !== null)) {
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
            gr(t, e);
          } catch (u) {
            Nt(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && Os(l);
      case 26:
      case 5:
        Nl(t, l), e === null && a & 4 && _s(l), a & 512 && Mi(l, l.return);
        break;
      case 12:
        Nl(t, l);
        break;
      case 31:
        Nl(t, l), a & 4 && Ns(t, l);
        break;
      case 13:
        Nl(t, l), a & 4 && ws(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = yh.bind(
          null,
          l
        ), jh(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Rl, !a) {
          e = e !== null && e.memoizedState !== null || ne, n = Rl;
          var i = ne;
          Rl = a, (ne = e) && !i ? wl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : Nl(t, l), Rl = n, ne = i;
        }
        break;
      case 30:
        break;
      default:
        Nl(t, l);
    }
  }
  function Rs(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Rs(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && $a(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Qt = null, Ae = !1;
  function Bl(t, e, l) {
    for (l = l.child; l !== null; )
      Bs(t, e, l), l = l.sibling;
  }
  function Bs(t, e, l) {
    if (Se && typeof Se.onCommitFiberUnmount == "function")
      try {
        Se.onCommitFiberUnmount(pa, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        ne || gl(l, e), Bl(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        ne || gl(l, e);
        var a = Qt, n = Ae;
        ca(l.type) && (Qt = l.stateNode, Ae = !1), Bl(
          t,
          e,
          l
        ), Bi(l.stateNode), Qt = a, Ae = n;
        break;
      case 5:
        ne || gl(l, e);
      case 6:
        if (a = Qt, n = Ae, Qt = null, Bl(
          t,
          e,
          l
        ), Qt = a, Ae = n, Qt !== null)
          if (Ae)
            try {
              (Qt.nodeType === 9 ? Qt.body : Qt.nodeName === "HTML" ? Qt.ownerDocument.body : Qt).removeChild(l.stateNode);
            } catch (i) {
              Nt(
                l,
                e,
                i
              );
            }
          else
            try {
              Qt.removeChild(l.stateNode);
            } catch (i) {
              Nt(
                l,
                e,
                i
              );
            }
        break;
      case 18:
        Qt !== null && (Ae ? (t = Qt, Ed(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), qn(t)) : Ed(Qt, l.stateNode));
        break;
      case 4:
        a = Qt, n = Ae, Qt = l.stateNode.containerInfo, Ae = !0, Bl(
          t,
          e,
          l
        ), Qt = a, Ae = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        ea(2, l, e), ne || ea(4, l, e), Bl(
          t,
          e,
          l
        );
        break;
      case 1:
        ne || (gl(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && As(
          l,
          e,
          a
        )), Bl(
          t,
          e,
          l
        );
        break;
      case 21:
        Bl(
          t,
          e,
          l
        );
        break;
      case 22:
        ne = (a = ne) || l.memoizedState !== null, Bl(
          t,
          e,
          l
        ), ne = a;
        break;
      default:
        Bl(
          t,
          e,
          l
        );
    }
  }
  function Ns(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null))) {
      t = t.dehydrated;
      try {
        qn(t);
      } catch (l) {
        Nt(e, e.return, l);
      }
    }
  }
  function ws(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        qn(t);
      } catch (l) {
        Nt(e, e.return, l);
      }
  }
  function oh(t) {
    switch (t.tag) {
      case 31:
      case 13:
      case 19:
        var e = t.stateNode;
        return e === null && (e = t.stateNode = new Cs()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new Cs()), e;
      default:
        throw Error(s(435, t.tag));
    }
  }
  function qu(t, e) {
    var l = oh(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = vh.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function _e(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], i = t, u = e, c = u;
        t: for (; c !== null; ) {
          switch (c.tag) {
            case 27:
              if (ca(c.type)) {
                Qt = c.stateNode, Ae = !1;
                break t;
              }
              break;
            case 5:
              Qt = c.stateNode, Ae = !1;
              break t;
            case 3:
            case 4:
              Qt = c.stateNode.containerInfo, Ae = !0;
              break t;
          }
          c = c.return;
        }
        if (Qt === null) throw Error(s(160));
        Bs(i, u, n), Qt = null, Ae = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Hs(e, t), e = e.sibling;
  }
  var ll = null;
  function Hs(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        _e(e, t), De(t), a & 4 && (ea(3, t, t.return), zi(3, t), ea(5, t, t.return));
        break;
      case 1:
        _e(e, t), De(t), a & 512 && (ne || l === null || gl(l, l.return)), a & 64 && Rl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = ll;
        if (_e(e, t), De(t), a & 512 && (ne || l === null || gl(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[xa] || i[te] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), be(i, a, l), i[te] = t, Wt(i), a = i;
                      break t;
                    case "link":
                      var u = Hd(
                        "link",
                        "href",
                        n
                      ).get(a + (l.href || ""));
                      if (u) {
                        for (var c = 0; c < u.length; c++)
                          if (i = u[c], i.getAttribute("href") === (l.href == null || l.href === "" ? null : l.href) && i.getAttribute("rel") === (l.rel == null ? null : l.rel) && i.getAttribute("title") === (l.title == null ? null : l.title) && i.getAttribute("crossorigin") === (l.crossOrigin == null ? null : l.crossOrigin)) {
                            u.splice(c, 1);
                            break e;
                          }
                      }
                      i = n.createElement(a), be(i, a, l), n.head.appendChild(i);
                      break;
                    case "meta":
                      if (u = Hd(
                        "meta",
                        "content",
                        n
                      ).get(a + (l.content || ""))) {
                        for (c = 0; c < u.length; c++)
                          if (i = u[c], i.getAttribute("content") === (l.content == null ? null : "" + l.content) && i.getAttribute("name") === (l.name == null ? null : l.name) && i.getAttribute("property") === (l.property == null ? null : l.property) && i.getAttribute("http-equiv") === (l.httpEquiv == null ? null : l.httpEquiv) && i.getAttribute("charset") === (l.charSet == null ? null : l.charSet)) {
                            u.splice(c, 1);
                            break e;
                          }
                      }
                      i = n.createElement(a), be(i, a, l), n.head.appendChild(i);
                      break;
                    default:
                      throw Error(s(468, a));
                  }
                  i[te] = t, Wt(i), a = i;
                }
                t.stateNode = a;
              } else
                jd(
                  n,
                  t.type,
                  t.stateNode
                );
            else
              t.stateNode = wd(
                n,
                a,
                t.memoizedProps
              );
          else
            i !== a ? (i === null ? l.stateNode !== null && (l = l.stateNode, l.parentNode.removeChild(l)) : i.count--, a === null ? jd(
              n,
              t.type,
              t.stateNode
            ) : wd(
              n,
              a,
              t.memoizedProps
            )) : a === null && t.stateNode !== null && Cc(
              t,
              t.memoizedProps,
              l.memoizedProps
            );
        }
        break;
      case 27:
        _e(e, t), De(t), a & 512 && (ne || l === null || gl(l, l.return)), l !== null && a & 4 && Cc(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (_e(e, t), De(t), a & 512 && (ne || l === null || gl(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            H(n, "");
          } catch (Y) {
            Nt(t, t.return, Y);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Cc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Bc = !0);
        break;
      case 6:
        if (_e(e, t), De(t), a & 4) {
          if (t.stateNode === null)
            throw Error(s(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (Y) {
            Nt(t, t.return, Y);
          }
        }
        break;
      case 3:
        if (tf = null, n = ll, ll = Iu(e.containerInfo), _e(e, t), ll = n, De(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            qn(e.containerInfo);
          } catch (Y) {
            Nt(t, t.return, Y);
          }
        Bc && (Bc = !1, js(t));
        break;
      case 4:
        a = ll, ll = Iu(
          t.stateNode.containerInfo
        ), _e(e, t), De(t), ll = a;
        break;
      case 12:
        _e(e, t), De(t);
        break;
      case 31:
        _e(e, t), De(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, qu(t, a)));
        break;
      case 13:
        _e(e, t), De(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Yu = me()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, qu(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var r = l !== null && l.memoizedState !== null, v = Rl, M = ne;
        if (Rl = v || n, ne = M || r, _e(e, t), ne = M, Rl = v, De(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || r || Rl || ne || Xa(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                r = l = e;
                try {
                  if (i = r.stateNode, n)
                    u = i.style, typeof u.setProperty == "function" ? u.setProperty("display", "none", "important") : u.display = "none";
                  else {
                    c = r.stateNode;
                    var O = r.memoizedProps.style, b = O != null && O.hasOwnProperty("display") ? O.display : null;
                    c.style.display = b == null || typeof b == "boolean" ? "" : ("" + b).trim();
                  }
                } catch (Y) {
                  Nt(r, r.return, Y);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                r = e;
                try {
                  r.stateNode.nodeValue = n ? "" : r.memoizedProps;
                } catch (Y) {
                  Nt(r, r.return, Y);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                r = e;
                try {
                  var T = r.stateNode;
                  n ? Ad(T, !0) : Ad(r.stateNode, !1);
                } catch (Y) {
                  Nt(r, r.return, Y);
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
        a & 4 && (a = t.updateQueue, a !== null && (l = a.retryQueue, l !== null && (a.retryQueue = null, qu(t, l))));
        break;
      case 19:
        _e(e, t), De(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, qu(t, a)));
        break;
      case 30:
        break;
      case 21:
        break;
      default:
        _e(e, t), De(t);
    }
  }
  function De(t) {
    var e = t.flags;
    if (e & 2) {
      try {
        for (var l, a = t.return; a !== null; ) {
          if (Ds(a)) {
            l = a;
            break;
          }
          a = a.return;
        }
        if (l == null) throw Error(s(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, i = Uc(t);
            ju(t, i, n);
            break;
          case 5:
            var u = l.stateNode;
            l.flags & 32 && (H(u, ""), l.flags &= -33);
            var c = Uc(t);
            ju(t, c, u);
            break;
          case 3:
          case 4:
            var r = l.stateNode.containerInfo, v = Uc(t);
            Rc(
              t,
              v,
              r
            );
            break;
          default:
            throw Error(s(161));
        }
      } catch (M) {
        Nt(t, t.return, M);
      }
      t.flags &= -3;
    }
    e & 4096 && (t.flags &= -4097);
  }
  function js(t) {
    if (t.subtreeFlags & 1024)
      for (t = t.child; t !== null; ) {
        var e = t;
        js(e), e.tag === 5 && e.flags & 1024 && e.stateNode.reset(), t = t.sibling;
      }
  }
  function Nl(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        Us(t, e.alternate, e), e = e.sibling;
  }
  function Xa(t) {
    for (t = t.child; t !== null; ) {
      var e = t;
      switch (e.tag) {
        case 0:
        case 11:
        case 14:
        case 15:
          ea(4, e, e.return), Xa(e);
          break;
        case 1:
          gl(e, e.return);
          var l = e.stateNode;
          typeof l.componentWillUnmount == "function" && As(
            e,
            e.return,
            l
          ), Xa(e);
          break;
        case 27:
          Bi(e.stateNode);
        case 26:
        case 5:
          gl(e, e.return), Xa(e);
          break;
        case 22:
          e.memoizedState === null && Xa(e);
          break;
        case 30:
          Xa(e);
          break;
        default:
          Xa(e);
      }
      t = t.sibling;
    }
  }
  function wl(t, e, l) {
    for (l = l && (e.subtreeFlags & 8772) !== 0, e = e.child; e !== null; ) {
      var a = e.alternate, n = t, i = e, u = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          wl(
            n,
            i,
            l
          ), zi(4, i);
          break;
        case 1:
          if (wl(
            n,
            i,
            l
          ), a = i, n = a.stateNode, typeof n.componentDidMount == "function")
            try {
              n.componentDidMount();
            } catch (v) {
              Nt(a, a.return, v);
            }
          if (a = i, n = a.updateQueue, n !== null) {
            var c = a.stateNode;
            try {
              var r = n.shared.hiddenCallbacks;
              if (r !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < r.length; n++)
                  hr(r[n], c);
            } catch (v) {
              Nt(a, a.return, v);
            }
          }
          l && u & 64 && Es(i), Mi(i, i.return);
          break;
        case 27:
          Os(i);
        case 26:
        case 5:
          wl(
            n,
            i,
            l
          ), l && a === null && u & 4 && _s(i), Mi(i, i.return);
          break;
        case 12:
          wl(
            n,
            i,
            l
          );
          break;
        case 31:
          wl(
            n,
            i,
            l
          ), l && u & 4 && Ns(n, i);
          break;
        case 13:
          wl(
            n,
            i,
            l
          ), l && u & 4 && ws(n, i);
          break;
        case 22:
          i.memoizedState === null && wl(
            n,
            i,
            l
          ), Mi(i, i.return);
          break;
        case 30:
          break;
        default:
          wl(
            n,
            i,
            l
          );
      }
      e = e.sibling;
    }
  }
  function Nc(t, e) {
    var l = null;
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && ri(l));
  }
  function wc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ri(t));
  }
  function al(t, e, l, a) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; )
        qs(
          t,
          e,
          l,
          a
        ), e = e.sibling;
  }
  function qs(t, e, l, a) {
    var n = e.flags;
    switch (e.tag) {
      case 0:
      case 11:
      case 15:
        al(
          t,
          e,
          l,
          a
        ), n & 2048 && zi(9, e);
        break;
      case 1:
        al(
          t,
          e,
          l,
          a
        );
        break;
      case 3:
        al(
          t,
          e,
          l,
          a
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ri(t)));
        break;
      case 12:
        if (n & 2048) {
          al(
            t,
            e,
            l,
            a
          ), t = e.stateNode;
          try {
            var i = e.memoizedProps, u = i.id, c = i.onPostCommit;
            typeof c == "function" && c(
              u,
              e.alternate === null ? "mount" : "update",
              t.passiveEffectDuration,
              -0
            );
          } catch (r) {
            Nt(e, e.return, r);
          }
        } else
          al(
            t,
            e,
            l,
            a
          );
        break;
      case 31:
        al(
          t,
          e,
          l,
          a
        );
        break;
      case 13:
        al(
          t,
          e,
          l,
          a
        );
        break;
      case 23:
        break;
      case 22:
        i = e.stateNode, u = e.alternate, e.memoizedState !== null ? i._visibility & 2 ? al(
          t,
          e,
          l,
          a
        ) : Ei(t, e) : i._visibility & 2 ? al(
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
        )), n & 2048 && Nc(u, e);
        break;
      case 24:
        al(
          t,
          e,
          l,
          a
        ), n & 2048 && wc(e.alternate, e);
        break;
      default:
        al(
          t,
          e,
          l,
          a
        );
    }
  }
  function _n(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var i = t, u = e, c = l, r = a, v = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          _n(
            i,
            u,
            c,
            r,
            n
          ), zi(8, u);
          break;
        case 23:
          break;
        case 22:
          var M = u.stateNode;
          u.memoizedState !== null ? M._visibility & 2 ? _n(
            i,
            u,
            c,
            r,
            n
          ) : Ei(
            i,
            u
          ) : (M._visibility |= 2, _n(
            i,
            u,
            c,
            r,
            n
          )), n && v & 2048 && Nc(
            u.alternate,
            u
          );
          break;
        case 24:
          _n(
            i,
            u,
            c,
            r,
            n
          ), n && v & 2048 && wc(u.alternate, u);
          break;
        default:
          _n(
            i,
            u,
            c,
            r,
            n
          );
      }
      e = e.sibling;
    }
  }
  function Ei(t, e) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; ) {
        var l = t, a = e, n = a.flags;
        switch (a.tag) {
          case 22:
            Ei(l, a), n & 2048 && Nc(
              a.alternate,
              a
            );
            break;
          case 24:
            Ei(l, a), n & 2048 && wc(a.alternate, a);
            break;
          default:
            Ei(l, a);
        }
        e = e.sibling;
      }
  }
  var Ai = 8192;
  function Dn(t, e, l) {
    if (t.subtreeFlags & Ai)
      for (t = t.child; t !== null; )
        Gs(
          t,
          e,
          l
        ), t = t.sibling;
  }
  function Gs(t, e, l) {
    switch (t.tag) {
      case 26:
        Dn(
          t,
          e,
          l
        ), t.flags & Ai && t.memoizedState !== null && Fh(
          l,
          ll,
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
        var a = ll;
        ll = Iu(t.stateNode.containerInfo), Dn(
          t,
          e,
          l
        ), ll = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = Ai, Ai = 16777216, Dn(
          t,
          e,
          l
        ), Ai = a) : Dn(
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
  function Ys(t) {
    var e = t.alternate;
    if (e !== null && (t = e.child, t !== null)) {
      e.child = null;
      do
        e = t.sibling, t.sibling = null, t = e;
      while (t !== null);
    }
  }
  function _i(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          se = a, Xs(
            a,
            t
          );
        }
      Ys(t);
    }
    if (t.subtreeFlags & 10256)
      for (t = t.child; t !== null; )
        Ls(t), t = t.sibling;
  }
  function Ls(t) {
    switch (t.tag) {
      case 0:
      case 11:
      case 15:
        _i(t), t.flags & 2048 && ea(9, t, t.return);
        break;
      case 3:
        _i(t);
        break;
      case 12:
        _i(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, Gu(t)) : _i(t);
        break;
      default:
        _i(t);
    }
  }
  function Gu(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          se = a, Xs(
            a,
            t
          );
        }
      Ys(t);
    }
    for (t = t.child; t !== null; ) {
      switch (e = t, e.tag) {
        case 0:
        case 11:
        case 15:
          ea(8, e, e.return), Gu(e);
          break;
        case 22:
          l = e.stateNode, l._visibility & 2 && (l._visibility &= -3, Gu(e));
          break;
        default:
          Gu(e);
      }
      t = t.sibling;
    }
  }
  function Xs(t, e) {
    for (; se !== null; ) {
      var l = se;
      switch (l.tag) {
        case 0:
        case 11:
        case 15:
          ea(8, l, e);
          break;
        case 23:
        case 22:
          if (l.memoizedState !== null && l.memoizedState.cachePool !== null) {
            var a = l.memoizedState.cachePool.pool;
            a != null && a.refCount++;
          }
          break;
        case 24:
          ri(l.memoizedState.cache);
      }
      if (a = l.child, a !== null) a.return = l, se = a;
      else
        t: for (l = t; se !== null; ) {
          a = se;
          var n = a.sibling, i = a.return;
          if (Rs(a), a === l) {
            se = null;
            break t;
          }
          if (n !== null) {
            n.return = i, se = n;
            break t;
          }
          se = i;
        }
    }
  }
  var rh = {
    getCacheForType: function(t) {
      var e = ye(ee), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return ye(ee).controller.signal;
    }
  }, sh = typeof WeakMap == "function" ? WeakMap : Map, Ot = 0, qt = null, gt = null, bt = 0, Bt = 0, qe = null, la = !1, On = !1, Hc = !1, Hl = 0, kt = 0, aa = 0, Qa = 0, jc = 0, Ge = 0, Cn = 0, Di = null, Oe = null, qc = !1, Yu = 0, Qs = 0, Lu = 1 / 0, Xu = null, na = null, ce = 0, ia = null, Un = null, jl = 0, Gc = 0, Yc = null, Vs = null, Oi = 0, Lc = null;
  function Ye() {
    return (Ot & 2) !== 0 && bt !== 0 ? bt & -bt : g.T !== null ? Jc() : $i();
  }
  function Zs() {
    if (Ge === 0)
      if ((bt & 536870912) === 0 || St) {
        var t = ka;
        ka <<= 1, (ka & 3932160) === 0 && (ka = 262144), Ge = t;
      } else Ge = 536870912;
    return t = He.current, t !== null && (t.flags |= 32), Ge;
  }
  function Ce(t, e, l) {
    (t === qt && (Bt === 2 || Bt === 9) || t.cancelPendingCommit !== null) && (Rn(t, 0), ua(
      t,
      bt,
      Ge,
      !1
    )), fl(t, l), ((Ot & 2) === 0 || t !== qt) && (t === qt && ((Ot & 2) === 0 && (Qa |= l), kt === 4 && ua(
      t,
      bt,
      Ge,
      !1
    )), pl(t));
  }
  function Ks(t, e, l) {
    if ((Ot & 6) !== 0) throw Error(s(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || va(t, e), n = a ? hh(t, e) : Qc(t, e, !0), i = a;
    do {
      if (n === 0) {
        On && !a && ua(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, i && !dh(l)) {
          n = Qc(t, e, !1), i = !1;
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
              var c = t;
              n = Di;
              var r = c.current.memoizedState.isDehydrated;
              if (r && (Rn(c, u).flags |= 256), u = Qc(
                c,
                u,
                !1
              ), u !== 2) {
                if (Hc && !r) {
                  c.errorRecoveryDisabledLanes |= i, Qa |= i, n = 4;
                  break t;
                }
                i = Oe, Oe = n, i !== null && (Oe === null ? Oe = i : Oe.push.apply(
                  Oe,
                  i
                ));
              }
              n = u;
            }
            if (i = !1, n !== 2) continue;
          }
        }
        if (n === 1) {
          Rn(t, 0), ua(t, e, 0, !0);
          break;
        }
        t: {
          switch (a = t, i = n, i) {
            case 0:
            case 1:
              throw Error(s(345));
            case 4:
              if ((e & 4194048) !== e) break;
            case 6:
              ua(
                a,
                e,
                Ge,
                !la
              );
              break t;
            case 2:
              Oe = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(s(329));
          }
          if ((e & 62914560) === e && (n = Yu + 300 - me(), 10 < n)) {
            if (ua(
              a,
              e,
              Ge,
              !la
            ), ya(a, 0, !0) !== 0) break t;
            jl = e, a.timeoutHandle = zd(
              Js.bind(
                null,
                a,
                l,
                Oe,
                Xu,
                qc,
                e,
                Ge,
                Qa,
                Cn,
                la,
                i,
                "Throttled",
                -0,
                0
              ),
              n
            );
            break t;
          }
          Js(
            a,
            l,
            Oe,
            Xu,
            qc,
            e,
            Ge,
            Qa,
            Cn,
            la,
            i,
            null,
            -0,
            0
          );
        }
      }
      break;
    } while (!0);
    pl(t);
  }
  function Js(t, e, l, a, n, i, u, c, r, v, M, O, b, T) {
    if (t.timeoutHandle = -1, O = e.subtreeFlags, O & 8192 || (O & 16785408) === 16785408) {
      O = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: tl
      }, Gs(
        e,
        i,
        O
      );
      var Y = (i & 62914560) === i ? Yu - me() : (i & 4194048) === i ? Qs - me() : 0;
      if (Y = Wh(
        O,
        Y
      ), Y !== null) {
        jl = i, t.cancelPendingCommit = Y(
          ed.bind(
            null,
            t,
            e,
            i,
            l,
            a,
            n,
            u,
            c,
            r,
            M,
            O,
            null,
            b,
            T
          )
        ), ua(t, i, u, !v);
        return;
      }
    }
    ed(
      t,
      e,
      i,
      l,
      a,
      n,
      u,
      c,
      r
    );
  }
  function dh(t) {
    for (var e = t; ; ) {
      var l = e.tag;
      if ((l === 0 || l === 11 || l === 15) && e.flags & 16384 && (l = e.updateQueue, l !== null && (l = l.stores, l !== null)))
        for (var a = 0; a < l.length; a++) {
          var n = l[a], i = n.getSnapshot;
          n = n.value;
          try {
            if (!Ne(i(), n)) return !1;
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
  function ua(t, e, l, a) {
    e &= ~jc, e &= ~Qa, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var i = 31 - ue(n), u = 1 << i;
      a[i] = -1, n &= ~u;
    }
    l !== 0 && Wi(t, l, e);
  }
  function Qu() {
    return (Ot & 6) === 0 ? (Ci(0), !1) : !0;
  }
  function Xc() {
    if (gt !== null) {
      if (Bt === 0)
        var t = gt.return;
      else
        t = gt, Al = Na = null, nc(t), Tn = null, di = 0, t = gt;
      for (; t !== null; )
        Ms(t.alternate, t), t = t.return;
      gt = null;
    }
  }
  function Rn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Rh(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), jl = 0, Xc(), qt = t, gt = l = Ml(t.current, null), bt = e, Bt = 0, qe = null, la = !1, On = va(t, e), Hc = !1, Cn = Ge = jc = Qa = aa = kt = 0, Oe = Di = null, qc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - ue(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return Hl = e, ru(), l;
  }
  function ks(t, e) {
    ot = null, g.H = xi, e === Sn || e === vu ? (e = rr(), Bt = 3) : e === Kf ? (e = rr(), Bt = 4) : Bt = e === xc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, qe = e, gt === null && (kt = 1, Ru(
      t,
      Ze(e, t.current)
    ));
  }
  function Fs() {
    var t = He.current;
    return t === null ? !0 : (bt & 4194048) === bt ? Fe === null : (bt & 62914560) === bt || (bt & 536870912) !== 0 ? t === Fe : !1;
  }
  function Ws() {
    var t = g.H;
    return g.H = xi, t === null ? xi : t;
  }
  function $s() {
    var t = g.A;
    return g.A = rh, t;
  }
  function Vu() {
    kt = 4, la || (bt & 4194048) !== bt && He.current !== null || (On = !0), (aa & 134217727) === 0 && (Qa & 134217727) === 0 || qt === null || ua(
      qt,
      bt,
      Ge,
      !1
    );
  }
  function Qc(t, e, l) {
    var a = Ot;
    Ot |= 2;
    var n = Ws(), i = $s();
    (qt !== t || bt !== e) && (Xu = null, Rn(t, e)), e = !1;
    var u = kt;
    t: do
      try {
        if (Bt !== 0 && gt !== null) {
          var c = gt, r = qe;
          switch (Bt) {
            case 8:
              Xc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              He.current === null && (e = !0);
              var v = Bt;
              if (Bt = 0, qe = null, Bn(t, c, r, v), l && On) {
                u = 0;
                break t;
              }
              break;
            default:
              v = Bt, Bt = 0, qe = null, Bn(t, c, r, v);
          }
        }
        mh(), u = kt;
        break;
      } catch (M) {
        ks(t, M);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Al = Na = null, Ot = a, g.H = n, g.A = i, gt === null && (qt = null, bt = 0, ru()), u;
  }
  function mh() {
    for (; gt !== null; ) Is(gt);
  }
  function hh(t, e) {
    var l = Ot;
    Ot |= 2;
    var a = Ws(), n = $s();
    qt !== t || bt !== e ? (Xu = null, Lu = me() + 500, Rn(t, e)) : On = va(
      t,
      e
    );
    t: do
      try {
        if (Bt !== 0 && gt !== null) {
          e = gt;
          var i = qe;
          e: switch (Bt) {
            case 1:
              Bt = 0, qe = null, Bn(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (cr(i)) {
                Bt = 0, qe = null, Ps(e);
                break;
              }
              e = function() {
                Bt !== 2 && Bt !== 9 || qt !== t || (Bt = 7), pl(t);
              }, i.then(e, e);
              break t;
            case 3:
              Bt = 7;
              break t;
            case 4:
              Bt = 5;
              break t;
            case 7:
              cr(i) ? (Bt = 0, qe = null, Ps(e)) : (Bt = 0, qe = null, Bn(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (gt.tag) {
                case 26:
                  u = gt.memoizedState;
                case 5:
                case 27:
                  var c = gt;
                  if (u ? qd(u) : c.stateNode.complete) {
                    Bt = 0, qe = null;
                    var r = c.sibling;
                    if (r !== null) gt = r;
                    else {
                      var v = c.return;
                      v !== null ? (gt = v, Zu(v)) : gt = null;
                    }
                    break e;
                  }
              }
              Bt = 0, qe = null, Bn(t, e, i, 5);
              break;
            case 6:
              Bt = 0, qe = null, Bn(t, e, i, 6);
              break;
            case 8:
              Xc(), kt = 6;
              break t;
            default:
              throw Error(s(462));
          }
        }
        gh();
        break;
      } catch (M) {
        ks(t, M);
      }
    while (!0);
    return Al = Na = null, g.H = a, g.A = n, Ot = l, gt !== null ? 0 : (qt = null, bt = 0, ru(), kt);
  }
  function gh() {
    for (; gt !== null && !Qn(); )
      Is(gt);
  }
  function Is(t) {
    var e = Ts(t.alternate, t, Hl);
    t.memoizedProps = t.pendingProps, e === null ? Zu(t) : gt = e;
  }
  function Ps(t) {
    var e = t, l = e.alternate;
    switch (e.tag) {
      case 15:
      case 0:
        e = ps(
          l,
          e,
          e.pendingProps,
          e.type,
          void 0,
          bt
        );
        break;
      case 11:
        e = ps(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          bt
        );
        break;
      case 5:
        nc(e);
      default:
        Ms(l, e), e = gt = $o(e, Hl), e = Ts(l, e, Hl);
    }
    t.memoizedProps = t.pendingProps, e === null ? Zu(t) : gt = e;
  }
  function Bn(t, e, l, a) {
    Al = Na = null, nc(e), Tn = null, di = 0;
    var n = e.return;
    try {
      if (ah(
        t,
        n,
        e,
        l,
        bt
      )) {
        kt = 1, Ru(
          t,
          Ze(l, t.current)
        ), gt = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw gt = n, i;
      kt = 1, Ru(
        t,
        Ze(l, t.current)
      ), gt = null;
      return;
    }
    e.flags & 32768 ? (St || a === 1 ? t = !0 : On || (bt & 536870912) !== 0 ? t = !1 : (la = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = He.current, a !== null && a.tag === 13 && (a.flags |= 16384))), td(e, t)) : Zu(e);
  }
  function Zu(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        td(
          e,
          la
        );
        return;
      }
      t = e.return;
      var l = uh(
        e.alternate,
        e,
        Hl
      );
      if (l !== null) {
        gt = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        gt = e;
        return;
      }
      gt = e = t;
    } while (e !== null);
    kt === 0 && (kt = 5);
  }
  function td(t, e) {
    do {
      var l = fh(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, gt = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        gt = t;
        return;
      }
      gt = t = l;
    } while (t !== null);
    kt = 6, gt = null;
  }
  function ed(t, e, l, a, n, i, u, c, r) {
    t.cancelPendingCommit = null;
    do
      Ku();
    while (ce !== 0);
    if ((Ot & 6) !== 0) throw Error(s(327));
    if (e !== null) {
      if (e === t.current) throw Error(s(177));
      if (i = e.lanes | e.childLanes, i |= Uf, Fi(
        t,
        l,
        i,
        u,
        c,
        r
      ), t === qt && (gt = qt = null, bt = 0), Un = e, ia = t, jl = l, Gc = i, Yc = n, Vs = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, bh(ga, function() {
        return ud(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = g.T, g.T = null, n = U.p, U.p = 2, u = Ot, Ot |= 4;
        try {
          ch(t, e, l);
        } finally {
          Ot = u, U.p = n, g.T = a;
        }
      }
      ce = 1, ld(), ad(), nd();
    }
  }
  function ld() {
    if (ce === 1) {
      ce = 0;
      var t = ia, e = Un, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = g.T, g.T = null;
        var a = U.p;
        U.p = 2;
        var n = Ot;
        Ot |= 4;
        try {
          Hs(e, t);
          var i = eo, u = Xo(t.containerInfo), c = i.focusedElem, r = i.selectionRange;
          if (u !== c && c && c.ownerDocument && Lo(
            c.ownerDocument.documentElement,
            c
          )) {
            if (r !== null && Af(c)) {
              var v = r.start, M = r.end;
              if (M === void 0 && (M = v), "selectionStart" in c)
                c.selectionStart = v, c.selectionEnd = Math.min(
                  M,
                  c.value.length
                );
              else {
                var O = c.ownerDocument || document, b = O && O.defaultView || window;
                if (b.getSelection) {
                  var T = b.getSelection(), Y = c.textContent.length, I = Math.min(r.start, Y), jt = r.end === void 0 ? I : Math.min(r.end, Y);
                  !T.extend && I > jt && (u = jt, jt = I, I = u);
                  var p = Yo(
                    c,
                    I
                  ), h = Yo(
                    c,
                    jt
                  );
                  if (p && h && (T.rangeCount !== 1 || T.anchorNode !== p.node || T.anchorOffset !== p.offset || T.focusNode !== h.node || T.focusOffset !== h.offset)) {
                    var y = O.createRange();
                    y.setStart(p.node, p.offset), T.removeAllRanges(), I > jt ? (T.addRange(y), T.extend(h.node, h.offset)) : (y.setEnd(h.node, h.offset), T.addRange(y));
                  }
                }
              }
            }
            for (O = [], T = c; T = T.parentNode; )
              T.nodeType === 1 && O.push({
                element: T,
                left: T.scrollLeft,
                top: T.scrollTop
              });
            for (typeof c.focus == "function" && c.focus(), c = 0; c < O.length; c++) {
              var E = O[c];
              E.element.scrollLeft = E.left, E.element.scrollTop = E.top;
            }
          }
          nf = !!to, eo = to = null;
        } finally {
          Ot = n, U.p = a, g.T = l;
        }
      }
      t.current = e, ce = 2;
    }
  }
  function ad() {
    if (ce === 2) {
      ce = 0;
      var t = ia, e = Un, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = g.T, g.T = null;
        var a = U.p;
        U.p = 2;
        var n = Ot;
        Ot |= 4;
        try {
          Us(t, e.alternate, e);
        } finally {
          Ot = n, U.p = a, g.T = l;
        }
      }
      ce = 3;
    }
  }
  function nd() {
    if (ce === 4 || ce === 3) {
      ce = 0, Qi();
      var t = ia, e = Un, l = jl, a = Vs;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? ce = 5 : (ce = 0, Un = ia = null, id(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (na = null), Kn(l), e = e.stateNode, Se && typeof Se.onCommitFiberRoot == "function")
        try {
          Se.onCommitFiberRoot(
            pa,
            e,
            void 0,
            (e.current.flags & 128) === 128
          );
        } catch {
        }
      if (a !== null) {
        e = g.T, n = U.p, U.p = 2, g.T = null;
        try {
          for (var i = t.onRecoverableError, u = 0; u < a.length; u++) {
            var c = a[u];
            i(c.value, {
              componentStack: c.stack
            });
          }
        } finally {
          g.T = e, U.p = n;
        }
      }
      (jl & 3) !== 0 && Ku(), pl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Lc ? Oi++ : (Oi = 0, Lc = t) : Oi = 0, Ci(0);
    }
  }
  function id(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, ri(e)));
  }
  function Ku() {
    return ld(), ad(), nd(), ud();
  }
  function ud() {
    if (ce !== 5) return !1;
    var t = ia, e = Gc;
    Gc = 0;
    var l = Kn(jl), a = g.T, n = U.p;
    try {
      U.p = 32 > l ? 32 : l, g.T = null, l = Yc, Yc = null;
      var i = ia, u = jl;
      if (ce = 0, Un = ia = null, jl = 0, (Ot & 6) !== 0) throw Error(s(331));
      var c = Ot;
      if (Ot |= 4, Ls(i.current), qs(
        i,
        i.current,
        u,
        l
      ), Ot = c, Ci(0, !1), Se && typeof Se.onPostCommitFiberRoot == "function")
        try {
          Se.onPostCommitFiberRoot(pa, i);
        } catch {
        }
      return !0;
    } finally {
      U.p = n, g.T = a, id(t, e);
    }
  }
  function fd(t, e, l) {
    e = Ze(l, e), e = bc(t.stateNode, e, 2), t = Il(t, e, 2), t !== null && (fl(t, 2), pl(t));
  }
  function Nt(t, e, l) {
    if (t.tag === 3)
      fd(t, t, l);
    else
      for (; e !== null; ) {
        if (e.tag === 3) {
          fd(
            e,
            t,
            l
          );
          break;
        } else if (e.tag === 1) {
          var a = e.stateNode;
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (na === null || !na.has(a))) {
            t = Ze(l, t), l = cs(2), a = Il(e, l, 2), a !== null && (os(
              l,
              a,
              e,
              t
            ), fl(a, 2), pl(a));
            break;
          }
        }
        e = e.return;
      }
  }
  function Vc(t, e, l) {
    var a = t.pingCache;
    if (a === null) {
      a = t.pingCache = new sh();
      var n = /* @__PURE__ */ new Set();
      a.set(e, n);
    } else
      n = a.get(e), n === void 0 && (n = /* @__PURE__ */ new Set(), a.set(e, n));
    n.has(l) || (Hc = !0, n.add(l), t = ph.bind(null, t, e, l), e.then(t, t));
  }
  function ph(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, qt === t && (bt & l) === l && (kt === 4 || kt === 3 && (bt & 62914560) === bt && 300 > me() - Yu ? (Ot & 2) === 0 && Rn(t, 0) : jc |= l, Cn === bt && (Cn = 0)), pl(t);
  }
  function cd(t, e) {
    e === 0 && (e = Vn()), t = Ua(t, e), t !== null && (fl(t, e), pl(t));
  }
  function yh(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), cd(t, l);
  }
  function vh(t, e) {
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
        throw Error(s(314));
    }
    a !== null && a.delete(e), cd(t, l);
  }
  function bh(t, e) {
    return Xn(t, e);
  }
  var Ju = null, Nn = null, Zc = !1, ku = !1, Kc = !1, fa = 0;
  function pl(t) {
    t !== Nn && t.next === null && (Nn === null ? Ju = Nn = t : Nn = Nn.next = t), ku = !0, Zc || (Zc = !0, Sh());
  }
  function Ci(t, e) {
    if (!Kc && ku) {
      Kc = !0;
      do
        for (var l = !1, a = Ju; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var i = 0;
            else {
              var u = a.suspendedLanes, c = a.pingedLanes;
              i = (1 << 31 - ue(42 | t) + 1) - 1, i &= n & ~(u & ~c), i = i & 201326741 ? i & 201326741 | 1 : i ? i | 2 : 0;
            }
            i !== 0 && (l = !0, dd(a, i));
          } else
            i = bt, i = ya(
              a,
              a === qt ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || va(a, i) || (l = !0, dd(a, i));
          a = a.next;
        }
      while (l);
      Kc = !1;
    }
  }
  function xh() {
    od();
  }
  function od() {
    ku = Zc = !1;
    var t = 0;
    fa !== 0 && Uh() && (t = fa);
    for (var e = me(), l = null, a = Ju; a !== null; ) {
      var n = a.next, i = rd(a, e);
      i === 0 ? (a.next = null, l === null ? Ju = n : l.next = n, n === null && (Nn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (ku = !0)), a = n;
    }
    ce !== 0 && ce !== 5 || Ci(t), fa !== 0 && (fa = 0);
  }
  function rd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - ue(i), c = 1 << u, r = n[u];
      r === -1 ? ((c & l) === 0 || (c & a) !== 0) && (n[u] = xl(c, e)) : r <= e && (t.expiredLanes |= c), i &= ~c;
    }
    if (e = qt, l = bt, l = ya(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (Bt === 2 || Bt === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && ha(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || va(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && ha(a), Kn(l)) {
        case 2:
        case 8:
          l = Ka;
          break;
        case 32:
          l = ga;
          break;
        case 268435456:
          l = Ki;
          break;
        default:
          l = ga;
      }
      return a = sd.bind(null, t), l = Xn(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && ha(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function sd(t, e) {
    if (ce !== 0 && ce !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Ku() && t.callbackNode !== l)
      return null;
    var a = bt;
    return a = ya(
      t,
      t === qt ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Ks(t, a, e), rd(t, me()), t.callbackNode != null && t.callbackNode === l ? sd.bind(null, t) : null);
  }
  function dd(t, e) {
    if (Ku()) return null;
    Ks(t, e, !0);
  }
  function Sh() {
    Bh(function() {
      (Ot & 6) !== 0 ? Xn(
        Zi,
        xh
      ) : od();
    });
  }
  function Jc() {
    if (fa === 0) {
      var t = bn;
      t === 0 && (t = bl, bl <<= 1, (bl & 261888) === 0 && (bl = 256)), fa = t;
    }
    return fa;
  }
  function md(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : en("" + t);
  }
  function hd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function Th(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = md(
        (n[he] || null).action
      ), u = a.submitter;
      u && (e = (e = u[he] || null) ? md(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
      var c = new cn(
        "action",
        "action",
        null,
        a,
        n
      );
      t.push({
        event: c,
        listeners: [
          {
            instance: null,
            listener: function() {
              if (a.defaultPrevented) {
                if (fa !== 0) {
                  var r = u ? hd(n, u) : new FormData(n);
                  mc(
                    l,
                    {
                      pending: !0,
                      data: r,
                      method: n.method,
                      action: i
                    },
                    null,
                    r
                  );
                }
              } else
                typeof i == "function" && (c.preventDefault(), r = u ? hd(n, u) : new FormData(n), mc(
                  l,
                  {
                    pending: !0,
                    data: r,
                    method: n.method,
                    action: i
                  },
                  i,
                  r
                ));
            },
            currentTarget: n
          }
        ]
      });
    }
  }
  for (var kc = 0; kc < Cf.length; kc++) {
    var Fc = Cf[kc], zh = Fc.toLowerCase(), Mh = Fc[0].toUpperCase() + Fc.slice(1);
    el(
      zh,
      "on" + Mh
    );
  }
  el(Zo, "onAnimationEnd"), el(Ko, "onAnimationIteration"), el(Jo, "onAnimationStart"), el("dblclick", "onDoubleClick"), el("focusin", "onFocus"), el("focusout", "onBlur"), el(Ym, "onTransitionRun"), el(Lm, "onTransitionStart"), el(Xm, "onTransitionCancel"), el(ko, "onTransitionEnd"), Ll("onMouseEnter", ["mouseout", "mouseover"]), Ll("onMouseLeave", ["mouseout", "mouseover"]), Ll("onPointerEnter", ["pointerout", "pointerover"]), Ll("onPointerLeave", ["pointerout", "pointerover"]), sl(
    "onChange",
    "change click focusin focusout input keydown keyup selectionchange".split(" ")
  ), sl(
    "onSelect",
    "focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(
      " "
    )
  ), sl("onBeforeInput", [
    "compositionend",
    "keypress",
    "textInput",
    "paste"
  ]), sl(
    "onCompositionEnd",
    "compositionend focusout keydown keypress keyup mousedown".split(" ")
  ), sl(
    "onCompositionStart",
    "compositionstart focusout keydown keypress keyup mousedown".split(" ")
  ), sl(
    "onCompositionUpdate",
    "compositionupdate focusout keydown keypress keyup mousedown".split(" ")
  );
  var Ui = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), Eh = new Set(
    "beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(Ui)
  );
  function gd(t, e) {
    e = (e & 4) !== 0;
    for (var l = 0; l < t.length; l++) {
      var a = t[l], n = a.event;
      a = a.listeners;
      t: {
        var i = void 0;
        if (e)
          for (var u = a.length - 1; 0 <= u; u--) {
            var c = a[u], r = c.instance, v = c.currentTarget;
            if (c = c.listener, r !== i && n.isPropagationStopped())
              break t;
            i = c, n.currentTarget = v;
            try {
              i(n);
            } catch (M) {
              ou(M);
            }
            n.currentTarget = null, i = r;
          }
        else
          for (u = 0; u < a.length; u++) {
            if (c = a[u], r = c.instance, v = c.currentTarget, c = c.listener, r !== i && n.isPropagationStopped())
              break t;
            i = c, n.currentTarget = v;
            try {
              i(n);
            } catch (M) {
              ou(M);
            }
            n.currentTarget = null, i = r;
          }
      }
    }
  }
  function pt(t, e) {
    var l = e[kn];
    l === void 0 && (l = e[kn] = /* @__PURE__ */ new Set());
    var a = t + "__bubble";
    l.has(a) || (pd(e, t, 2, !1), l.add(a));
  }
  function Wc(t, e, l) {
    var a = 0;
    e && (a |= 4), pd(
      l,
      t,
      a,
      e
    );
  }
  var Fu = "_reactListening" + Math.random().toString(36).slice(2);
  function $c(t) {
    if (!t[Fu]) {
      t[Fu] = !0, Fn.forEach(function(l) {
        l !== "selectionchange" && (Eh.has(l) || Wc(l, !1, t), Wc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[Fu] || (e[Fu] = !0, Wc("selectionchange", !1, e));
    }
  }
  function pd(t, e, l, a) {
    switch (Zd(e)) {
      case 2:
        var n = Ph;
        break;
      case 8:
        n = tg;
        break;
      default:
        n = mo;
    }
    l = n.bind(
      null,
      e,
      l,
      t
    ), n = void 0, !Ma || e !== "touchstart" && e !== "touchmove" && e !== "wheel" || (n = !0), a ? n !== void 0 ? t.addEventListener(e, l, {
      capture: !0,
      passive: n
    }) : t.addEventListener(e, l, !0) : n !== void 0 ? t.addEventListener(e, l, {
      passive: n
    }) : t.addEventListener(e, l, !1);
  }
  function Ic(t, e, l, a, n) {
    var i = a;
    if ((e & 1) === 0 && (e & 2) === 0 && a !== null)
      t: for (; ; ) {
        if (a === null) return;
        var u = a.tag;
        if (u === 3 || u === 4) {
          var c = a.stateNode.containerInfo;
          if (c === n) break;
          if (u === 4)
            for (u = a.return; u !== null; ) {
              var r = u.tag;
              if ((r === 3 || r === 4) && u.stateNode.containerInfo === n)
                return;
              u = u.return;
            }
          for (; c !== null; ) {
            if (u = ol(c), u === null) return;
            if (r = u.tag, r === 5 || r === 6 || r === 26 || r === 27) {
              a = i = u;
              continue t;
            }
            c = c.parentNode;
          }
        }
        a = a.return;
      }
    an(function() {
      var v = i, M = ln(l), O = [];
      t: {
        var b = Fo.get(t);
        if (b !== void 0) {
          var T = cn, Y = t;
          switch (t) {
            case "keypress":
              if (Ea(l) === 0) break t;
            case "keydown":
            case "keyup":
              T = vm;
              break;
            case "focusin":
              Y = "focus", T = P;
              break;
            case "focusout":
              Y = "blur", T = P;
              break;
            case "beforeblur":
            case "afterblur":
              T = P;
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
              T = li;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              T = _;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              T = Sm;
              break;
            case Zo:
            case Ko:
            case Jo:
              T = zt;
              break;
            case ko:
              T = zm;
              break;
            case "scroll":
            case "scrollend":
              T = uu;
              break;
            case "wheel":
              T = Em;
              break;
            case "copy":
            case "cut":
            case "paste":
              T = Kt;
              break;
            case "gotpointercapture":
            case "lostpointercapture":
            case "pointercancel":
            case "pointerdown":
            case "pointermove":
            case "pointerout":
            case "pointerover":
            case "pointerup":
              T = Ao;
              break;
            case "toggle":
            case "beforetoggle":
              T = _m;
          }
          var I = (e & 4) !== 0, jt = !I && (t === "scroll" || t === "scrollend"), p = I ? b !== null ? b + "Capture" : null : b;
          I = [];
          for (var h = v, y; h !== null; ) {
            var E = h;
            if (y = E.stateNode, E = E.tag, E !== 5 && E !== 26 && E !== 27 || y === null || p === null || (E = za(h, p), E != null && I.push(
              Ri(h, E, y)
            )), jt) break;
            h = h.return;
          }
          0 < I.length && (b = new T(
            b,
            Y,
            null,
            l,
            M
          ), O.push({ event: b, listeners: I }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (b = t === "mouseover" || t === "pointerover", T = t === "mouseout" || t === "pointerout", b && l !== In && (Y = l.relatedTarget || l.fromElement) && (ol(Y) || Y[Sl]))
            break t;
          if ((T || b) && (b = M.window === M ? M : (b = M.ownerDocument) ? b.defaultView || b.parentWindow : window, T ? (Y = l.relatedTarget || l.toElement, T = v, Y = Y ? ol(Y) : null, Y !== null && (jt = k(Y), I = Y.tag, Y !== jt || I !== 5 && I !== 27 && I !== 6) && (Y = null)) : (T = null, Y = v), T !== Y)) {
            if (I = li, E = "onMouseLeave", p = "onMouseEnter", h = "mouse", (t === "pointerout" || t === "pointerover") && (I = Ao, E = "onPointerLeave", p = "onPointerEnter", h = "pointer"), jt = T == null ? b : Yl(T), y = Y == null ? b : Yl(Y), b = new I(
              E,
              h + "leave",
              T,
              l,
              M
            ), b.target = jt, b.relatedTarget = y, E = null, ol(M) === v && (I = new I(
              p,
              h + "enter",
              Y,
              l,
              M
            ), I.target = y, I.relatedTarget = jt, E = I), jt = E, T && Y)
              e: {
                for (I = Ah, p = T, h = Y, y = 0, E = p; E; E = I(E))
                  y++;
                E = 0;
                for (var F = h; F; F = I(F))
                  E++;
                for (; 0 < y - E; )
                  p = I(p), y--;
                for (; 0 < E - y; )
                  h = I(h), E--;
                for (; y--; ) {
                  if (p === h || h !== null && p === h.alternate) {
                    I = p;
                    break e;
                  }
                  p = I(p), h = I(h);
                }
                I = null;
              }
            else I = null;
            T !== null && yd(
              O,
              b,
              T,
              I,
              !1
            ), Y !== null && jt !== null && yd(
              O,
              jt,
              Y,
              I,
              !0
            );
          }
        }
        t: {
          if (b = v ? Yl(v) : window, T = b.nodeName && b.nodeName.toLowerCase(), T === "select" || T === "input" && b.type === "file")
            var Et = No;
          else if (Ro(b))
            if (wo)
              Et = jm;
            else {
              Et = wm;
              var V = Nm;
            }
          else
            T = b.nodeName, !T || T.toLowerCase() !== "input" || b.type !== "checkbox" && b.type !== "radio" ? v && vt(v.elementType) && (Et = No) : Et = Hm;
          if (Et && (Et = Et(t, v))) {
            Bo(
              O,
              Et,
              l,
              M
            );
            break t;
          }
          V && V(t, b, v), t === "focusout" && v && b.type === "number" && v.memoizedProps.value != null && o(b, "number", b.value);
        }
        switch (V = v ? Yl(v) : window, t) {
          case "focusin":
            (Ro(V) || V.contentEditable === "true") && (sn = V, _f = v, fi = null);
            break;
          case "focusout":
            fi = _f = sn = null;
            break;
          case "mousedown":
            Df = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Df = !1, Qo(O, l, M);
            break;
          case "selectionchange":
            if (Gm) break;
          case "keydown":
          case "keyup":
            Qo(O, l, M);
        }
        var st;
        if (zf)
          t: {
            switch (t) {
              case "compositionstart":
                var xt = "onCompositionStart";
                break t;
              case "compositionend":
                xt = "onCompositionEnd";
                break t;
              case "compositionupdate":
                xt = "onCompositionUpdate";
                break t;
            }
            xt = void 0;
          }
        else
          rn ? Co(t, l) && (xt = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (xt = "onCompositionStart");
        xt && (_o && l.locale !== "ko" && (rn || xt !== "onCompositionStart" ? xt === "onCompositionEnd" && rn && (st = Pn()) : (Ee = M, nn = "value" in Ee ? Ee.value : Ee.textContent, rn = !0)), V = Wu(v, xt), 0 < V.length && (xt = new Zl(
          xt,
          t,
          null,
          l,
          M
        ), O.push({ event: xt, listeners: V }), st ? xt.data = st : (st = Uo(l), st !== null && (xt.data = st)))), (st = Om ? Cm(t, l) : Um(t, l)) && (xt = Wu(v, "onBeforeInput"), 0 < xt.length && (V = new Zl(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          M
        ), O.push({
          event: V,
          listeners: xt
        }), V.data = st)), Th(
          O,
          t,
          v,
          l,
          M
        );
      }
      gd(O, e);
    });
  }
  function Ri(t, e, l) {
    return {
      instance: t,
      listener: e,
      currentTarget: l
    };
  }
  function Wu(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, i = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = za(t, l), n != null && a.unshift(
        Ri(t, n, i)
      ), n = za(t, e), n != null && a.push(
        Ri(t, n, i)
      )), t.tag === 3) return a;
      t = t.return;
    }
    return [];
  }
  function Ah(t) {
    if (t === null) return null;
    do
      t = t.return;
    while (t && t.tag !== 5 && t.tag !== 27);
    return t || null;
  }
  function yd(t, e, l, a, n) {
    for (var i = e._reactName, u = []; l !== null && l !== a; ) {
      var c = l, r = c.alternate, v = c.stateNode;
      if (c = c.tag, r !== null && r === a) break;
      c !== 5 && c !== 26 && c !== 27 || v === null || (r = v, n ? (v = za(l, i), v != null && u.unshift(
        Ri(l, v, r)
      )) : n || (v = za(l, i), v != null && u.push(
        Ri(l, v, r)
      ))), l = l.return;
    }
    u.length !== 0 && t.push({ event: e, listeners: u });
  }
  var _h = /\r\n?/g, Dh = /\u0000|\uFFFD/g;
  function vd(t) {
    return (typeof t == "string" ? t : "" + t).replace(_h, `
`).replace(Dh, "");
  }
  function bd(t, e) {
    return e = vd(e), vd(t) === e;
  }
  function Ht(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || H(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && H(t, "" + a);
        break;
      case "className":
        Sa(t, "class", a);
        break;
      case "tabIndex":
        Sa(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        Sa(t, l, a);
        break;
      case "style":
        nt(t, a, i);
        break;
      case "data":
        if (e !== "object") {
          Sa(t, "data", a);
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
        a = en("" + a), t.setAttribute(l, a);
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
          typeof i == "function" && (l === "formAction" ? (e !== "input" && Ht(t, e, "name", n.name, n, null), Ht(
            t,
            e,
            "formEncType",
            n.formEncType,
            n,
            null
          ), Ht(
            t,
            e,
            "formMethod",
            n.formMethod,
            n,
            null
          ), Ht(
            t,
            e,
            "formTarget",
            n.formTarget,
            n,
            null
          )) : (Ht(t, e, "encType", n.encType, n, null), Ht(t, e, "method", n.method, n, null), Ht(t, e, "target", n.target, n, null)));
        if (a == null || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = en("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = tl);
        break;
      case "onScroll":
        a != null && pt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && pt("scrollend", t);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(s(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(s(60));
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
        l = en("" + a), t.setAttributeNS(
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
        pt("beforetoggle", t), pt("toggle", t), Ia(t, "popover", a);
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
        Ia(t, "is", a);
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = Dt.get(l) || l, Ia(t, l, a));
    }
  }
  function Pc(t, e, l, a, n, i) {
    switch (l) {
      case "style":
        nt(t, a, i);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(s(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(s(60));
            t.innerHTML = l;
          }
        }
        break;
      case "children":
        typeof a == "string" ? H(t, a) : (typeof a == "number" || typeof a == "bigint") && H(t, "" + a);
        break;
      case "onScroll":
        a != null && pt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && pt("scrollend", t);
        break;
      case "onClick":
        a != null && (t.onclick = tl);
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
        if (!Pi.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[he] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : Ia(t, l, a);
          }
    }
  }
  function be(t, e, l) {
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
        pt("error", t), pt("load", t);
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
                  throw Error(s(137, e));
                default:
                  Ht(t, e, i, u, l, null);
              }
          }
        n && Ht(t, e, "srcSet", l.srcSet, l, null), a && Ht(t, e, "src", l.src, l, null);
        return;
      case "input":
        pt("invalid", t);
        var c = i = u = n = null, r = null, v = null;
        for (a in l)
          if (l.hasOwnProperty(a)) {
            var M = l[a];
            if (M != null)
              switch (a) {
                case "name":
                  n = M;
                  break;
                case "type":
                  u = M;
                  break;
                case "checked":
                  r = M;
                  break;
                case "defaultChecked":
                  v = M;
                  break;
                case "value":
                  i = M;
                  break;
                case "defaultValue":
                  c = M;
                  break;
                case "children":
                case "dangerouslySetInnerHTML":
                  if (M != null)
                    throw Error(s(137, e));
                  break;
                default:
                  Ht(t, e, a, M, l, null);
              }
          }
        nu(
          t,
          i,
          c,
          r,
          v,
          u,
          n,
          !1
        );
        return;
      case "select":
        pt("invalid", t), a = u = i = null;
        for (n in l)
          if (l.hasOwnProperty(n) && (c = l[n], c != null))
            switch (n) {
              case "value":
                i = c;
                break;
              case "defaultValue":
                u = c;
                break;
              case "multiple":
                a = c;
              default:
                Ht(t, e, n, c, l, null);
            }
        e = i, l = u, t.multiple = !!a, e != null ? d(t, !!a, e, !1) : l != null && d(t, !!a, l, !0);
        return;
      case "textarea":
        pt("invalid", t), i = n = a = null;
        for (u in l)
          if (l.hasOwnProperty(u) && (c = l[u], c != null))
            switch (u) {
              case "value":
                a = c;
                break;
              case "defaultValue":
                n = c;
                break;
              case "children":
                i = c;
                break;
              case "dangerouslySetInnerHTML":
                if (c != null) throw Error(s(91));
                break;
              default:
                Ht(t, e, u, c, l, null);
            }
        B(t, a, n, i);
        return;
      case "option":
        for (r in l)
          l.hasOwnProperty(r) && (a = l[r], a != null) && (r === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : Ht(t, e, r, a, l, null));
        return;
      case "dialog":
        pt("beforetoggle", t), pt("toggle", t), pt("cancel", t), pt("close", t);
        break;
      case "iframe":
      case "object":
        pt("load", t);
        break;
      case "video":
      case "audio":
        for (a = 0; a < Ui.length; a++)
          pt(Ui[a], t);
        break;
      case "image":
        pt("error", t), pt("load", t);
        break;
      case "details":
        pt("toggle", t);
        break;
      case "embed":
      case "source":
      case "link":
        pt("error", t), pt("load", t);
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
                throw Error(s(137, e));
              default:
                Ht(t, e, v, a, l, null);
            }
        return;
      default:
        if (vt(e)) {
          for (M in l)
            l.hasOwnProperty(M) && (a = l[M], a !== void 0 && Pc(
              t,
              e,
              M,
              a,
              l,
              void 0
            ));
          return;
        }
    }
    for (c in l)
      l.hasOwnProperty(c) && (a = l[c], a != null && Ht(t, e, c, a, l, null));
  }
  function Oh(t, e, l, a) {
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
        var n = null, i = null, u = null, c = null, r = null, v = null, M = null;
        for (T in l) {
          var O = l[T];
          if (l.hasOwnProperty(T) && O != null)
            switch (T) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                r = O;
              default:
                a.hasOwnProperty(T) || Ht(t, e, T, null, a, O);
            }
        }
        for (var b in a) {
          var T = a[b];
          if (O = l[b], a.hasOwnProperty(b) && (T != null || O != null))
            switch (b) {
              case "type":
                i = T;
                break;
              case "name":
                n = T;
                break;
              case "checked":
                v = T;
                break;
              case "defaultChecked":
                M = T;
                break;
              case "value":
                u = T;
                break;
              case "defaultValue":
                c = T;
                break;
              case "children":
              case "dangerouslySetInnerHTML":
                if (T != null)
                  throw Error(s(137, e));
                break;
              default:
                T !== O && Ht(
                  t,
                  e,
                  b,
                  T,
                  a,
                  O
                );
            }
        }
        $n(
          t,
          u,
          c,
          r,
          v,
          M,
          i,
          n
        );
        return;
      case "select":
        T = u = c = b = null;
        for (i in l)
          if (r = l[i], l.hasOwnProperty(i) && r != null)
            switch (i) {
              case "value":
                break;
              case "multiple":
                T = r;
              default:
                a.hasOwnProperty(i) || Ht(
                  t,
                  e,
                  i,
                  null,
                  a,
                  r
                );
            }
        for (n in a)
          if (i = a[n], r = l[n], a.hasOwnProperty(n) && (i != null || r != null))
            switch (n) {
              case "value":
                b = i;
                break;
              case "defaultValue":
                c = i;
                break;
              case "multiple":
                u = i;
              default:
                i !== r && Ht(
                  t,
                  e,
                  n,
                  i,
                  a,
                  r
                );
            }
        e = c, l = u, a = T, b != null ? d(t, !!l, b, !1) : !!a != !!l && (e != null ? d(t, !!l, e, !0) : d(t, !!l, l ? [] : "", !1));
        return;
      case "textarea":
        T = b = null;
        for (c in l)
          if (n = l[c], l.hasOwnProperty(c) && n != null && !a.hasOwnProperty(c))
            switch (c) {
              case "value":
                break;
              case "children":
                break;
              default:
                Ht(t, e, c, null, a, n);
            }
        for (u in a)
          if (n = a[u], i = l[u], a.hasOwnProperty(u) && (n != null || i != null))
            switch (u) {
              case "value":
                b = n;
                break;
              case "defaultValue":
                T = n;
                break;
              case "children":
                break;
              case "dangerouslySetInnerHTML":
                if (n != null) throw Error(s(91));
                break;
              default:
                n !== i && Ht(t, e, u, n, a, i);
            }
        x(t, b, T);
        return;
      case "option":
        for (var Y in l)
          b = l[Y], l.hasOwnProperty(Y) && b != null && !a.hasOwnProperty(Y) && (Y === "selected" ? t.selected = !1 : Ht(
            t,
            e,
            Y,
            null,
            a,
            b
          ));
        for (r in a)
          b = a[r], T = l[r], a.hasOwnProperty(r) && b !== T && (b != null || T != null) && (r === "selected" ? t.selected = b && typeof b != "function" && typeof b != "symbol" : Ht(
            t,
            e,
            r,
            b,
            a,
            T
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
        for (var I in l)
          b = l[I], l.hasOwnProperty(I) && b != null && !a.hasOwnProperty(I) && Ht(t, e, I, null, a, b);
        for (v in a)
          if (b = a[v], T = l[v], a.hasOwnProperty(v) && b !== T && (b != null || T != null))
            switch (v) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (b != null)
                  throw Error(s(137, e));
                break;
              default:
                Ht(
                  t,
                  e,
                  v,
                  b,
                  a,
                  T
                );
            }
        return;
      default:
        if (vt(e)) {
          for (var jt in l)
            b = l[jt], l.hasOwnProperty(jt) && b !== void 0 && !a.hasOwnProperty(jt) && Pc(
              t,
              e,
              jt,
              void 0,
              a,
              b
            );
          for (M in a)
            b = a[M], T = l[M], !a.hasOwnProperty(M) || b === T || b === void 0 && T === void 0 || Pc(
              t,
              e,
              M,
              b,
              a,
              T
            );
          return;
        }
    }
    for (var p in l)
      b = l[p], l.hasOwnProperty(p) && b != null && !a.hasOwnProperty(p) && Ht(t, e, p, null, a, b);
    for (O in a)
      b = a[O], T = l[O], !a.hasOwnProperty(O) || b === T || b == null && T == null || Ht(t, e, O, b, a, T);
  }
  function xd(t) {
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
  function Ch() {
    if (typeof performance.getEntriesByType == "function") {
      for (var t = 0, e = 0, l = performance.getEntriesByType("resource"), a = 0; a < l.length; a++) {
        var n = l[a], i = n.transferSize, u = n.initiatorType, c = n.duration;
        if (i && c && xd(u)) {
          for (u = 0, c = n.responseEnd, a += 1; a < l.length; a++) {
            var r = l[a], v = r.startTime;
            if (v > c) break;
            var M = r.transferSize, O = r.initiatorType;
            M && xd(O) && (r = r.responseEnd, u += M * (r < c ? 1 : (c - v) / (r - v)));
          }
          if (--a, e += 8 * (i + u) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var to = null, eo = null;
  function $u(t) {
    return t.nodeType === 9 ? t : t.ownerDocument;
  }
  function Sd(t) {
    switch (t) {
      case "http://www.w3.org/2000/svg":
        return 1;
      case "http://www.w3.org/1998/Math/MathML":
        return 2;
      default:
        return 0;
    }
  }
  function Td(t, e) {
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
  function lo(t, e) {
    return t === "textarea" || t === "noscript" || typeof e.children == "string" || typeof e.children == "number" || typeof e.children == "bigint" || typeof e.dangerouslySetInnerHTML == "object" && e.dangerouslySetInnerHTML !== null && e.dangerouslySetInnerHTML.__html != null;
  }
  var ao = null;
  function Uh() {
    var t = window.event;
    return t && t.type === "popstate" ? t === ao ? !1 : (ao = t, !0) : (ao = null, !1);
  }
  var zd = typeof setTimeout == "function" ? setTimeout : void 0, Rh = typeof clearTimeout == "function" ? clearTimeout : void 0, Md = typeof Promise == "function" ? Promise : void 0, Bh = typeof queueMicrotask == "function" ? queueMicrotask : typeof Md < "u" ? function(t) {
    return Md.resolve(null).then(t).catch(Nh);
  } : zd;
  function Nh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function ca(t) {
    return t === "head";
  }
  function Ed(t, e) {
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
          Bi(t.ownerDocument.documentElement);
        else if (l === "head") {
          l = t.ownerDocument.head, Bi(l);
          for (var i = l.firstChild; i; ) {
            var u = i.nextSibling, c = i.nodeName;
            i[xa] || c === "SCRIPT" || c === "STYLE" || c === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && Bi(t.ownerDocument.body);
      l = n;
    } while (l);
    qn(e);
  }
  function Ad(t, e) {
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
  function no(t) {
    var e = t.firstChild;
    for (e && e.nodeType === 10 && (e = e.nextSibling); e; ) {
      var l = e;
      switch (e = e.nextSibling, l.nodeName) {
        case "HTML":
        case "HEAD":
        case "BODY":
          no(l), $a(l);
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
  function wh(t, e, l, a) {
    for (; t.nodeType === 1; ) {
      var n = l;
      if (t.nodeName.toLowerCase() !== e.toLowerCase()) {
        if (!a && (t.nodeName !== "INPUT" || t.type !== "hidden"))
          break;
      } else if (a) {
        if (!t[xa])
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
      if (t = We(t.nextSibling), t === null) break;
    }
    return null;
  }
  function Hh(t, e, l) {
    if (e === "") return null;
    for (; t.nodeType !== 3; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !l || (t = We(t.nextSibling), t === null)) return null;
    return t;
  }
  function _d(t, e) {
    for (; t.nodeType !== 8; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !e || (t = We(t.nextSibling), t === null)) return null;
    return t;
  }
  function io(t) {
    return t.data === "$?" || t.data === "$~";
  }
  function uo(t) {
    return t.data === "$!" || t.data === "$?" && t.ownerDocument.readyState !== "loading";
  }
  function jh(t, e) {
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
  var fo = null;
  function Dd(t) {
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
  function Od(t) {
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
  function Cd(t, e, l) {
    switch (e = $u(l), t) {
      case "html":
        if (t = e.documentElement, !t) throw Error(s(452));
        return t;
      case "head":
        if (t = e.head, !t) throw Error(s(453));
        return t;
      case "body":
        if (t = e.body, !t) throw Error(s(454));
        return t;
      default:
        throw Error(s(451));
    }
  }
  function Bi(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    $a(t);
  }
  var $e = /* @__PURE__ */ new Map(), Ud = /* @__PURE__ */ new Set();
  function Iu(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var ql = U.d;
  U.d = {
    f: qh,
    r: Gh,
    D: Yh,
    C: Lh,
    L: Xh,
    m: Qh,
    X: Zh,
    S: Vh,
    M: Kh
  };
  function qh() {
    var t = ql.f(), e = Qu();
    return t || e;
  }
  function Gh(t) {
    var e = rl(t);
    e !== null && e.tag === 5 && e.type === "form" ? kr(e) : ql.r(t);
  }
  var wn = typeof document > "u" ? null : document;
  function Rd(t, e, l) {
    var a = wn;
    if (a && typeof e == "string" && e) {
      var n = ge(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Ud.has(n) || (Ud.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), be(e, "link", t), Wt(e), a.head.appendChild(e)));
    }
  }
  function Yh(t) {
    ql.D(t), Rd("dns-prefetch", t, null);
  }
  function Lh(t, e) {
    ql.C(t, e), Rd("preconnect", t, e);
  }
  function Xh(t, e, l) {
    ql.L(t, e, l);
    var a = wn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + ge(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + ge(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + ge(
        l.imageSizes
      ) + '"]')) : n += '[href="' + ge(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = Hn(t);
          break;
        case "script":
          i = jn(t);
      }
      $e.has(i) || (t = w(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), $e.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Ni(i)) || e === "script" && a.querySelector(wi(i)) || (e = a.createElement("link"), be(e, "link", t), Wt(e), a.head.appendChild(e)));
    }
  }
  function Qh(t, e) {
    ql.m(t, e);
    var l = wn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + ge(a) + '"][href="' + ge(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = jn(t);
      }
      if (!$e.has(i) && (t = w({ rel: "modulepreload", href: t }, e), $e.set(i, t), l.querySelector(n) === null)) {
        switch (a) {
          case "audioworklet":
          case "paintworklet":
          case "serviceworker":
          case "sharedworker":
          case "worker":
          case "script":
            if (l.querySelector(wi(i)))
              return;
        }
        a = l.createElement("link"), be(a, "link", t), Wt(a), l.head.appendChild(a);
      }
    }
  }
  function Vh(t, e, l) {
    ql.S(t, e, l);
    var a = wn;
    if (a && t) {
      var n = Ie(a).hoistableStyles, i = Hn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var c = { loading: 0, preload: null };
        if (u = a.querySelector(
          Ni(i)
        ))
          c.loading = 5;
        else {
          t = w(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = $e.get(i)) && co(t, l);
          var r = u = a.createElement("link");
          Wt(r), be(r, "link", t), r._p = new Promise(function(v, M) {
            r.onload = v, r.onerror = M;
          }), r.addEventListener("load", function() {
            c.loading |= 1;
          }), r.addEventListener("error", function() {
            c.loading |= 2;
          }), c.loading |= 4, Pu(u, e, a);
        }
        u = {
          type: "stylesheet",
          instance: u,
          count: 1,
          state: c
        }, n.set(i, u);
      }
    }
  }
  function Zh(t, e) {
    ql.X(t, e);
    var l = wn;
    if (l && t) {
      var a = Ie(l).hoistableScripts, n = jn(t), i = a.get(n);
      i || (i = l.querySelector(wi(n)), i || (t = w({ src: t, async: !0 }, e), (e = $e.get(n)) && oo(t, e), i = l.createElement("script"), Wt(i), be(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Kh(t, e) {
    ql.M(t, e);
    var l = wn;
    if (l && t) {
      var a = Ie(l).hoistableScripts, n = jn(t), i = a.get(n);
      i || (i = l.querySelector(wi(n)), i || (t = w({ src: t, async: !0, type: "module" }, e), (e = $e.get(n)) && oo(t, e), i = l.createElement("script"), Wt(i), be(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Bd(t, e, l, a) {
    var n = (n = ft.current) ? Iu(n) : null;
    if (!n) throw Error(s(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = Hn(l.href), l = Ie(
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
          var i = Ie(
            n
          ).hoistableStyles, u = i.get(t);
          if (u || (n = n.ownerDocument || n, u = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, i.set(t, u), (i = n.querySelector(
            Ni(t)
          )) && !i._p && (u.instance = i, u.state.loading = 5), $e.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, $e.set(t, l), i || Jh(
            n,
            t,
            l,
            u.state
          ))), e && a === null)
            throw Error(s(528, ""));
          return u;
        }
        if (e && a !== null)
          throw Error(s(529, ""));
        return null;
      case "script":
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = jn(l), l = Ie(
          n
        ).hoistableScripts, a = l.get(e), a || (a = {
          type: "script",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      default:
        throw Error(s(444, t));
    }
  }
  function Hn(t) {
    return 'href="' + ge(t) + '"';
  }
  function Ni(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Nd(t) {
    return w({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function Jh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), be(e, "link", l), Wt(e), t.head.appendChild(e));
  }
  function jn(t) {
    return '[src="' + ge(t) + '"]';
  }
  function wi(t) {
    return "script[async]" + t;
  }
  function wd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + ge(l.href) + '"]'
          );
          if (a)
            return e.instance = a, Wt(a), a;
          var n = w({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), Wt(a), be(a, "style", n), Pu(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = Hn(l.href);
          var i = t.querySelector(
            Ni(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, Wt(i), i;
          a = Nd(l), (n = $e.get(n)) && co(a, n), i = (t.ownerDocument || t).createElement("link"), Wt(i);
          var u = i;
          return u._p = new Promise(function(c, r) {
            u.onload = c, u.onerror = r;
          }), be(i, "link", a), e.state.loading |= 4, Pu(i, l.precedence, t), e.instance = i;
        case "script":
          return i = jn(l.src), (n = t.querySelector(
            wi(i)
          )) ? (e.instance = n, Wt(n), n) : (a = l, (n = $e.get(i)) && (a = w({}, l), oo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Wt(n), be(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(s(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, Pu(a, l.precedence, t));
    return e.instance;
  }
  function Pu(t, e, l) {
    for (var a = l.querySelectorAll(
      'link[rel="stylesheet"][data-precedence],style[data-precedence]'
    ), n = a.length ? a[a.length - 1] : null, i = n, u = 0; u < a.length; u++) {
      var c = a[u];
      if (c.dataset.precedence === e) i = c;
      else if (i !== n) break;
    }
    i ? i.parentNode.insertBefore(t, i.nextSibling) : (e = l.nodeType === 9 ? l.head : l, e.insertBefore(t, e.firstChild));
  }
  function co(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.title == null && (t.title = e.title);
  }
  function oo(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.integrity == null && (t.integrity = e.integrity);
  }
  var tf = null;
  function Hd(t, e, l) {
    if (tf === null) {
      var a = /* @__PURE__ */ new Map(), n = tf = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = tf, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var i = l[n];
      if (!(i[xa] || i[te] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
        var u = i.getAttribute(e) || "";
        u = t + u;
        var c = a.get(u);
        c ? c.push(i) : a.set(u, [i]);
      }
    }
    return a;
  }
  function jd(t, e, l) {
    t = t.ownerDocument || t, t.head.insertBefore(
      l,
      e === "title" ? t.querySelector("head > title") : null
    );
  }
  function kh(t, e, l) {
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
  function qd(t) {
    return !(t.type === "stylesheet" && (t.state.loading & 3) === 0);
  }
  function Fh(t, e, l, a) {
    if (l.type === "stylesheet" && (typeof a.media != "string" || matchMedia(a.media).matches !== !1) && (l.state.loading & 4) === 0) {
      if (l.instance === null) {
        var n = Hn(a.href), i = e.querySelector(
          Ni(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = ef.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, Wt(i);
          return;
        }
        i = e.ownerDocument || e, a = Nd(a), (n = $e.get(n)) && co(a, n), i = i.createElement("link"), Wt(i);
        var u = i;
        u._p = new Promise(function(c, r) {
          u.onload = c, u.onerror = r;
        }), be(i, "link", a), l.instance = i;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = ef.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var ro = 0;
  function Wh(t, e) {
    return t.stylesheets && t.count === 0 && af(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && af(t, t.stylesheets), t.unsuspend) {
          var i = t.unsuspend;
          t.unsuspend = null, i();
        }
      }, 6e4 + e);
      0 < t.imgBytes && ro === 0 && (ro = 62500 * Ch());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && af(t, t.stylesheets), t.unsuspend)) {
            var i = t.unsuspend;
            t.unsuspend = null, i();
          }
        },
        (t.imgBytes > ro ? 50 : 800) + e
      );
      return t.unsuspend = l, function() {
        t.unsuspend = null, clearTimeout(a), clearTimeout(n);
      };
    } : null;
  }
  function ef() {
    if (this.count--, this.count === 0 && (this.imgCount === 0 || !this.waitingForImages)) {
      if (this.stylesheets) af(this, this.stylesheets);
      else if (this.unsuspend) {
        var t = this.unsuspend;
        this.unsuspend = null, t();
      }
    }
  }
  var lf = null;
  function af(t, e) {
    t.stylesheets = null, t.unsuspend !== null && (t.count++, lf = /* @__PURE__ */ new Map(), e.forEach($h, t), lf = null, ef.call(t));
  }
  function $h(t, e) {
    if (!(e.state.loading & 4)) {
      var l = lf.get(t);
      if (l) var a = l.get(null);
      else {
        l = /* @__PURE__ */ new Map(), lf.set(t, l);
        for (var n = t.querySelectorAll(
          "link[data-precedence],style[data-precedence]"
        ), i = 0; i < n.length; i++) {
          var u = n[i];
          (u.nodeName === "LINK" || u.getAttribute("media") !== "not all") && (l.set(u.dataset.precedence, u), a = u);
        }
        a && l.set(null, a);
      }
      n = e.instance, u = n.getAttribute("data-precedence"), i = l.get(u) || a, i === a && l.set(null, n), l.set(u, n), this.count++, a = ef.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), i ? i.parentNode.insertBefore(n, i.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Hi = {
    $$typeof: mt,
    Provider: null,
    Consumer: null,
    _currentValue: Z,
    _currentValue2: Z,
    _threadCount: 0
  };
  function Ih(t, e, l, a, n, i, u, c, r) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Zn(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Zn(0), this.hiddenUpdates = Zn(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = r, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function Gd(t, e, l, a, n, i, u, c, r, v, M, O) {
    return t = new Ih(
      t,
      e,
      l,
      u,
      r,
      v,
      M,
      O,
      c
    ), e = 1, i === !0 && (e |= 24), i = we(3, null, null, e), t.current = i, i.stateNode = t, e = Qf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Jf(i), t;
  }
  function Yd(t) {
    return t ? (t = hn, t) : hn;
  }
  function Ld(t, e, l, a, n, i) {
    n = Yd(n), a.context === null ? a.context = n : a.pendingContext = n, a = $l(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = Il(t, a, e), l !== null && (Ce(l, t, e), hi(l, t, e));
  }
  function Xd(t, e) {
    if (t = t.memoizedState, t !== null && t.dehydrated !== null) {
      var l = t.retryLane;
      t.retryLane = l !== 0 && l < e ? l : e;
    }
  }
  function so(t, e) {
    Xd(t, e), (t = t.alternate) && Xd(t, e);
  }
  function Qd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Ua(t, 67108864);
      e !== null && Ce(e, t, 67108864), so(t, 67108864);
    }
  }
  function Vd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Ye();
      e = ba(e);
      var l = Ua(t, e);
      l !== null && Ce(l, t, e), so(t, e);
    }
  }
  var nf = !0;
  function Ph(t, e, l, a) {
    var n = g.T;
    g.T = null;
    var i = U.p;
    try {
      U.p = 2, mo(t, e, l, a);
    } finally {
      U.p = i, g.T = n;
    }
  }
  function tg(t, e, l, a) {
    var n = g.T;
    g.T = null;
    var i = U.p;
    try {
      U.p = 8, mo(t, e, l, a);
    } finally {
      U.p = i, g.T = n;
    }
  }
  function mo(t, e, l, a) {
    if (nf) {
      var n = ho(a);
      if (n === null)
        Ic(
          t,
          e,
          a,
          uf,
          l
        ), Kd(t, a);
      else if (lg(
        n,
        t,
        e,
        l,
        a
      ))
        a.stopPropagation();
      else if (Kd(t, a), e & 4 && -1 < eg.indexOf(t)) {
        for (; n !== null; ) {
          var i = rl(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = ul(i.pendingLanes);
                  if (u !== 0) {
                    var c = i;
                    for (c.pendingLanes |= 2, c.entangledLanes |= 2; u; ) {
                      var r = 1 << 31 - ue(u);
                      c.entanglements[1] |= r, u &= ~r;
                    }
                    pl(i), (Ot & 6) === 0 && (Lu = me() + 500, Ci(0));
                  }
                }
                break;
              case 31:
              case 13:
                c = Ua(i, 2), c !== null && Ce(c, i, 2), Qu(), so(i, 2);
            }
          if (i = ho(a), i === null && Ic(
            t,
            e,
            a,
            uf,
            l
          ), i === n) break;
          n = i;
        }
        n !== null && a.stopPropagation();
      } else
        Ic(
          t,
          e,
          a,
          null,
          l
        );
    }
  }
  function ho(t) {
    return t = ln(t), go(t);
  }
  var uf = null;
  function go(t) {
    if (uf = null, t = ol(t), t !== null) {
      var e = k(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = Q(e), t !== null) return t;
          t = null;
        } else if (l === 31) {
          if (t = lt(e), t !== null) return t;
          t = null;
        } else if (l === 3) {
          if (e.stateNode.current.memoizedState.isDehydrated)
            return e.tag === 3 ? e.stateNode.containerInfo : null;
          t = null;
        } else e !== t && (t = null);
      }
    }
    return uf = t, null;
  }
  function Zd(t) {
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
        switch (Vi()) {
          case Zi:
            return 2;
          case Ka:
            return 8;
          case ga:
          case gf:
            return 32;
          case Ki:
            return 268435456;
          default:
            return 32;
        }
      default:
        return 32;
    }
  }
  var po = !1, oa = null, ra = null, sa = null, ji = /* @__PURE__ */ new Map(), qi = /* @__PURE__ */ new Map(), da = [], eg = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Kd(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        oa = null;
        break;
      case "dragenter":
      case "dragleave":
        ra = null;
        break;
      case "mouseover":
      case "mouseout":
        sa = null;
        break;
      case "pointerover":
      case "pointerout":
        ji.delete(e.pointerId);
        break;
      case "gotpointercapture":
      case "lostpointercapture":
        qi.delete(e.pointerId);
    }
  }
  function Gi(t, e, l, a, n, i) {
    return t === null || t.nativeEvent !== i ? (t = {
      blockedOn: e,
      domEventName: l,
      eventSystemFlags: a,
      nativeEvent: i,
      targetContainers: [n]
    }, e !== null && (e = rl(e), e !== null && Qd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function lg(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return oa = Gi(
          oa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return ra = Gi(
          ra,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return sa = Gi(
          sa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "pointerover":
        var i = n.pointerId;
        return ji.set(
          i,
          Gi(
            ji.get(i) || null,
            t,
            e,
            l,
            a,
            n
          )
        ), !0;
      case "gotpointercapture":
        return i = n.pointerId, qi.set(
          i,
          Gi(
            qi.get(i) || null,
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
  function Jd(t) {
    var e = ol(t.target);
    if (e !== null) {
      var l = k(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = Q(l), e !== null) {
            t.blockedOn = e, Jn(t.priority, function() {
              Vd(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = lt(l), e !== null) {
            t.blockedOn = e, Jn(t.priority, function() {
              Vd(l);
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
  function ff(t) {
    if (t.blockedOn !== null) return !1;
    for (var e = t.targetContainers; 0 < e.length; ) {
      var l = ho(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        In = a, l.target.dispatchEvent(a), In = null;
      } else
        return e = rl(l), e !== null && Qd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function kd(t, e, l) {
    ff(t) && l.delete(e);
  }
  function ag() {
    po = !1, oa !== null && ff(oa) && (oa = null), ra !== null && ff(ra) && (ra = null), sa !== null && ff(sa) && (sa = null), ji.forEach(kd), qi.forEach(kd);
  }
  function cf(t, e) {
    t.blockedOn === e && (t.blockedOn = null, po || (po = !0, S.unstable_scheduleCallback(
      S.unstable_NormalPriority,
      ag
    )));
  }
  var of = null;
  function Fd(t) {
    of !== t && (of = t, S.unstable_scheduleCallback(
      S.unstable_NormalPriority,
      function() {
        of === t && (of = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (go(a || l) === null)
              continue;
            break;
          }
          var i = rl(l);
          i !== null && (t.splice(e, 3), e -= 3, mc(
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
    function e(r) {
      return cf(r, t);
    }
    oa !== null && cf(oa, t), ra !== null && cf(ra, t), sa !== null && cf(sa, t), ji.forEach(e), qi.forEach(e);
    for (var l = 0; l < da.length; l++) {
      var a = da[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < da.length && (l = da[0], l.blockedOn === null); )
      Jd(l), l.blockedOn === null && da.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[he] || null;
        if (typeof i == "function")
          u || Fd(l);
        else if (u) {
          var c = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[he] || null)
              c = u.formAction;
            else if (go(n) !== null) continue;
          } else c = u.action;
          typeof c == "function" ? l[a + 1] = c : (l.splice(a, 3), a -= 3), Fd(l);
        }
      }
  }
  function Wd() {
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
  function yo(t) {
    this._internalRoot = t;
  }
  rf.prototype.render = yo.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(s(409));
    var l = e.current, a = Ye();
    Ld(l, a, t, e, null, null);
  }, rf.prototype.unmount = yo.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      Ld(t.current, 2, null, t, null, null), Qu(), e[Sl] = null;
    }
  };
  function rf(t) {
    this._internalRoot = t;
  }
  rf.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = $i();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < da.length && e !== 0 && e < da[l].priority; l++) ;
      da.splice(l, 0, t), l === 0 && Jd(t);
    }
  };
  var $d = f.version;
  if ($d !== "19.2.3")
    throw Error(
      s(
        527,
        $d,
        "19.2.3"
      )
    );
  U.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(s(188)) : (t = Object.keys(t).join(","), Error(s(268, t)));
    return t = z(e), t = t !== null ? L(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var ng = {
    bundleType: 0,
    version: "19.2.3",
    rendererPackageName: "react-dom",
    currentDispatcherRef: g,
    reconcilerVersion: "19.2.3"
  };
  if (typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ < "u") {
    var sf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!sf.isDisabled && sf.supportsFiber)
      try {
        pa = sf.inject(
          ng
        ), Se = sf;
      } catch {
      }
  }
  return Li.createRoot = function(t, e) {
    if (!G(t)) throw Error(s(299));
    var l = !1, a = "", n = ns, i = is, u = us;
    return e != null && (e.unstable_strictMode === !0 && (l = !0), e.identifierPrefix !== void 0 && (a = e.identifierPrefix), e.onUncaughtError !== void 0 && (n = e.onUncaughtError), e.onCaughtError !== void 0 && (i = e.onCaughtError), e.onRecoverableError !== void 0 && (u = e.onRecoverableError)), e = Gd(
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
      Wd
    ), t[Sl] = e.current, $c(t), new yo(e);
  }, Li.hydrateRoot = function(t, e, l) {
    if (!G(t)) throw Error(s(299));
    var a = !1, n = "", i = ns, u = is, c = us, r = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (i = l.onUncaughtError), l.onCaughtError !== void 0 && (u = l.onCaughtError), l.onRecoverableError !== void 0 && (c = l.onRecoverableError), l.formState !== void 0 && (r = l.formState)), e = Gd(
      t,
      1,
      !0,
      e,
      l ?? null,
      a,
      n,
      r,
      i,
      u,
      c,
      Wd
    ), e.context = Yd(null), l = e.current, a = Ye(), a = ba(a), n = $l(a), n.callback = null, Il(l, n, a), l = a, e.current.lanes = l, fl(e, l), pl(e), t[Sl] = e.current, $c(t), new rf(e);
  }, Li.version = "19.2.3", Li;
}
var fm;
function hg() {
  if (fm) return bo.exports;
  fm = 1;
  function S() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(S);
      } catch (f) {
        console.error(f);
      }
  }
  return S(), bo.exports = mg(), bo.exports;
}
var gg = hg(), Mo = { exports: {} }, Eo = {};
var cm;
function pg() {
  if (cm) return Eo;
  cm = 1;
  var S = mf().__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  return Eo.c = function(f) {
    return S.H.useMemoCache(f);
  }, Eo;
}
var om;
function yg() {
  return om || (om = 1, Mo.exports = pg()), Mo.exports;
}
var Za = yg(), vg = mf();
const bg = {
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
function rm() {
  return !1;
}
function sm(S, f = {}) {
  const D = /* @__PURE__ */ new Set();
  return (s) => {
    const G = S?.[s];
    if (typeof G == "string" && G.trim() !== "")
      return G;
    if (f.assertMissing && !D.has(s))
      throw D.add(s), new Error(`Missing cmux diff viewer label: ${s}`);
    return bg[s];
  };
}
const xg = {
  background: "#ffffff",
  foreground: "#000000",
  ghosttyName: "Apple System Colors Light",
  name: "cmux-ghostty-light",
  palette: {},
  selectionBackground: "#abd8ff",
  selectionForeground: "#000000",
  type: "light"
}, Sg = {
  background: "#000000",
  foreground: "#ffffff",
  ghosttyName: "Apple System Colors",
  name: "cmux-ghostty-dark",
  palette: {},
  selectionBackground: "#3f638b",
  selectionForeground: "#ffffff",
  type: "dark"
};
function dm(S) {
  const f = {
    ...xg,
    ...S?.themes?.light
  }, D = {
    ...Sg,
    ...S?.themes?.dark
  };
  return {
    backgroundOpacity: hm(S?.backgroundOpacity),
    fontFamily: S?.fontFamily ?? "Menlo",
    fontSize: df(S?.fontSize, 10),
    lineHeight: df(S?.lineHeight, 20),
    theme: {
      light: S?.theme?.light ?? f.name ?? "cmux-ghostty-light",
      dark: S?.theme?.dark ?? D.name ?? "cmux-ghostty-dark"
    },
    themes: {
      light: f,
      dark: D
    }
  };
}
function mm(S) {
  if (!S)
    return;
  const f = S.themes?.light ?? {}, D = S.themes?.dark ?? {}, s = document.documentElement.style;
  s.setProperty("--cmux-diff-bg-light", Va(f.background, "#ffffff")), s.setProperty("--cmux-diff-bg-dark", Va(D.background, "#000000")), s.setProperty("--cmux-diff-fg-light", Va(f.foreground, "#000000")), s.setProperty("--cmux-diff-fg-dark", Va(D.foreground, "#ffffff")), s.setProperty("--cmux-diff-selection-bg-light", Va(f.selectionBackground, "#abd8ff")), s.setProperty("--cmux-diff-selection-bg-dark", Va(D.selectionBackground, "#3f638b")), s.setProperty("--cmux-diff-code-font-family", zg(S.fontFamily)), s.setProperty("--cmux-diff-font-size", `${df(S.fontSize, 10)}px`), s.setProperty("--cmux-diff-line-height", `${df(S.lineHeight, 20)}px`);
}
function Tg(S, f) {
  return hm(f?.backgroundOpacity) < 0.999 ? "transparent" : Va(S, "#000000");
}
function Va(S, f) {
  return typeof S == "string" && S.trim() !== "" ? S.trim() : f;
}
function zg(S) {
  const f = typeof S == "string" && S.trim() !== "" ? S.trim() : "Menlo";
  return `${JSON.stringify(f)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
}
function df(S, f) {
  return typeof S == "number" && Number.isFinite(S) && S > 0 ? S : f;
}
function hm(S) {
  return typeof S != "number" || !Number.isFinite(S) ? 1 : Math.max(0, Math.min(1, S));
}
function Mg(S, f, D) {
  if (!S)
    return {
      kind: "reset"
    };
  const s = S.pathCount ?? S.paths?.length ?? 0, G = f.pathCount ?? D.length;
  return !(f.previousSource === S || Eg(S, f)) || G < s ? {
    kind: "reset"
  } : {
    addedPaths: D.slice(s, G),
    kind: "append"
  };
}
function Eg(S, f) {
  const D = S.paths, s = f.paths, G = S.pathCount ?? D?.length ?? 0, k = f.pathCount ?? s?.length ?? 0;
  if (!Array.isArray(D) || !Array.isArray(s) || G > k)
    return !1;
  for (let Q = 0; Q < G; Q += 1)
    if (D[Q] !== s[Q])
      return !1;
  return !0;
}
function Ag(S) {
  const f = (o) => {
    const d = document.getElementById(o);
    if (!d)
      throw new Error(`Missing cmux diff viewer element: ${o}`);
    return d;
  }, D = S.assets ?? {}, s = (o, d) => {
    if (typeof o != "string" || o.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${d}`);
    return new URL(o, window.location.href).href;
  }, G = s(D.diffsModuleURL, "diffsModuleURL"), k = s(D.treesModuleURL, "treesModuleURL"), Q = s(D.workerPoolModuleURL, "workerPoolModuleURL"), lt = s(D.workerModuleURL, "workerModuleURL"), C = S.payload ?? {}, z = dm(C.appearance), L = f("viewer"), w = f("status"), tt = f("toolbar"), rt = f("source-select"), dt = f("repo-select"), yt = f("base-select"), Gt = f("source-detail"), ut = f("jump-select"), Yt = f("external-link"), mt = f("files-toggle"), _t = f("layout-toggle"), Ct = f("options-button"), ht = f("options-menu"), $ = f("files-sidebar"), Ut = f("file-list"), Pt = f("files-count"), Ft = f("file-search-toggle"), Vt = f("file-collapse-toggle"), Zt = f("stats-files"), de = f("stats-added"), ie = f("stats-deleted"), X = sm(C.labels, {
    assertMissing: rm()
  }), g = {
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
  let U, Z, W;
  const et = [], m = [], A = /* @__PURE__ */ new Map();
  let N = /* @__PURE__ */ new Set(), j = null, at = null, ft = /* @__PURE__ */ new Map(), Tt = {
    value: null
  }, oe = "", Rt = "", yl = !1, Le = /* @__PURE__ */ new Map(), nl = /* @__PURE__ */ new Map();
  typeof C.title == "string" && C.title.trim() !== "" && (document.title = C.title), mm(z), Se(), cl(C.sourceOptions ?? []), Sl(dt, C.repoOptions ?? [], C.repoRoot ?? "", X("repoPath")), Sl(yt, C.baseOptions ?? [], C.branchBaseRef ?? "", X("branchBase"));
  const Gn = globalThis.queueMicrotask ?? ((o) => setTimeout(o, 0));
  C.pendingReplacement === !0 ? (Ue(C.statusMessage ?? X("loadingDiff"), {
    loading: !0,
    pending: !0
  }), Xi()) : typeof C.statusMessage == "string" && C.statusMessage.length > 0 ? Ue(C.statusMessage, {
    error: C.statusIsError === !0,
    loading: !1,
    statusOnly: !0
  }) : Gn(() => {
    vl().catch((o) => {
      console.error("cmux diff viewer render failed", o), Ue(X("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      });
    });
  });
  async function vl() {
    Ue(X("loadingRenderer"), {
      loading: !0
    });
    const [{
      CodeView: o,
      getFiletypeFromFileName: d,
      parsePatchFiles: x,
      preloadHighlighter: B,
      processFile: H,
      registerCustomTheme: q
    }, K] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(G),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(k).catch((vt) => (console.warn("cmux diff file tree import failed", vt), null))
    ]);
    if (ge(q, z.themes.light), ge(q, z.themes.dark), Ue(X("parsingDiff"), {
      loading: !0
    }), ha("loading"), Z = await Ln(), tu(et), Te(), window.__cmuxDiffViewer = {
      codeView: U,
      items: et,
      state: g,
      workerPool: Z
    }, Xn(Z), Z?.initialize?.()?.then?.(() => Qn(Z?.getStats?.()))?.catch?.((vt) => console.warn("cmux diff worker pool initialization failed", vt)), window.addEventListener("pagehide", () => Z?.terminate?.(), {
      once: !0
    }), await Zi({
      CodeView: o,
      parsePatchFiles: x,
      processFile: H,
      treesModule: K
    }), et.length === 0)
      throw new Error(X("noFileDiffs"));
    Z || $n(z, m.length > 0 ? m : et, d, B).catch((vt) => console.warn("cmux diff highlighter preload failed", vt));
  }
  function Ue(o, d = {}) {
    w.isConnected || L.replaceChildren(w), document.body.dataset.loading = d.loading === !0 || d.pending === !0 ? "true" : "false", document.body.dataset.statusOnly = d.statusOnly === !0 ? "true" : "false", w.dataset.error = d.error === !0 ? "true" : "false", w.dataset.pending = d.pending === !0 ? "true" : "false", w.textContent = o;
  }
  function Yn(o) {
    document.open(), document.write(o), document.close();
  }
  async function hf(o) {
    if (!o.ok)
      return Ue(X("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      }), !1;
    const d = await o.text();
    return d.includes('data-cmux-diff-pending="true"') ? !1 : (Yn(d), !0);
  }
  async function Xi() {
    try {
      const o = await fetch("/__cmux_diff_viewer_wait" + location.pathname, {
        cache: "no-store"
      });
      await hf(o);
    } catch (o) {
      document.documentElement.dataset.cmuxDiffWait = "failed", Ue(X("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      }), console.warn("cmux diff viewer deferred load failed", o);
    }
  }
  async function Ln() {
    if (typeof Worker > "u")
      return null;
    try {
      const o = await import(Q);
      ge(o.registerCustomTheme, z.themes.light), ge(o.registerCustomTheme, z.themes.dark);
      const d = new URL(lt, window.location.href).href;
      return o.createDiffWorkerPool({
        workerURL: d,
        highlighterOptions: Qi()
      }) ?? null;
    } catch (o) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", o), null;
    }
  }
  function Xn(o) {
    if (!o) {
      ha("fallback");
      return;
    }
    ha("enabled"), Qn(o.getStats?.());
    const d = o.subscribeToStatChanges?.((x) => {
      Qn(x);
    });
    typeof d == "function" && window.addEventListener("pagehide", d, {
      once: !0
    });
  }
  function ha(o) {
    document.body.dataset.workerPool = o;
  }
  function Qn(o) {
    !o || typeof o != "object" || (typeof o.managerState == "string" && (document.body.dataset.workerPoolState = o.managerState), Number.isFinite(o.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(o.totalWorkers)), typeof o.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(o.workersFailed)));
  }
  function Qi() {
    return {
      theme: z.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: g.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const me = /^From\s+([a-f0-9]+)\s/im;
  function Vi(o, d) {
    const x = o?.match(me);
    return x?.[1] ? new TextDecoder().decode(new TextEncoder().encode(x[1].slice(0, 5))) : `${X("commit")} ${d + 1}`;
  }
  async function Zi({
    CodeView: o,
    parsePatchFiles: d,
    processFile: x,
    treesModule: B
  }) {
    const H = gf(), q = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, K = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let nt = performance.now(), vt = performance.now(), Dt = !0;
    const Ql = {
      initialBatchSize: Fn(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function en(_, R) {
      const P = tl(H, _, R);
      return P?.renamedItem && iu(P.renamedItem), P?.item;
    }
    function tl(_, R, P) {
      if (!R)
        return null;
      const ct = re(R), zt = P == null ? ct : `${P}/${ct}`, Mt = ct.length === 0 ? void 0 : _.pathStateByTreePath.get(zt), Kt = Mt == null ? void 0 : In(_, zt, Mt), ze = Xl(R), Be = {
        id: _.itemIdToFile.has(zt) ? ln(_, `${zt}?2`) : zt,
        type: "diff",
        fileDiff: R,
        version: 0
      }, fu = _.items.length;
      _.fileIndex += 1, _.items.push(Be), _.pendingItems.push(Be), _.pendingItemById.set(Be.id, Be), _.itemIdToFile.set(Be.id, {
        fileOrder: fu,
        path: ct
      }), _.itemIdByTreePath.set(zt, Be.id), _.treePathByItemId.set(Be.id, zt), _.diffStats.addedLines += ze.added, _.diffStats.deletedLines += ze.deleted, _.diffStats.fileCount += 1, _.diffStats.totalLinesOfCode += R.unifiedLineCount ?? R.splitLineCount ?? 0;
      const Sf = _.statsByPath.get(zt);
      return _.statsByPath.set(zt, ze), Mt != null && !tn(Sf, ze) && (_.pendingStatsChanged = !0), ct.length > 0 && (Mt == null && _.paths.push(zt), _.pathToItemId.set(zt, Be.id), Vl(_, zt, R.type, Mt?.sawDeleted === !0), _.pathStateByTreePath.set(zt, {
        currentItem: Be,
        currentItemId: Be.id,
        currentType: R.type,
        fileOrder: fu,
        sawDeleted: Mt?.sawDeleted === !0 || R.type === "deleted"
      })), {
        item: Be,
        renamedItem: Kt
      };
    }
    function In(_, R, P) {
      const ct = P.currentItemId, zt = P.currentType === "deleted" ? "?deleted" : "?previous", Mt = ln(_, `${R}${zt}`);
      if (P.currentItem.id = Mt, P.currentItemId = Mt, _.itemIdToFile.has(ct)) {
        const Kt = _.itemIdToFile.get(ct);
        _.itemIdToFile.delete(ct), _.itemIdToFile.set(Mt, Kt);
      }
      if (_.treePathByItemId.has(ct) && (_.treePathByItemId.delete(ct), _.treePathByItemId.set(Mt, R)), _.pendingItemById.has(ct)) {
        const Kt = _.pendingItemById.get(ct);
        _.pendingItemById.delete(ct), _.pendingItemById.set(Mt, Kt);
        return;
      }
      return {
        oldId: ct,
        newId: Mt
      };
    }
    function ln(_, R) {
      if (!_.itemIdToFile.has(R))
        return R;
      let P = _.nextCollisionSuffixByBase.get(R) ?? 2, ct = `${R}-${P}`;
      for (; _.itemIdToFile.has(ct); )
        P += 1, ct = `${R}-${P}`;
      return _.nextCollisionSuffixByBase.set(R, P + 1), ct;
    }
    function Vl(_, R, P, ct) {
      if (ct && P !== "deleted") {
        _.gitStatusByPath.delete(R) && Tl(_, R);
        return;
      }
      const zt = Pa(P);
      if (zt === "modified") {
        _.gitStatusByPath.delete(R) && Tl(_, R);
        return;
      }
      if (_.gitStatusByPath.get(R)?.status === zt)
        return;
      const Kt = {
        path: R,
        status: zt
      };
      _.gitStatusByPath.set(R, Kt), _.pendingGitStatusRemovePaths.delete(R), _.pendingGitStatusSetByPath.set(R, Kt);
    }
    function Tl(_, R) {
      _.pendingGitStatusSetByPath.delete(R), _.pendingGitStatusRemovePaths.add(R);
    }
    function iu(_) {
      if (N.delete(_.oldId) && N.add(_.newId), A.has(_.oldId)) {
        const R = A.get(_.oldId);
        A.delete(_.oldId), R && A.set(_.newId, R);
      }
      lu(_.oldId, _.newId), U?.updateItemId?.(_.oldId, _.newId);
    }
    async function Ta(_, R) {
      en(_, R) && await an(!1);
    }
    async function an(_) {
      if (H.pendingItems.length === 0)
        return;
      const R = performance.now();
      if (!_ && Dt && R - nt >= 8 && H.pendingItems.length < Ql.initialBatchSize && R - vt < Ql.initialMaxWait) {
        await Ji(), nt = performance.now();
        return;
      }
      const P = Dt ? Ql.initialBatchSize : Ql.incrementalBatchSize, ct = Dt ? Ql.initialMaxWait : Ql.incrementalMaxWait;
      if (_ || H.pendingItems.length >= P || R - vt >= ct) {
        za(), await Ji(), nt = performance.now();
        return;
      }
    }
    function za() {
      if (H.pendingItems.length === 0)
        return;
      const _ = H.pendingItems.splice(0, H.pendingItems.length);
      H.pendingItemById.clear();
      const R = _, P = m.length > 0;
      et.push(..._);
      for (const ct of _)
        A.set(ct.id, ct);
      if (R.length > 0) {
        m.push(...R);
        for (const ct of R)
          N.add(ct.id);
        U ? U.addItems(R) : (U = new o(ya(), Z ?? void 0), U.setup(L), U.setItems(m), U.render(!0), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.codeView = U));
      }
      eu(_), Ma(B, !1, _.length), K.flushCount += 1, K.maxBatchSize = Math.max(K.maxBatchSize, _.length), K.fileCount = et.length, K.renderableFileCount = m.length, Ka(K), vt = performance.now(), Dt && (Dt = !1, document.body.dataset.loading = "false", w.remove()), P || Sa(m[0]?.id ?? et[0]?.id ?? ""), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.items = et, window.__cmuxDiffViewer.codeViewItems = m, window.__cmuxDiffViewer.streamMetrics = K);
    }
    function Xe() {
      U && (U.syncContainerHeight?.(), U.render(!0));
    }
    function Ma(_, R, P = 1) {
      if (q.treesModule = _, q.dirtyCount += P, R || q.lastRefreshAt === 0) {
        zl(q.treesModule);
        return;
      }
      const ct = performance.now() - q.lastRefreshAt;
      if (q.dirtyCount >= 1e3 || ct >= 1e3) {
        zl(q.treesModule);
        return;
      }
      if (q.timeout !== 0)
        return;
      const zt = Math.max(0, 1e3 - ct);
      q.timeout = window.setTimeout(() => {
        q.timeout = 0, zl(q.treesModule);
      }, zt);
    }
    function zl(_) {
      q.timeout !== 0 && (window.clearTimeout(q.timeout), q.timeout = 0), q.dirtyCount = 0, q.lastRefreshAt = performance.now(), K.treeRefreshCount += 1, at = Ki(H), vf(at, _), Te(), Ka(K);
    }
    const Ee = await fetch(C.patchURL, {
      cache: "no-store"
    });
    if (!Ee.ok)
      throw new Error(`${X("loadingDiff")} (${Ee.status})`);
    if (!Ee.body?.getReader) {
      const _ = await Ee.text();
      await ga(_, d, Ta), await an(!0), Xe(), Ma(B, !0), K.completedAt = performance.now();
      return;
    }
    const nn = new TextDecoder(), un = Ee.body.getReader(), Pn = "diff --git ", Ea = `
` + Pn, fn = Ea.length - 1, ti = /\S/;
    function fe(_, R) {
      const P = Math.max(R, 0);
      if (P === 0 && _.startsWith(Pn))
        return 0;
      const ct = _.indexOf(Ea, P);
      return ct === -1 ? void 0 : ct + 1;
    }
    function dl(_, R) {
      return Math.max(R, _.length - fn);
    }
    function cn(_, R, P) {
      const ct = Math.max(R, 0), zt = Math.min(P, _.length);
      if (ct >= zt)
        return;
      let Mt = _.lastIndexOf(`
From `, zt - 1);
      for (; Mt !== -1; ) {
        const Kt = Mt + 1;
        if (Kt < ct)
          return;
        if (Kt >= zt) {
          Mt = _.lastIndexOf(`
From `, Mt - 1);
          continue;
        }
        const ze = _.indexOf(`
`, Kt + 1), Zl = _.slice(Kt, ze === -1 || ze > zt ? zt : ze);
        if (me.test(Zl))
          return Kt;
        Mt = _.lastIndexOf(`
From `, Mt - 1);
      }
    }
    function Aa(_) {
      const R = fe(_, 0);
      if (R == null || R <= 0)
        return;
      const P = _.slice(0, R);
      return me.test(P) ? P : void 0;
    }
    async function uu(_) {
      if (_.trim() === "")
        return;
      const R = Aa(_);
      R != null && (Da = Vi(R, li), li += 1);
      const P = `cmux-diff-file-${H.fileIndex}`;
      await Ta(x(_, {
        cacheKey: P,
        isGitDiff: !0
      }), Da);
    }
    function ei() {
      let _, R = "", P = 0, ct = !1;
      function zt() {
        if (_ == null) {
          if (_ = fe(R, P), _ == null)
            return P = dl(R, 0), null;
          ct = !0, P = _ + 1;
        }
        for (; ; ) {
          const Mt = _;
          if (Mt == null)
            return null;
          const Kt = fe(R, P);
          if (Kt == null)
            return P = dl(R, Mt + 1), null;
          const ze = cn(R, Mt + 1, Kt) ?? Kt, Zl = R.slice(0, ze);
          if (R = R.slice(ze), _ = fe(R, 0), P = _ == null ? 0 : _ + 1, ti.test(Zl))
            return Zl;
        }
      }
      return {
        push(Mt) {
          Mt.length > 0 && (R += Mt);
        },
        takeAvailableFile: zt,
        finish() {
          const Mt = zt();
          if (Mt != null)
            return {
              fileText: Mt
            };
          if (!ti.test(R))
            return R = "", {};
          if (!ct) {
            const ze = R;
            return R = "", {
              fallbackPatchContent: ze
            };
          }
          const Kt = R;
          return R = "", {
            fileText: Kt
          };
        }
      };
    }
    async function _a(_) {
      let R;
      for (; (R = _.takeAvailableFile()) != null; )
        await uu(R);
    }
    const Qe = ei();
    let Da, li = 0;
    for (; ; ) {
      const {
        done: _,
        value: R
      } = await un.read();
      if (_) {
        const P = nn.decode();
        P.length > 0 && (Qe.push(P), await _a(Qe));
        break;
      }
      Qe.push(nn.decode(R, {
        stream: !0
      })), await _a(Qe);
    }
    const on = Qe.finish();
    on.fileText != null ? (await uu(on.fileText), await _a(Qe)) : on.fallbackPatchContent != null && await ga(on.fallbackPatchContent, d, Ta), await an(!0), Xe(), Ma(B, !0), K.completedAt = performance.now(), Ka(K);
  }
  function Ka(o) {
    document.body.dataset.streamFileCount = String(o.fileCount ?? et.length), document.body.dataset.streamRenderableFileCount = String(o.renderableFileCount ?? m.length), document.body.dataset.streamFlushCount = String(o.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(o.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(o.treeRefreshCount ?? 0), Number.isFinite(o.completedAt) && o.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(o.completedAt - o.startedAt)));
  }
  async function ga(o, d, x) {
    const B = d(o, "cmux-diff"), H = B.length > 1;
    for (const [q, K] of B.entries()) {
      const nt = H ? Vi(K.patchMetadata, q) : void 0;
      for (const vt of K.files ?? [])
        await x(vt, nt);
    }
  }
  function gf() {
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
  function Ki(o) {
    const d = o.lastTreeSource, x = pf(o), B = {
      diffStats: {
        ...o.diffStats
      },
      gitStatus: Array.from(o.gitStatusByPath.values()),
      gitStatusPatch: x,
      pathCount: o.paths.length,
      paths: o.paths,
      pathToItemId: o.pathToItemId,
      previousSource: d,
      statsChanged: o.pendingStatsChanged,
      statsByPath: o.statsByPath,
      treePathByItemId: o.treePathByItemId
    };
    return o.pendingStatsChanged = !1, o.lastTreeSource = B, B;
  }
  function pf(o) {
    if (o.pendingGitStatusRemovePaths.size === 0 && o.pendingGitStatusSetByPath.size === 0)
      return;
    const d = {};
    return o.pendingGitStatusRemovePaths.size > 0 && (d.remove = Array.from(o.pendingGitStatusRemovePaths), o.pendingGitStatusRemovePaths.clear()), o.pendingGitStatusSetByPath.size > 0 && (d.set = Array.from(o.pendingGitStatusSetByPath.values()), o.pendingGitStatusSetByPath.clear()), d;
  }
  function Ji() {
    return new Promise((o) => {
      let d = !1, x = 0;
      const B = () => {
        d || (d = !0, x !== 0 && window.clearTimeout(x), o());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        x = window.setTimeout(B, 50), window.requestAnimationFrame(B);
      else if (typeof MessageChannel < "u") {
        const H = new MessageChannel();
        H.port1.onmessage = B, H.port2.postMessage(void 0);
      } else
        queueMicrotask(B);
    });
  }
  async function pa() {
    return Tt.value == null && (Tt.value = fetch(C.patchURL, {
      cache: "no-store"
    }).then(async (o) => {
      if (!o.ok)
        throw new Error(`${X("loadingDiff")} (${o.status})`);
      return o.text();
    })), Tt.value;
  }
  function Se() {
    mt.innerHTML = Re("files"), Ft.innerHTML = Re("search"), Vt.innerHTML = Re("sidebarCollapse"), _t.innerHTML = Re(g.layout), Ct.innerHTML = Re("dots"), typeof C.externalURL == "string" && C.externalURL.length > 0 && (Yt.href = C.externalURL, Yt.innerHTML = Re("external"), Yt.hidden = !1), mt.addEventListener("click", () => fl(!g.filesVisible)), Vt.addEventListener("click", () => fl(!1)), Ft.addEventListener("click", () => Fi(!g.fileSearchOpen)), _t.addEventListener("click", () => Zn(g.layout === "split" ? "unified" : "split")), Ct.addEventListener("click", () => Wa(ht.hidden)), document.addEventListener("click", (o) => {
      ht.hidden || o.target instanceof Node && tt.contains(o.target) || Wa(!1);
    }), document.addEventListener("keydown", (o) => {
      o.key === "Escape" && Wa(!1);
    }), il(), Te();
  }
  function il() {
    const o = C.shortcuts ?? {}, d = ue(o.diffViewerScrollDown), x = ue(o.diffViewerScrollUp), B = ue(o.diffViewerScrollToBottom), H = ue(o.diffViewerScrollToTop), q = ue(o.diffViewerOpenFileSearch);
    let K = null, nt = 0;
    document.addEventListener("keydown", (Dt) => {
      if (!(Dt.defaultPrevented || Fa(Dt.target))) {
        if (K && !bl(K.shortcut.second, Dt) && vt(), K && bl(K.shortcut.second, Dt)) {
          Dt.preventDefault(), K.action(), vt();
          return;
        }
        if (Ja(d, Dt)) {
          Dt.preventDefault(), ul(1);
          return;
        }
        if (Ja(x, Dt)) {
          Dt.preventDefault(), ul(-1);
          return;
        }
        if (Ja(B, Dt)) {
          Dt.preventDefault(), L.scrollTo({
            top: L.scrollHeight,
            behavior: "auto"
          });
          return;
        }
        if (Ja(q, Dt) && W) {
          Dt.preventDefault(), fl(!0), Fi(!0);
          return;
        }
        H && yf(H, Dt) && (Dt.preventDefault(), K = {
          shortcut: H,
          action: () => L.scrollTo({
            top: 0,
            behavior: "auto"
          })
        }, nt = window.setTimeout(vt, 700));
      }
    });
    function vt() {
      K = null, nt !== 0 && (window.clearTimeout(nt), nt = 0);
    }
  }
  function ue(o) {
    return !o || o.unbound === !0 || !o.first ? null : {
      first: ki(o.first),
      second: o.second ? ki(o.second) : null
    };
  }
  function ki(o) {
    return {
      key: String(o?.key ?? "").toLowerCase(),
      command: o?.command === !0,
      shift: o?.shift === !0,
      option: o?.option === !0,
      control: o?.control === !0
    };
  }
  function Ja(o, d) {
    return o && !o.second && bl(o.first, d);
  }
  function yf(o, d) {
    return o && o.second && bl(o.first, d);
  }
  function bl(o, d) {
    return !o || d.metaKey !== o.command || d.ctrlKey !== o.control || d.altKey !== o.option || d.shiftKey !== o.shift ? !1 : ka(d) === o.key;
  }
  function ka(o) {
    return o.code === "Space" ? "space" : typeof o.key != "string" || o.key.length === 0 ? "" : (o.key.length === 1, o.key.toLowerCase());
  }
  function Fa(o) {
    const d = o instanceof Element ? o : null;
    return d ? !!d.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function ul(o) {
    const d = Math.max(80, Math.floor(L.clientHeight * 0.38));
    L.scrollBy({
      top: o * d,
      behavior: "auto"
    });
  }
  function ya() {
    return {
      layout: {
        paddingTop: 0,
        gap: 1,
        paddingBottom: 0
      },
      diffStyle: g.layout,
      diffIndicators: g.diffIndicators,
      overflow: g.wordWrap ? "wrap" : "scroll",
      expandUnchanged: g.expandUnchanged,
      disableBackground: !g.showBackgrounds,
      disableLineNumbers: !g.lineNumbers,
      lineHoverHighlight: "number",
      enableLineSelection: !0,
      enableGutterUtility: !0,
      lineDiffType: g.wordDiffs ? "word" : "none",
      stickyHeaders: !0,
      unsafeCSS: va(),
      theme: z.theme,
      themeType: "system"
    };
  }
  function va() {
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
  function xl() {
    const o = ya();
    if (!U) {
      Vn();
      return;
    }
    U.setOptions(o), Vn(), U.render(!0);
  }
  function Vn() {
    Z?.setRenderOptions && Z.setRenderOptions(Qi()).then(() => U?.render(!0)).catch((o) => console.warn("cmux diff worker render options update failed", o));
  }
  function Zn(o) {
    g.layout = o === "unified" ? "unified" : "split", Te(), xl();
  }
  function fl(o) {
    g.filesVisible = o, document.body.dataset.filesHidden = o ? "false" : "true", $.setAttribute("aria-hidden", String(!o)), o ? $.removeAttribute("inert") : $.setAttribute("inert", ""), Te();
  }
  function Fi(o) {
    g.fileSearchOpen = !!o, W && (g.fileSearchOpen ? W.openSearch("") : W.closeSearch()), Te();
  }
  function Wi(o) {
    g.collapsed = o;
    const d = m.map((H) => ({
      ...H,
      collapsed: o,
      version: (H.version ?? 0) + 1
    })), x = new Map(d.map((H) => [H.id, H])), B = et.map((H) => x.get(H.id) ?? {
      ...H,
      collapsed: o,
      version: (H.version ?? 0) + 1
    });
    m.splice(0, m.length, ...d), et.splice(0, et.length, ...B), U && (U.setItems(m), U.render(!0)), Te();
  }
  function Te() {
    mt.setAttribute("aria-pressed", String(g.filesVisible)), mt.title = g.filesVisible ? X("hideFiles") : X("showFiles"), mt.setAttribute("aria-label", mt.title), Vt.title = X("hideFiles"), Vt.setAttribute("aria-label", Vt.title), _t.innerHTML = Re(g.layout), _t.title = g.layout === "split" ? X("switchToUnifiedDiff") : X("switchToSplitDiff"), _t.setAttribute("aria-label", _t.title), Ct.setAttribute("aria-expanded", String(!ht.hidden)), document.documentElement.dataset.layout = g.layout, document.documentElement.dataset.wordWrap = String(g.wordWrap), document.documentElement.dataset.diffIndicators = g.diffIndicators, Ft.disabled = !W, Ft.setAttribute("aria-pressed", String(g.fileSearchOpen)), Ft.title = g.fileSearchOpen ? X("hideFileSearch") : X("showFileSearch"), Ft.setAttribute("aria-label", Ft.title);
  }
  function Wa(o) {
    o && ba(), ht.hidden = !o, Te();
  }
  function ba() {
    ht.textContent = "";
    const o = [{
      label: X("refresh"),
      icon: "refresh",
      action: () => window.location.reload()
    }, {
      label: g.wordWrap ? X("disableWordWrap") : X("enableWordWrap"),
      icon: "wrap",
      checked: g.wordWrap,
      action: () => {
        g.wordWrap = !g.wordWrap, xl();
      }
    }, {
      label: g.collapsed ? X("expandAllDiffs") : X("collapseAllDiffs"),
      icon: "collapse",
      checked: g.collapsed,
      action: () => Wi(!g.collapsed)
    }, "separator", {
      label: g.filesVisible ? X("hideFiles") : X("showFiles"),
      icon: "files",
      checked: g.filesVisible,
      action: () => fl(!g.filesVisible)
    }, {
      label: g.expandUnchanged ? X("collapseUnchangedContext") : X("expandUnchangedContext"),
      icon: "document",
      checked: g.expandUnchanged,
      action: () => {
        g.expandUnchanged = !g.expandUnchanged, xl();
      }
    }, {
      label: g.showBackgrounds ? X("hideBackgrounds") : X("showBackgrounds"),
      icon: "background",
      checked: g.showBackgrounds,
      action: () => {
        g.showBackgrounds = !g.showBackgrounds, xl();
      }
    }, {
      label: g.lineNumbers ? X("hideLineNumbers") : X("showLineNumbers"),
      icon: "numbers",
      checked: g.lineNumbers,
      action: () => {
        g.lineNumbers = !g.lineNumbers, xl();
      }
    }, {
      label: g.wordDiffs ? X("disableWordDiffs") : X("enableWordDiffs"),
      icon: "word",
      checked: g.wordDiffs,
      action: () => {
        g.wordDiffs = !g.wordDiffs, xl();
      }
    }, {
      kind: "segment",
      label: X("indicatorStyle"),
      icon: "bars",
      options: [{
        value: "bars",
        icon: "bars",
        label: X("bars")
      }, {
        value: "classic",
        icon: "classic",
        label: X("classic")
      }, {
        value: "none",
        icon: "eye",
        label: X("none")
      }]
    }, "separator", {
      label: X("copyGitApplyCommand"),
      icon: "clipboard",
      action: $i
    }];
    for (const d of o) {
      if (d === "separator") {
        const H = document.createElement("div");
        H.className = "menu-separator", ht.append(H);
        continue;
      }
      if (d.kind === "segment") {
        const H = document.createElement("div");
        H.className = "menu-item menu-segment", H.setAttribute("role", "presentation"), H.innerHTML = `${Re(d.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
        const q = H.querySelector(".menu-label");
        q && (q.textContent = d.label);
        const K = H.querySelector(".menu-segment-controls");
        if (!K)
          continue;
        for (const nt of d.options) {
          const vt = document.createElement("button");
          vt.type = "button", vt.className = "segment-button", vt.title = nt.label, vt.setAttribute("aria-label", nt.label), vt.setAttribute("aria-pressed", String(g.diffIndicators === nt.value)), vt.innerHTML = Re(nt.icon), vt.addEventListener("click", () => {
            g.diffIndicators = nt.value, xl(), ba(), Te();
          }), K.append(vt);
        }
        ht.append(H);
        continue;
      }
      const x = document.createElement("button");
      x.type = "button", x.className = "menu-item", x.setAttribute("role", d.checked == null ? "menuitem" : "menuitemcheckbox"), d.checked != null && x.setAttribute("aria-checked", String(!!d.checked)), x.disabled = !!d.disabled, x.innerHTML = `${Re(d.icon)}<span class="menu-label"></span><span class="menu-check">${d.checked ? Re("check") : ""}</span>`;
      const B = x.querySelector(".menu-label");
      B && (B.textContent = d.label), x.addEventListener("click", () => {
        x.disabled || (d.action?.(), ba(), Te());
      }), ht.append(x);
    }
  }
  function Kn(o) {
    const d = new Set(o.split(/\r?\n/));
    let x = "CMUX_DIFF_PATCH", B = 0;
    for (; d.has(x); )
      B += 1, x = `CMUX_DIFF_PATCH_${B}`;
    return x;
  }
  async function $i() {
    const d = await pa(), x = d.endsWith(`
`) ? d : `${d}
`, B = Kn(x), H = `git apply <<'${B}'
${x}${B}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(H);
      } catch {
        Jn(H);
      }
    else
      Jn(H);
    Ct.title = X("copiedGitApplyCommand"), Ct.setAttribute("aria-label", X("copiedGitApplyCommand"));
  }
  function Jn(o) {
    const d = document.createElement("textarea");
    d.value = o, d.setAttribute("readonly", ""), d.style.position = "fixed", d.style.left = "-9999px", document.body.append(d), d.select(), document.execCommand("copy"), d.remove();
  }
  function cl(o) {
    if (Gt.textContent = he(), !Array.isArray(o) || o.length < 2)
      return;
    rt.textContent = "";
    const d = o.find((x) => x.selected) ?? o.find((x) => !x.disabled);
    for (const x of o) {
      const B = document.createElement("option");
      B.value = x.value, B.textContent = x.label, B.disabled = x.disabled || !x.url, B.selected = x.value === d?.value, x.message && (B.title = x.message), rt.append(B);
    }
    Gt.textContent = d?.sourceLabel ?? he(), rt.hidden = !1, rt.addEventListener("change", () => {
      const x = o.find((B) => B.value === rt.value);
      if (!x?.url) {
        rt.value = d?.value ?? "";
        return;
      }
      Ue(X("loadingDiff"), {
        pending: !0
      }), window.location.href = te(x.url);
    });
  }
  function te(o) {
    try {
      const d = new URL(o, window.location.href);
      if (window.location.protocol === "cmux-diff-viewer:" && (d.protocol === "http:" || d.protocol === "https:")) {
        const x = d.pathname.split("/").filter(Boolean).slice(1).join("/");
        return `cmux-diff-viewer://${window.location.host}/${x}`;
      }
      return d.href;
    } catch {
      return o;
    }
  }
  function he() {
    return [C.sourceLabel, C.repoRoot, C.branchBaseRef].filter((d) => typeof d == "string" && d.trim() !== "").join(" | ");
  }
  function Sl(o, d, x, B) {
    if (!o || !Array.isArray(d) || d.length < 2)
      return;
    o.textContent = "";
    const H = d.find((q) => q.selected) ?? d.find((q) => !q.disabled);
    for (const q of d) {
      const K = document.createElement("option");
      K.value = q.value, K.textContent = q.label, K.disabled = q.disabled || !q.url, K.selected = q.value === H?.value, q.message && (K.title = q.message), o.append(K);
    }
    o.hidden = !1, o.title = B, o.addEventListener("change", () => {
      const q = d.find((K) => K.value === o.value);
      if (!q?.url) {
        o.value = H?.value ?? x ?? "";
        return;
      }
      Ue(X("loadingDiff"), {
        pending: !0
      }), window.location.href = te(q.url);
    });
  }
  function kn(o, d) {
    const x = $a(o), B = xa(d);
    if (Ie(o, []), W && (W.cleanUp?.(), W = null), j = null, g.fileSearchOpen = !1, Ut.textContent = "", Pt.textContent = `${x}`, sl(o), B)
      try {
        bf(o, d), Te();
        return;
      } catch (q) {
        console.warn("cmux diff file tree setup failed", q);
      }
    const H = ol(o);
    Ie(o, H), Wt(H), Te();
  }
  function vf(o, d) {
    const x = $a(o);
    if (Ie(o, []), Pt.textContent = `${x}`, sl(o), W && Ut.dataset.treeMode === "pierre" && d?.preparePresortedFileTreeInput) {
      Ii(o, d);
      return;
    }
    if (W || Ut.childElementCount === 0) {
      kn(o, d);
      return;
    }
    const B = ol(o);
    Ie(o, B), Ut.textContent = "", Wt(B);
  }
  function bf(o, d) {
    const {
      FileTree: x,
      preparePresortedFileTreeInput: B
    } = d, H = rl(o);
    j = o;
    const q = H[0];
    Yl(o), Ut.dataset.treeMode = "pierre", W = new x({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: q ? [q] : [],
      initialVisibleRowCount: Fn(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: B(H),
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: o.gitStatus,
      renderRowDecoration(K) {
        if (K.item.kind !== "file")
          return null;
        const nt = ft.get(K.item.path);
        return nt == null || nt.added === 0 && nt.deleted === 0 ? null : {
          text: `+${nt.added} -${nt.deleted}`,
          title: `${nt.added} ${X("additions")}, ${nt.deleted} ${X("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Pi(),
      onSelectionChange(K) {
        if (yl)
          return;
        const nt = K[K.length - 1], vt = Le.get(nt);
        vt && Wn(vt);
      }
    }), W.render({
      containerWrapper: Ut
    });
  }
  function Ii(o, d) {
    const x = j, B = rl(o);
    j = o, Yl(o);
    let H = !1;
    const q = Mg(x, o, B);
    if (q.kind === "append") {
      const K = q.addedPaths;
      if (K.length > 0)
        try {
          W.batch(K.map((nt) => ({
            type: "add",
            path: nt
          })));
        } catch (nt) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", nt), W.resetPaths(B, {
            preparedInput: d.preparePresortedFileTreeInput(B)
          }), H = !0;
        }
    } else
      W.resetPaths(B, {
        preparedInput: d.preparePresortedFileTreeInput(B)
      }), H = !0;
    o.gitStatusPatch ? typeof W.applyGitStatusPatch == "function" ? W.applyGitStatusPatch(o.gitStatusPatch) : W.setGitStatus(o.gitStatus) : (H || o.statsChanged === !0) && W.setGitStatus(o.gitStatus);
  }
  function xa(o) {
    return !!(o?.FileTree && o?.preparePresortedFileTreeInput);
  }
  function $a(o) {
    return o?.pathCount ?? o?.entries?.length ?? 0;
  }
  function ol(o) {
    const d = o?.pathCount ?? o?.entries?.length ?? 0, x = o?.entries ?? [];
    if (x.length > 0)
      return x.length === d ? x : x.slice(0, d);
    const B = rl(o), H = o?.pathToItemId, q = o?.statsByPath;
    return B.map((K) => {
      const nt = H instanceof Map ? H.get(K) : void 0, vt = nt ? A.get(nt) : void 0, Dt = vt?.fileDiff ?? {};
      return {
        item: vt ?? {
          id: nt ?? K,
          fileDiff: Dt
        },
        path: K,
        status: xf(Dt),
        stats: q instanceof Map ? q.get(K) ?? Xl(Dt) : Xl(Dt)
      };
    });
  }
  function rl(o) {
    const d = o?.pathCount ?? o?.paths?.length ?? 0, x = o?.paths ?? [];
    return x.length === d ? x : x.slice(0, d);
  }
  function Yl(o) {
    if (o?.statsByPath instanceof Map) {
      ft = o.statsByPath;
      return;
    }
    ft = /* @__PURE__ */ new Map();
    const d = ol(o);
    for (const x of d)
      ft.set(x.path, x.stats);
  }
  function Ie(o, d) {
    if (o?.pathToItemId instanceof Map && o?.treePathByItemId instanceof Map)
      Le = o.pathToItemId, nl = o.treePathByItemId;
    else if (o?.pathToItemId instanceof Map) {
      Le = o.pathToItemId, nl = /* @__PURE__ */ new Map();
      for (const [x, B] of Le)
        nl.set(B, x);
    } else {
      Le = /* @__PURE__ */ new Map(), nl = /* @__PURE__ */ new Map();
      for (const x of d) {
        const B = x.item?.id;
        B && (Le.set(x.path, B), nl.set(B, x.path));
      }
    }
    Rt && !Le.has(Rt) && (Rt = "");
  }
  function Wt(o) {
    delete Ut.dataset.treeMode;
    for (const d of o) {
      const x = d.item, B = x.fileDiff ?? {}, H = d.stats ?? Xl(B), q = document.createElement("button");
      q.type = "button", q.className = "file-entry", q.dataset.itemId = x.id, q.title = re(B), q.innerHTML = `
      <span class="file-status">${au(B)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${H.added}</span>
        <span class="stat-del">-${H.deleted}</span>
      </span>
    `;
      const K = q.querySelector(".file-name");
      K && (K.textContent = re(B)), q.addEventListener("click", () => Wn(x.id)), Ut.append(q);
    }
  }
  function Fn() {
    const o = window.visualViewport?.height ?? window.innerHeight;
    return !Number.isFinite(o) || o <= 0 ? 25 : Math.min(96, Math.max(25, Math.ceil(o / 24)));
  }
  function Pi() {
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
  function sl(o) {
    const d = o?.diffStats;
    if (d && Number.isFinite(d.addedLines) && Number.isFinite(d.deletedLines) && Number.isFinite(d.fileCount)) {
      Zt.textContent = `${d.fileCount}`, de.textContent = `+${d.addedLines}`, ie.textContent = `-${d.deletedLines}`;
      return;
    }
    Ll(o?.entries ?? []);
  }
  function Ll(o) {
    const d = o.reduce((x, B) => {
      const H = B.stats ?? Xl(B.item?.fileDiff ?? {});
      return x.added += H.added, x.deleted += H.deleted, x;
    }, {
      added: 0,
      deleted: 0
    });
    Zt.textContent = `${o.length}`, de.textContent = `+${d.added}`, ie.textContent = `-${d.deleted}`;
  }
  function tu(o) {
    ut.textContent = "";
    const d = document.createElement("option");
    d.value = "", d.textContent = X("jumpToFile"), ut.append(d), ut.dataset.initialized = "true";
    for (const x of o) {
      const B = document.createElement("option");
      B.value = x.id, B.textContent = re(x.fileDiff ?? {}), ut.append(B);
    }
    ut.hidden = o.length === 0, ut.onchange = () => {
      ut.value && Wn(ut.value);
    };
  }
  function eu(o) {
    if (o.length === 0)
      return;
    ut.dataset.initialized !== "true" && tu([]);
    const d = document.createDocumentFragment();
    for (const x of o) {
      const B = document.createElement("option");
      B.value = x.id, B.textContent = re(x.fileDiff ?? {}), d.append(B);
    }
    ut.append(d), ut.hidden = !1;
  }
  function lu(o, d) {
    if (ut.dataset.initialized === "true") {
      for (const x of ut.options)
        if (x.value === o) {
          x.value = d;
          return;
        }
    }
  }
  function Wn(o) {
    if (!U)
      return;
    const d = Ia(o);
    d && (U.scrollTo({
      type: "item",
      id: d,
      align: "start",
      behavior: "smooth-auto"
    }), Sa(d));
  }
  function Ia(o) {
    if (N.has(o))
      return o;
    const d = et.findIndex((x) => x.id === o);
    if (d === -1)
      return m[0]?.id ?? "";
    for (let x = d + 1; x < et.length; x += 1)
      if (N.has(et[x].id))
        return et[x].id;
    for (let x = d - 1; x >= 0; x -= 1)
      if (N.has(et[x].id))
        return et[x].id;
    return "";
  }
  function Sa(o) {
    if (!(!o || oe === o)) {
      oe = o, Pe(o);
      for (const d of Ut.querySelectorAll(".file-entry"))
        d.setAttribute("aria-current", d.dataset.itemId === o ? "true" : "false");
      ut.value !== o && (ut.value = o);
    }
  }
  function Pe(o) {
    if (!W)
      return;
    const d = nl.get(o);
    if (!(!d || d === Rt)) {
      yl = !0;
      try {
        Rt && W.getItem(Rt)?.deselect(), W.getItem(d)?.select(), W.scrollToPath(d, {
          focus: !1,
          offset: "nearest"
        }), Rt = d;
      } finally {
        Gn(() => {
          yl = !1;
        });
      }
    }
  }
  function re(o) {
    return o.name ?? o.newName ?? o.oldName ?? o.prevName ?? X("untitled");
  }
  function au(o) {
    switch (o.type) {
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
  function xf(o) {
    return Pa(o.type);
  }
  function Pa(o) {
    switch (o) {
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
  function Xl(o) {
    const d = {
      added: 0,
      deleted: 0
    };
    for (const x of o.hunks ?? [])
      d.added += x.additionLines ?? 0, d.deleted += x.deletionLines ?? 0;
    return d;
  }
  function tn(o, d) {
    return o?.added === d.added && o?.deleted === d.deleted;
  }
  function Re(o) {
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
    }[o] ?? ""}</svg>`;
  }
  function ge(o, d) {
    o(d.name, () => Promise.resolve(nu(d)));
  }
  function $n(o, d, x, B) {
    const H = Array.from(new Set([o.theme?.light, o.theme?.dark].filter(Boolean))), q = Array.from(new Set(d.flatMap((K) => {
      const nt = K.fileDiff ?? {}, vt = nt.name ?? nt.newName ?? nt.oldName ?? nt.prevName ?? "", Dt = nt.lang ?? x(vt) ?? "text";
      return Dt ? [Dt] : [];
    })));
    return B({
      themes: H,
      langs: q.length > 0 ? q : ["text"]
    });
  }
  function nu(o) {
    const d = o.palette ?? {}, x = o.foreground, B = Tg(o.background, z);
    return {
      name: o.name,
      displayName: o.ghosttyName,
      type: o.type,
      colors: {
        "editor.background": B,
        "editor.foreground": x,
        "terminal.background": B,
        "terminal.foreground": x,
        "terminal.ansiBlack": d[0] ?? x,
        "terminal.ansiRed": d[1] ?? x,
        "terminal.ansiGreen": d[2] ?? x,
        "terminal.ansiYellow": d[3] ?? x,
        "terminal.ansiBlue": d[4] ?? x,
        "terminal.ansiMagenta": d[5] ?? x,
        "terminal.ansiCyan": d[6] ?? x,
        "terminal.ansiWhite": d[7] ?? x,
        "terminal.ansiBrightBlack": d[8] ?? x,
        "terminal.ansiBrightRed": d[9] ?? d[1] ?? x,
        "terminal.ansiBrightGreen": d[10] ?? d[2] ?? x,
        "terminal.ansiBrightYellow": d[11] ?? d[3] ?? x,
        "terminal.ansiBrightBlue": d[12] ?? d[4] ?? x,
        "terminal.ansiBrightMagenta": d[13] ?? d[5] ?? x,
        "terminal.ansiBrightCyan": d[14] ?? d[6] ?? x,
        "terminal.ansiBrightWhite": d[15] ?? x,
        "gitDecoration.addedResourceForeground": d[10] ?? d[2] ?? "#32d74b",
        "gitDecoration.deletedResourceForeground": d[9] ?? d[1] ?? "#ff453a",
        "gitDecoration.modifiedResourceForeground": d[12] ?? d[4] ?? "#0a84ff",
        "editor.selectionBackground": o.selectionBackground,
        "editor.selectionForeground": o.selectionForeground
      },
      tokenColors: [{
        settings: {
          foreground: x,
          background: B
        }
      }, {
        scope: ["comment", "punctuation.definition.comment"],
        settings: {
          foreground: d[8] ?? x,
          fontStyle: "italic"
        }
      }, {
        scope: ["string", "constant.other.symbol"],
        settings: {
          foreground: d[2] ?? x
        }
      }, {
        scope: ["constant.numeric", "constant.language", "support.constant"],
        settings: {
          foreground: d[3] ?? x
        }
      }, {
        scope: ["keyword", "storage", "storage.type"],
        settings: {
          foreground: d[5] ?? x
        }
      }, {
        scope: ["entity.name.function", "support.function"],
        settings: {
          foreground: d[4] ?? x
        }
      }, {
        scope: ["entity.name.type", "entity.name.class", "support.type"],
        settings: {
          foreground: d[6] ?? x
        }
      }, {
        scope: ["variable", "meta.definition.variable"],
        settings: {
          foreground: x
        }
      }, {
        scope: ["invalid", "message.error"],
        settings: {
          foreground: d[9] ?? d[1] ?? x
        }
      }]
    };
  }
}
const _g = ["82%", "64%", "76%", "58%", "70%", "46%"], Dg = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
function Og() {
  const S = Za.c(1);
  let f;
  return S[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ J.jsx("div", { className: "diff-loading-placeholder", "aria-hidden": "true", children: _g.map(Cg) }), S[0] = f) : f = S[0], f;
}
function Cg(S, f) {
  return /* @__PURE__ */ J.jsxs("div", { className: "grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]", children: [
    /* @__PURE__ */ J.jsx("span", { className: "size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ J.jsx("span", { className: "h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: S
    } }),
    /* @__PURE__ */ J.jsx("span", { className: "h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: {
      width: f % 2 === 0 ? "34px" : "24px"
    } })
  ] }, `${S}-${f}`);
}
function Ug() {
  const S = Za.c(2);
  let f;
  S[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ J.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
    /* @__PURE__ */ J.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ J.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ J.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
  ] }), S[0] = f) : f = S[0];
  let D;
  return S[1] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (D = /* @__PURE__ */ J.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    f,
    /* @__PURE__ */ J.jsx("div", { className: "space-y-[13px] px-3 py-1", children: Dg.map(Rg) })
  ] }), S[1] = D) : D = S[1], D;
}
function Rg(S, f) {
  return /* @__PURE__ */ J.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
    /* @__PURE__ */ J.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
    /* @__PURE__ */ J.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: S
    } })
  ] }, `${S}-${f}`);
}
function Bg(S) {
  const f = Za.c(8), {
    config: D,
    label: s
  } = S;
  let G;
  f[0] !== D.payload?.statusMessage || f[1] !== s ? (G = D.payload?.statusMessage ?? s("loadingDiff"), f[0] = D.payload?.statusMessage, f[1] = s, f[2] = G) : G = f[2];
  let k;
  f[3] !== G ? (k = /* @__PURE__ */ J.jsx("div", { id: "status", children: G }), f[3] = G, f[4] = k) : k = f[4];
  let Q;
  f[5] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Q = /* @__PURE__ */ J.jsx(Ug, {}), f[5] = Q) : Q = f[5];
  let lt;
  return f[6] !== k ? (lt = /* @__PURE__ */ J.jsxs("div", { id: "loading-layer", "aria-live": "polite", children: [
    k,
    Q
  ] }), f[6] = k, f[7] = lt) : lt = f[7], lt;
}
function Ng(S) {
  const f = Za.c(17), {
    label: D
  } = S;
  let s;
  f[0] !== D ? (s = D("diffTarget"), f[0] = D, f[1] = s) : s = f[1];
  let G;
  f[2] !== s ? (G = /* @__PURE__ */ J.jsx("select", { id: "source-select", "aria-label": s, hidden: !0 }), f[2] = s, f[3] = G) : G = f[3];
  let k;
  f[4] !== D ? (k = D("repoPath"), f[4] = D, f[5] = k) : k = f[5];
  let Q;
  f[6] !== k ? (Q = /* @__PURE__ */ J.jsx("select", { id: "repo-select", "aria-label": k, hidden: !0 }), f[6] = k, f[7] = Q) : Q = f[7];
  let lt;
  f[8] !== D ? (lt = D("branchBase"), f[8] = D, f[9] = lt) : lt = f[9];
  let C;
  f[10] !== lt ? (C = /* @__PURE__ */ J.jsx("select", { id: "base-select", "aria-label": lt, hidden: !0 }), f[10] = lt, f[11] = C) : C = f[11];
  let z;
  f[12] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (z = /* @__PURE__ */ J.jsx("span", { id: "source-detail" }), f[12] = z) : z = f[12];
  let L;
  return f[13] !== G || f[14] !== Q || f[15] !== C ? (L = /* @__PURE__ */ J.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    G,
    Q,
    C,
    z
  ] }), f[13] = G, f[14] = Q, f[15] = C, f[16] = L) : L = f[16], L;
}
function wg(S) {
  const f = Za.c(50), {
    config: D,
    label: s
  } = S;
  let G;
  f[0] !== D || f[1] !== s ? (G = /* @__PURE__ */ J.jsx(Ng, { config: D, label: s }), f[0] = D, f[1] = s, f[2] = G) : G = f[2];
  let k;
  f[3] !== s ? (k = s("jumpToFile"), f[3] = s, f[4] = k) : k = f[4];
  let Q;
  f[5] !== k ? (Q = /* @__PURE__ */ J.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ J.jsx("select", { id: "jump-select", "aria-label": k, hidden: !0 }) }), f[5] = k, f[6] = Q) : Q = f[6];
  const lt = D.payload?.externalURL ?? "#";
  let C;
  f[7] !== s ? (C = s("openSourceURL"), f[7] = s, f[8] = C) : C = f[8];
  let z;
  f[9] !== s ? (z = s("openSourceURL"), f[9] = s, f[10] = z) : z = f[10];
  let L;
  f[11] !== lt || f[12] !== C || f[13] !== z ? (L = /* @__PURE__ */ J.jsx("a", { id: "external-link", className: "toolbar-icon", href: lt, target: "_blank", rel: "noreferrer", title: C, "aria-label": z, hidden: !0 }), f[11] = lt, f[12] = C, f[13] = z, f[14] = L) : L = f[14];
  let w;
  f[15] !== s ? (w = s("hideFiles"), f[15] = s, f[16] = w) : w = f[16];
  let tt;
  f[17] !== s ? (tt = s("hideFiles"), f[17] = s, f[18] = tt) : tt = f[18];
  let rt;
  f[19] !== w || f[20] !== tt ? (rt = /* @__PURE__ */ J.jsx("button", { id: "files-toggle", className: "toolbar-icon", type: "button", title: w, "aria-label": tt, "aria-pressed": "true" }), f[19] = w, f[20] = tt, f[21] = rt) : rt = f[21];
  let dt;
  f[22] !== s ? (dt = s("switchToUnifiedDiff"), f[22] = s, f[23] = dt) : dt = f[23];
  let yt;
  f[24] !== s ? (yt = s("switchToUnifiedDiff"), f[24] = s, f[25] = yt) : yt = f[25];
  let Gt;
  f[26] !== dt || f[27] !== yt ? (Gt = /* @__PURE__ */ J.jsx("button", { id: "layout-toggle", className: "toolbar-icon", type: "button", title: dt, "aria-label": yt }), f[26] = dt, f[27] = yt, f[28] = Gt) : Gt = f[28];
  let ut;
  f[29] !== s ? (ut = s("options"), f[29] = s, f[30] = ut) : ut = f[30];
  let Yt;
  f[31] !== s ? (Yt = s("options"), f[31] = s, f[32] = Yt) : Yt = f[32];
  let mt;
  f[33] !== ut || f[34] !== Yt ? (mt = /* @__PURE__ */ J.jsx("button", { id: "options-button", className: "toolbar-icon", type: "button", title: ut, "aria-label": Yt, "aria-expanded": "false", "aria-haspopup": "menu" }), f[33] = ut, f[34] = Yt, f[35] = mt) : mt = f[35];
  let _t;
  f[36] !== rt || f[37] !== Gt || f[38] !== mt || f[39] !== L ? (_t = /* @__PURE__ */ J.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
    L,
    rt,
    Gt,
    mt
  ] }), f[36] = rt, f[37] = Gt, f[38] = mt, f[39] = L, f[40] = _t) : _t = f[40];
  let Ct;
  f[41] !== s ? (Ct = s("options"), f[41] = s, f[42] = Ct) : Ct = f[42];
  let ht;
  f[43] !== Ct ? (ht = /* @__PURE__ */ J.jsx("div", { id: "options-menu", role: "menu", "aria-label": Ct, hidden: !0 }), f[43] = Ct, f[44] = ht) : ht = f[44];
  let $;
  return f[45] !== G || f[46] !== _t || f[47] !== ht || f[48] !== Q ? ($ = /* @__PURE__ */ J.jsxs("header", { id: "toolbar", children: [
    G,
    Q,
    _t,
    ht
  ] }), f[45] = G, f[46] = _t, f[47] = ht, f[48] = Q, f[49] = $) : $ = f[49], $;
}
function Hg(S) {
  const f = Za.c(62), {
    label: D
  } = S;
  let s;
  f[0] !== D ? (s = D("changedFiles"), f[0] = D, f[1] = s) : s = f[1];
  let G;
  f[2] !== D ? (G = D("files"), f[2] = D, f[3] = G) : G = f[3];
  let k;
  f[4] !== G ? (k = /* @__PURE__ */ J.jsx("span", { children: G }), f[4] = G, f[5] = k) : k = f[5];
  let Q;
  f[6] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Q = /* @__PURE__ */ J.jsx("span", { id: "files-count" }), f[6] = Q) : Q = f[6];
  let lt;
  f[7] !== k ? (lt = /* @__PURE__ */ J.jsxs("span", { id: "files-title", children: [
    k,
    Q
  ] }), f[7] = k, f[8] = lt) : lt = f[8];
  let C;
  f[9] !== D ? (C = D("showFileSearch"), f[9] = D, f[10] = C) : C = f[10];
  let z;
  f[11] !== D ? (z = D("showFileSearch"), f[11] = D, f[12] = z) : z = f[12];
  let L;
  f[13] !== C || f[14] !== z ? (L = /* @__PURE__ */ J.jsx("button", { id: "file-search-toggle", type: "button", title: C, "aria-label": z, "aria-pressed": "false" }), f[13] = C, f[14] = z, f[15] = L) : L = f[15];
  let w;
  f[16] !== D ? (w = D("hideFiles"), f[16] = D, f[17] = w) : w = f[17];
  let tt;
  f[18] !== D ? (tt = D("hideFiles"), f[18] = D, f[19] = tt) : tt = f[19];
  let rt;
  f[20] !== tt || f[21] !== w ? (rt = /* @__PURE__ */ J.jsx("button", { id: "file-collapse-toggle", type: "button", title: w, "aria-label": tt }), f[20] = tt, f[21] = w, f[22] = rt) : rt = f[22];
  let dt;
  f[23] !== rt || f[24] !== L ? (dt = /* @__PURE__ */ J.jsxs("span", { id: "files-header-actions", children: [
    L,
    rt
  ] }), f[23] = rt, f[24] = L, f[25] = dt) : dt = f[25];
  let yt;
  f[26] !== dt || f[27] !== lt ? (yt = /* @__PURE__ */ J.jsxs("div", { id: "files-header", children: [
    lt,
    dt
  ] }), f[26] = dt, f[27] = lt, f[28] = yt) : yt = f[28];
  let Gt;
  f[29] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Gt = /* @__PURE__ */ J.jsx("div", { id: "file-list", children: /* @__PURE__ */ J.jsx(Og, {}) }), f[29] = Gt) : Gt = f[29];
  let ut;
  f[30] !== D ? (ut = D("diffStats"), f[30] = D, f[31] = ut) : ut = f[31];
  let Yt;
  f[32] !== D ? (Yt = D("files"), f[32] = D, f[33] = Yt) : Yt = f[33];
  let mt;
  f[34] !== Yt ? (mt = /* @__PURE__ */ J.jsx("span", { children: Yt }), f[34] = Yt, f[35] = mt) : mt = f[35];
  let _t;
  f[36] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (_t = /* @__PURE__ */ J.jsx("strong", { id: "stats-files", children: "0" }), f[36] = _t) : _t = f[36];
  let Ct;
  f[37] !== mt ? (Ct = /* @__PURE__ */ J.jsxs("div", { className: "stats-row", children: [
    mt,
    _t
  ] }), f[37] = mt, f[38] = Ct) : Ct = f[38];
  let ht;
  f[39] !== D ? (ht = D("additions"), f[39] = D, f[40] = ht) : ht = f[40];
  let $;
  f[41] !== ht ? ($ = /* @__PURE__ */ J.jsx("span", { children: ht }), f[41] = ht, f[42] = $) : $ = f[42];
  let Ut;
  f[43] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Ut = /* @__PURE__ */ J.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" }), f[43] = Ut) : Ut = f[43];
  let Pt;
  f[44] !== $ ? (Pt = /* @__PURE__ */ J.jsxs("div", { className: "stats-row", children: [
    $,
    Ut
  ] }), f[44] = $, f[45] = Pt) : Pt = f[45];
  let Ft;
  f[46] !== D ? (Ft = D("deletions"), f[46] = D, f[47] = Ft) : Ft = f[47];
  let Vt;
  f[48] !== Ft ? (Vt = /* @__PURE__ */ J.jsx("span", { children: Ft }), f[48] = Ft, f[49] = Vt) : Vt = f[49];
  let Zt;
  f[50] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Zt = /* @__PURE__ */ J.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" }), f[50] = Zt) : Zt = f[50];
  let de;
  f[51] !== Vt ? (de = /* @__PURE__ */ J.jsxs("div", { className: "stats-row", children: [
    Vt,
    Zt
  ] }), f[51] = Vt, f[52] = de) : de = f[52];
  let ie;
  f[53] !== ut || f[54] !== Ct || f[55] !== Pt || f[56] !== de ? (ie = /* @__PURE__ */ J.jsxs("div", { id: "files-footer", "aria-label": ut, children: [
    Ct,
    Pt,
    de
  ] }), f[53] = ut, f[54] = Ct, f[55] = Pt, f[56] = de, f[57] = ie) : ie = f[57];
  let X;
  return f[58] !== s || f[59] !== yt || f[60] !== ie ? (X = /* @__PURE__ */ J.jsxs("aside", { id: "files-sidebar", "aria-label": s, children: [
    yt,
    Gt,
    ie
  ] }), f[58] = s, f[59] = yt, f[60] = ie, f[61] = X) : X = f[61], X;
}
function jg(S) {
  const f = Za.c(25), {
    config: D
  } = S, s = vg.useRef(!1), G = D.payload?.labels;
  let k;
  f[0] !== G ? (k = sm(G, {
    assertMissing: rm()
  }), f[0] = G, f[1] = k) : k = f[1];
  const Q = k;
  let lt;
  f[2] !== D ? (lt = (Gt) => {
    !Gt || s.current || (s.current = !0, Ag(D));
  }, f[2] = D, f[3] = lt) : lt = f[3];
  const C = lt;
  let z;
  f[4] !== D || f[5] !== Q ? (z = /* @__PURE__ */ J.jsx(wg, { config: D, label: Q }), f[4] = D, f[5] = Q, f[6] = z) : z = f[6];
  let L;
  f[7] !== D || f[8] !== Q ? (L = /* @__PURE__ */ J.jsx(Hg, { config: D, label: Q }), f[7] = D, f[8] = Q, f[9] = L) : L = f[9];
  let w;
  f[10] !== Q ? (w = Q("diffViewer"), f[10] = Q, f[11] = w) : w = f[11];
  let tt;
  f[12] !== D || f[13] !== Q ? (tt = /* @__PURE__ */ J.jsx(Bg, { config: D, label: Q }), f[12] = D, f[13] = Q, f[14] = tt) : tt = f[14];
  let rt;
  f[15] !== w || f[16] !== tt ? (rt = /* @__PURE__ */ J.jsx("main", { id: "viewer", "aria-label": w, children: tt }), f[15] = w, f[16] = tt, f[17] = rt) : rt = f[17];
  let dt;
  f[18] !== L || f[19] !== rt ? (dt = /* @__PURE__ */ J.jsxs("section", { id: "content", children: [
    L,
    rt
  ] }), f[18] = L, f[19] = rt, f[20] = dt) : dt = f[20];
  let yt;
  return f[21] !== C || f[22] !== z || f[23] !== dt ? (yt = /* @__PURE__ */ J.jsxs("div", { id: "app", ref: C, children: [
    z,
    dt
  ] }), f[21] = C, f[22] = z, f[23] = dt, f[24] = yt) : yt = f[24], yt;
}
const qg = '@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-space-y-reverse:0;--tw-border-style:solid}}}@layer theme{:root,:host{--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--spacing:.25rem;--radius-md:.375rem;--default-font-family:var(--font-sans);--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab,red,red)){::placeholder{color:color-mix(in oklab,currentcolor 50%,transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}}@layer components;@layer utilities{.\\@container{container-type:inline-size}.collapse{visibility:collapse}.visible{visibility:visible}.fixed{position:fixed}.static{position:static}.mx-3\\.5{margin-inline:calc(var(--spacing) * 3.5)}.mt-3\\.5{margin-top:calc(var(--spacing) * 3.5)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.flex{display:flex}.grid{display:grid}.hidden{display:none}.size-4{width:calc(var(--spacing) * 4);height:calc(var(--spacing) * 4)}.h-3{height:calc(var(--spacing) * 3)}.h-6{height:calc(var(--spacing) * 6)}.h-9{height:calc(var(--spacing) * 9)}.h-\\[11px\\]{height:11px}.h-px{height:1px}.w-2\\/5{width:40%}.min-w-0{min-width:calc(var(--spacing) * 0)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.grid-cols-\\[16px_minmax\\(0\\,1fr\\)_44px\\]{grid-template-columns:16px minmax(0,1fr) 44px}.grid-cols-\\[42px_minmax\\(0\\,1fr\\)\\]{grid-template-columns:42px minmax(0,1fr)}.grid-cols-\\[72px_minmax\\(0\\,1fr\\)_96px\\]{grid-template-columns:72px minmax(0,1fr) 96px}.items-center{align-items:center}.justify-center{justify-content:center}.gap-1\\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}:where(.space-y-\\[13px\\]>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(13px * var(--tw-space-y-reverse));margin-block-end:calc(13px * calc(1 - var(--tw-space-y-reverse)))}.justify-self-end{justify-self:flex-end}.rounded{border-radius:.25rem}.rounded-\\[5px\\]{border-radius:5px}.rounded-md{border-radius:var(--radius-md)}.border{border-style:var(--tw-border-style);border-width:1px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:color-mix(in lab,var(--cmux-diff-fg) 18%,transparent)}}.border-\\[var\\(--cmux-diff-border\\)\\]{border-color:var(--cmux-diff-border)}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.bg-\\[var\\(--cmux-diff-muted-bg\\)\\]{background-color:var(--cmux-diff-muted-bg)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-\\[7px\\]{padding-inline:7px}.py-1{padding-block:calc(var(--spacing) * 1)}.pt-3{padding-top:calc(var(--spacing) * 3)}.italic{font-style:italic}.opacity-70{opacity:.7}}:root{color-scheme:light dark;--cmux-diff-bg-light:#fff;--cmux-diff-bg-dark:#000;--cmux-diff-fg-light:#000;--cmux-diff-fg-dark:#fff;--cmux-diff-selection-bg-light:#abd8ff;--cmux-diff-selection-bg-dark:#3f638b;--cmux-diff-ui-font-family:system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size:12px;--cmux-diff-ui-line-height:16px;--cmux-diff-code-font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size:10px;--cmux-diff-line-height:20px;--cmux-diff-bg:var(--cmux-diff-bg-light);--cmux-diff-fg:var(--cmux-diff-fg-light);--cmux-diff-border:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-border:color-mix(in lab, var(--cmux-diff-fg) 12%, transparent)}}:root{--cmux-diff-sidebar-bg:transparent;--cmux-diff-muted-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-muted-bg:color-mix(in lab, var(--cmux-diff-fg) 8%, transparent)}}:root{--cmux-diff-hover-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-hover-bg:color-mix(in lab, var(--cmux-diff-fg) 10%, transparent)}}:root{--cmux-diff-accent:light-dark(#0a84ff,#7ab7ff);color:var(--cmux-diff-fg);background:0 0}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg:var(--cmux-diff-bg-dark);--cmux-diff-fg:var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{background:0 0;height:100%;overflow:hidden}body{height:100vh;min-height:0;color:var(--cmux-diff-fg);font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height);background:0 0;flex-direction:column;margin:0;display:flex;overflow:hidden}#root{background:0 0;height:100%;min-height:0}#app{overscroll-behavior:contain;contain:strict;height:100vh;min-height:0;color:inherit;background:0 0;grid-template-rows:auto minmax(0,1fr);display:grid;overflow:hidden}#toolbar{border-bottom:1px solid var(--cmux-diff-fg);flex:none;align-items:center;gap:7px;min-height:32px;padding:3px 8px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#toolbar{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}#toolbar{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#toolbar{color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg))}}#toolbar{z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{align-items:center;gap:6px;min-width:0;display:flex}.toolbar-left{flex:0 36%}.toolbar-middle{flex:auto;justify-content:center}.toolbar-actions{flex:none}#source-select,#repo-select,#base-select,#jump-select{appearance:none;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,var(--cmux-diff-fg);border:1px solid #0000;border-radius:6px;min-width:118px;max-width:min(30vw,320px);height:24px;padding:0 24px 0 9px}@supports (color:color-mix(in lab,red,red)){#source-select,#repo-select,#base-select,#jump-select{background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent)}}#source-select,#repo-select,#base-select,#jump-select{color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent)}}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent)}}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline-offset:1px}#source-detail{text-overflow:ellipsis;white-space:nowrap;min-width:0;color:var(--cmux-diff-fg);overflow:hidden}@supports (color:color-mix(in lab,red,red)){#source-detail{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}.toolbar-icon{width:28px;height:26px;color:var(--cmux-diff-fg);background:0 0;border:1px solid #0000;border-radius:6px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.toolbar-icon{color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg))}}.toolbar-icon{cursor:pointer;padding:0}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true],.toolbar-icon[aria-pressed=true]{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:16px;height:16px;display:block}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{border:1px solid var(--cmux-diff-fg);min-width:246px;padding:8px;position:absolute;top:calc(100% + 7px);right:10px}@supports (color:color-mix(in lab,red,red)){#options-menu{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent)}}#options-menu{background:var(--cmux-diff-bg);z-index:100;border-radius:8px;box-shadow:0 16px 34px lab(0% none none/.28)}#options-menu[hidden]{display:none}.menu-separator{background:var(--cmux-diff-fg);height:1px;margin:7px 6px}@supports (color:color-mix(in lab,red,red)){.menu-separator{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.menu-item{width:100%;min-height:31px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:6px;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;display:grid}@supports (color:color-mix(in lab,red,red)){.menu-item{color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg))}}.menu-item{font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.menu-item:hover:not(:disabled){color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:0 0}.menu-segment-controls{background:0 0;border-radius:7px;justify-self:end;align-items:center;gap:2px;padding:2px;display:inline-flex}.segment-button{width:27px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.segment-button{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.segment-button{padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.segment-button:hover,.segment-button[aria-pressed=true],.menu-item:disabled{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}}.menu-label{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.menu-check{justify-self:end}#content{--cmux-diff-files-width:clamp(190px, 22vw, 252px);grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);overscroll-behavior:contain;contain:strict;background:0 0;flex:auto;grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";min-width:0;min-height:0;display:grid;position:relative;overflow:hidden}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{border-left:1px solid var(--cmux-diff-border);contain:strict;opacity:1;background:0 0;flex-direction:column;grid-area:files;width:100%;min-width:0;height:100%;min-height:0;transition:opacity .1s,visibility linear;display:flex;position:relative;overflow:hidden}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s,visibility 0s linear .1s}body[data-status-only=true] #files-sidebar{display:none}#files-header{z-index:1;border-bottom:1px solid var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:8px;min-height:30px;padding:0 7px 0 10px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#files-header{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-header{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#files-header{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}#files-title{align-items:center;gap:6px;min-width:0;display:inline-flex}#files-header-actions{flex:none;align-items:center;gap:2px;display:inline-flex}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;flex:none;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){#file-search-toggle,#file-collapse-toggle{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}#file-search-toggle,#file-collapse-toggle{padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:15px;height:15px}#file-list{--trees-bg-override:var(--cmux-diff-sidebar-bg);--trees-fg-override:var(--cmux-diff-fg);flex:auto;min-height:0;padding:6px 4px 6px 6px;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-override:color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg))}}#file-list{--trees-fg-muted-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-muted-override:color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg))}}#file-list{--trees-bg-muted-override:var(--cmux-diff-hover-bg);--trees-selected-bg-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-selected-bg-override:color-mix(in lab, var(--cmux-diff-fg) 11%, transparent)}}#file-list{--trees-selected-fg-override:var(--cmux-diff-fg);--trees-selected-focused-border-color-override:transparent;--trees-border-color-override:var(--cmux-diff-border);--trees-focus-ring-color-override:var(--cmux-diff-accent)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-focus-ring-color-override:color-mix(in lab, var(--cmux-diff-accent) 72%, transparent)}}#file-list{--trees-font-family-override:var(--cmux-diff-ui-font-family);--trees-font-size-override:var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override:500;--trees-density-override:.78;--trees-border-radius-override:5px;--trees-item-padding-x-override:7px;--trees-item-margin-x-override:0;--trees-padding-inline-override:0;--trees-search-bg-override:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-search-bg-override:color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))}}#file-list{--trees-status-added-override:light-dark(#257a3e,#8fd88f);--trees-status-modified-override:var(--cmux-diff-accent);--trees-status-renamed-override:light-dark(#a26300,#ffd166);--trees-status-deleted-override:light-dark(#b42318,#ff8a80)}body[data-loading=false] .diff-loading-placeholder,body[data-loading=false]:not([data-status-only=true]) #loading-layer{display:none}#file-list file-tree-container{width:100%;height:100%}#files-footer{border-top:1px solid var(--cmux-diff-fg);flex:none;padding:7px 10px 8px}@supports (color:color-mix(in lab,red,red)){#files-footer{border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-footer{background:0 0}.stats-row{min-height:19px;color:var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:10px;display:flex}@supports (color:color-mix(in lab,red,red)){.stats-row{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}.stats-row strong{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg))}}.stats-row strong{font-weight:600}.file-entry{width:100%;min-height:30px;color:inherit;font:inherit;text-align:left;background:0 0;border:0;border-radius:6px;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;padding:3px 7px;display:grid}.file-entry:hover,.file-entry[aria-current=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.file-status{width:17px;height:17px;color:var(--cmux-diff-fg);border:1px solid;border-radius:5px;justify-content:center;align-items:center;font-size:9px;line-height:1;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-status{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.file-name{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.file-stats{color:var(--cmux-diff-fg);gap:5px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-stats{color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));overscroll-behavior:contain;overflow-anchor:none;contain:strict;border-bottom:1px solid var(--cmux-diff-border);background:0 0;grid-area:viewer;width:100%;min-width:0;height:100%;min-height:0;position:relative;overflow:clip auto}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border);display:block;overflow:clip}#loading-layer{z-index:4;pointer-events:none;contain:strict;background:0 0;position:absolute;inset:0;overflow:hidden}body[data-status-only=true] #loading-layer{pointer-events:auto;width:100%;height:100%;display:flex;position:static}#status{z-index:5;border:1px solid var(--cmux-diff-fg);align-items:center;gap:10px;max-width:calc(100% - 24px);min-height:32px;padding:8px 12px;display:flex;position:absolute;top:10px;left:12px}@supports (color:color-mix(in lab,red,red)){#status{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#status{background:var(--cmux-diff-bg);font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:var(--cmux-diff-fg);border-radius:7px}@supports (color:color-mix(in lab,red,red)){#status{color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}body[data-status-only=true] #status{border:0;border-bottom:1px solid var(--cmux-diff-fg);width:100%;max-width:none;min-height:40px;position:static}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}body[data-status-only=true] #status{border-radius:0;padding:10px 14px}#status[data-pending=true]:before,body[data-loading=true] #status:before{content:"";border:2px solid var(--cmux-diff-fg);flex:none;width:14px;height:14px}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent)}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-radius:50%;animation:.8s linear infinite cmuxDiffPendingSpin}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before,body[data-loading=true] #status:before{animation:none}}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}';
function Gg() {
  const S = document.getElementById("cmux-diff-viewer-config");
  if (!S?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(S.textContent);
}
function Yg() {
  const S = document.createElement("style");
  S.dataset.cmuxDiffViewerStyle = "true", S.textContent = qg, document.head.append(S);
}
const Gl = Gg();
Yg();
mm(dm(Gl.payload?.appearance));
typeof Gl.payload?.title == "string" && Gl.payload.title.trim() !== "" && (document.title = Gl.payload.title);
document.body.dataset.filesHidden = "false";
document.body.dataset.loading = Gl.payload?.pendingReplacement || !Gl.payload?.statusMessage ? "true" : "false";
document.body.dataset.statusOnly = Gl.payload?.statusMessage && !Gl.payload.pendingReplacement ? "true" : "false";
const gm = document.getElementById("root");
if (!gm)
  throw new Error("Missing cmux diff viewer root");
gg.createRoot(gm).render(/* @__PURE__ */ J.jsx(jg, { config: Gl }));
