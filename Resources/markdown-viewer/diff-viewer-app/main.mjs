var yo = { exports: {} }, qi = {};
var $d;
function ug() {
  if ($d) return qi;
  $d = 1;
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
  return qi.Fragment = f, qi.jsx = D, qi.jsxs = D, qi;
}
var Id;
function fg() {
  return Id || (Id = 1, yo.exports = ug()), yo.exports;
}
var K = fg(), vo = { exports: {} }, Gi = {}, bo = { exports: {} }, xo = {};
var Pd;
function cg() {
  return Pd || (Pd = 1, (function(S) {
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
          var A = 2 * (W + 1) - 1, N = g[A], q = A + 1, at = g[q];
          if (0 > G(N, Z))
            q < et && 0 > G(at, N) ? (g[W] = at, g[q] = Z, W = q) : (g[W] = N, g[A] = Z, W = A);
          else if (q < et && 0 > G(at, Z))
            g[W] = at, g[q] = Z, W = q;
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
    var C = [], z = [], L = 1, w = null, tt = 3, rt = !1, dt = !1, yt = !1, Gt = !1, ft = typeof setTimeout == "function" ? setTimeout : null, Yt = typeof clearTimeout == "function" ? clearTimeout : null, mt = typeof setImmediate < "u" ? setImmediate : null;
    function Dt(g) {
      for (var U = D(z); U !== null; ) {
        if (U.callback === null) s(z);
        else if (U.startTime <= g)
          s(z), U.sortIndex = U.expirationTime, f(C, U);
        else break;
        U = D(z);
      }
    }
    function Ct(g) {
      if (yt = !1, Dt(g), !dt)
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
                for (Dt(g), w = D(C); w !== null && !(w.expirationTime > g && Ft()); ) {
                  var W = w.callback;
                  if (typeof W == "function") {
                    w.callback = null, tt = w.priorityLevel;
                    var et = W(
                      w.expirationTime <= g
                    );
                    if (g = S.unstable_now(), typeof et == "function") {
                      w.callback = et, Dt(g), U = !0;
                      break e;
                    }
                    w === D(C) && s(C), Dt(g);
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
      var re = new MessageChannel(), ie = re.port2;
      re.port1.onmessage = Vt, Zt = function() {
        ie.postMessage(null);
      };
    } else
      Zt = function() {
        ft(Vt, 0);
      };
    function X(g, U) {
      $ = ft(function() {
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
  })(xo)), xo;
}
var tm;
function og() {
  return tm || (tm = 1, bo.exports = cg()), bo.exports;
}
var So = { exports: {} }, ut = {};
var em;
function rg() {
  if (em) return ut;
  em = 1;
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
  function ft(m, A, N) {
    this.props = m, this.context = A, this.refs = Gt, this.updater = N || dt;
  }
  ft.prototype.isReactComponent = {}, ft.prototype.setState = function(m, A) {
    if (typeof m != "object" && typeof m != "function" && m != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, m, A, "setState");
  }, ft.prototype.forceUpdate = function(m) {
    this.updater.enqueueForceUpdate(this, m, "forceUpdate");
  };
  function Yt() {
  }
  Yt.prototype = ft.prototype;
  function mt(m, A, N) {
    this.props = m, this.context = A, this.refs = Gt, this.updater = N || dt;
  }
  var Dt = mt.prototype = new Yt();
  Dt.constructor = mt, yt(Dt, ft.prototype), Dt.isPureReactComponent = !0;
  var Ct = Array.isArray;
  function ht() {
  }
  var $ = { H: null, A: null, T: null, S: null }, Ut = Object.prototype.hasOwnProperty;
  function Pt(m, A, N) {
    var q = N.ref;
    return {
      $$typeof: S,
      type: m,
      key: A,
      ref: q !== void 0 ? q : null,
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
  var re = /\/+/g;
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
  function g(m, A, N, q, at) {
    var ct = typeof m;
    (ct === "undefined" || ct === "boolean") && (m = null);
    var Tt = !1;
    if (m === null) Tt = !0;
    else
      switch (ct) {
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
                q,
                at
              );
          }
      }
    if (Tt)
      return at = at(m), Tt = q === "" ? "." + ie(m, 0) : q, Ct(at) ? (N = "", Tt != null && (N = Tt.replace(re, "$&/") + "/"), g(at, A, N, "", function(gl) {
        return gl;
      })) : at != null && (Vt(at) && (at = Ft(
        at,
        N + (at.key == null || m && m.key === at.key ? "" : ("" + at.key).replace(
          re,
          "$&/"
        ) + "/") + Tt
      )), A.push(at)), 1;
    Tt = 0;
    var ce = q === "" ? "." : q + ":";
    if (Ct(m))
      for (var Rt = 0; Rt < m.length; Rt++)
        q = m[Rt], ct = ce + ie(q, Rt), Tt += g(
          q,
          A,
          N,
          ct,
          at
        );
    else if (Rt = rt(m), typeof Rt == "function")
      for (m = Rt.call(m), Rt = 0; !(q = m.next()).done; )
        q = q.value, ct = ce + ie(q, Rt++), Tt += g(
          q,
          A,
          N,
          ct,
          at
        );
    else if (ct === "object") {
      if (typeof m.then == "function")
        return g(
          X(m),
          A,
          N,
          q,
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
    var q = [], at = 0;
    return g(m, q, "", "", function(ct) {
      return A.call(N, ct, at++);
    }), q;
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
  return ut.Activity = w, ut.Children = et, ut.Component = ft, ut.Fragment = D, ut.Profiler = G, ut.PureComponent = mt, ut.StrictMode = s, ut.Suspense = C, ut.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = $, ut.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(m) {
      return $.H.useMemoCache(m);
    }
  }, ut.cache = function(m) {
    return function() {
      return m.apply(null, arguments);
    };
  }, ut.cacheSignal = function() {
    return null;
  }, ut.cloneElement = function(m, A, N) {
    if (m == null)
      throw Error(
        "The argument must be a React element, but you passed " + m + "."
      );
    var q = yt({}, m.props), at = m.key;
    if (A != null)
      for (ct in A.key !== void 0 && (at = "" + A.key), A)
        !Ut.call(A, ct) || ct === "key" || ct === "__self" || ct === "__source" || ct === "ref" && A.ref === void 0 || (q[ct] = A[ct]);
    var ct = arguments.length - 2;
    if (ct === 1) q.children = N;
    else if (1 < ct) {
      for (var Tt = Array(ct), ce = 0; ce < ct; ce++)
        Tt[ce] = arguments[ce + 2];
      q.children = Tt;
    }
    return Pt(m.type, at, q);
  }, ut.createContext = function(m) {
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
  }, ut.createElement = function(m, A, N) {
    var q, at = {}, ct = null;
    if (A != null)
      for (q in A.key !== void 0 && (ct = "" + A.key), A)
        Ut.call(A, q) && q !== "key" && q !== "__self" && q !== "__source" && (at[q] = A[q]);
    var Tt = arguments.length - 2;
    if (Tt === 1) at.children = N;
    else if (1 < Tt) {
      for (var ce = Array(Tt), Rt = 0; Rt < Tt; Rt++)
        ce[Rt] = arguments[Rt + 2];
      at.children = ce;
    }
    if (m && m.defaultProps)
      for (q in Tt = m.defaultProps, Tt)
        at[q] === void 0 && (at[q] = Tt[q]);
    return Pt(m, ct, at);
  }, ut.createRef = function() {
    return { current: null };
  }, ut.forwardRef = function(m) {
    return { $$typeof: lt, render: m };
  }, ut.isValidElement = Vt, ut.lazy = function(m) {
    return {
      $$typeof: L,
      _payload: { _status: -1, _result: m },
      _init: Z
    };
  }, ut.memo = function(m, A) {
    return {
      $$typeof: z,
      type: m,
      compare: A === void 0 ? null : A
    };
  }, ut.startTransition = function(m) {
    var A = $.T, N = {};
    $.T = N;
    try {
      var q = m(), at = $.S;
      at !== null && at(N, q), typeof q == "object" && q !== null && typeof q.then == "function" && q.then(ht, W);
    } catch (ct) {
      W(ct);
    } finally {
      A !== null && N.types !== null && (A.types = N.types), $.T = A;
    }
  }, ut.unstable_useCacheRefresh = function() {
    return $.H.useCacheRefresh();
  }, ut.use = function(m) {
    return $.H.use(m);
  }, ut.useActionState = function(m, A, N) {
    return $.H.useActionState(m, A, N);
  }, ut.useCallback = function(m, A) {
    return $.H.useCallback(m, A);
  }, ut.useContext = function(m) {
    return $.H.useContext(m);
  }, ut.useDebugValue = function() {
  }, ut.useDeferredValue = function(m, A) {
    return $.H.useDeferredValue(m, A);
  }, ut.useEffect = function(m, A) {
    return $.H.useEffect(m, A);
  }, ut.useEffectEvent = function(m) {
    return $.H.useEffectEvent(m);
  }, ut.useId = function() {
    return $.H.useId();
  }, ut.useImperativeHandle = function(m, A, N) {
    return $.H.useImperativeHandle(m, A, N);
  }, ut.useInsertionEffect = function(m, A) {
    return $.H.useInsertionEffect(m, A);
  }, ut.useLayoutEffect = function(m, A) {
    return $.H.useLayoutEffect(m, A);
  }, ut.useMemo = function(m, A) {
    return $.H.useMemo(m, A);
  }, ut.useOptimistic = function(m, A) {
    return $.H.useOptimistic(m, A);
  }, ut.useReducer = function(m, A, N) {
    return $.H.useReducer(m, A, N);
  }, ut.useRef = function(m) {
    return $.H.useRef(m);
  }, ut.useState = function(m) {
    return $.H.useState(m);
  }, ut.useSyncExternalStore = function(m, A, N) {
    return $.H.useSyncExternalStore(
      m,
      A,
      N
    );
  }, ut.useTransition = function() {
    return $.H.useTransition();
  }, ut.version = "19.2.3", ut;
}
var lm;
function of() {
  return lm || (lm = 1, So.exports = rg()), So.exports;
}
var To = { exports: {} }, be = {};
var am;
function sg() {
  if (am) return be;
  am = 1;
  var S = of();
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
  return be.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = s, be.createPortal = function(C, z) {
    var L = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!z || z.nodeType !== 1 && z.nodeType !== 9 && z.nodeType !== 11)
      throw Error(f(299));
    return k(C, z, null, L);
  }, be.flushSync = function(C) {
    var z = Q.T, L = s.p;
    try {
      if (Q.T = null, s.p = 2, C) return C();
    } finally {
      Q.T = z, s.p = L, s.d.f();
    }
  }, be.preconnect = function(C, z) {
    typeof C == "string" && (z ? (z = z.crossOrigin, z = typeof z == "string" ? z === "use-credentials" ? z : "" : void 0) : z = null, s.d.C(C, z));
  }, be.prefetchDNS = function(C) {
    typeof C == "string" && s.d.D(C);
  }, be.preinit = function(C, z) {
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
  }, be.preinitModule = function(C, z) {
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
  }, be.preload = function(C, z) {
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
  }, be.preloadModule = function(C, z) {
    if (typeof C == "string")
      if (z) {
        var L = lt(z.as, z.crossOrigin);
        s.d.m(C, {
          as: typeof z.as == "string" && z.as !== "script" ? z.as : void 0,
          crossOrigin: L,
          integrity: typeof z.integrity == "string" ? z.integrity : void 0
        });
      } else s.d.m(C);
  }, be.requestFormReset = function(C) {
    s.d.r(C);
  }, be.unstable_batchedUpdates = function(C, z) {
    return C(z);
  }, be.useFormState = function(C, z, L) {
    return Q.H.useFormState(C, z, L);
  }, be.useFormStatus = function() {
    return Q.H.useHostTransitionStatus();
  }, be.version = "19.2.3", be;
}
var nm;
function dg() {
  if (nm) return To.exports;
  nm = 1;
  function S() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(S);
      } catch (f) {
        console.error(f);
      }
  }
  return S(), To.exports = sg(), To.exports;
}
var im;
function mg() {
  if (im) return Gi;
  im = 1;
  var S = og(), f = of(), D = dg();
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
  var w = Object.assign, tt = /* @__PURE__ */ Symbol.for("react.element"), rt = /* @__PURE__ */ Symbol.for("react.transitional.element"), dt = /* @__PURE__ */ Symbol.for("react.portal"), yt = /* @__PURE__ */ Symbol.for("react.fragment"), Gt = /* @__PURE__ */ Symbol.for("react.strict_mode"), ft = /* @__PURE__ */ Symbol.for("react.profiler"), Yt = /* @__PURE__ */ Symbol.for("react.consumer"), mt = /* @__PURE__ */ Symbol.for("react.context"), Dt = /* @__PURE__ */ Symbol.for("react.forward_ref"), Ct = /* @__PURE__ */ Symbol.for("react.suspense"), ht = /* @__PURE__ */ Symbol.for("react.suspense_list"), $ = /* @__PURE__ */ Symbol.for("react.memo"), Ut = /* @__PURE__ */ Symbol.for("react.lazy"), Pt = /* @__PURE__ */ Symbol.for("react.activity"), Ft = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), Vt = Symbol.iterator;
  function Zt(t) {
    return t === null || typeof t != "object" ? null : (t = Vt && t[Vt] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var re = /* @__PURE__ */ Symbol.for("react.client.reference");
  function ie(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === re ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case yt:
        return "Fragment";
      case ft:
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
        case Dt:
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
  var q = m(null), at = m(null), ct = m(null), Tt = m(null);
  function ce(t, e) {
    switch (N(ct, e), N(at, t), N(q, null), e.nodeType) {
      case 9:
      case 11:
        t = (t = e.documentElement) && (t = t.namespaceURI) ? xd(t) : 0;
        break;
      default:
        if (t = e.tagName, e = e.namespaceURI)
          e = xd(e), t = Sd(e, t);
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
    A(q), N(q, t);
  }
  function Rt() {
    A(q), A(at), A(ct);
  }
  function gl(t) {
    t.memoizedState !== null && N(Tt, t);
    var e = q.current, l = Sd(e, t.type);
    e !== l && (N(at, t), N(q, l));
  }
  function Xe(t) {
    at.current === t && (A(q), A(at)), Tt.current === t && (A(Tt), Ni._currentValue = Z);
  }
  var al, Yn;
  function pl(t) {
    if (al === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        al = e && e[1] || "", Yn = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + al + t + Yn;
  }
  var Be = !1;
  function Ln(t, e) {
    if (!t || Be) return "";
    Be = !0;
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
      Be = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? pl(l) : "";
  }
  function rf(t, e) {
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
        return Ln(t.type, !1);
      case 11:
        return Ln(t.type.render, !1);
      case 1:
        return Ln(t.type, !0);
      case 31:
        return pl("Activity");
      default:
        return "";
    }
  }
  function Yi(t) {
    try {
      var e = "", l = null;
      do
        e += rf(t, l), l = t, t = t.return;
      while (t);
      return e;
    } catch (a) {
      return `
Error generating stack: ` + a.message + `
` + a.stack;
    }
  }
  var Xn = Object.prototype.hasOwnProperty, Qn = S.unstable_scheduleCallback, ya = S.unstable_cancelCallback, Vn = S.unstable_shouldYield, Li = S.unstable_requestPaint, se = S.unstable_now, Xi = S.unstable_getCurrentPriorityLevel, Qi = S.unstable_ImmediatePriority, $a = S.unstable_UserBlockingPriority, va = S.unstable_NormalPriority, sf = S.unstable_LowPriority, Vi = S.unstable_IdlePriority, df = S.log, Zi = S.unstable_setDisableYieldValue, ba = null, xe = null;
  function nl(t) {
    if (typeof df == "function" && Zi(t), xe && typeof xe.setStrictMode == "function")
      try {
        xe.setStrictMode(ba, t);
      } catch {
      }
  }
  var ue = Math.clz32 ? Math.clz32 : mf, Ki = Math.log, Ia = Math.LN2;
  function mf(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (Ki(t) / Ia | 0) | 0;
  }
  var yl = 256, Pa = 262144, tn = 4194304;
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
    var c = a & 134217727;
    return c !== 0 ? (a = c & ~i, a !== 0 ? n = il(a) : (u &= c, u !== 0 ? n = il(u) : l || (l = c & ~t, l !== 0 && (n = il(l))))) : (c = a & ~i, c !== 0 ? n = il(c) : u !== 0 ? n = il(u) : l || (l = a & ~t, l !== 0 && (n = il(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
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
  function Zn() {
    var t = tn;
    return tn <<= 1, (tn & 62914560) === 0 && (tn = 4194304), t;
  }
  function Kn(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function ul(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function Ji(t, e, l, a, n, i) {
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
    a !== 0 && ki(t, a, 0), i !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= i & ~(u & ~e));
  }
  function ki(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - ue(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function Se(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - ue(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function en(t, e) {
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
  function Jn(t) {
    return t &= -t, 2 < t ? 8 < t ? (t & 134217727) !== 0 ? 32 : 268435456 : 8 : 2;
  }
  function Fi() {
    var t = U.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Vd(t.type));
  }
  function kn(t, e) {
    var l = U.p;
    try {
      return U.p = t, e();
    } finally {
      U.p = l;
    }
  }
  var fl = Math.random().toString(36).slice(2), te = "__reactFiber$" + fl, de = "__reactProps$" + fl, Xl = "__reactContainer$" + fl, Fn = "__reactEvents$" + fl, hf = "__reactListeners$" + fl, gf = "__reactHandles$" + fl, Wi = "__reactResources$" + fl, Ql = "__reactMarker$" + fl;
  function za(t) {
    delete t[te], delete t[de], delete t[Fn], delete t[hf], delete t[gf];
  }
  function cl(t) {
    var e = t[te];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[Xl] || l[te]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Dd(t); t !== null; ) {
            if (l = t[te]) return l;
            t = Dd(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function bl(t) {
    if (t = t[te] || t[Xl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function ol(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(s(33));
  }
  function xl(t) {
    var e = t[Wi];
    return e || (e = t[Wi] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function Wt(t) {
    t[Ql] = !0;
  }
  var $i = /* @__PURE__ */ new Set(), Wn = {};
  function Sl(t, e) {
    Tl(t, e), Tl(t + "Capture", e);
  }
  function Tl(t, e) {
    for (Wn[t] = e, t = 0; t < e.length; t++)
      $i.add(e[t]);
  }
  var pf = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), Ii = {}, ln = {};
  function yf(t) {
    return Xn.call(ln, t) ? !0 : Xn.call(Ii, t) ? !1 : pf.test(t) ? ln[t] = !0 : (Ii[t] = !0, !1);
  }
  function Ma(t, e, l) {
    if (yf(e))
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
  function an(t, e, l) {
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
  function Te(t, e, l, a) {
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
  function Ee(t) {
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
  function Pi(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function tu(t, e, l) {
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
      var e = Pi(t) ? "checked" : "value";
      t._valueTracker = tu(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function eu(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = Pi(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function ve(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var nn = /[\n"\\]/g;
  function Ae(t) {
    return t.replace(
      nn,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function $n(t, e, l, a, n, i, u, c) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + Ee(e)) : t.value !== "" + Ee(e) && (t.value = "" + Ee(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? d(t, u, Ee(e)) : l != null ? d(t, u, Ee(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), c != null && typeof c != "function" && typeof c != "symbol" && typeof c != "boolean" ? t.name = "" + Ee(c) : t.removeAttribute("name");
  }
  function o(t, e, l, a, n, i, u, c) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        zl(t);
        return;
      }
      l = l != null ? "" + Ee(l) : "", e = e != null ? "" + Ee(e) : l, c || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = c ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), zl(t);
  }
  function d(t, e, l) {
    e === "number" && ve(t.ownerDocument) === t || t.defaultValue === "" + l || (t.defaultValue = "" + l);
  }
  function x(t, e, l, a) {
    if (t = t.options, e) {
      e = {};
      for (var n = 0; n < l.length; n++)
        e["$" + l[n]] = !0;
      for (l = 0; l < t.length; l++)
        n = e.hasOwnProperty("$" + t[l].value), t[l].selected !== n && (t[l].selected = n), n && a && (t[l].defaultSelected = !0);
    } else {
      for (l = "" + Ee(l), e = null, n = 0; n < t.length; n++) {
        if (t[n].value === l) {
          t[n].selected = !0, a && (t[n].defaultSelected = !0);
          return;
        }
        e !== null || t[n].disabled || (e = t[n]);
      }
      e !== null && (e.selected = !0);
    }
  }
  function B(t, e, l) {
    if (e != null && (e = "" + Ee(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + Ee(l) : "";
  }
  function H(t, e, l, a) {
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
    l = Ee(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), zl(t);
  }
  function j(t, e) {
    if (e) {
      var l = t.firstChild;
      if (l && l === t.lastChild && l.nodeType === 3) {
        l.nodeValue = e;
        return;
      }
    }
    t.textContent = e;
  }
  var J = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function nt(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || J.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function xt(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(s(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && nt(t, n, a);
    } else
      for (var i in e)
        e.hasOwnProperty(i) && nt(t, i, e[i]);
  }
  function zt(t) {
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
  ]), vf = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function un(t) {
    return vf.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function $e() {
  }
  var fn = null;
  function In(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Ml = null, Zl = null;
  function cn(t) {
    var e = bl(t);
    if (e && (t = e.stateNode)) {
      var l = t[de] || null;
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
              'input[name="' + Ae(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[de] || null;
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
              a = l[e], a.form === t.form && eu(a);
          }
          break t;
        case "textarea":
          B(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && x(t, !!l.multiple, e, !1);
      }
    }
  }
  var Ea = !1;
  function lu(t, e, l) {
    if (Ea) return t(e, l);
    Ea = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (Ea = !1, (Ml !== null || Zl !== null) && (Gu(), Ml && (e = Ml, t = Zl, Zl = Ml = null, cn(e), t)))
        for (e = 0; e < t.length; e++) cn(t[e]);
    }
  }
  function Kl(t, e) {
    var l = t.stateNode;
    if (l === null) return null;
    var a = l[de] || null;
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
  var Ne = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), Aa = !1;
  if (Ne)
    try {
      var Ie = {};
      Object.defineProperty(Ie, "passive", {
        get: function() {
          Aa = !0;
        }
      }), window.addEventListener("test", Ie, Ie), window.removeEventListener("test", Ie, Ie);
    } catch {
      Aa = !1;
    }
  var Pe = null, Pn = null, _a = null;
  function ti() {
    if (_a) return _a;
    var t, e = Pn, l = e.length, a, n = "value" in Pe ? Pe.value : Pe.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return _a = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function on(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function Da() {
    return !0;
  }
  function Oa() {
    return !1;
  }
  function me(t) {
    function e(l, a, n, i, u) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = i, this.target = u, this.currentTarget = null;
      for (var c in t)
        t.hasOwnProperty(c) && (l = t[c], this[c] = l ? l(i) : i[c]);
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? Da : Oa, this.isPropagationStopped = Oa, this;
    }
    return w(e.prototype, {
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
  }, rn = me(El), Jl = w({}, El, { view: 0, detail: 0 }), bf = me(Jl), Ca, rl, kl, Ua = w({}, Jl, {
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
    getModifierState: Sf,
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
  }), Ra = me(Ua), _ = w({}, Ua, { dataTransfer: 0 }), R = me(_), P = w({}, Jl, { relatedTarget: 0 }), it = me(P), Mt = w({}, El, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), Et = me(Mt), Kt = w({}, El, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), ze = me(Kt), Ba = w({}, El, { data: 0 }), _e = me(Ba), au = {
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
  }, xf = {
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
  }, gm = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function pm(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = gm[t]) ? !!e[t] : !1;
  }
  function Sf() {
    return pm;
  }
  var ym = w({}, Jl, {
    key: function(t) {
      if (t.key) {
        var e = au[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = on(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? xf[t.keyCode] || "Unidentified" : "";
    },
    code: 0,
    location: 0,
    ctrlKey: 0,
    shiftKey: 0,
    altKey: 0,
    metaKey: 0,
    repeat: 0,
    locale: 0,
    getModifierState: Sf,
    charCode: function(t) {
      return t.type === "keypress" ? on(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? on(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), vm = me(ym), bm = w({}, Ua, {
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
  }), Eo = me(bm), xm = w({}, Jl, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: Sf
  }), Sm = me(xm), Tm = w({}, El, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), zm = me(Tm), Mm = w({}, Ua, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), Em = me(Mm), Am = w({}, El, {
    newState: 0,
    oldState: 0
  }), _m = me(Am), Dm = [9, 13, 27, 32], Tf = Ne && "CompositionEvent" in window, ei = null;
  Ne && "documentMode" in document && (ei = document.documentMode);
  var Om = Ne && "TextEvent" in window && !ei, Ao = Ne && (!Tf || ei && 8 < ei && 11 >= ei), _o = " ", Do = !1;
  function Oo(t, e) {
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
  function Co(t) {
    return t = t.detail, typeof t == "object" && "data" in t ? t.data : null;
  }
  var sn = !1;
  function Cm(t, e) {
    switch (t) {
      case "compositionend":
        return Co(e);
      case "keypress":
        return e.which !== 32 ? null : (Do = !0, _o);
      case "textInput":
        return t = e.data, t === _o && Do ? null : t;
      default:
        return null;
    }
  }
  function Um(t, e) {
    if (sn)
      return t === "compositionend" || !Tf && Oo(t, e) ? (t = ti(), _a = Pn = Pe = null, sn = !1, t) : null;
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
        return Ao && e.locale !== "ko" ? null : e.data;
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
  function Uo(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e === "input" ? !!Rm[t.type] : e === "textarea";
  }
  function Ro(t, e, l, a) {
    Ml ? Zl ? Zl.push(a) : Zl = [a] : Ml = a, e = Ku(e, "onChange"), 0 < e.length && (l = new rn(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var li = null, ai = null;
  function Bm(t) {
    hd(t, 0);
  }
  function nu(t) {
    var e = ol(t);
    if (eu(e)) return t;
  }
  function Bo(t, e) {
    if (t === "change") return e;
  }
  var No = !1;
  if (Ne) {
    var zf;
    if (Ne) {
      var Mf = "oninput" in document;
      if (!Mf) {
        var wo = document.createElement("div");
        wo.setAttribute("oninput", "return;"), Mf = typeof wo.oninput == "function";
      }
      zf = Mf;
    } else zf = !1;
    No = zf && (!document.documentMode || 9 < document.documentMode);
  }
  function Ho() {
    li && (li.detachEvent("onpropertychange", jo), ai = li = null);
  }
  function jo(t) {
    if (t.propertyName === "value" && nu(ai)) {
      var e = [];
      Ro(
        e,
        ai,
        t,
        In(t)
      ), lu(Bm, e);
    }
  }
  function Nm(t, e, l) {
    t === "focusin" ? (Ho(), li = e, ai = l, li.attachEvent("onpropertychange", jo)) : t === "focusout" && Ho();
  }
  function wm(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return nu(ai);
  }
  function Hm(t, e) {
    if (t === "click") return nu(e);
  }
  function jm(t, e) {
    if (t === "input" || t === "change")
      return nu(e);
  }
  function qm(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var we = typeof Object.is == "function" ? Object.is : qm;
  function ni(t, e) {
    if (we(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!Xn.call(e, n) || !we(t[n], e[n]))
        return !1;
    }
    return !0;
  }
  function qo(t) {
    for (; t && t.firstChild; ) t = t.firstChild;
    return t;
  }
  function Go(t, e) {
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
  function Yo(t, e) {
    return t && e ? t === e ? !0 : t && t.nodeType === 3 ? !1 : e && e.nodeType === 3 ? Yo(t, e.parentNode) : "contains" in t ? t.contains(e) : t.compareDocumentPosition ? !!(t.compareDocumentPosition(e) & 16) : !1 : !1;
  }
  function Lo(t) {
    t = t != null && t.ownerDocument != null && t.ownerDocument.defaultView != null ? t.ownerDocument.defaultView : window;
    for (var e = ve(t.document); e instanceof t.HTMLIFrameElement; ) {
      try {
        var l = typeof e.contentWindow.location.href == "string";
      } catch {
        l = !1;
      }
      if (l) t = e.contentWindow;
      else break;
      e = ve(t.document);
    }
    return e;
  }
  function Ef(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var Gm = Ne && "documentMode" in document && 11 >= document.documentMode, dn = null, Af = null, ii = null, _f = !1;
  function Xo(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    _f || dn == null || dn !== ve(a) || (a = dn, "selectionStart" in a && Ef(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), ii && ni(ii, a) || (ii = a, a = Ku(Af, "onSelect"), 0 < a.length && (e = new rn(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = dn)));
  }
  function Na(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var mn = {
    animationend: Na("Animation", "AnimationEnd"),
    animationiteration: Na("Animation", "AnimationIteration"),
    animationstart: Na("Animation", "AnimationStart"),
    transitionrun: Na("Transition", "TransitionRun"),
    transitionstart: Na("Transition", "TransitionStart"),
    transitioncancel: Na("Transition", "TransitionCancel"),
    transitionend: Na("Transition", "TransitionEnd")
  }, Df = {}, Qo = {};
  Ne && (Qo = document.createElement("div").style, "AnimationEvent" in window || (delete mn.animationend.animation, delete mn.animationiteration.animation, delete mn.animationstart.animation), "TransitionEvent" in window || delete mn.transitionend.transition);
  function wa(t) {
    if (Df[t]) return Df[t];
    if (!mn[t]) return t;
    var e = mn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Qo)
        return Df[t] = e[l];
    return t;
  }
  var Vo = wa("animationend"), Zo = wa("animationiteration"), Ko = wa("animationstart"), Ym = wa("transitionrun"), Lm = wa("transitionstart"), Xm = wa("transitioncancel"), Jo = wa("transitionend"), ko = /* @__PURE__ */ new Map(), Of = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Of.push("scrollEnd");
  function tl(t, e) {
    ko.set(t, e), Sl(e, [t]);
  }
  var iu = typeof reportError == "function" ? reportError : function(t) {
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
  }, Qe = [], hn = 0, Cf = 0;
  function uu() {
    for (var t = hn, e = Cf = hn = 0; e < t; ) {
      var l = Qe[e];
      Qe[e++] = null;
      var a = Qe[e];
      Qe[e++] = null;
      var n = Qe[e];
      Qe[e++] = null;
      var i = Qe[e];
      if (Qe[e++] = null, a !== null && n !== null) {
        var u = a.pending;
        u === null ? n.next = n : (n.next = u.next, u.next = n), a.pending = n;
      }
      i !== 0 && Fo(l, n, i);
    }
  }
  function fu(t, e, l, a) {
    Qe[hn++] = t, Qe[hn++] = e, Qe[hn++] = l, Qe[hn++] = a, Cf |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Uf(t, e, l, a) {
    return fu(t, e, l, a), cu(t);
  }
  function Ha(t, e) {
    return fu(t, null, null, e), cu(t);
  }
  function Fo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, i = t.return; i !== null; )
      i.childLanes |= l, a = i.alternate, a !== null && (a.childLanes |= l), i.tag === 22 && (t = i.stateNode, t === null || t._visibility & 1 || (n = !0)), t = i, i = i.return;
    return t.tag === 3 ? (i = t.stateNode, n && e !== null && (n = 31 - ue(l), t = i.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), i) : null;
  }
  function cu(t) {
    if (50 < _i)
      throw _i = 0, Yc = null, Error(s(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var gn = {};
  function Qm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function He(t, e, l, a) {
    return new Qm(t, e, l, a);
  }
  function Rf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function Al(t, e) {
    var l = t.alternate;
    return l === null ? (l = He(
      t.tag,
      e,
      t.key,
      t.mode
    ), l.elementType = t.elementType, l.type = t.type, l.stateNode = t.stateNode, l.alternate = t, t.alternate = l) : (l.pendingProps = e, l.type = t.type, l.flags = 0, l.subtreeFlags = 0, l.deletions = null), l.flags = t.flags & 65011712, l.childLanes = t.childLanes, l.lanes = t.lanes, l.child = t.child, l.memoizedProps = t.memoizedProps, l.memoizedState = t.memoizedState, l.updateQueue = t.updateQueue, e = t.dependencies, l.dependencies = e === null ? null : { lanes: e.lanes, firstContext: e.firstContext }, l.sibling = t.sibling, l.index = t.index, l.ref = t.ref, l.refCleanup = t.refCleanup, l;
  }
  function Wo(t, e) {
    t.flags &= 65011714;
    var l = t.alternate;
    return l === null ? (t.childLanes = 0, t.lanes = e, t.child = null, t.subtreeFlags = 0, t.memoizedProps = null, t.memoizedState = null, t.updateQueue = null, t.dependencies = null, t.stateNode = null) : (t.childLanes = l.childLanes, t.lanes = l.lanes, t.child = l.child, t.subtreeFlags = 0, t.deletions = null, t.memoizedProps = l.memoizedProps, t.memoizedState = l.memoizedState, t.updateQueue = l.updateQueue, t.type = l.type, e = l.dependencies, t.dependencies = e === null ? null : {
      lanes: e.lanes,
      firstContext: e.firstContext
    }), t;
  }
  function ou(t, e, l, a, n, i) {
    var u = 0;
    if (a = t, typeof t == "function") Rf(t) && (u = 1);
    else if (typeof t == "string")
      u = kh(
        t,
        l,
        q.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case Pt:
          return t = He(31, l, e, n), t.elementType = Pt, t.lanes = i, t;
        case yt:
          return ja(l.children, n, i, e);
        case Gt:
          u = 8, n |= 24;
          break;
        case ft:
          return t = He(12, l, e, n | 2), t.elementType = ft, t.lanes = i, t;
        case Ct:
          return t = He(13, l, e, n), t.elementType = Ct, t.lanes = i, t;
        case ht:
          return t = He(19, l, e, n), t.elementType = ht, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case mt:
                u = 10;
                break t;
              case Yt:
                u = 9;
                break t;
              case Dt:
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
    return e = He(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function ja(t, e, l, a) {
    return t = He(7, t, a, e), t.lanes = l, t;
  }
  function Bf(t, e, l) {
    return t = He(6, t, null, e), t.lanes = l, t;
  }
  function $o(t) {
    var e = He(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function Nf(t, e, l) {
    return e = He(
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
  var Io = /* @__PURE__ */ new WeakMap();
  function Ve(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = Io.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Yi(e)
      }, Io.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Yi(e)
    };
  }
  var pn = [], yn = 0, ru = null, ui = 0, Ze = [], Ke = 0, Fl = null, sl = 1, dl = "";
  function _l(t, e) {
    pn[yn++] = ui, pn[yn++] = ru, ru = t, ui = e;
  }
  function Po(t, e, l) {
    Ze[Ke++] = sl, Ze[Ke++] = dl, Ze[Ke++] = Fl, Fl = t;
    var a = sl;
    t = dl;
    var n = 32 - ue(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - ue(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, sl = 1 << 32 - ue(e) + n | l << n | a, dl = i + t;
    } else
      sl = 1 << i | l << n | a, dl = t;
  }
  function wf(t) {
    t.return !== null && (_l(t, 1), Po(t, 1, 0));
  }
  function Hf(t) {
    for (; t === ru; )
      ru = pn[--yn], pn[yn] = null, ui = pn[--yn], pn[yn] = null;
    for (; t === Fl; )
      Fl = Ze[--Ke], Ze[Ke] = null, dl = Ze[--Ke], Ze[Ke] = null, sl = Ze[--Ke], Ze[Ke] = null;
  }
  function tr(t, e) {
    Ze[Ke++] = sl, Ze[Ke++] = dl, Ze[Ke++] = Fl, sl = e.id, dl = e.overflow, Fl = t;
  }
  var he = null, Lt = null, St = !1, Wl = null, Je = !1, jf = Error(s(519));
  function $l(t) {
    var e = Error(
      s(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw fi(Ve(e, t)), jf;
  }
  function er(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[te] = t, e[de] = a, l) {
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
        for (l = 0; l < Oi.length; l++)
          pt(Oi[l], e);
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
        pt("invalid", e), o(
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
        pt("invalid", e), H(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || vd(e.textContent, l) ? (a.popover != null && (pt("beforetoggle", e), pt("toggle", e)), a.onScroll != null && pt("scroll", e), a.onScrollEnd != null && pt("scrollend", e), a.onClick != null && (e.onclick = $e), e = !0) : e = !1, e || $l(t, !0);
  }
  function lr(t) {
    for (he = t.return; he; )
      switch (he.tag) {
        case 5:
        case 31:
        case 13:
          Je = !1;
          return;
        case 27:
        case 3:
          Je = !0;
          return;
        default:
          he = he.return;
      }
  }
  function vn(t) {
    if (t !== he) return !1;
    if (!St) return lr(t), St = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || eo(t.type, t.memoizedProps)), l = !l), l && Lt && $l(t), lr(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = _d(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = _d(t);
    } else
      e === 27 ? (e = Lt, sa(t.type) ? (t = uo, uo = null, Lt = t) : Lt = e) : Lt = he ? Fe(t.stateNode.nextSibling) : null;
    return !0;
  }
  function qa() {
    Lt = he = null, St = !1;
  }
  function qf() {
    var t = Wl;
    return t !== null && (Ue === null ? Ue = t : Ue.push.apply(
      Ue,
      t
    ), Wl = null), t;
  }
  function fi(t) {
    Wl === null ? Wl = [t] : Wl.push(t);
  }
  var Gf = m(null), Ga = null, Dl = null;
  function Il(t, e, l) {
    N(Gf, e._currentValue), e._currentValue = l;
  }
  function Ol(t) {
    t._currentValue = Gf.current, A(Gf);
  }
  function Yf(t, e, l) {
    for (; t !== null; ) {
      var a = t.alternate;
      if ((t.childLanes & e) !== e ? (t.childLanes |= e, a !== null && (a.childLanes |= e)) : a !== null && (a.childLanes & e) !== e && (a.childLanes |= e), t === l) break;
      t = t.return;
    }
  }
  function Lf(t, e, l, a) {
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
              i.lanes |= l, c = i.alternate, c !== null && (c.lanes |= l), Yf(
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
        u.lanes |= l, i = u.alternate, i !== null && (i.lanes |= l), Yf(u, l, t), u = null;
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
  function bn(t, e, l, a) {
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
          we(n.pendingProps.value, u.value) || (t !== null ? t.push(c) : t = [c]);
        }
      } else if (n === Tt.current) {
        if (u = n.alternate, u === null) throw Error(s(387));
        u.memoizedState.memoizedState !== n.memoizedState.memoizedState && (t !== null ? t.push(Ni) : t = [Ni]);
      }
      n = n.return;
    }
    t !== null && Lf(
      e,
      t,
      l,
      a
    ), e.flags |= 262144;
  }
  function su(t) {
    for (t = t.firstContext; t !== null; ) {
      if (!we(
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
  function ge(t) {
    return ar(Ga, t);
  }
  function du(t, e) {
    return Ga === null && Ya(t), ar(t, e);
  }
  function ar(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Dl === null) {
      if (t === null) throw Error(s(308));
      Dl = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else Dl = Dl.next = e;
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
  function Xf() {
    return {
      controller: new Vm(),
      data: /* @__PURE__ */ new Map(),
      refCount: 0
    };
  }
  function ci(t) {
    t.refCount--, t.refCount === 0 && Zm(Km, function() {
      t.controller.abort();
    });
  }
  var oi = null, Qf = 0, xn = 0, Sn = null;
  function Jm(t, e) {
    if (oi === null) {
      var l = oi = [];
      Qf = 0, xn = Kc(), Sn = {
        status: "pending",
        value: void 0,
        then: function(a) {
          l.push(a);
        }
      };
    }
    return Qf++, e.then(nr, nr), e;
  }
  function nr() {
    if (--Qf === 0 && oi !== null) {
      Sn !== null && (Sn.status = "fulfilled");
      var t = oi;
      oi = null, xn = 0, Sn = null;
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
  var ir = g.S;
  g.S = function(t, e) {
    Xs = se(), typeof e == "object" && e !== null && typeof e.then == "function" && Jm(t, e), ir !== null && ir(t, e);
  };
  var La = m(null);
  function Vf() {
    var t = La.current;
    return t !== null ? t : qt.pooledCache;
  }
  function mu(t, e) {
    e === null ? N(La, La.current) : N(La, e.pool);
  }
  function ur() {
    var t = Vf();
    return t === null ? null : { parent: ee._currentValue, pool: t };
  }
  var Tn = Error(s(460)), Zf = Error(s(474)), hu = Error(s(542)), gu = { then: function() {
  } };
  function fr(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function cr(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then($e, $e), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, rr(t), t;
      default:
        if (typeof e.status == "string") e.then($e, $e);
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
            throw t = e.reason, rr(t), t;
        }
        throw Qa = e, Tn;
    }
  }
  function Xa(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (Qa = l, Tn) : l;
    }
  }
  var Qa = null;
  function or() {
    if (Qa === null) throw Error(s(459));
    var t = Qa;
    return Qa = null, t;
  }
  function rr(t) {
    if (t === Tn || t === hu)
      throw Error(s(483));
  }
  var zn = null, ri = 0;
  function pu(t) {
    var e = ri;
    return ri += 1, zn === null && (zn = []), cr(zn, t, e);
  }
  function si(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function yu(t, e) {
    throw e.$$typeof === tt ? Error(s(525)) : (t = Object.prototype.toString.call(e), Error(
      s(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function sr(t) {
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
      return p = Al(p, h), p.index = 0, p.sibling = null, p;
    }
    function i(p, h, y) {
      return p.index = y, t ? (y = p.alternate, y !== null ? (y = y.index, y < h ? (p.flags |= 67108866, h) : y) : (p.flags |= 67108866, h)) : (p.flags |= 1048576, h);
    }
    function u(p) {
      return t && p.alternate === null && (p.flags |= 67108866), p;
    }
    function c(p, h, y, E) {
      return h === null || h.tag !== 6 ? (h = Bf(y, p.mode, E), h.return = p, h) : (h = n(h, y), h.return = p, h);
    }
    function r(p, h, y, E) {
      var F = y.type;
      return F === yt ? M(
        p,
        h,
        y.props.children,
        E,
        y.key
      ) : h !== null && (h.elementType === F || typeof F == "object" && F !== null && F.$$typeof === Ut && Xa(F) === h.type) ? (h = n(h, y.props), si(h, y), h.return = p, h) : (h = ou(
        y.type,
        y.key,
        y.props,
        null,
        p.mode,
        E
      ), si(h, y), h.return = p, h);
    }
    function v(p, h, y, E) {
      return h === null || h.tag !== 4 || h.stateNode.containerInfo !== y.containerInfo || h.stateNode.implementation !== y.implementation ? (h = Nf(y, p.mode, E), h.return = p, h) : (h = n(h, y.children || []), h.return = p, h);
    }
    function M(p, h, y, E, F) {
      return h === null || h.tag !== 7 ? (h = ja(
        y,
        p.mode,
        E,
        F
      ), h.return = p, h) : (h = n(h, y), h.return = p, h);
    }
    function O(p, h, y) {
      if (typeof h == "string" && h !== "" || typeof h == "number" || typeof h == "bigint")
        return h = Bf(
          "" + h,
          p.mode,
          y
        ), h.return = p, h;
      if (typeof h == "object" && h !== null) {
        switch (h.$$typeof) {
          case rt:
            return y = ou(
              h.type,
              h.key,
              h.props,
              null,
              p.mode,
              y
            ), si(y, h), y.return = p, y;
          case dt:
            return h = Nf(
              h,
              p.mode,
              y
            ), h.return = p, h;
          case Ut:
            return h = Xa(h), O(p, h, y);
        }
        if (X(h) || Zt(h))
          return h = ja(
            h,
            p.mode,
            y,
            null
          ), h.return = p, h;
        if (typeof h.then == "function")
          return O(p, pu(h), y);
        if (h.$$typeof === mt)
          return O(
            p,
            du(p, h),
            y
          );
        yu(p, h);
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
            return y = Xa(y), b(p, h, y, E);
        }
        if (X(y) || Zt(y))
          return F !== null ? null : M(p, h, y, E, null);
        if (typeof y.then == "function")
          return b(
            p,
            h,
            pu(y),
            E
          );
        if (y.$$typeof === mt)
          return b(
            p,
            h,
            du(p, y),
            E
          );
        yu(p, y);
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
            return E = Xa(E), T(
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
            pu(E),
            F
          );
        if (E.$$typeof === mt)
          return T(
            p,
            h,
            y,
            du(h, E),
            F
          );
        yu(h, E);
      }
      return null;
    }
    function Y(p, h, y, E) {
      for (var F = null, At = null, V = h, st = h = 0, bt = null; V !== null && st < y.length; st++) {
        V.index > st ? (bt = V, V = null) : bt = V.sibling;
        var _t = b(
          p,
          V,
          y[st],
          E
        );
        if (_t === null) {
          V === null && (V = bt);
          break;
        }
        t && V && _t.alternate === null && e(p, V), h = i(_t, h, st), At === null ? F = _t : At.sibling = _t, At = _t, V = bt;
      }
      if (st === y.length)
        return l(p, V), St && _l(p, st), F;
      if (V === null) {
        for (; st < y.length; st++)
          V = O(p, y[st], E), V !== null && (h = i(
            V,
            h,
            st
          ), At === null ? F = V : At.sibling = V, At = V);
        return St && _l(p, st), F;
      }
      for (V = a(V); st < y.length; st++)
        bt = T(
          V,
          p,
          st,
          y[st],
          E
        ), bt !== null && (t && bt.alternate !== null && V.delete(
          bt.key === null ? st : bt.key
        ), h = i(
          bt,
          h,
          st
        ), At === null ? F = bt : At.sibling = bt, At = bt);
      return t && V.forEach(function(pa) {
        return e(p, pa);
      }), St && _l(p, st), F;
    }
    function I(p, h, y, E) {
      if (y == null) throw Error(s(151));
      for (var F = null, At = null, V = h, st = h = 0, bt = null, _t = y.next(); V !== null && !_t.done; st++, _t = y.next()) {
        V.index > st ? (bt = V, V = null) : bt = V.sibling;
        var pa = b(p, V, _t.value, E);
        if (pa === null) {
          V === null && (V = bt);
          break;
        }
        t && V && pa.alternate === null && e(p, V), h = i(pa, h, st), At === null ? F = pa : At.sibling = pa, At = pa, V = bt;
      }
      if (_t.done)
        return l(p, V), St && _l(p, st), F;
      if (V === null) {
        for (; !_t.done; st++, _t = y.next())
          _t = O(p, _t.value, E), _t !== null && (h = i(_t, h, st), At === null ? F = _t : At.sibling = _t, At = _t);
        return St && _l(p, st), F;
      }
      for (V = a(V); !_t.done; st++, _t = y.next())
        _t = T(V, p, st, _t.value, E), _t !== null && (t && _t.alternate !== null && V.delete(_t.key === null ? st : _t.key), h = i(_t, h, st), At === null ? F = _t : At.sibling = _t, At = _t);
      return t && V.forEach(function(ig) {
        return e(p, ig);
      }), St && _l(p, st), F;
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
                  } else if (h.elementType === F || typeof F == "object" && F !== null && F.$$typeof === Ut && Xa(F) === h.type) {
                    l(
                      p,
                      h.sibling
                    ), E = n(h, y.props), si(E, y), E.return = p, p = E;
                    break t;
                  }
                  l(p, h);
                  break;
                } else e(p, h);
                h = h.sibling;
              }
              y.type === yt ? (E = ja(
                y.props.children,
                p.mode,
                E,
                y.key
              ), E.return = p, p = E) : (E = ou(
                y.type,
                y.key,
                y.props,
                null,
                p.mode,
                E
              ), si(E, y), E.return = p, p = E);
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
              E = Nf(y, p.mode, E), E.return = p, p = E;
            }
            return u(p);
          case Ut:
            return y = Xa(y), jt(
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
            pu(y),
            E
          );
        if (y.$$typeof === mt)
          return jt(
            p,
            h,
            du(p, y),
            E
          );
        yu(p, y);
      }
      return typeof y == "string" && y !== "" || typeof y == "number" || typeof y == "bigint" ? (y = "" + y, h !== null && h.tag === 6 ? (l(p, h.sibling), E = n(h, y), E.return = p, p = E) : (l(p, h), E = Bf(y, p.mode, E), E.return = p, p = E), u(p)) : l(p, h);
    }
    return function(p, h, y, E) {
      try {
        ri = 0;
        var F = jt(
          p,
          h,
          y,
          E
        );
        return zn = null, F;
      } catch (V) {
        if (V === Tn || V === hu) throw V;
        var At = He(29, V, null, p.mode);
        return At.lanes = E, At.return = p, At;
      }
    };
  }
  var Va = sr(!0), dr = sr(!1), Pl = !1;
  function Kf(t) {
    t.updateQueue = {
      baseState: t.memoizedState,
      firstBaseUpdate: null,
      lastBaseUpdate: null,
      shared: { pending: null, lanes: 0, hiddenCallbacks: null },
      callbacks: null
    };
  }
  function Jf(t, e) {
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
    if (a = a.shared, (Ot & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = cu(t), Fo(t, null, l), e;
    }
    return fu(t, a, e, l), cu(t);
  }
  function di(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Se(t, l);
    }
  }
  function kf(t, e) {
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
  var Ff = !1;
  function mi() {
    if (Ff) {
      var t = Sn;
      if (t !== null) throw t;
    }
  }
  function hi(t, e, l, a) {
    Ff = !1;
    var n = t.updateQueue;
    Pl = !1;
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
        if (T ? (vt & b) === b : (a & b) === b) {
          b !== 0 && b === xn && (Ff = !0), M !== null && (M = M.next = {
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
                Pl = !0;
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
      M === null && (r = O), n.baseState = r, n.firstBaseUpdate = v, n.lastBaseUpdate = M, i === null && (n.shared.lanes = 0), ua |= u, t.lanes = u, t.memoizedState = O;
    }
  }
  function mr(t, e) {
    if (typeof t != "function")
      throw Error(s(191, t));
    t.call(e);
  }
  function hr(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        mr(l[t], e);
  }
  var Mn = m(null), vu = m(0);
  function gr(t, e) {
    t = ql, N(vu, t), N(Mn, e), ql = t | e.baseLanes;
  }
  function Wf() {
    N(vu, ql), N(Mn, Mn.current);
  }
  function $f() {
    ql = vu.current, A(Mn), A(vu);
  }
  var je = m(null), ke = null;
  function la(t) {
    var e = t.alternate;
    N($t, $t.current & 1), N(je, t), ke === null && (e === null || Mn.current !== null || e.memoizedState !== null) && (ke = t);
  }
  function If(t) {
    N($t, $t.current), N(je, t), ke === null && (ke = t);
  }
  function pr(t) {
    t.tag === 22 ? (N($t, $t.current), N(je, t), ke === null && (ke = t)) : aa();
  }
  function aa() {
    N($t, $t.current), N(je, je.current);
  }
  function qe(t) {
    A(je), ke === t && (ke = null), A($t);
  }
  var $t = m(0);
  function bu(t) {
    for (var e = t; e !== null; ) {
      if (e.tag === 13) {
        var l = e.memoizedState;
        if (l !== null && (l = l.dehydrated, l === null || no(l) || io(l)))
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
  var Cl = 0, ot = null, wt = null, le = null, xu = !1, En = !1, Za = !1, Su = 0, gi = 0, An = null, Fm = 0;
  function Jt() {
    throw Error(s(321));
  }
  function Pf(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!we(t[l], e[l])) return !1;
    return !0;
  }
  function tc(t, e, l, a, n, i) {
    return Cl = i, ot = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, g.H = t === null || t.memoizedState === null ? Pr : gc, Za = !1, i = l(a, n), Za = !1, En && (i = vr(
      e,
      l,
      a,
      n
    )), yr(t), i;
  }
  function yr(t) {
    g.H = vi;
    var e = wt !== null && wt.next !== null;
    if (Cl = 0, le = wt = ot = null, xu = !1, gi = 0, An = null, e) throw Error(s(300));
    t === null || ae || (t = t.dependencies, t !== null && su(t) && (ae = !0));
  }
  function vr(t, e, l, a) {
    ot = t;
    var n = 0;
    do {
      if (En && (An = null), gi = 0, En = !1, 25 <= n) throw Error(s(301));
      if (n += 1, le = wt = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      g.H = ts, i = e(l, a);
    } while (En);
    return i;
  }
  function Wm() {
    var t = g.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? pi(e) : e, t = t.useState()[0], (wt !== null ? wt.memoizedState : null) !== t && (ot.flags |= 1024), e;
  }
  function ec() {
    var t = Su !== 0;
    return Su = 0, t;
  }
  function lc(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function ac(t) {
    if (xu) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      xu = !1;
    }
    Cl = 0, le = wt = ot = null, En = !1, gi = Su = 0, An = null;
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
  function Tu() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function pi(t) {
    var e = gi;
    return gi += 1, An === null && (An = []), t = cr(An, t, e), e = ot, (le === null ? e.memoizedState : le.next) === null && (e = e.alternate, g.H = e === null || e.memoizedState === null ? Pr : gc), t;
  }
  function zu(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return pi(t);
      if (t.$$typeof === mt) return ge(t);
    }
    throw Error(s(438, String(t)));
  }
  function nc(t) {
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
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Tu(), ot.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = Ft;
    return e.index++, l;
  }
  function Ul(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function Mu(t) {
    var e = It();
    return ic(e, wt, t);
  }
  function ic(t, e, l) {
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
        if (O !== v.lane ? (vt & O) === O : (Cl & O) === O) {
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
            }), O === xn && (M = !0);
          else if ((Cl & b) === b) {
            v = v.next, b === xn && (M = !0);
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
            }, r === null ? (c = r = O, u = i) : r = r.next = O, ot.lanes |= b, ua |= b;
          O = v.action, Za && l(i, O), i = v.hasEagerState ? v.eagerState : l(i, O);
        } else
          b = {
            lane: O,
            revertLane: v.revertLane,
            gesture: v.gesture,
            action: v.action,
            hasEagerState: v.hasEagerState,
            eagerState: v.eagerState,
            next: null
          }, r === null ? (c = r = b, u = i) : r = r.next = b, ot.lanes |= O, ua |= O;
        v = v.next;
      } while (v !== null && v !== e);
      if (r === null ? u = i : r.next = c, !we(i, t.memoizedState) && (ae = !0, M && (l = Sn, l !== null)))
        throw l;
      t.memoizedState = i, t.baseState = u, t.baseQueue = r, a.lastRenderedState = i;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function uc(t) {
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
      we(i, e.memoizedState) || (ae = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function br(t, e, l) {
    var a = ot, n = It(), i = St;
    if (i) {
      if (l === void 0) throw Error(s(407));
      l = l();
    } else l = e();
    var u = !we(
      (wt || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, ae = !0), n = n.queue, oc(Tr.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || le !== null && le.memoizedState.tag & 1) {
      if (a.flags |= 2048, _n(
        9,
        { destroy: void 0 },
        Sr.bind(
          null,
          a,
          n,
          l,
          e
        ),
        null
      ), qt === null) throw Error(s(349));
      i || (Cl & 127) !== 0 || xr(a, e, l);
    }
    return l;
  }
  function xr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = ot.updateQueue, e === null ? (e = Tu(), ot.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
  }
  function Sr(t, e, l, a) {
    e.value = l, e.getSnapshot = a, zr(e) && Mr(t);
  }
  function Tr(t, e, l) {
    return l(function() {
      zr(e) && Mr(t);
    });
  }
  function zr(t) {
    var e = t.getSnapshot;
    t = t.value;
    try {
      var l = e();
      return !we(t, l);
    } catch {
      return !0;
    }
  }
  function Mr(t) {
    var e = Ha(t, 2);
    e !== null && Re(e, t, 2);
  }
  function fc(t) {
    var e = Me();
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
  function Er(t, e, l, a) {
    return t.baseState = l, ic(
      t,
      wt,
      typeof a == "function" ? a : Ul
    );
  }
  function $m(t, e, l, a, n) {
    if (_u(t)) throw Error(s(485));
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
      g.T !== null ? l(!0) : i.isTransition = !1, a(i), l = e.pending, l === null ? (i.next = e.pending = i, Ar(e, i)) : (i.next = l.next, e.pending = l.next = i);
    }
  }
  function Ar(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var i = g.T, u = {};
      g.T = u;
      try {
        var c = l(n, a), r = g.S;
        r !== null && r(u, c), _r(t, e, c);
      } catch (v) {
        cc(t, e, v);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), g.T = i;
      }
    } else
      try {
        i = l(n, a), _r(t, e, i);
      } catch (v) {
        cc(t, e, v);
      }
  }
  function _r(t, e, l) {
    l !== null && typeof l == "object" && typeof l.then == "function" ? l.then(
      function(a) {
        Dr(t, e, a);
      },
      function(a) {
        return cc(t, e, a);
      }
    ) : Dr(t, e, l);
  }
  function Dr(t, e, l) {
    e.status = "fulfilled", e.value = l, Or(e), t.state = l, e = t.pending, e !== null && (l = e.next, l === e ? t.pending = null : (l = l.next, e.next = l, Ar(t, l)));
  }
  function cc(t, e, l) {
    var a = t.pending;
    if (t.pending = null, a !== null) {
      a = a.next;
      do
        e.status = "rejected", e.reason = l, Or(e), e = e.next;
      while (e !== a);
    }
    t.action = null;
  }
  function Or(t) {
    t = t.listeners;
    for (var e = 0; e < t.length; e++) (0, t[e])();
  }
  function Cr(t, e) {
    return e;
  }
  function Ur(t, e) {
    if (St) {
      var l = qt.formState;
      if (l !== null) {
        t: {
          var a = ot;
          if (St) {
            if (Lt) {
              e: {
                for (var n = Lt, i = Je; n.nodeType !== 8; ) {
                  if (!i) {
                    n = null;
                    break e;
                  }
                  if (n = Fe(
                    n.nextSibling
                  ), n === null) {
                    n = null;
                    break e;
                  }
                }
                i = n.data, n = i === "F!" || i === "F" ? n : null;
              }
              if (n) {
                Lt = Fe(
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
    return l = Me(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Cr,
      lastRenderedState: e
    }, l.queue = a, l = Wr.bind(
      null,
      ot,
      a
    ), a.dispatch = l, a = fc(!1), i = hc.bind(
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
  function Rr(t) {
    var e = It();
    return Br(e, wt, t);
  }
  function Br(t, e, l) {
    if (e = ic(
      t,
      e,
      Cr
    )[0], t = Mu(Ul)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = pi(e);
      } catch (u) {
        throw u === Tn ? hu : u;
      }
    else a = e;
    e = It();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (ot.flags |= 2048, _n(
      9,
      { destroy: void 0 },
      Im.bind(null, n, l),
      null
    )), [a, i, t];
  }
  function Im(t, e) {
    t.action = e;
  }
  function Nr(t) {
    var e = It(), l = wt;
    if (l !== null)
      return Br(e, l, t);
    It(), e = e.memoizedState, l = It();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function _n(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = ot.updateQueue, e === null && (e = Tu(), ot.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function wr() {
    return It().memoizedState;
  }
  function Eu(t, e, l, a) {
    var n = Me();
    ot.flags |= t, n.memoizedState = _n(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Au(t, e, l, a) {
    var n = It();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    wt !== null && a !== null && Pf(a, wt.memoizedState.deps) ? n.memoizedState = _n(e, i, l, a) : (ot.flags |= t, n.memoizedState = _n(
      1 | e,
      i,
      l,
      a
    ));
  }
  function Hr(t, e) {
    Eu(8390656, 8, t, e);
  }
  function oc(t, e) {
    Au(2048, 8, t, e);
  }
  function Pm(t) {
    ot.flags |= 4;
    var e = ot.updateQueue;
    if (e === null)
      e = Tu(), ot.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function jr(t) {
    var e = It().memoizedState;
    return Pm({ ref: e, nextImpl: t }), function() {
      if ((Ot & 2) !== 0) throw Error(s(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function qr(t, e) {
    return Au(4, 2, t, e);
  }
  function Gr(t, e) {
    return Au(4, 4, t, e);
  }
  function Yr(t, e) {
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
  function Lr(t, e, l) {
    l = l != null ? l.concat([t]) : null, Au(4, 4, Yr.bind(null, e, t), l);
  }
  function rc() {
  }
  function Xr(t, e) {
    var l = It();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && Pf(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Qr(t, e) {
    var l = It();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && Pf(e, a[1]))
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
  function sc(t, e, l) {
    return l === void 0 || (Cl & 1073741824) !== 0 && (vt & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Vs(), ot.lanes |= t, ua |= t, l);
  }
  function Vr(t, e, l, a) {
    return we(l, e) ? l : Mn.current !== null ? (t = sc(t, l, a), we(t, e) || (ae = !0), t) : (Cl & 42) === 0 || (Cl & 1073741824) !== 0 && (vt & 261930) === 0 ? (ae = !0, t.memoizedState = l) : (t = Vs(), ot.lanes |= t, ua |= t, e);
  }
  function Zr(t, e, l, a, n) {
    var i = U.p;
    U.p = i !== 0 && 8 > i ? i : 8;
    var u = g.T, c = {};
    g.T = c, hc(t, !1, e, l);
    try {
      var r = n(), v = g.S;
      if (v !== null && v(c, r), r !== null && typeof r == "object" && typeof r.then == "function") {
        var M = km(
          r,
          a
        );
        yi(
          t,
          e,
          M,
          Le(t)
        );
      } else
        yi(
          t,
          e,
          a,
          Le(t)
        );
    } catch (O) {
      yi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: O },
        Le()
      );
    } finally {
      U.p = i, u !== null && c.types !== null && (u.types = c.types), g.T = u;
    }
  }
  function th() {
  }
  function dc(t, e, l, a) {
    if (t.tag !== 5) throw Error(s(476));
    var n = Kr(t).queue;
    Zr(
      t,
      n,
      e,
      Z,
      l === null ? th : function() {
        return Jr(t), l(a);
      }
    );
  }
  function Kr(t) {
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
        lastRenderedReducer: Ul,
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
        lastRenderedReducer: Ul,
        lastRenderedState: l
      },
      next: null
    }, t.memoizedState = e, t = t.alternate, t !== null && (t.memoizedState = e), e;
  }
  function Jr(t) {
    var e = Kr(t);
    e.next === null && (e = t.alternate.memoizedState), yi(
      t,
      e.next.queue,
      {},
      Le()
    );
  }
  function mc() {
    return ge(Ni);
  }
  function kr() {
    return It().memoizedState;
  }
  function Fr() {
    return It().memoizedState;
  }
  function eh(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = Le();
          t = ta(l);
          var a = ea(e, t, l);
          a !== null && (Re(a, e, l), di(a, e, l)), e = { cache: Xf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function lh(t, e, l) {
    var a = Le();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, _u(t) ? $r(e, l) : (l = Uf(t, e, l, a), l !== null && (Re(l, t, a), Ir(l, e, a)));
  }
  function Wr(t, e, l) {
    var a = Le();
    yi(t, e, l, a);
  }
  function yi(t, e, l, a) {
    var n = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    };
    if (_u(t)) $r(e, n);
    else {
      var i = t.alternate;
      if (t.lanes === 0 && (i === null || i.lanes === 0) && (i = e.lastRenderedReducer, i !== null))
        try {
          var u = e.lastRenderedState, c = i(u, l);
          if (n.hasEagerState = !0, n.eagerState = c, we(c, u))
            return fu(t, e, n, 0), qt === null && uu(), !1;
        } catch {
        }
      if (l = Uf(t, e, n, a), l !== null)
        return Re(l, t, a), Ir(l, e, a), !0;
    }
    return !1;
  }
  function hc(t, e, l, a) {
    if (a = {
      lane: 2,
      revertLane: Kc(),
      gesture: null,
      action: a,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, _u(t)) {
      if (e) throw Error(s(479));
    } else
      e = Uf(
        t,
        l,
        a,
        2
      ), e !== null && Re(e, t, 2);
  }
  function _u(t) {
    var e = t.alternate;
    return t === ot || e !== null && e === ot;
  }
  function $r(t, e) {
    En = xu = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function Ir(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Se(t, l);
    }
  }
  var vi = {
    readContext: ge,
    use: zu,
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
  vi.useEffectEvent = Jt;
  var Pr = {
    readContext: ge,
    use: zu,
    useCallback: function(t, e) {
      return Me().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: ge,
    useEffect: Hr,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, Eu(
        4194308,
        4,
        Yr.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return Eu(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      Eu(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = Me();
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
      var a = Me();
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
      t = fc(t);
      var e = t.queue, l = Wr.bind(null, ot, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: rc,
    useDeferredValue: function(t, e) {
      var l = Me();
      return sc(l, t, e);
    },
    useTransition: function() {
      var t = fc(!1);
      return t = Zr.bind(
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
        (vt & 127) !== 0 || xr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, Hr(Tr.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, _n(
        9,
        { destroy: void 0 },
        Sr.bind(
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
        var l = dl, a = sl;
        l = (a & ~(1 << 32 - ue(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = Su++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Fm++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: mc,
    useFormState: Ur,
    useActionState: Ur,
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
      return e.queue = l, e = hc.bind(
        null,
        ot,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: nc,
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
  }, gc = {
    readContext: ge,
    use: zu,
    useCallback: Xr,
    useContext: ge,
    useEffect: oc,
    useImperativeHandle: Lr,
    useInsertionEffect: qr,
    useLayoutEffect: Gr,
    useMemo: Qr,
    useReducer: Mu,
    useRef: wr,
    useState: function() {
      return Mu(Ul);
    },
    useDebugValue: rc,
    useDeferredValue: function(t, e) {
      var l = It();
      return Vr(
        l,
        wt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = Mu(Ul)[0], e = It().memoizedState;
      return [
        typeof t == "boolean" ? t : pi(t),
        e
      ];
    },
    useSyncExternalStore: br,
    useId: kr,
    useHostTransitionStatus: mc,
    useFormState: Rr,
    useActionState: Rr,
    useOptimistic: function(t, e) {
      var l = It();
      return Er(l, wt, t, e);
    },
    useMemoCache: nc,
    useCacheRefresh: Fr
  };
  gc.useEffectEvent = jr;
  var ts = {
    readContext: ge,
    use: zu,
    useCallback: Xr,
    useContext: ge,
    useEffect: oc,
    useImperativeHandle: Lr,
    useInsertionEffect: qr,
    useLayoutEffect: Gr,
    useMemo: Qr,
    useReducer: uc,
    useRef: wr,
    useState: function() {
      return uc(Ul);
    },
    useDebugValue: rc,
    useDeferredValue: function(t, e) {
      var l = It();
      return wt === null ? sc(l, t, e) : Vr(
        l,
        wt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = uc(Ul)[0], e = It().memoizedState;
      return [
        typeof t == "boolean" ? t : pi(t),
        e
      ];
    },
    useSyncExternalStore: br,
    useId: kr,
    useHostTransitionStatus: mc,
    useFormState: Nr,
    useActionState: Nr,
    useOptimistic: function(t, e) {
      var l = It();
      return wt !== null ? Er(l, wt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: nc,
    useCacheRefresh: Fr
  };
  ts.useEffectEvent = jr;
  function pc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : w({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var yc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = Le(), n = ta(a);
      n.payload = e, l != null && (n.callback = l), e = ea(t, n, a), e !== null && (Re(e, t, a), di(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = Le(), n = ta(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = ea(t, n, a), e !== null && (Re(e, t, a), di(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = Le(), a = ta(l);
      a.tag = 2, e != null && (a.callback = e), e = ea(t, a, l), e !== null && (Re(e, t, l), di(e, t, l));
    }
  };
  function es(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ni(l, a) || !ni(n, i) : !0;
  }
  function ls(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && yc.enqueueReplaceState(e, e.state, null);
  }
  function Ka(t, e) {
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
  function as(t) {
    iu(t);
  }
  function ns(t) {
    console.error(t);
  }
  function is(t) {
    iu(t);
  }
  function Du(t, e) {
    try {
      var l = t.onUncaughtError;
      l(e.value, { componentStack: e.stack });
    } catch (a) {
      setTimeout(function() {
        throw a;
      });
    }
  }
  function us(t, e, l) {
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
    return l = ta(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Du(t, e);
    }, l;
  }
  function fs(t) {
    return t = ta(t), t.tag = 3, t;
  }
  function cs(t, e, l, a) {
    var n = l.type.getDerivedStateFromError;
    if (typeof n == "function") {
      var i = a.value;
      t.payload = function() {
        return n(i);
      }, t.callback = function() {
        us(e, l, a);
      };
    }
    var u = l.stateNode;
    u !== null && typeof u.componentDidCatch == "function" && (t.callback = function() {
      us(e, l, a), typeof n != "function" && (fa === null ? fa = /* @__PURE__ */ new Set([this]) : fa.add(this));
      var c = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: c !== null ? c : ""
      });
    });
  }
  function ah(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && bn(
        e,
        l,
        n,
        !0
      ), l = je.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return ke === null ? Yu() : l.alternate === null && kt === 0 && (kt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === gu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Qc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === gu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Qc(t, a, n)), !1;
        }
        throw Error(s(435, l.tag));
      }
      return Qc(t, a, n), Yu(), !1;
    }
    if (St)
      return e = je.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== jf && (t = Error(s(422), { cause: a }), fi(Ve(t, l)))) : (a !== jf && (e = Error(s(423), {
        cause: a
      }), fi(
        Ve(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ve(a, l), n = vc(
        t.stateNode,
        a,
        n
      ), kf(t, n), kt !== 4 && (kt = 2)), !1;
    var i = Error(s(520), { cause: a });
    if (i = Ve(i, l), Ai === null ? Ai = [i] : Ai.push(i), kt !== 4 && (kt = 2), e === null) return !0;
    a = Ve(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = vc(l.stateNode, a, t), kf(l, t), !1;
        case 1:
          if (e = l.type, i = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || i !== null && typeof i.componentDidCatch == "function" && (fa === null || !fa.has(i))))
            return l.flags |= 65536, n &= -n, l.lanes |= n, n = fs(n), cs(
              n,
              t,
              l,
              a
            ), kf(l, n), !1;
      }
      l = l.return;
    } while (l !== null);
    return !1;
  }
  var bc = Error(s(461)), ae = !1;
  function pe(t, e, l, a) {
    e.child = t === null ? dr(e, null, l, a) : Va(
      e,
      t.child,
      l,
      a
    );
  }
  function os(t, e, l, a, n) {
    l = l.render;
    var i = e.ref;
    if ("ref" in a) {
      var u = {};
      for (var c in a)
        c !== "ref" && (u[c] = a[c]);
    } else u = a;
    return Ya(e), a = tc(
      t,
      e,
      l,
      u,
      i,
      n
    ), c = ec(), t !== null && !ae ? (lc(t, e, n), Rl(t, e, n)) : (St && c && wf(e), e.flags |= 1, pe(t, e, a, n), e.child);
  }
  function rs(t, e, l, a, n) {
    if (t === null) {
      var i = l.type;
      return typeof i == "function" && !Rf(i) && i.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = i, ss(
        t,
        e,
        i,
        a,
        n
      )) : (t = ou(
        l.type,
        null,
        a,
        e,
        e.mode,
        n
      ), t.ref = e.ref, t.return = e, e.child = t);
    }
    if (i = t.child, !_c(t, n)) {
      var u = i.memoizedProps;
      if (l = l.compare, l = l !== null ? l : ni, l(u, a) && t.ref === e.ref)
        return Rl(t, e, n);
    }
    return e.flags |= 1, t = Al(i, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function ss(t, e, l, a, n) {
    if (t !== null) {
      var i = t.memoizedProps;
      if (ni(i, a) && t.ref === e.ref)
        if (ae = !1, e.pendingProps = a = i, _c(t, n))
          (t.flags & 131072) !== 0 && (ae = !0);
        else
          return e.lanes = t.lanes, Rl(t, e, n);
    }
    return xc(
      t,
      e,
      l,
      a,
      n
    );
  }
  function ds(t, e, l, a) {
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
        return ms(
          t,
          e,
          i,
          l,
          a
        );
      }
      if ((l & 536870912) !== 0)
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && mu(
          e,
          i !== null ? i.cachePool : null
        ), i !== null ? gr(e, i) : Wf(), pr(e);
      else
        return a = e.lanes = 536870912, ms(
          t,
          e,
          i !== null ? i.baseLanes | l : l,
          l,
          a
        );
    } else
      i !== null ? (mu(e, i.cachePool), gr(e, i), aa(), e.memoizedState = null) : (t !== null && mu(e, null), Wf(), aa());
    return pe(t, e, n, l), e.child;
  }
  function bi(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function ms(t, e, l, a, n) {
    var i = Vf();
    return i = i === null ? null : { parent: ee._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && mu(e, null), Wf(), pr(e), t !== null && bn(t, e, a, !0), e.childLanes = n, null;
  }
  function Ou(t, e) {
    return e = Uu(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function hs(t, e, l) {
    return Va(e, t.child, null, l), t = Ou(e, e.pendingProps), t.flags |= 2, qe(e), e.memoizedState = null, t;
  }
  function nh(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (St) {
        if (a.mode === "hidden")
          return t = Ou(e, a), e.lanes = 536870912, bi(null, t);
        if (If(e), (t = Lt) ? (t = Ad(
          t,
          Je
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Fl !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = $o(t), l.return = e, e.child = l, he = e, Lt = null)) : t = null, t === null) throw $l(e);
        return e.lanes = 536870912, null;
      }
      return Ou(e, a);
    }
    var i = t.memoizedState;
    if (i !== null) {
      var u = i.dehydrated;
      if (If(e), n)
        if (e.flags & 256)
          e.flags &= -257, e = hs(
            t,
            e,
            l
          );
        else if (e.memoizedState !== null)
          e.child = t.child, e.flags |= 128, e = null;
        else throw Error(s(558));
      else if (ae || bn(t, e, l, !1), n = (l & t.childLanes) !== 0, ae || n) {
        if (a = qt, a !== null && (u = en(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, Ha(t, u), Re(a, t, u), bc;
        Yu(), e = hs(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, Lt = Fe(u.nextSibling), he = e, St = !0, Wl = null, Je = !1, t !== null && tr(e, t), e = Ou(e, a), e.flags |= 4096;
      return e;
    }
    return t = Al(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Cu(t, e) {
    var l = e.ref;
    if (l === null)
      t !== null && t.ref !== null && (e.flags |= 4194816);
    else {
      if (typeof l != "function" && typeof l != "object")
        throw Error(s(284));
      (t === null || t.ref !== l) && (e.flags |= 4194816);
    }
  }
  function xc(t, e, l, a, n) {
    return Ya(e), l = tc(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = ec(), t !== null && !ae ? (lc(t, e, n), Rl(t, e, n)) : (St && a && wf(e), e.flags |= 1, pe(t, e, l, n), e.child);
  }
  function gs(t, e, l, a, n, i) {
    return Ya(e), e.updateQueue = null, l = vr(
      e,
      a,
      l,
      n
    ), yr(t), a = ec(), t !== null && !ae ? (lc(t, e, i), Rl(t, e, i)) : (St && a && wf(e), e.flags |= 1, pe(t, e, l, i), e.child);
  }
  function ps(t, e, l, a, n) {
    if (Ya(e), e.stateNode === null) {
      var i = gn, u = l.contextType;
      typeof u == "object" && u !== null && (i = ge(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = yc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Kf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? ge(u) : gn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (pc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && yc.enqueueReplaceState(i, i.state, null), hi(e, a, i, n), mi(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var c = e.memoizedProps, r = Ka(l, c);
      i.props = r;
      var v = i.context, M = l.contextType;
      u = gn, typeof M == "object" && M !== null && (u = ge(M));
      var O = l.getDerivedStateFromProps;
      M = typeof O == "function" || typeof i.getSnapshotBeforeUpdate == "function", c = e.pendingProps !== c, M || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (c || v !== u) && ls(
        e,
        i,
        a,
        u
      ), Pl = !1;
      var b = e.memoizedState;
      i.state = b, hi(e, a, i, n), mi(), v = e.memoizedState, c || b !== v || Pl ? (typeof O == "function" && (pc(
        e,
        l,
        O,
        a
      ), v = e.memoizedState), (r = Pl || es(
        e,
        l,
        r,
        a,
        b,
        v,
        u
      )) ? (M || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = v), i.props = a, i.state = v, i.context = u, a = r) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, Jf(t, e), u = e.memoizedProps, M = Ka(l, u), i.props = M, O = e.pendingProps, b = i.context, v = l.contextType, r = gn, typeof v == "object" && v !== null && (r = ge(v)), c = l.getDerivedStateFromProps, (v = typeof c == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== O || b !== r) && ls(
        e,
        i,
        a,
        r
      ), Pl = !1, b = e.memoizedState, i.state = b, hi(e, a, i, n), mi();
      var T = e.memoizedState;
      u !== O || b !== T || Pl || t !== null && t.dependencies !== null && su(t.dependencies) ? (typeof c == "function" && (pc(
        e,
        l,
        c,
        a
      ), T = e.memoizedState), (M = Pl || es(
        e,
        l,
        M,
        a,
        b,
        T,
        r
      ) || t !== null && t.dependencies !== null && su(t.dependencies)) ? (v || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, T, r), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        T,
        r
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = T), i.props = a, i.state = T, i.context = r, a = M) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return i = a, Cu(t, e), a = (e.flags & 128) !== 0, i || a ? (i = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : i.render(), e.flags |= 1, t !== null && a ? (e.child = Va(
      e,
      t.child,
      null,
      n
    ), e.child = Va(
      e,
      null,
      l,
      n
    )) : pe(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = Rl(
      t,
      e,
      n
    ), t;
  }
  function ys(t, e, l, a) {
    return qa(), e.flags |= 256, pe(t, e, l, a), e.child;
  }
  var Sc = {
    dehydrated: null,
    treeContext: null,
    retryLane: 0,
    hydrationErrors: null
  };
  function Tc(t) {
    return { baseLanes: t, cachePool: ur() };
  }
  function zc(t, e, l) {
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= Ye), t;
  }
  function vs(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : ($t.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (St) {
        if (n ? la(e) : aa(), (t = Lt) ? (t = Ad(
          t,
          Je
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Fl !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = $o(t), l.return = e, e.child = l, he = e, Lt = null)) : t = null, t === null) throw $l(e);
        return io(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var c = a.children;
      return a = a.fallback, n ? (aa(), n = e.mode, c = Uu(
        { mode: "hidden", children: c },
        n
      ), a = ja(
        a,
        n,
        l,
        null
      ), c.return = e, a.return = e, c.sibling = a, e.child = c, a = e.child, a.memoizedState = Tc(l), a.childLanes = zc(
        t,
        u,
        l
      ), e.memoizedState = Sc, bi(null, a)) : (la(e), Mc(e, c));
    }
    var r = t.memoizedState;
    if (r !== null && (c = r.dehydrated, c !== null)) {
      if (i)
        e.flags & 256 ? (la(e), e.flags &= -257, e = Ec(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (aa(), e.child = t.child, e.flags |= 128, e = null) : (aa(), c = a.fallback, n = e.mode, a = Uu(
          { mode: "visible", children: a.children },
          n
        ), c = ja(
          c,
          n,
          l,
          null
        ), c.flags |= 2, a.return = e, c.return = e, a.sibling = c, e.child = a, Va(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = Tc(l), a.childLanes = zc(
          t,
          u,
          l
        ), e.memoizedState = Sc, e = bi(null, a));
      else if (la(e), io(c)) {
        if (u = c.nextSibling && c.nextSibling.dataset, u) var v = u.dgst;
        u = v, a = Error(s(419)), a.stack = "", a.digest = u, fi({ value: a, source: null, stack: null }), e = Ec(
          t,
          e,
          l
        );
      } else if (ae || bn(t, e, l, !1), u = (l & t.childLanes) !== 0, ae || u) {
        if (u = qt, u !== null && (a = en(u, l), a !== 0 && a !== r.retryLane))
          throw r.retryLane = a, Ha(t, a), Re(u, t, a), bc;
        no(c) || Yu(), e = Ec(
          t,
          e,
          l
        );
      } else
        no(c) ? (e.flags |= 192, e.child = t.child, e = null) : (t = r.treeContext, Lt = Fe(
          c.nextSibling
        ), he = e, St = !0, Wl = null, Je = !1, t !== null && tr(e, t), e = Mc(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (aa(), c = a.fallback, n = e.mode, r = t.child, v = r.sibling, a = Al(r, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = r.subtreeFlags & 65011712, v !== null ? c = Al(
      v,
      c
    ) : (c = ja(
      c,
      n,
      l,
      null
    ), c.flags |= 2), c.return = e, a.return = e, a.sibling = c, e.child = a, bi(null, a), a = e.child, c = t.child.memoizedState, c === null ? c = Tc(l) : (n = c.cachePool, n !== null ? (r = ee._currentValue, n = n.parent !== r ? { parent: r, pool: r } : n) : n = ur(), c = {
      baseLanes: c.baseLanes | l,
      cachePool: n
    }), a.memoizedState = c, a.childLanes = zc(
      t,
      u,
      l
    ), e.memoizedState = Sc, bi(t.child, a)) : (la(e), l = t.child, t = l.sibling, l = Al(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function Mc(t, e) {
    return e = Uu(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Uu(t, e) {
    return t = He(22, t, null, e), t.lanes = 0, t;
  }
  function Ec(t, e, l) {
    return Va(e, t.child, null, l), t = Mc(
      e,
      e.pendingProps.children
    ), t.flags |= 2, e.memoizedState = null, t;
  }
  function bs(t, e, l) {
    t.lanes |= e;
    var a = t.alternate;
    a !== null && (a.lanes |= e), Yf(t.return, e, l);
  }
  function Ac(t, e, l, a, n, i) {
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
  function xs(t, e, l) {
    var a = e.pendingProps, n = a.revealOrder, i = a.tail;
    a = a.children;
    var u = $t.current, c = (u & 2) !== 0;
    if (c ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, N($t, u), pe(t, e, a, l), a = St ? ui : 0, !c && t !== null && (t.flags & 128) !== 0)
      t: for (t = e.child; t !== null; ) {
        if (t.tag === 13)
          t.memoizedState !== null && bs(t, l, e);
        else if (t.tag === 19)
          bs(t, l, e);
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
          t = l.alternate, t !== null && bu(t) === null && (n = l), l = l.sibling;
        l = n, l === null ? (n = e.child, e.child = null) : (n = l.sibling, l.sibling = null), Ac(
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
          if (t = n.alternate, t !== null && bu(t) === null) {
            e.child = n;
            break;
          }
          t = n.sibling, n.sibling = l, l = n, n = t;
        }
        Ac(
          e,
          !0,
          l,
          null,
          i,
          a
        );
        break;
      case "together":
        Ac(
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
    if (t !== null && (e.dependencies = t.dependencies), ua |= e.lanes, (l & e.childLanes) === 0)
      if (t !== null) {
        if (bn(
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
      for (t = e.child, l = Al(t, t.pendingProps), e.child = l, l.return = e; t.sibling !== null; )
        t = t.sibling, l = l.sibling = Al(t, t.pendingProps), l.return = e;
      l.sibling = null;
    }
    return e.child;
  }
  function _c(t, e) {
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && su(t)));
  }
  function ih(t, e, l) {
    switch (e.tag) {
      case 3:
        ce(e, e.stateNode.containerInfo), Il(e, ee, t.memoizedState.cache), qa();
        break;
      case 27:
      case 5:
        gl(e);
        break;
      case 4:
        ce(e, e.stateNode.containerInfo);
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
          return e.flags |= 128, If(e), null;
        break;
      case 13:
        var a = e.memoizedState;
        if (a !== null)
          return a.dehydrated !== null ? (la(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? vs(t, e, l) : (la(e), t = Rl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        la(e);
        break;
      case 19:
        var n = (t.flags & 128) !== 0;
        if (a = (l & e.childLanes) !== 0, a || (bn(
          t,
          e,
          l,
          !1
        ), a = (l & e.childLanes) !== 0), n) {
          if (a)
            return xs(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), N($t, $t.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, ds(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        Il(e, ee, t.memoizedState.cache);
    }
    return Rl(t, e, l);
  }
  function Ss(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        ae = !0;
      else {
        if (!_c(t, l) && (e.flags & 128) === 0)
          return ae = !1, ih(
            t,
            e,
            l
          );
        ae = (t.flags & 131072) !== 0;
      }
    else
      ae = !1, St && (e.flags & 1048576) !== 0 && Po(e, ui, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = Xa(e.elementType), e.type = t, typeof t == "function")
            Rf(t) ? (a = Ka(t, a), e.tag = 1, e = ps(
              null,
              e,
              t,
              a,
              l
            )) : (e.tag = 0, e = xc(
              null,
              e,
              t,
              a,
              l
            ));
          else {
            if (t != null) {
              var n = t.$$typeof;
              if (n === Dt) {
                e.tag = 11, e = os(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === $) {
                e.tag = 14, e = rs(
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
        return xc(
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
        ), ps(
          t,
          e,
          a,
          n,
          l
        );
      case 3:
        t: {
          if (ce(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(s(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, Jf(t, e), hi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, Il(e, ee, a), a !== i.cache && Lf(
            e,
            [ee],
            l,
            !0
          ), mi(), a = u.element, i.isDehydrated)
            if (i = {
              element: a,
              isDehydrated: !1,
              cache: u.cache
            }, e.updateQueue.baseState = i, e.memoizedState = i, e.flags & 256) {
              e = ys(
                t,
                e,
                a,
                l
              );
              break t;
            } else if (a !== n) {
              n = Ve(
                Error(s(424)),
                e
              ), fi(n), e = ys(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Lt = Fe(t.firstChild), he = e, St = !0, Wl = null, Je = !0, l = dr(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (qa(), a === n) {
              e = Rl(
                t,
                e,
                l
              );
              break t;
            }
            pe(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Cu(t, e), t === null ? (l = Rd(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : St || (l = e.type, t = e.pendingProps, a = Ju(
          ct.current
        ).createElement(l), a[te] = e, a[de] = t, ye(a, l, t), Wt(a), e.stateNode = a) : e.memoizedState = Rd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return gl(e), t === null && St && (a = e.stateNode = Od(
          e.type,
          e.pendingProps,
          ct.current
        ), he = e, Je = !0, n = Lt, sa(e.type) ? (uo = n, Lt = Fe(a.firstChild)) : Lt = n), pe(
          t,
          e,
          e.pendingProps.children,
          l
        ), Cu(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && St && ((n = a = Lt) && (a = wh(
          a,
          e.type,
          e.pendingProps,
          Je
        ), a !== null ? (e.stateNode = a, he = e, Lt = Fe(a.firstChild), Je = !1, n = !0) : n = !1), n || $l(e)), gl(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, eo(n, i) ? a = null : u !== null && eo(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = tc(
          t,
          e,
          Wm,
          null,
          null,
          l
        ), Ni._currentValue = n), Cu(t, e), pe(t, e, a, l), e.child;
      case 6:
        return t === null && St && ((t = l = Lt) && (l = Hh(
          l,
          e.pendingProps,
          Je
        ), l !== null ? (e.stateNode = l, he = e, Lt = null, t = !0) : t = !1), t || $l(e)), null;
      case 13:
        return vs(t, e, l);
      case 4:
        return ce(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = Va(
          e,
          null,
          a,
          l
        ) : pe(t, e, a, l), e.child;
      case 11:
        return os(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return pe(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return pe(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return pe(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, Il(e, e.type, a.value), pe(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, Ya(e), n = ge(n), a = a(n), e.flags |= 1, pe(t, e, a, l), e.child;
      case 14:
        return rs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 15:
        return ss(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 19:
        return xs(t, e, l);
      case 31:
        return nh(t, e, l);
      case 22:
        return ds(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return Ya(e), a = ge(ee), t === null ? (n = Vf(), n === null && (n = qt, i = Xf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Kf(e), Il(e, ee, n)) : ((t.lanes & l) !== 0 && (Jf(t, e), hi(e, null, null, l), mi()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), Il(e, ee, a)) : (a = i.cache, Il(e, ee, a), a !== n.cache && Lf(
          e,
          [ee],
          l,
          !0
        ))), pe(
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
  function Bl(t) {
    t.flags |= 4;
  }
  function Dc(t, e, l, a, n) {
    if ((e = (t.mode & 32) !== 0) && (e = !1), e) {
      if (t.flags |= 16777216, (n & 335544128) === n)
        if (t.stateNode.complete) t.flags |= 8192;
        else if (ks()) t.flags |= 8192;
        else
          throw Qa = gu, Zf;
    } else t.flags &= -16777217;
  }
  function Ts(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !jd(e))
      if (ks()) t.flags |= 8192;
      else
        throw Qa = gu, Zf;
  }
  function Ru(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? Zn() : 536870912, t.lanes |= e, Un |= e);
  }
  function xi(t, e) {
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
        return Xt(e), null;
      case 1:
        return Xt(e), null;
      case 3:
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), Ol(ee), Rt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (vn(e) ? Bl(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, qf())), Xt(e), null;
      case 26:
        var n = e.type, i = e.memoizedState;
        return t === null ? (Bl(e), i !== null ? (Xt(e), Ts(e, i)) : (Xt(e), Dc(
          e,
          n,
          null,
          a,
          l
        ))) : i ? i !== t.memoizedState ? (Bl(e), Xt(e), Ts(e, i)) : (Xt(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Bl(e), Xt(e), Dc(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if (Xe(e), l = ct.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Bl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          t = q.current, vn(e) ? er(e) : (t = Od(n, a, l), e.stateNode = t, Bl(e));
        }
        return Xt(e), null;
      case 5:
        if (Xe(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Bl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          if (i = q.current, vn(e))
            er(e);
          else {
            var u = Ju(
              ct.current
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
            i[te] = e, i[de] = a;
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
            t: switch (ye(i, n, a), n) {
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
            a && Bl(e);
          }
        }
        return Xt(e), Dc(
          e,
          e.type,
          t === null ? null : t.memoizedProps,
          e.pendingProps,
          l
        ), null;
      case 6:
        if (t && e.stateNode != null)
          t.memoizedProps !== a && Bl(e);
        else {
          if (typeof a != "string" && e.stateNode === null)
            throw Error(s(166));
          if (t = ct.current, vn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = he, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[te] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || vd(t.nodeValue, l)), t || $l(e, !0);
          } else
            t = Ju(t).createTextNode(
              a
            ), t[te] = e, e.stateNode = t;
        }
        return Xt(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = vn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(s(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(557));
              t[te] = e;
            } else
              qa(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), t = !1;
          } else
            l = qf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (qe(e), e) : (qe(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(s(558));
        }
        return Xt(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = vn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(s(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(s(317));
              n[te] = e;
            } else
              qa(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), n = !1;
          } else
            n = qf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (qe(e), e) : (qe(e), null);
        }
        return qe(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Ru(e, e.updateQueue), Xt(e), null);
      case 4:
        return Rt(), t === null && Wc(e.stateNode.containerInfo), Xt(e), null;
      case 10:
        return Ol(e.type), Xt(e), null;
      case 19:
        if (A($t), a = e.memoizedState, a === null) return Xt(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) xi(a, !1);
          else {
            if (kt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = bu(t), i !== null) {
                  for (e.flags |= 128, xi(a, !1), t = i.updateQueue, e.updateQueue = t, Ru(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    Wo(l, t), l = l.sibling;
                  return N(
                    $t,
                    $t.current & 1 | 2
                  ), St && _l(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && se() > ju && (e.flags |= 128, n = !0, xi(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = bu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Ru(e, t), xi(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !St)
                return Xt(e), null;
            } else
              2 * se() - a.renderingStartTime > ju && l !== 536870912 && (e.flags |= 128, n = !0, xi(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = se(), t.sibling = null, l = $t.current, N(
          $t,
          n ? l & 1 | 2 : l & 1
        ), St && _l(e, a.treeForkCount), t) : (Xt(e), null);
      case 22:
      case 23:
        return qe(e), $f(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Xt(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Xt(e), l = e.updateQueue, l !== null && Ru(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && A(La), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), Ol(ee), Xt(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(s(156, e.tag));
  }
  function fh(t, e) {
    switch (Hf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return Ol(ee), Rt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return Xe(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (qe(e), e.alternate === null)
            throw Error(s(340));
          qa();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (qe(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(s(340));
          qa();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return A($t), null;
      case 4:
        return Rt(), null;
      case 10:
        return Ol(e.type), null;
      case 22:
      case 23:
        return qe(e), $f(), t !== null && A(La), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return Ol(ee), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function zs(t, e) {
    switch (Hf(e), e.tag) {
      case 3:
        Ol(ee), Rt();
        break;
      case 26:
      case 27:
      case 5:
        Xe(e);
        break;
      case 4:
        Rt();
        break;
      case 31:
        e.memoizedState !== null && qe(e);
        break;
      case 13:
        qe(e);
        break;
      case 19:
        A($t);
        break;
      case 10:
        Ol(e.type);
        break;
      case 22:
      case 23:
        qe(e), $f(), t !== null && A(La);
        break;
      case 24:
        Ol(ee);
    }
  }
  function Si(t, e) {
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
  function na(t, e, l) {
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
  function Ms(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        hr(e, l);
      } catch (a) {
        Nt(t, t.return, a);
      }
    }
  }
  function Es(t, e, l) {
    l.props = Ka(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      Nt(t, e, a);
    }
  }
  function Ti(t, e) {
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
  function ml(t, e) {
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
  function As(t) {
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
  function Oc(t, e, l) {
    try {
      var a = t.stateNode;
      Oh(a, t.type, l, e), a[de] = e;
    } catch (n) {
      Nt(t, t.return, n);
    }
  }
  function _s(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && sa(t.type) || t.tag === 4;
  }
  function Cc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || _s(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && sa(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Uc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = $e));
    else if (a !== 4 && (a === 27 && sa(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Uc(t, e, l), t = t.sibling; t !== null; )
        Uc(t, e, l), t = t.sibling;
  }
  function Bu(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && sa(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (Bu(t, e, l), t = t.sibling; t !== null; )
        Bu(t, e, l), t = t.sibling;
  }
  function Ds(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      ye(e, a, l), e[te] = t, e[de] = l;
    } catch (i) {
      Nt(t, t.return, i);
    }
  }
  var Nl = !1, ne = !1, Rc = !1, Os = typeof WeakSet == "function" ? WeakSet : Set, oe = null;
  function ch(t, e) {
    if (t = t.containerInfo, Pc = tf, t = Lo(t), Ef(t)) {
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
    for (to = { focusedElem: t, selectionRange: l }, tf = !1, oe = e; oe !== null; )
      if (e = oe, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, oe = t;
      else
        for (; oe !== null; ) {
          switch (e = oe, i = e.alternate, t = e.flags, e.tag) {
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
                  var Y = Ka(
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
                  ao(t);
                else if (l === 1)
                  switch (t.nodeName) {
                    case "HEAD":
                    case "HTML":
                    case "BODY":
                      ao(t);
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
            t.return = e.return, oe = t;
            break;
          }
          oe = e.return;
        }
  }
  function Cs(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        Hl(t, l), a & 4 && Si(5, l);
        break;
      case 1:
        if (Hl(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              Nt(l, l.return, u);
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
              Nt(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && Ms(l), a & 512 && Ti(l, l.return);
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
            hr(t, e);
          } catch (u) {
            Nt(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && Ds(l);
      case 26:
      case 5:
        Hl(t, l), e === null && a & 4 && As(l), a & 512 && Ti(l, l.return);
        break;
      case 12:
        Hl(t, l);
        break;
      case 31:
        Hl(t, l), a & 4 && Bs(t, l);
        break;
      case 13:
        Hl(t, l), a & 4 && Ns(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = yh.bind(
          null,
          l
        ), jh(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Nl, !a) {
          e = e !== null && e.memoizedState !== null || ne, n = Nl;
          var i = ne;
          Nl = a, (ne = e) && !i ? jl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : Hl(t, l), Nl = n, ne = i;
        }
        break;
      case 30:
        break;
      default:
        Hl(t, l);
    }
  }
  function Us(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Us(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && za(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Qt = null, De = !1;
  function wl(t, e, l) {
    for (l = l.child; l !== null; )
      Rs(t, e, l), l = l.sibling;
  }
  function Rs(t, e, l) {
    if (xe && typeof xe.onCommitFiberUnmount == "function")
      try {
        xe.onCommitFiberUnmount(ba, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        ne || ml(l, e), wl(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        ne || ml(l, e);
        var a = Qt, n = De;
        sa(l.type) && (Qt = l.stateNode, De = !1), wl(
          t,
          e,
          l
        ), Ui(l.stateNode), Qt = a, De = n;
        break;
      case 5:
        ne || ml(l, e);
      case 6:
        if (a = Qt, n = De, Qt = null, wl(
          t,
          e,
          l
        ), Qt = a, De = n, Qt !== null)
          if (De)
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
        Qt !== null && (De ? (t = Qt, Md(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), Gn(t)) : Md(Qt, l.stateNode));
        break;
      case 4:
        a = Qt, n = De, Qt = l.stateNode.containerInfo, De = !0, wl(
          t,
          e,
          l
        ), Qt = a, De = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        na(2, l, e), ne || na(4, l, e), wl(
          t,
          e,
          l
        );
        break;
      case 1:
        ne || (ml(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && Es(
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
        ne = (a = ne) || l.memoizedState !== null, wl(
          t,
          e,
          l
        ), ne = a;
        break;
      default:
        wl(
          t,
          e,
          l
        );
    }
  }
  function Bs(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null))) {
      t = t.dehydrated;
      try {
        Gn(t);
      } catch (l) {
        Nt(e, e.return, l);
      }
    }
  }
  function Ns(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        Gn(t);
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
        return e === null && (e = t.stateNode = new Os()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new Os()), e;
      default:
        throw Error(s(435, t.tag));
    }
  }
  function Nu(t, e) {
    var l = oh(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = vh.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function Oe(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], i = t, u = e, c = u;
        t: for (; c !== null; ) {
          switch (c.tag) {
            case 27:
              if (sa(c.type)) {
                Qt = c.stateNode, De = !1;
                break t;
              }
              break;
            case 5:
              Qt = c.stateNode, De = !1;
              break t;
            case 3:
            case 4:
              Qt = c.stateNode.containerInfo, De = !0;
              break t;
          }
          c = c.return;
        }
        if (Qt === null) throw Error(s(160));
        Rs(i, u, n), Qt = null, De = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        ws(e, t), e = e.sibling;
  }
  var el = null;
  function ws(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Oe(e, t), Ce(t), a & 4 && (na(3, t, t.return), Si(3, t), na(5, t, t.return));
        break;
      case 1:
        Oe(e, t), Ce(t), a & 512 && (ne || l === null || ml(l, l.return)), a & 64 && Nl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = el;
        if (Oe(e, t), Ce(t), a & 512 && (ne || l === null || ml(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[Ql] || i[te] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), ye(i, a, l), i[te] = t, Wt(i), a = i;
                      break t;
                    case "link":
                      var u = wd(
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
                      i = n.createElement(a), ye(i, a, l), n.head.appendChild(i);
                      break;
                    case "meta":
                      if (u = wd(
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
                      i = n.createElement(a), ye(i, a, l), n.head.appendChild(i);
                      break;
                    default:
                      throw Error(s(468, a));
                  }
                  i[te] = t, Wt(i), a = i;
                }
                t.stateNode = a;
              } else
                Hd(
                  n,
                  t.type,
                  t.stateNode
                );
            else
              t.stateNode = Nd(
                n,
                a,
                t.memoizedProps
              );
          else
            i !== a ? (i === null ? l.stateNode !== null && (l = l.stateNode, l.parentNode.removeChild(l)) : i.count--, a === null ? Hd(
              n,
              t.type,
              t.stateNode
            ) : Nd(
              n,
              a,
              t.memoizedProps
            )) : a === null && t.stateNode !== null && Oc(
              t,
              t.memoizedProps,
              l.memoizedProps
            );
        }
        break;
      case 27:
        Oe(e, t), Ce(t), a & 512 && (ne || l === null || ml(l, l.return)), l !== null && a & 4 && Oc(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (Oe(e, t), Ce(t), a & 512 && (ne || l === null || ml(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            j(n, "");
          } catch (Y) {
            Nt(t, t.return, Y);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Oc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Rc = !0);
        break;
      case 6:
        if (Oe(e, t), Ce(t), a & 4) {
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
        if (Wu = null, n = el, el = ku(e.containerInfo), Oe(e, t), el = n, Ce(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            Gn(e.containerInfo);
          } catch (Y) {
            Nt(t, t.return, Y);
          }
        Rc && (Rc = !1, Hs(t));
        break;
      case 4:
        a = el, el = ku(
          t.stateNode.containerInfo
        ), Oe(e, t), Ce(t), el = a;
        break;
      case 12:
        Oe(e, t), Ce(t);
        break;
      case 31:
        Oe(e, t), Ce(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 13:
        Oe(e, t), Ce(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Hu = se()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var r = l !== null && l.memoizedState !== null, v = Nl, M = ne;
        if (Nl = v || n, ne = M || r, Oe(e, t), ne = M, Nl = v, Ce(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || r || Nl || ne || Ja(t)), l = null, e = t; ; ) {
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
                  n ? Ed(T, !0) : Ed(r.stateNode, !1);
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
        a & 4 && (a = t.updateQueue, a !== null && (l = a.retryQueue, l !== null && (a.retryQueue = null, Nu(t, l))));
        break;
      case 19:
        Oe(e, t), Ce(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 30:
        break;
      case 21:
        break;
      default:
        Oe(e, t), Ce(t);
    }
  }
  function Ce(t) {
    var e = t.flags;
    if (e & 2) {
      try {
        for (var l, a = t.return; a !== null; ) {
          if (_s(a)) {
            l = a;
            break;
          }
          a = a.return;
        }
        if (l == null) throw Error(s(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, i = Cc(t);
            Bu(t, i, n);
            break;
          case 5:
            var u = l.stateNode;
            l.flags & 32 && (j(u, ""), l.flags &= -33);
            var c = Cc(t);
            Bu(t, c, u);
            break;
          case 3:
          case 4:
            var r = l.stateNode.containerInfo, v = Cc(t);
            Uc(
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
  function Hs(t) {
    if (t.subtreeFlags & 1024)
      for (t = t.child; t !== null; ) {
        var e = t;
        Hs(e), e.tag === 5 && e.flags & 1024 && e.stateNode.reset(), t = t.sibling;
      }
  }
  function Hl(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        Cs(t, e.alternate, e), e = e.sibling;
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
          typeof l.componentWillUnmount == "function" && Es(
            e,
            e.return,
            l
          ), Ja(e);
          break;
        case 27:
          Ui(e.stateNode);
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
          ), Si(4, i);
          break;
        case 1:
          if (jl(
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
                  mr(r[n], c);
            } catch (v) {
              Nt(a, a.return, v);
            }
          }
          l && u & 64 && Ms(i), Ti(i, i.return);
          break;
        case 27:
          Ds(i);
        case 26:
        case 5:
          jl(
            n,
            i,
            l
          ), l && a === null && u & 4 && As(i), Ti(i, i.return);
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
          ), l && u & 4 && Bs(n, i);
          break;
        case 13:
          jl(
            n,
            i,
            l
          ), l && u & 4 && Ns(n, i);
          break;
        case 22:
          i.memoizedState === null && jl(
            n,
            i,
            l
          ), Ti(i, i.return);
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
  function Bc(t, e) {
    var l = null;
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && ci(l));
  }
  function Nc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ci(t));
  }
  function ll(t, e, l, a) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; )
        js(
          t,
          e,
          l,
          a
        ), e = e.sibling;
  }
  function js(t, e, l, a) {
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
        ), n & 2048 && Si(9, e);
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
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ci(t)));
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
        i = e.stateNode, u = e.alternate, e.memoizedState !== null ? i._visibility & 2 ? ll(
          t,
          e,
          l,
          a
        ) : zi(t, e) : i._visibility & 2 ? ll(
          t,
          e,
          l,
          a
        ) : (i._visibility |= 2, Dn(
          t,
          e,
          l,
          a,
          (e.subtreeFlags & 10256) !== 0 || !1
        )), n & 2048 && Bc(u, e);
        break;
      case 24:
        ll(
          t,
          e,
          l,
          a
        ), n & 2048 && Nc(e.alternate, e);
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
  function Dn(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var i = t, u = e, c = l, r = a, v = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          Dn(
            i,
            u,
            c,
            r,
            n
          ), Si(8, u);
          break;
        case 23:
          break;
        case 22:
          var M = u.stateNode;
          u.memoizedState !== null ? M._visibility & 2 ? Dn(
            i,
            u,
            c,
            r,
            n
          ) : zi(
            i,
            u
          ) : (M._visibility |= 2, Dn(
            i,
            u,
            c,
            r,
            n
          )), n && v & 2048 && Bc(
            u.alternate,
            u
          );
          break;
        case 24:
          Dn(
            i,
            u,
            c,
            r,
            n
          ), n && v & 2048 && Nc(u.alternate, u);
          break;
        default:
          Dn(
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
  function zi(t, e) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; ) {
        var l = t, a = e, n = a.flags;
        switch (a.tag) {
          case 22:
            zi(l, a), n & 2048 && Bc(
              a.alternate,
              a
            );
            break;
          case 24:
            zi(l, a), n & 2048 && Nc(a.alternate, a);
            break;
          default:
            zi(l, a);
        }
        e = e.sibling;
      }
  }
  var Mi = 8192;
  function On(t, e, l) {
    if (t.subtreeFlags & Mi)
      for (t = t.child; t !== null; )
        qs(
          t,
          e,
          l
        ), t = t.sibling;
  }
  function qs(t, e, l) {
    switch (t.tag) {
      case 26:
        On(
          t,
          e,
          l
        ), t.flags & Mi && t.memoizedState !== null && Fh(
          l,
          el,
          t.memoizedState,
          t.memoizedProps
        );
        break;
      case 5:
        On(
          t,
          e,
          l
        );
        break;
      case 3:
      case 4:
        var a = el;
        el = ku(t.stateNode.containerInfo), On(
          t,
          e,
          l
        ), el = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = Mi, Mi = 16777216, On(
          t,
          e,
          l
        ), Mi = a) : On(
          t,
          e,
          l
        ));
        break;
      default:
        On(
          t,
          e,
          l
        );
    }
  }
  function Gs(t) {
    var e = t.alternate;
    if (e !== null && (t = e.child, t !== null)) {
      e.child = null;
      do
        e = t.sibling, t.sibling = null, t = e;
      while (t !== null);
    }
  }
  function Ei(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          oe = a, Ls(
            a,
            t
          );
        }
      Gs(t);
    }
    if (t.subtreeFlags & 10256)
      for (t = t.child; t !== null; )
        Ys(t), t = t.sibling;
  }
  function Ys(t) {
    switch (t.tag) {
      case 0:
      case 11:
      case 15:
        Ei(t), t.flags & 2048 && na(9, t, t.return);
        break;
      case 3:
        Ei(t);
        break;
      case 12:
        Ei(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, wu(t)) : Ei(t);
        break;
      default:
        Ei(t);
    }
  }
  function wu(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          oe = a, Ls(
            a,
            t
          );
        }
      Gs(t);
    }
    for (t = t.child; t !== null; ) {
      switch (e = t, e.tag) {
        case 0:
        case 11:
        case 15:
          na(8, e, e.return), wu(e);
          break;
        case 22:
          l = e.stateNode, l._visibility & 2 && (l._visibility &= -3, wu(e));
          break;
        default:
          wu(e);
      }
      t = t.sibling;
    }
  }
  function Ls(t, e) {
    for (; oe !== null; ) {
      var l = oe;
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
          ci(l.memoizedState.cache);
      }
      if (a = l.child, a !== null) a.return = l, oe = a;
      else
        t: for (l = t; oe !== null; ) {
          a = oe;
          var n = a.sibling, i = a.return;
          if (Us(a), a === l) {
            oe = null;
            break t;
          }
          if (n !== null) {
            n.return = i, oe = n;
            break t;
          }
          oe = i;
        }
    }
  }
  var rh = {
    getCacheForType: function(t) {
      var e = ge(ee), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return ge(ee).controller.signal;
    }
  }, sh = typeof WeakMap == "function" ? WeakMap : Map, Ot = 0, qt = null, gt = null, vt = 0, Bt = 0, Ge = null, ia = !1, Cn = !1, wc = !1, ql = 0, kt = 0, ua = 0, ka = 0, Hc = 0, Ye = 0, Un = 0, Ai = null, Ue = null, jc = !1, Hu = 0, Xs = 0, ju = 1 / 0, qu = null, fa = null, fe = 0, ca = null, Rn = null, Gl = 0, qc = 0, Gc = null, Qs = null, _i = 0, Yc = null;
  function Le() {
    return (Ot & 2) !== 0 && vt !== 0 ? vt & -vt : g.T !== null ? Kc() : Fi();
  }
  function Vs() {
    if (Ye === 0)
      if ((vt & 536870912) === 0 || St) {
        var t = Pa;
        Pa <<= 1, (Pa & 3932160) === 0 && (Pa = 262144), Ye = t;
      } else Ye = 536870912;
    return t = je.current, t !== null && (t.flags |= 32), Ye;
  }
  function Re(t, e, l) {
    (t === qt && (Bt === 2 || Bt === 9) || t.cancelPendingCommit !== null) && (Bn(t, 0), oa(
      t,
      vt,
      Ye,
      !1
    )), ul(t, l), ((Ot & 2) === 0 || t !== qt) && (t === qt && ((Ot & 2) === 0 && (ka |= l), kt === 4 && oa(
      t,
      vt,
      Ye,
      !1
    )), hl(t));
  }
  function Zs(t, e, l) {
    if ((Ot & 6) !== 0) throw Error(s(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Sa(t, e), n = a ? hh(t, e) : Xc(t, e, !0), i = a;
    do {
      if (n === 0) {
        Cn && !a && oa(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, i && !dh(l)) {
          n = Xc(t, e, !1), i = !1;
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
              n = Ai;
              var r = c.current.memoizedState.isDehydrated;
              if (r && (Bn(c, u).flags |= 256), u = Xc(
                c,
                u,
                !1
              ), u !== 2) {
                if (wc && !r) {
                  c.errorRecoveryDisabledLanes |= i, ka |= i, n = 4;
                  break t;
                }
                i = Ue, Ue = n, i !== null && (Ue === null ? Ue = i : Ue.push.apply(
                  Ue,
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
              throw Error(s(345));
            case 4:
              if ((e & 4194048) !== e) break;
            case 6:
              oa(
                a,
                e,
                Ye,
                !ia
              );
              break t;
            case 2:
              Ue = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(s(329));
          }
          if ((e & 62914560) === e && (n = Hu + 300 - se(), 10 < n)) {
            if (oa(
              a,
              e,
              Ye,
              !ia
            ), xa(a, 0, !0) !== 0) break t;
            Gl = e, a.timeoutHandle = Td(
              Ks.bind(
                null,
                a,
                l,
                Ue,
                qu,
                jc,
                e,
                Ye,
                ka,
                Un,
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
          Ks(
            a,
            l,
            Ue,
            qu,
            jc,
            e,
            Ye,
            ka,
            Un,
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
  function Ks(t, e, l, a, n, i, u, c, r, v, M, O, b, T) {
    if (t.timeoutHandle = -1, O = e.subtreeFlags, O & 8192 || (O & 16785408) === 16785408) {
      O = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: $e
      }, qs(
        e,
        i,
        O
      );
      var Y = (i & 62914560) === i ? Hu - se() : (i & 4194048) === i ? Xs - se() : 0;
      if (Y = Wh(
        O,
        Y
      ), Y !== null) {
        Gl = i, t.cancelPendingCommit = Y(
          td.bind(
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
        ), oa(t, i, u, !v);
        return;
      }
    }
    td(
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
            if (!we(i(), n)) return !1;
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
    e &= ~Hc, e &= ~ka, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var i = 31 - ue(n), u = 1 << i;
      a[i] = -1, n &= ~u;
    }
    l !== 0 && ki(t, l, e);
  }
  function Gu() {
    return (Ot & 6) === 0 ? (Di(0), !1) : !0;
  }
  function Lc() {
    if (gt !== null) {
      if (Bt === 0)
        var t = gt.return;
      else
        t = gt, Dl = Ga = null, ac(t), zn = null, ri = 0, t = gt;
      for (; t !== null; )
        zs(t.alternate, t), t = t.return;
      gt = null;
    }
  }
  function Bn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Rh(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), Gl = 0, Lc(), qt = t, gt = l = Al(t.current, null), vt = e, Bt = 0, Ge = null, ia = !1, Cn = Sa(t, e), wc = !1, Un = Ye = Hc = ka = ua = kt = 0, Ue = Ai = null, jc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - ue(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return ql = e, uu(), l;
  }
  function Js(t, e) {
    ot = null, g.H = vi, e === Tn || e === hu ? (e = or(), Bt = 3) : e === Zf ? (e = or(), Bt = 4) : Bt = e === bc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, Ge = e, gt === null && (kt = 1, Du(
      t,
      Ve(e, t.current)
    ));
  }
  function ks() {
    var t = je.current;
    return t === null ? !0 : (vt & 4194048) === vt ? ke === null : (vt & 62914560) === vt || (vt & 536870912) !== 0 ? t === ke : !1;
  }
  function Fs() {
    var t = g.H;
    return g.H = vi, t === null ? vi : t;
  }
  function Ws() {
    var t = g.A;
    return g.A = rh, t;
  }
  function Yu() {
    kt = 4, ia || (vt & 4194048) !== vt && je.current !== null || (Cn = !0), (ua & 134217727) === 0 && (ka & 134217727) === 0 || qt === null || oa(
      qt,
      vt,
      Ye,
      !1
    );
  }
  function Xc(t, e, l) {
    var a = Ot;
    Ot |= 2;
    var n = Fs(), i = Ws();
    (qt !== t || vt !== e) && (qu = null, Bn(t, e)), e = !1;
    var u = kt;
    t: do
      try {
        if (Bt !== 0 && gt !== null) {
          var c = gt, r = Ge;
          switch (Bt) {
            case 8:
              Lc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              je.current === null && (e = !0);
              var v = Bt;
              if (Bt = 0, Ge = null, Nn(t, c, r, v), l && Cn) {
                u = 0;
                break t;
              }
              break;
            default:
              v = Bt, Bt = 0, Ge = null, Nn(t, c, r, v);
          }
        }
        mh(), u = kt;
        break;
      } catch (M) {
        Js(t, M);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Dl = Ga = null, Ot = a, g.H = n, g.A = i, gt === null && (qt = null, vt = 0, uu()), u;
  }
  function mh() {
    for (; gt !== null; ) $s(gt);
  }
  function hh(t, e) {
    var l = Ot;
    Ot |= 2;
    var a = Fs(), n = Ws();
    qt !== t || vt !== e ? (qu = null, ju = se() + 500, Bn(t, e)) : Cn = Sa(
      t,
      e
    );
    t: do
      try {
        if (Bt !== 0 && gt !== null) {
          e = gt;
          var i = Ge;
          e: switch (Bt) {
            case 1:
              Bt = 0, Ge = null, Nn(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (fr(i)) {
                Bt = 0, Ge = null, Is(e);
                break;
              }
              e = function() {
                Bt !== 2 && Bt !== 9 || qt !== t || (Bt = 7), hl(t);
              }, i.then(e, e);
              break t;
            case 3:
              Bt = 7;
              break t;
            case 4:
              Bt = 5;
              break t;
            case 7:
              fr(i) ? (Bt = 0, Ge = null, Is(e)) : (Bt = 0, Ge = null, Nn(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (gt.tag) {
                case 26:
                  u = gt.memoizedState;
                case 5:
                case 27:
                  var c = gt;
                  if (u ? jd(u) : c.stateNode.complete) {
                    Bt = 0, Ge = null;
                    var r = c.sibling;
                    if (r !== null) gt = r;
                    else {
                      var v = c.return;
                      v !== null ? (gt = v, Lu(v)) : gt = null;
                    }
                    break e;
                  }
              }
              Bt = 0, Ge = null, Nn(t, e, i, 5);
              break;
            case 6:
              Bt = 0, Ge = null, Nn(t, e, i, 6);
              break;
            case 8:
              Lc(), kt = 6;
              break t;
            default:
              throw Error(s(462));
          }
        }
        gh();
        break;
      } catch (M) {
        Js(t, M);
      }
    while (!0);
    return Dl = Ga = null, g.H = a, g.A = n, Ot = l, gt !== null ? 0 : (qt = null, vt = 0, uu(), kt);
  }
  function gh() {
    for (; gt !== null && !Vn(); )
      $s(gt);
  }
  function $s(t) {
    var e = Ss(t.alternate, t, ql);
    t.memoizedProps = t.pendingProps, e === null ? Lu(t) : gt = e;
  }
  function Is(t) {
    var e = t, l = e.alternate;
    switch (e.tag) {
      case 15:
      case 0:
        e = gs(
          l,
          e,
          e.pendingProps,
          e.type,
          void 0,
          vt
        );
        break;
      case 11:
        e = gs(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          vt
        );
        break;
      case 5:
        ac(e);
      default:
        zs(l, e), e = gt = Wo(e, ql), e = Ss(l, e, ql);
    }
    t.memoizedProps = t.pendingProps, e === null ? Lu(t) : gt = e;
  }
  function Nn(t, e, l, a) {
    Dl = Ga = null, ac(e), zn = null, ri = 0;
    var n = e.return;
    try {
      if (ah(
        t,
        n,
        e,
        l,
        vt
      )) {
        kt = 1, Du(
          t,
          Ve(l, t.current)
        ), gt = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw gt = n, i;
      kt = 1, Du(
        t,
        Ve(l, t.current)
      ), gt = null;
      return;
    }
    e.flags & 32768 ? (St || a === 1 ? t = !0 : Cn || (vt & 536870912) !== 0 ? t = !1 : (ia = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = je.current, a !== null && a.tag === 13 && (a.flags |= 16384))), Ps(e, t)) : Lu(e);
  }
  function Lu(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        Ps(
          e,
          ia
        );
        return;
      }
      t = e.return;
      var l = uh(
        e.alternate,
        e,
        ql
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
  function Ps(t, e) {
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
  function td(t, e, l, a, n, i, u, c, r) {
    t.cancelPendingCommit = null;
    do
      Xu();
    while (fe !== 0);
    if ((Ot & 6) !== 0) throw Error(s(327));
    if (e !== null) {
      if (e === t.current) throw Error(s(177));
      if (i = e.lanes | e.childLanes, i |= Cf, Ji(
        t,
        l,
        i,
        u,
        c,
        r
      ), t === qt && (gt = qt = null, vt = 0), Rn = e, ca = t, Gl = l, qc = i, Gc = n, Qs = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, bh(va, function() {
        return id(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = g.T, g.T = null, n = U.p, U.p = 2, u = Ot, Ot |= 4;
        try {
          ch(t, e, l);
        } finally {
          Ot = u, U.p = n, g.T = a;
        }
      }
      fe = 1, ed(), ld(), ad();
    }
  }
  function ed() {
    if (fe === 1) {
      fe = 0;
      var t = ca, e = Rn, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = g.T, g.T = null;
        var a = U.p;
        U.p = 2;
        var n = Ot;
        Ot |= 4;
        try {
          ws(e, t);
          var i = to, u = Lo(t.containerInfo), c = i.focusedElem, r = i.selectionRange;
          if (u !== c && c && c.ownerDocument && Yo(
            c.ownerDocument.documentElement,
            c
          )) {
            if (r !== null && Ef(c)) {
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
                  var p = Go(
                    c,
                    I
                  ), h = Go(
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
          tf = !!Pc, to = Pc = null;
        } finally {
          Ot = n, U.p = a, g.T = l;
        }
      }
      t.current = e, fe = 2;
    }
  }
  function ld() {
    if (fe === 2) {
      fe = 0;
      var t = ca, e = Rn, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = g.T, g.T = null;
        var a = U.p;
        U.p = 2;
        var n = Ot;
        Ot |= 4;
        try {
          Cs(t, e.alternate, e);
        } finally {
          Ot = n, U.p = a, g.T = l;
        }
      }
      fe = 3;
    }
  }
  function ad() {
    if (fe === 4 || fe === 3) {
      fe = 0, Li();
      var t = ca, e = Rn, l = Gl, a = Qs;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? fe = 5 : (fe = 0, Rn = ca = null, nd(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (fa = null), Jn(l), e = e.stateNode, xe && typeof xe.onCommitFiberRoot == "function")
        try {
          xe.onCommitFiberRoot(
            ba,
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
      (Gl & 3) !== 0 && Xu(), hl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Yc ? _i++ : (_i = 0, Yc = t) : _i = 0, Di(0);
    }
  }
  function nd(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, ci(e)));
  }
  function Xu() {
    return ed(), ld(), ad(), id();
  }
  function id() {
    if (fe !== 5) return !1;
    var t = ca, e = qc;
    qc = 0;
    var l = Jn(Gl), a = g.T, n = U.p;
    try {
      U.p = 32 > l ? 32 : l, g.T = null, l = Gc, Gc = null;
      var i = ca, u = Gl;
      if (fe = 0, Rn = ca = null, Gl = 0, (Ot & 6) !== 0) throw Error(s(331));
      var c = Ot;
      if (Ot |= 4, Ys(i.current), js(
        i,
        i.current,
        u,
        l
      ), Ot = c, Di(0, !1), xe && typeof xe.onPostCommitFiberRoot == "function")
        try {
          xe.onPostCommitFiberRoot(ba, i);
        } catch {
        }
      return !0;
    } finally {
      U.p = n, g.T = a, nd(t, e);
    }
  }
  function ud(t, e, l) {
    e = Ve(l, e), e = vc(t.stateNode, e, 2), t = ea(t, e, 2), t !== null && (ul(t, 2), hl(t));
  }
  function Nt(t, e, l) {
    if (t.tag === 3)
      ud(t, t, l);
    else
      for (; e !== null; ) {
        if (e.tag === 3) {
          ud(
            e,
            t,
            l
          );
          break;
        } else if (e.tag === 1) {
          var a = e.stateNode;
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (fa === null || !fa.has(a))) {
            t = Ve(l, t), l = fs(2), a = ea(e, l, 2), a !== null && (cs(
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
  function Qc(t, e, l) {
    var a = t.pingCache;
    if (a === null) {
      a = t.pingCache = new sh();
      var n = /* @__PURE__ */ new Set();
      a.set(e, n);
    } else
      n = a.get(e), n === void 0 && (n = /* @__PURE__ */ new Set(), a.set(e, n));
    n.has(l) || (wc = !0, n.add(l), t = ph.bind(null, t, e, l), e.then(t, t));
  }
  function ph(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, qt === t && (vt & l) === l && (kt === 4 || kt === 3 && (vt & 62914560) === vt && 300 > se() - Hu ? (Ot & 2) === 0 && Bn(t, 0) : Hc |= l, Un === vt && (Un = 0)), hl(t);
  }
  function fd(t, e) {
    e === 0 && (e = Zn()), t = Ha(t, e), t !== null && (ul(t, e), hl(t));
  }
  function yh(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), fd(t, l);
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
    a !== null && a.delete(e), fd(t, l);
  }
  function bh(t, e) {
    return Qn(t, e);
  }
  var Qu = null, wn = null, Vc = !1, Vu = !1, Zc = !1, ra = 0;
  function hl(t) {
    t !== wn && t.next === null && (wn === null ? Qu = wn = t : wn = wn.next = t), Vu = !0, Vc || (Vc = !0, Sh());
  }
  function Di(t, e) {
    if (!Zc && Vu) {
      Zc = !0;
      do
        for (var l = !1, a = Qu; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var i = 0;
            else {
              var u = a.suspendedLanes, c = a.pingedLanes;
              i = (1 << 31 - ue(42 | t) + 1) - 1, i &= n & ~(u & ~c), i = i & 201326741 ? i & 201326741 | 1 : i ? i | 2 : 0;
            }
            i !== 0 && (l = !0, sd(a, i));
          } else
            i = vt, i = xa(
              a,
              a === qt ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || Sa(a, i) || (l = !0, sd(a, i));
          a = a.next;
        }
      while (l);
      Zc = !1;
    }
  }
  function xh() {
    cd();
  }
  function cd() {
    Vu = Vc = !1;
    var t = 0;
    ra !== 0 && Uh() && (t = ra);
    for (var e = se(), l = null, a = Qu; a !== null; ) {
      var n = a.next, i = od(a, e);
      i === 0 ? (a.next = null, l === null ? Qu = n : l.next = n, n === null && (wn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (Vu = !0)), a = n;
    }
    fe !== 0 && fe !== 5 || Di(t), ra !== 0 && (ra = 0);
  }
  function od(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - ue(i), c = 1 << u, r = n[u];
      r === -1 ? ((c & l) === 0 || (c & a) !== 0) && (n[u] = vl(c, e)) : r <= e && (t.expiredLanes |= c), i &= ~c;
    }
    if (e = qt, l = vt, l = xa(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (Bt === 2 || Bt === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && ya(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Sa(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && ya(a), Jn(l)) {
        case 2:
        case 8:
          l = $a;
          break;
        case 32:
          l = va;
          break;
        case 268435456:
          l = Vi;
          break;
        default:
          l = va;
      }
      return a = rd.bind(null, t), l = Qn(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && ya(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function rd(t, e) {
    if (fe !== 0 && fe !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Xu() && t.callbackNode !== l)
      return null;
    var a = vt;
    return a = xa(
      t,
      t === qt ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Zs(t, a, e), od(t, se()), t.callbackNode != null && t.callbackNode === l ? rd.bind(null, t) : null);
  }
  function sd(t, e) {
    if (Xu()) return null;
    Zs(t, e, !0);
  }
  function Sh() {
    Bh(function() {
      (Ot & 6) !== 0 ? Qn(
        Qi,
        xh
      ) : cd();
    });
  }
  function Kc() {
    if (ra === 0) {
      var t = xn;
      t === 0 && (t = yl, yl <<= 1, (yl & 261888) === 0 && (yl = 256)), ra = t;
    }
    return ra;
  }
  function dd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : un("" + t);
  }
  function md(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function Th(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = dd(
        (n[de] || null).action
      ), u = a.submitter;
      u && (e = (e = u[de] || null) ? dd(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
      var c = new rn(
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
                if (ra !== 0) {
                  var r = u ? md(n, u) : new FormData(n);
                  dc(
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
                typeof i == "function" && (c.preventDefault(), r = u ? md(n, u) : new FormData(n), dc(
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
  for (var Jc = 0; Jc < Of.length; Jc++) {
    var kc = Of[Jc], zh = kc.toLowerCase(), Mh = kc[0].toUpperCase() + kc.slice(1);
    tl(
      zh,
      "on" + Mh
    );
  }
  tl(Vo, "onAnimationEnd"), tl(Zo, "onAnimationIteration"), tl(Ko, "onAnimationStart"), tl("dblclick", "onDoubleClick"), tl("focusin", "onFocus"), tl("focusout", "onBlur"), tl(Ym, "onTransitionRun"), tl(Lm, "onTransitionStart"), tl(Xm, "onTransitionCancel"), tl(Jo, "onTransitionEnd"), Tl("onMouseEnter", ["mouseout", "mouseover"]), Tl("onMouseLeave", ["mouseout", "mouseover"]), Tl("onPointerEnter", ["pointerout", "pointerover"]), Tl("onPointerLeave", ["pointerout", "pointerover"]), Sl(
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
  var Oi = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), Eh = new Set(
    "beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(Oi)
  );
  function hd(t, e) {
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
              iu(M);
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
              iu(M);
            }
            n.currentTarget = null, i = r;
          }
      }
    }
  }
  function pt(t, e) {
    var l = e[Fn];
    l === void 0 && (l = e[Fn] = /* @__PURE__ */ new Set());
    var a = t + "__bubble";
    l.has(a) || (gd(e, t, 2, !1), l.add(a));
  }
  function Fc(t, e, l) {
    var a = 0;
    e && (a |= 4), gd(
      l,
      t,
      a,
      e
    );
  }
  var Zu = "_reactListening" + Math.random().toString(36).slice(2);
  function Wc(t) {
    if (!t[Zu]) {
      t[Zu] = !0, $i.forEach(function(l) {
        l !== "selectionchange" && (Eh.has(l) || Fc(l, !1, t), Fc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[Zu] || (e[Zu] = !0, Fc("selectionchange", !1, e));
    }
  }
  function gd(t, e, l, a) {
    switch (Vd(e)) {
      case 2:
        var n = Ph;
        break;
      case 8:
        n = tg;
        break;
      default:
        n = so;
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
  function $c(t, e, l, a, n) {
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
            if (u = cl(c), u === null) return;
            if (r = u.tag, r === 5 || r === 6 || r === 26 || r === 27) {
              a = i = u;
              continue t;
            }
            c = c.parentNode;
          }
        }
        a = a.return;
      }
    lu(function() {
      var v = i, M = In(l), O = [];
      t: {
        var b = ko.get(t);
        if (b !== void 0) {
          var T = rn, Y = t;
          switch (t) {
            case "keypress":
              if (on(l) === 0) break t;
            case "keydown":
            case "keyup":
              T = vm;
              break;
            case "focusin":
              Y = "focus", T = it;
              break;
            case "focusout":
              Y = "blur", T = it;
              break;
            case "beforeblur":
            case "afterblur":
              T = it;
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
              T = Ra;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              T = R;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              T = Sm;
              break;
            case Vo:
            case Zo:
            case Ko:
              T = Et;
              break;
            case Jo:
              T = zm;
              break;
            case "scroll":
            case "scrollend":
              T = bf;
              break;
            case "wheel":
              T = Em;
              break;
            case "copy":
            case "cut":
            case "paste":
              T = ze;
              break;
            case "gotpointercapture":
            case "lostpointercapture":
            case "pointercancel":
            case "pointerdown":
            case "pointermove":
            case "pointerout":
            case "pointerover":
            case "pointerup":
              T = Eo;
              break;
            case "toggle":
            case "beforetoggle":
              T = _m;
          }
          var I = (e & 4) !== 0, jt = !I && (t === "scroll" || t === "scrollend"), p = I ? b !== null ? b + "Capture" : null : b;
          I = [];
          for (var h = v, y; h !== null; ) {
            var E = h;
            if (y = E.stateNode, E = E.tag, E !== 5 && E !== 26 && E !== 27 || y === null || p === null || (E = Kl(h, p), E != null && I.push(
              Ci(h, E, y)
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
          if (b = t === "mouseover" || t === "pointerover", T = t === "mouseout" || t === "pointerout", b && l !== fn && (Y = l.relatedTarget || l.fromElement) && (cl(Y) || Y[Xl]))
            break t;
          if ((T || b) && (b = M.window === M ? M : (b = M.ownerDocument) ? b.defaultView || b.parentWindow : window, T ? (Y = l.relatedTarget || l.toElement, T = v, Y = Y ? cl(Y) : null, Y !== null && (jt = k(Y), I = Y.tag, Y !== jt || I !== 5 && I !== 27 && I !== 6) && (Y = null)) : (T = null, Y = v), T !== Y)) {
            if (I = Ra, E = "onMouseLeave", p = "onMouseEnter", h = "mouse", (t === "pointerout" || t === "pointerover") && (I = Eo, E = "onPointerLeave", p = "onPointerEnter", h = "pointer"), jt = T == null ? b : ol(T), y = Y == null ? b : ol(Y), b = new I(
              E,
              h + "leave",
              T,
              l,
              M
            ), b.target = jt, b.relatedTarget = y, E = null, cl(M) === v && (I = new I(
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
            T !== null && pd(
              O,
              b,
              T,
              I,
              !1
            ), Y !== null && jt !== null && pd(
              O,
              jt,
              Y,
              I,
              !0
            );
          }
        }
        t: {
          if (b = v ? ol(v) : window, T = b.nodeName && b.nodeName.toLowerCase(), T === "select" || T === "input" && b.type === "file")
            var At = Bo;
          else if (Uo(b))
            if (No)
              At = jm;
            else {
              At = wm;
              var V = Nm;
            }
          else
            T = b.nodeName, !T || T.toLowerCase() !== "input" || b.type !== "checkbox" && b.type !== "radio" ? v && zt(v.elementType) && (At = Bo) : At = Hm;
          if (At && (At = At(t, v))) {
            Ro(
              O,
              At,
              l,
              M
            );
            break t;
          }
          V && V(t, b, v), t === "focusout" && v && b.type === "number" && v.memoizedProps.value != null && d(b, "number", b.value);
        }
        switch (V = v ? ol(v) : window, t) {
          case "focusin":
            (Uo(V) || V.contentEditable === "true") && (dn = V, Af = v, ii = null);
            break;
          case "focusout":
            ii = Af = dn = null;
            break;
          case "mousedown":
            _f = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            _f = !1, Xo(O, l, M);
            break;
          case "selectionchange":
            if (Gm) break;
          case "keydown":
          case "keyup":
            Xo(O, l, M);
        }
        var st;
        if (Tf)
          t: {
            switch (t) {
              case "compositionstart":
                var bt = "onCompositionStart";
                break t;
              case "compositionend":
                bt = "onCompositionEnd";
                break t;
              case "compositionupdate":
                bt = "onCompositionUpdate";
                break t;
            }
            bt = void 0;
          }
        else
          sn ? Oo(t, l) && (bt = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (bt = "onCompositionStart");
        bt && (Ao && l.locale !== "ko" && (sn || bt !== "onCompositionStart" ? bt === "onCompositionEnd" && sn && (st = ti()) : (Pe = M, Pn = "value" in Pe ? Pe.value : Pe.textContent, sn = !0)), V = Ku(v, bt), 0 < V.length && (bt = new _e(
          bt,
          t,
          null,
          l,
          M
        ), O.push({ event: bt, listeners: V }), st ? bt.data = st : (st = Co(l), st !== null && (bt.data = st)))), (st = Om ? Cm(t, l) : Um(t, l)) && (bt = Ku(v, "onBeforeInput"), 0 < bt.length && (V = new _e(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          M
        ), O.push({
          event: V,
          listeners: bt
        }), V.data = st)), Th(
          O,
          t,
          v,
          l,
          M
        );
      }
      hd(O, e);
    });
  }
  function Ci(t, e, l) {
    return {
      instance: t,
      listener: e,
      currentTarget: l
    };
  }
  function Ku(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, i = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = Kl(t, l), n != null && a.unshift(
        Ci(t, n, i)
      ), n = Kl(t, e), n != null && a.push(
        Ci(t, n, i)
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
  function pd(t, e, l, a, n) {
    for (var i = e._reactName, u = []; l !== null && l !== a; ) {
      var c = l, r = c.alternate, v = c.stateNode;
      if (c = c.tag, r !== null && r === a) break;
      c !== 5 && c !== 26 && c !== 27 || v === null || (r = v, n ? (v = Kl(l, i), v != null && u.unshift(
        Ci(l, v, r)
      )) : n || (v = Kl(l, i), v != null && u.push(
        Ci(l, v, r)
      ))), l = l.return;
    }
    u.length !== 0 && t.push({ event: e, listeners: u });
  }
  var _h = /\r\n?/g, Dh = /\u0000|\uFFFD/g;
  function yd(t) {
    return (typeof t == "string" ? t : "" + t).replace(_h, `
`).replace(Dh, "");
  }
  function vd(t, e) {
    return e = yd(e), yd(t) === e;
  }
  function Ht(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || j(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && j(t, "" + a);
        break;
      case "className":
        an(t, "class", a);
        break;
      case "tabIndex":
        an(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        an(t, l, a);
        break;
      case "style":
        xt(t, a, i);
        break;
      case "data":
        if (e !== "object") {
          an(t, "data", a);
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
        a = un("" + a), t.setAttribute(l, a);
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
        a = un("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = $e);
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
        l = un("" + a), t.setAttributeNS(
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
        pt("beforetoggle", t), pt("toggle", t), Ma(t, "popover", a);
        break;
      case "xlinkActuate":
        Te(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:actuate",
          a
        );
        break;
      case "xlinkArcrole":
        Te(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:arcrole",
          a
        );
        break;
      case "xlinkRole":
        Te(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:role",
          a
        );
        break;
      case "xlinkShow":
        Te(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:show",
          a
        );
        break;
      case "xlinkTitle":
        Te(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:title",
          a
        );
        break;
      case "xlinkType":
        Te(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:type",
          a
        );
        break;
      case "xmlBase":
        Te(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:base",
          a
        );
        break;
      case "xmlLang":
        Te(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:lang",
          a
        );
        break;
      case "xmlSpace":
        Te(
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
  function Ic(t, e, l, a, n, i) {
    switch (l) {
      case "style":
        xt(t, a, i);
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
        typeof a == "string" ? j(t, a) : (typeof a == "number" || typeof a == "bigint") && j(t, "" + a);
        break;
      case "onScroll":
        a != null && pt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && pt("scrollend", t);
        break;
      case "onClick":
        a != null && (t.onclick = $e);
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
        if (!Wn.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[de] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : Ma(t, l, a);
          }
    }
  }
  function ye(t, e, l) {
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
        o(
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
        e = i, l = u, t.multiple = !!a, e != null ? x(t, !!a, e, !1) : l != null && x(t, !!a, l, !0);
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
        H(t, a, n, i);
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
        for (a = 0; a < Oi.length; a++)
          pt(Oi[a], t);
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
        if (zt(e)) {
          for (M in l)
            l.hasOwnProperty(M) && (a = l[M], a !== void 0 && Ic(
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
        e = c, l = u, a = T, b != null ? x(t, !!l, b, !1) : !!a != !!l && (e != null ? x(t, !!l, e, !0) : x(t, !!l, l ? [] : "", !1));
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
        B(t, b, T);
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
        if (zt(e)) {
          for (var jt in l)
            b = l[jt], l.hasOwnProperty(jt) && b !== void 0 && !a.hasOwnProperty(jt) && Ic(
              t,
              e,
              jt,
              void 0,
              a,
              b
            );
          for (M in a)
            b = a[M], T = l[M], !a.hasOwnProperty(M) || b === T || b === void 0 && T === void 0 || Ic(
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
  function bd(t) {
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
        if (i && c && bd(u)) {
          for (u = 0, c = n.responseEnd, a += 1; a < l.length; a++) {
            var r = l[a], v = r.startTime;
            if (v > c) break;
            var M = r.transferSize, O = r.initiatorType;
            M && bd(O) && (r = r.responseEnd, u += M * (r < c ? 1 : (c - v) / (r - v)));
          }
          if (--a, e += 8 * (i + u) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var Pc = null, to = null;
  function Ju(t) {
    return t.nodeType === 9 ? t : t.ownerDocument;
  }
  function xd(t) {
    switch (t) {
      case "http://www.w3.org/2000/svg":
        return 1;
      case "http://www.w3.org/1998/Math/MathML":
        return 2;
      default:
        return 0;
    }
  }
  function Sd(t, e) {
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
  function eo(t, e) {
    return t === "textarea" || t === "noscript" || typeof e.children == "string" || typeof e.children == "number" || typeof e.children == "bigint" || typeof e.dangerouslySetInnerHTML == "object" && e.dangerouslySetInnerHTML !== null && e.dangerouslySetInnerHTML.__html != null;
  }
  var lo = null;
  function Uh() {
    var t = window.event;
    return t && t.type === "popstate" ? t === lo ? !1 : (lo = t, !0) : (lo = null, !1);
  }
  var Td = typeof setTimeout == "function" ? setTimeout : void 0, Rh = typeof clearTimeout == "function" ? clearTimeout : void 0, zd = typeof Promise == "function" ? Promise : void 0, Bh = typeof queueMicrotask == "function" ? queueMicrotask : typeof zd < "u" ? function(t) {
    return zd.resolve(null).then(t).catch(Nh);
  } : Td;
  function Nh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function sa(t) {
    return t === "head";
  }
  function Md(t, e) {
    var l = e, a = 0;
    do {
      var n = l.nextSibling;
      if (t.removeChild(l), n && n.nodeType === 8)
        if (l = n.data, l === "/$" || l === "/&") {
          if (a === 0) {
            t.removeChild(n), Gn(e);
            return;
          }
          a--;
        } else if (l === "$" || l === "$?" || l === "$~" || l === "$!" || l === "&")
          a++;
        else if (l === "html")
          Ui(t.ownerDocument.documentElement);
        else if (l === "head") {
          l = t.ownerDocument.head, Ui(l);
          for (var i = l.firstChild; i; ) {
            var u = i.nextSibling, c = i.nodeName;
            i[Ql] || c === "SCRIPT" || c === "STYLE" || c === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && Ui(t.ownerDocument.body);
      l = n;
    } while (l);
    Gn(e);
  }
  function Ed(t, e) {
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
  function ao(t) {
    var e = t.firstChild;
    for (e && e.nodeType === 10 && (e = e.nextSibling); e; ) {
      var l = e;
      switch (e = e.nextSibling, l.nodeName) {
        case "HTML":
        case "HEAD":
        case "BODY":
          ao(l), za(l);
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
      if (t = Fe(t.nextSibling), t === null) break;
    }
    return null;
  }
  function Hh(t, e, l) {
    if (e === "") return null;
    for (; t.nodeType !== 3; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !l || (t = Fe(t.nextSibling), t === null)) return null;
    return t;
  }
  function Ad(t, e) {
    for (; t.nodeType !== 8; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !e || (t = Fe(t.nextSibling), t === null)) return null;
    return t;
  }
  function no(t) {
    return t.data === "$?" || t.data === "$~";
  }
  function io(t) {
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
  function Fe(t) {
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
  function _d(t) {
    t = t.nextSibling;
    for (var e = 0; t; ) {
      if (t.nodeType === 8) {
        var l = t.data;
        if (l === "/$" || l === "/&") {
          if (e === 0)
            return Fe(t.nextSibling);
          e--;
        } else
          l !== "$" && l !== "$!" && l !== "$?" && l !== "$~" && l !== "&" || e++;
      }
      t = t.nextSibling;
    }
    return null;
  }
  function Dd(t) {
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
  function Od(t, e, l) {
    switch (e = Ju(l), t) {
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
  function Ui(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    za(t);
  }
  var We = /* @__PURE__ */ new Map(), Cd = /* @__PURE__ */ new Set();
  function ku(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var Yl = U.d;
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
    var t = Yl.f(), e = Gu();
    return t || e;
  }
  function Gh(t) {
    var e = bl(t);
    e !== null && e.tag === 5 && e.type === "form" ? Jr(e) : Yl.r(t);
  }
  var Hn = typeof document > "u" ? null : document;
  function Ud(t, e, l) {
    var a = Hn;
    if (a && typeof e == "string" && e) {
      var n = Ae(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Cd.has(n) || (Cd.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), ye(e, "link", t), Wt(e), a.head.appendChild(e)));
    }
  }
  function Yh(t) {
    Yl.D(t), Ud("dns-prefetch", t, null);
  }
  function Lh(t, e) {
    Yl.C(t, e), Ud("preconnect", t, e);
  }
  function Xh(t, e, l) {
    Yl.L(t, e, l);
    var a = Hn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + Ae(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + Ae(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + Ae(
        l.imageSizes
      ) + '"]')) : n += '[href="' + Ae(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = jn(t);
          break;
        case "script":
          i = qn(t);
      }
      We.has(i) || (t = w(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), We.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Ri(i)) || e === "script" && a.querySelector(Bi(i)) || (e = a.createElement("link"), ye(e, "link", t), Wt(e), a.head.appendChild(e)));
    }
  }
  function Qh(t, e) {
    Yl.m(t, e);
    var l = Hn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + Ae(a) + '"][href="' + Ae(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = qn(t);
      }
      if (!We.has(i) && (t = w({ rel: "modulepreload", href: t }, e), We.set(i, t), l.querySelector(n) === null)) {
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
        a = l.createElement("link"), ye(a, "link", t), Wt(a), l.head.appendChild(a);
      }
    }
  }
  function Vh(t, e, l) {
    Yl.S(t, e, l);
    var a = Hn;
    if (a && t) {
      var n = xl(a).hoistableStyles, i = jn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var c = { loading: 0, preload: null };
        if (u = a.querySelector(
          Ri(i)
        ))
          c.loading = 5;
        else {
          t = w(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = We.get(i)) && fo(t, l);
          var r = u = a.createElement("link");
          Wt(r), ye(r, "link", t), r._p = new Promise(function(v, M) {
            r.onload = v, r.onerror = M;
          }), r.addEventListener("load", function() {
            c.loading |= 1;
          }), r.addEventListener("error", function() {
            c.loading |= 2;
          }), c.loading |= 4, Fu(u, e, a);
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
    Yl.X(t, e);
    var l = Hn;
    if (l && t) {
      var a = xl(l).hoistableScripts, n = qn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = w({ src: t, async: !0 }, e), (e = We.get(n)) && co(t, e), i = l.createElement("script"), Wt(i), ye(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Kh(t, e) {
    Yl.M(t, e);
    var l = Hn;
    if (l && t) {
      var a = xl(l).hoistableScripts, n = qn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = w({ src: t, async: !0, type: "module" }, e), (e = We.get(n)) && co(t, e), i = l.createElement("script"), Wt(i), ye(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Rd(t, e, l, a) {
    var n = (n = ct.current) ? ku(n) : null;
    if (!n) throw Error(s(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = jn(l.href), l = xl(
          n
        ).hoistableStyles, a = l.get(e), a || (a = {
          type: "style",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      case "link":
        if (l.rel === "stylesheet" && typeof l.href == "string" && typeof l.precedence == "string") {
          t = jn(l.href);
          var i = xl(
            n
          ).hoistableStyles, u = i.get(t);
          if (u || (n = n.ownerDocument || n, u = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, i.set(t, u), (i = n.querySelector(
            Ri(t)
          )) && !i._p && (u.instance = i, u.state.loading = 5), We.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, We.set(t, l), i || Jh(
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
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = qn(l), l = xl(
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
  function jn(t) {
    return 'href="' + Ae(t) + '"';
  }
  function Ri(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Bd(t) {
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
    }), ye(e, "link", l), Wt(e), t.head.appendChild(e));
  }
  function qn(t) {
    return '[src="' + Ae(t) + '"]';
  }
  function Bi(t) {
    return "script[async]" + t;
  }
  function Nd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + Ae(l.href) + '"]'
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
          ), Wt(a), ye(a, "style", n), Fu(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = jn(l.href);
          var i = t.querySelector(
            Ri(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, Wt(i), i;
          a = Bd(l), (n = We.get(n)) && fo(a, n), i = (t.ownerDocument || t).createElement("link"), Wt(i);
          var u = i;
          return u._p = new Promise(function(c, r) {
            u.onload = c, u.onerror = r;
          }), ye(i, "link", a), e.state.loading |= 4, Fu(i, l.precedence, t), e.instance = i;
        case "script":
          return i = qn(l.src), (n = t.querySelector(
            Bi(i)
          )) ? (e.instance = n, Wt(n), n) : (a = l, (n = We.get(i)) && (a = w({}, l), co(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Wt(n), ye(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(s(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, Fu(a, l.precedence, t));
    return e.instance;
  }
  function Fu(t, e, l) {
    for (var a = l.querySelectorAll(
      'link[rel="stylesheet"][data-precedence],style[data-precedence]'
    ), n = a.length ? a[a.length - 1] : null, i = n, u = 0; u < a.length; u++) {
      var c = a[u];
      if (c.dataset.precedence === e) i = c;
      else if (i !== n) break;
    }
    i ? i.parentNode.insertBefore(t, i.nextSibling) : (e = l.nodeType === 9 ? l.head : l, e.insertBefore(t, e.firstChild));
  }
  function fo(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.title == null && (t.title = e.title);
  }
  function co(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.integrity == null && (t.integrity = e.integrity);
  }
  var Wu = null;
  function wd(t, e, l) {
    if (Wu === null) {
      var a = /* @__PURE__ */ new Map(), n = Wu = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = Wu, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var i = l[n];
      if (!(i[Ql] || i[te] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
        var u = i.getAttribute(e) || "";
        u = t + u;
        var c = a.get(u);
        c ? c.push(i) : a.set(u, [i]);
      }
    }
    return a;
  }
  function Hd(t, e, l) {
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
  function jd(t) {
    return !(t.type === "stylesheet" && (t.state.loading & 3) === 0);
  }
  function Fh(t, e, l, a) {
    if (l.type === "stylesheet" && (typeof a.media != "string" || matchMedia(a.media).matches !== !1) && (l.state.loading & 4) === 0) {
      if (l.instance === null) {
        var n = jn(a.href), i = e.querySelector(
          Ri(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = $u.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, Wt(i);
          return;
        }
        i = e.ownerDocument || e, a = Bd(a), (n = We.get(n)) && fo(a, n), i = i.createElement("link"), Wt(i);
        var u = i;
        u._p = new Promise(function(c, r) {
          u.onload = c, u.onerror = r;
        }), ye(i, "link", a), l.instance = i;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = $u.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var oo = 0;
  function Wh(t, e) {
    return t.stylesheets && t.count === 0 && Pu(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && Pu(t, t.stylesheets), t.unsuspend) {
          var i = t.unsuspend;
          t.unsuspend = null, i();
        }
      }, 6e4 + e);
      0 < t.imgBytes && oo === 0 && (oo = 62500 * Ch());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && Pu(t, t.stylesheets), t.unsuspend)) {
            var i = t.unsuspend;
            t.unsuspend = null, i();
          }
        },
        (t.imgBytes > oo ? 50 : 800) + e
      );
      return t.unsuspend = l, function() {
        t.unsuspend = null, clearTimeout(a), clearTimeout(n);
      };
    } : null;
  }
  function $u() {
    if (this.count--, this.count === 0 && (this.imgCount === 0 || !this.waitingForImages)) {
      if (this.stylesheets) Pu(this, this.stylesheets);
      else if (this.unsuspend) {
        var t = this.unsuspend;
        this.unsuspend = null, t();
      }
    }
  }
  var Iu = null;
  function Pu(t, e) {
    t.stylesheets = null, t.unsuspend !== null && (t.count++, Iu = /* @__PURE__ */ new Map(), e.forEach($h, t), Iu = null, $u.call(t));
  }
  function $h(t, e) {
    if (!(e.state.loading & 4)) {
      var l = Iu.get(t);
      if (l) var a = l.get(null);
      else {
        l = /* @__PURE__ */ new Map(), Iu.set(t, l);
        for (var n = t.querySelectorAll(
          "link[data-precedence],style[data-precedence]"
        ), i = 0; i < n.length; i++) {
          var u = n[i];
          (u.nodeName === "LINK" || u.getAttribute("media") !== "not all") && (l.set(u.dataset.precedence, u), a = u);
        }
        a && l.set(null, a);
      }
      n = e.instance, u = n.getAttribute("data-precedence"), i = l.get(u) || a, i === a && l.set(null, n), l.set(u, n), this.count++, a = $u.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), i ? i.parentNode.insertBefore(n, i.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Ni = {
    $$typeof: mt,
    Provider: null,
    Consumer: null,
    _currentValue: Z,
    _currentValue2: Z,
    _threadCount: 0
  };
  function Ih(t, e, l, a, n, i, u, c, r) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Kn(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Kn(0), this.hiddenUpdates = Kn(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = r, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function qd(t, e, l, a, n, i, u, c, r, v, M, O) {
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
    ), e = 1, i === !0 && (e |= 24), i = He(3, null, null, e), t.current = i, i.stateNode = t, e = Xf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Kf(i), t;
  }
  function Gd(t) {
    return t ? (t = gn, t) : gn;
  }
  function Yd(t, e, l, a, n, i) {
    n = Gd(n), a.context === null ? a.context = n : a.pendingContext = n, a = ta(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = ea(t, a, e), l !== null && (Re(l, t, e), di(l, t, e));
  }
  function Ld(t, e) {
    if (t = t.memoizedState, t !== null && t.dehydrated !== null) {
      var l = t.retryLane;
      t.retryLane = l !== 0 && l < e ? l : e;
    }
  }
  function ro(t, e) {
    Ld(t, e), (t = t.alternate) && Ld(t, e);
  }
  function Xd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Ha(t, 67108864);
      e !== null && Re(e, t, 67108864), ro(t, 67108864);
    }
  }
  function Qd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Le();
      e = Ta(e);
      var l = Ha(t, e);
      l !== null && Re(l, t, e), ro(t, e);
    }
  }
  var tf = !0;
  function Ph(t, e, l, a) {
    var n = g.T;
    g.T = null;
    var i = U.p;
    try {
      U.p = 2, so(t, e, l, a);
    } finally {
      U.p = i, g.T = n;
    }
  }
  function tg(t, e, l, a) {
    var n = g.T;
    g.T = null;
    var i = U.p;
    try {
      U.p = 8, so(t, e, l, a);
    } finally {
      U.p = i, g.T = n;
    }
  }
  function so(t, e, l, a) {
    if (tf) {
      var n = mo(a);
      if (n === null)
        $c(
          t,
          e,
          a,
          ef,
          l
        ), Zd(t, a);
      else if (lg(
        n,
        t,
        e,
        l,
        a
      ))
        a.stopPropagation();
      else if (Zd(t, a), e & 4 && -1 < eg.indexOf(t)) {
        for (; n !== null; ) {
          var i = bl(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = il(i.pendingLanes);
                  if (u !== 0) {
                    var c = i;
                    for (c.pendingLanes |= 2, c.entangledLanes |= 2; u; ) {
                      var r = 1 << 31 - ue(u);
                      c.entanglements[1] |= r, u &= ~r;
                    }
                    hl(i), (Ot & 6) === 0 && (ju = se() + 500, Di(0));
                  }
                }
                break;
              case 31:
              case 13:
                c = Ha(i, 2), c !== null && Re(c, i, 2), Gu(), ro(i, 2);
            }
          if (i = mo(a), i === null && $c(
            t,
            e,
            a,
            ef,
            l
          ), i === n) break;
          n = i;
        }
        n !== null && a.stopPropagation();
      } else
        $c(
          t,
          e,
          a,
          null,
          l
        );
    }
  }
  function mo(t) {
    return t = In(t), ho(t);
  }
  var ef = null;
  function ho(t) {
    if (ef = null, t = cl(t), t !== null) {
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
    return ef = t, null;
  }
  function Vd(t) {
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
        switch (Xi()) {
          case Qi:
            return 2;
          case $a:
            return 8;
          case va:
          case sf:
            return 32;
          case Vi:
            return 268435456;
          default:
            return 32;
        }
      default:
        return 32;
    }
  }
  var go = !1, da = null, ma = null, ha = null, wi = /* @__PURE__ */ new Map(), Hi = /* @__PURE__ */ new Map(), ga = [], eg = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Zd(t, e) {
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
        wi.delete(e.pointerId);
        break;
      case "gotpointercapture":
      case "lostpointercapture":
        Hi.delete(e.pointerId);
    }
  }
  function ji(t, e, l, a, n, i) {
    return t === null || t.nativeEvent !== i ? (t = {
      blockedOn: e,
      domEventName: l,
      eventSystemFlags: a,
      nativeEvent: i,
      targetContainers: [n]
    }, e !== null && (e = bl(e), e !== null && Xd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function lg(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return da = ji(
          da,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return ma = ji(
          ma,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return ha = ji(
          ha,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "pointerover":
        var i = n.pointerId;
        return wi.set(
          i,
          ji(
            wi.get(i) || null,
            t,
            e,
            l,
            a,
            n
          )
        ), !0;
      case "gotpointercapture":
        return i = n.pointerId, Hi.set(
          i,
          ji(
            Hi.get(i) || null,
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
  function Kd(t) {
    var e = cl(t.target);
    if (e !== null) {
      var l = k(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = Q(l), e !== null) {
            t.blockedOn = e, kn(t.priority, function() {
              Qd(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = lt(l), e !== null) {
            t.blockedOn = e, kn(t.priority, function() {
              Qd(l);
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
  function lf(t) {
    if (t.blockedOn !== null) return !1;
    for (var e = t.targetContainers; 0 < e.length; ) {
      var l = mo(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        fn = a, l.target.dispatchEvent(a), fn = null;
      } else
        return e = bl(l), e !== null && Xd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function Jd(t, e, l) {
    lf(t) && l.delete(e);
  }
  function ag() {
    go = !1, da !== null && lf(da) && (da = null), ma !== null && lf(ma) && (ma = null), ha !== null && lf(ha) && (ha = null), wi.forEach(Jd), Hi.forEach(Jd);
  }
  function af(t, e) {
    t.blockedOn === e && (t.blockedOn = null, go || (go = !0, S.unstable_scheduleCallback(
      S.unstable_NormalPriority,
      ag
    )));
  }
  var nf = null;
  function kd(t) {
    nf !== t && (nf = t, S.unstable_scheduleCallback(
      S.unstable_NormalPriority,
      function() {
        nf === t && (nf = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (ho(a || l) === null)
              continue;
            break;
          }
          var i = bl(l);
          i !== null && (t.splice(e, 3), e -= 3, dc(
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
  function Gn(t) {
    function e(r) {
      return af(r, t);
    }
    da !== null && af(da, t), ma !== null && af(ma, t), ha !== null && af(ha, t), wi.forEach(e), Hi.forEach(e);
    for (var l = 0; l < ga.length; l++) {
      var a = ga[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < ga.length && (l = ga[0], l.blockedOn === null); )
      Kd(l), l.blockedOn === null && ga.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[de] || null;
        if (typeof i == "function")
          u || kd(l);
        else if (u) {
          var c = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[de] || null)
              c = u.formAction;
            else if (ho(n) !== null) continue;
          } else c = u.action;
          typeof c == "function" ? l[a + 1] = c : (l.splice(a, 3), a -= 3), kd(l);
        }
      }
  }
  function Fd() {
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
  function po(t) {
    this._internalRoot = t;
  }
  uf.prototype.render = po.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(s(409));
    var l = e.current, a = Le();
    Yd(l, a, t, e, null, null);
  }, uf.prototype.unmount = po.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      Yd(t.current, 2, null, t, null, null), Gu(), e[Xl] = null;
    }
  };
  function uf(t) {
    this._internalRoot = t;
  }
  uf.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = Fi();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < ga.length && e !== 0 && e < ga[l].priority; l++) ;
      ga.splice(l, 0, t), l === 0 && Kd(t);
    }
  };
  var Wd = f.version;
  if (Wd !== "19.2.3")
    throw Error(
      s(
        527,
        Wd,
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
    var ff = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!ff.isDisabled && ff.supportsFiber)
      try {
        ba = ff.inject(
          ng
        ), xe = ff;
      } catch {
      }
  }
  return Gi.createRoot = function(t, e) {
    if (!G(t)) throw Error(s(299));
    var l = !1, a = "", n = as, i = ns, u = is;
    return e != null && (e.unstable_strictMode === !0 && (l = !0), e.identifierPrefix !== void 0 && (a = e.identifierPrefix), e.onUncaughtError !== void 0 && (n = e.onUncaughtError), e.onCaughtError !== void 0 && (i = e.onCaughtError), e.onRecoverableError !== void 0 && (u = e.onRecoverableError)), e = qd(
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
      Fd
    ), t[Xl] = e.current, Wc(t), new po(e);
  }, Gi.hydrateRoot = function(t, e, l) {
    if (!G(t)) throw Error(s(299));
    var a = !1, n = "", i = as, u = ns, c = is, r = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (i = l.onUncaughtError), l.onCaughtError !== void 0 && (u = l.onCaughtError), l.onRecoverableError !== void 0 && (c = l.onRecoverableError), l.formState !== void 0 && (r = l.formState)), e = qd(
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
      Fd
    ), e.context = Gd(null), l = e.current, a = Le(), a = Ta(a), n = ta(a), n.callback = null, ea(l, n, a), l = a, e.current.lanes = l, ul(e, l), hl(e), t[Xl] = e.current, Wc(t), new uf(e);
  }, Gi.version = "19.2.3", Gi;
}
var um;
function hg() {
  if (um) return vo.exports;
  um = 1;
  function S() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(S);
      } catch (f) {
        console.error(f);
      }
  }
  return S(), vo.exports = mg(), vo.exports;
}
var gg = hg(), zo = { exports: {} }, Mo = {};
var fm;
function pg() {
  if (fm) return Mo;
  fm = 1;
  var S = of().__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  return Mo.c = function(f) {
    return S.H.useMemoCache(f);
  }, Mo;
}
var cm;
function yg() {
  return cm || (cm = 1, zo.exports = pg()), zo.exports;
}
var Wa = yg(), vg = of();
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
function om() {
  return !1;
}
function rm(S, f = {}) {
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
function sm(S) {
  const f = {
    ...xg,
    ...S?.themes?.light
  }, D = {
    ...Sg,
    ...S?.themes?.dark
  };
  return {
    backgroundOpacity: mm(S?.backgroundOpacity),
    fontFamily: S?.fontFamily ?? "Menlo",
    fontSize: cf(S?.fontSize, 10),
    lineHeight: cf(S?.lineHeight, 20),
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
function dm(S) {
  if (!S)
    return;
  const f = S.themes?.light ?? {}, D = S.themes?.dark ?? {}, s = document.documentElement.style;
  s.setProperty("--cmux-diff-bg-light", Fa(f.background, "#ffffff")), s.setProperty("--cmux-diff-bg-dark", Fa(D.background, "#000000")), s.setProperty("--cmux-diff-fg-light", Fa(f.foreground, "#000000")), s.setProperty("--cmux-diff-fg-dark", Fa(D.foreground, "#ffffff")), s.setProperty("--cmux-diff-selection-bg-light", Fa(f.selectionBackground, "#abd8ff")), s.setProperty("--cmux-diff-selection-bg-dark", Fa(D.selectionBackground, "#3f638b")), s.setProperty("--cmux-diff-code-font-family", zg(S.fontFamily)), s.setProperty("--cmux-diff-font-size", `${cf(S.fontSize, 10)}px`), s.setProperty("--cmux-diff-line-height", `${cf(S.lineHeight, 20)}px`);
}
function Tg(S, f) {
  return mm(f?.backgroundOpacity) < 0.999 ? "transparent" : Fa(S, "#000000");
}
function Fa(S, f) {
  return typeof S == "string" && S.trim() !== "" ? S.trim() : f;
}
function zg(S) {
  const f = typeof S == "string" && S.trim() !== "" ? S.trim() : "Menlo";
  return `${JSON.stringify(f)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
}
function cf(S, f) {
  return typeof S == "number" && Number.isFinite(S) && S > 0 ? S : f;
}
function mm(S) {
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
  }, G = s(D.diffsModuleURL, "diffsModuleURL"), k = s(D.treesModuleURL, "treesModuleURL"), Q = s(D.workerPoolModuleURL, "workerPoolModuleURL"), lt = s(D.workerModuleURL, "workerModuleURL"), C = S.payload ?? {}, z = sm(C.appearance), L = f("viewer"), w = f("status"), tt = f("toolbar"), rt = f("source-select"), dt = f("repo-select"), yt = f("base-select"), Gt = f("source-detail"), ft = f("jump-select"), Yt = f("external-link"), mt = f("files-toggle"), Dt = f("layout-toggle"), Ct = f("options-button"), ht = f("options-menu"), $ = f("files-sidebar"), Ut = f("file-list"), Pt = f("files-count"), Ft = f("file-search-toggle"), Vt = f("file-collapse-toggle"), Zt = f("stats-files"), re = f("stats-added"), ie = f("stats-deleted"), X = rm(C.labels, {
    assertMissing: om()
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
  let N = /* @__PURE__ */ new Set(), q = null, at = null, ct = /* @__PURE__ */ new Map(), Tt = {
    value: null
  }, ce = "", Rt = "", gl = !1, Xe = /* @__PURE__ */ new Map(), al = /* @__PURE__ */ new Map();
  typeof C.title == "string" && C.title.trim() !== "" && (document.title = C.title), dm(z), xe(), fl(C.sourceOptions ?? []), de(dt, C.repoOptions ?? [], C.repoRoot ?? "", X("repoPath")), de(yt, C.baseOptions ?? [], C.branchBaseRef ?? "", X("branchBase"));
  const Yn = globalThis.queueMicrotask ?? ((o) => setTimeout(o, 0));
  C.pendingReplacement === !0 ? (Be(C.statusMessage ?? X("loadingDiff"), {
    loading: !0,
    pending: !0
  }), Yi()) : typeof C.statusMessage == "string" && C.statusMessage.length > 0 ? Be(C.statusMessage, {
    error: C.statusIsError === !0,
    loading: !1,
    statusOnly: !0
  }) : Yn(() => {
    pl().catch((o) => {
      console.error("cmux diff viewer render failed", o), Be(X("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      });
    });
  });
  async function pl() {
    Be(X("loadingRenderer"), {
      loading: !0
    });
    const [{
      CodeView: o,
      getFiletypeFromFileName: d,
      parsePatchFiles: x,
      preloadHighlighter: B,
      processFile: H,
      registerCustomTheme: j
    }, J] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(G),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(k).catch((xt) => (console.warn("cmux diff file tree import failed", xt), null))
    ]);
    if (nn(j, z.themes.light), nn(j, z.themes.dark), Be(X("parsingDiff"), {
      loading: !0
    }), ya("loading"), Z = await Xn(), Tl(et), Se(), window.__cmuxDiffViewer = {
      codeView: U,
      items: et,
      state: g,
      workerPool: Z
    }, Qn(Z), Z?.initialize?.()?.then?.(() => Vn(Z?.getStats?.()))?.catch?.((xt) => console.warn("cmux diff worker pool initialization failed", xt)), window.addEventListener("pagehide", () => Z?.terminate?.(), {
      once: !0
    }), await Qi({
      CodeView: o,
      parsePatchFiles: x,
      processFile: H,
      treesModule: J
    }), et.length === 0)
      throw new Error(X("noFileDiffs"));
    Z || Ae(z, m.length > 0 ? m : et, d, B).catch((xt) => console.warn("cmux diff highlighter preload failed", xt));
  }
  function Be(o, d = {}) {
    w.isConnected || L.replaceChildren(w), document.body.dataset.loading = d.loading === !0 || d.pending === !0 ? "true" : "false", document.body.dataset.statusOnly = d.statusOnly === !0 ? "true" : "false", w.dataset.error = d.error === !0 ? "true" : "false", w.dataset.pending = d.pending === !0 ? "true" : "false", w.textContent = o;
  }
  function Ln(o) {
    document.open(), document.write(o), document.close();
  }
  async function rf(o) {
    if (!o.ok)
      return Be(X("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      }), !1;
    const d = await o.text();
    return d.includes('data-cmux-diff-pending="true"') ? !1 : (Ln(d), !0);
  }
  async function Yi() {
    try {
      const o = await fetch("/__cmux_diff_viewer_wait" + location.pathname, {
        cache: "no-store"
      });
      await rf(o);
    } catch (o) {
      document.documentElement.dataset.cmuxDiffWait = "failed", Be(X("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      }), console.warn("cmux diff viewer deferred load failed", o);
    }
  }
  async function Xn() {
    if (typeof Worker > "u")
      return null;
    try {
      const o = await import(Q);
      nn(o.registerCustomTheme, z.themes.light), nn(o.registerCustomTheme, z.themes.dark);
      const d = new URL(lt, window.location.href).href;
      return o.createDiffWorkerPool({
        workerURL: d,
        highlighterOptions: Li()
      }) ?? null;
    } catch (o) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", o), null;
    }
  }
  function Qn(o) {
    if (!o) {
      ya("fallback");
      return;
    }
    ya("enabled"), Vn(o.getStats?.());
    const d = o.subscribeToStatChanges?.((x) => {
      Vn(x);
    });
    typeof d == "function" && window.addEventListener("pagehide", d, {
      once: !0
    });
  }
  function ya(o) {
    document.body.dataset.workerPool = o;
  }
  function Vn(o) {
    !o || typeof o != "object" || (typeof o.managerState == "string" && (document.body.dataset.workerPoolState = o.managerState), Number.isFinite(o.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(o.totalWorkers)), typeof o.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(o.workersFailed)));
  }
  function Li() {
    return {
      theme: z.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: g.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const se = /^From\s+([a-f0-9]+)\s/im;
  function Xi(o, d) {
    const x = o?.match(se);
    return x?.[1] ? new TextDecoder().decode(new TextEncoder().encode(x[1].slice(0, 5))) : `${X("commit")} ${d + 1}`;
  }
  async function Qi({
    CodeView: o,
    parsePatchFiles: d,
    processFile: x,
    treesModule: B
  }) {
    const H = sf(), j = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, J = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let nt = performance.now(), xt = performance.now(), zt = !0;
    const Vl = {
      initialBatchSize: Wt(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function vf(_, R) {
      const P = un(H, _, R);
      return P?.renamedItem && Zl(P.renamedItem), P?.item;
    }
    function un(_, R, P) {
      if (!R)
        return null;
      const it = Te(R), Mt = P == null ? it : `${P}/${it}`, Et = it.length === 0 ? void 0 : _.pathStateByTreePath.get(Mt), Kt = Et == null ? void 0 : $e(_, Mt, Et), ze = zl(R), _e = {
        id: _.itemIdToFile.has(Mt) ? fn(_, `${Mt}?2`) : Mt,
        type: "diff",
        fileDiff: R,
        version: 0
      }, au = _.items.length;
      _.fileIndex += 1, _.items.push(_e), _.pendingItems.push(_e), _.pendingItemById.set(_e.id, _e), _.itemIdToFile.set(_e.id, {
        fileOrder: au,
        path: it
      }), _.itemIdByTreePath.set(Mt, _e.id), _.treePathByItemId.set(_e.id, Mt), _.diffStats.addedLines += ze.added, _.diffStats.deletedLines += ze.deleted, _.diffStats.fileCount += 1, _.diffStats.totalLinesOfCode += R.unifiedLineCount ?? R.splitLineCount ?? 0;
      const xf = _.statsByPath.get(Mt);
      return _.statsByPath.set(Mt, ze), Et != null && !eu(xf, ze) && (_.pendingStatsChanged = !0), it.length > 0 && (Et == null && _.paths.push(Mt), _.pathToItemId.set(Mt, _e.id), In(_, Mt, R.type, Et?.sawDeleted === !0), _.pathStateByTreePath.set(Mt, {
        currentItem: _e,
        currentItemId: _e.id,
        currentType: R.type,
        fileOrder: au,
        sawDeleted: Et?.sawDeleted === !0 || R.type === "deleted"
      })), {
        item: _e,
        renamedItem: Kt
      };
    }
    function $e(_, R, P) {
      const it = P.currentItemId, Mt = P.currentType === "deleted" ? "?deleted" : "?previous", Et = fn(_, `${R}${Mt}`);
      if (P.currentItem.id = Et, P.currentItemId = Et, _.itemIdToFile.has(it)) {
        const Kt = _.itemIdToFile.get(it);
        _.itemIdToFile.delete(it), _.itemIdToFile.set(Et, Kt);
      }
      if (_.treePathByItemId.has(it) && (_.treePathByItemId.delete(it), _.treePathByItemId.set(Et, R)), _.pendingItemById.has(it)) {
        const Kt = _.pendingItemById.get(it);
        _.pendingItemById.delete(it), _.pendingItemById.set(Et, Kt);
        return;
      }
      return {
        oldId: it,
        newId: Et
      };
    }
    function fn(_, R) {
      if (!_.itemIdToFile.has(R))
        return R;
      let P = _.nextCollisionSuffixByBase.get(R) ?? 2, it = `${R}-${P}`;
      for (; _.itemIdToFile.has(it); )
        P += 1, it = `${R}-${P}`;
      return _.nextCollisionSuffixByBase.set(R, P + 1), it;
    }
    function In(_, R, P, it) {
      if (it && P !== "deleted") {
        _.gitStatusByPath.delete(R) && Ml(_, R);
        return;
      }
      const Mt = tu(P);
      if (Mt === "modified") {
        _.gitStatusByPath.delete(R) && Ml(_, R);
        return;
      }
      if (_.gitStatusByPath.get(R)?.status === Mt)
        return;
      const Kt = {
        path: R,
        status: Mt
      };
      _.gitStatusByPath.set(R, Kt), _.pendingGitStatusRemovePaths.delete(R), _.pendingGitStatusSetByPath.set(R, Kt);
    }
    function Ml(_, R) {
      _.pendingGitStatusSetByPath.delete(R), _.pendingGitStatusRemovePaths.add(R);
    }
    function Zl(_) {
      if (N.delete(_.oldId) && N.add(_.newId), A.has(_.oldId)) {
        const R = A.get(_.oldId);
        A.delete(_.oldId), R && A.set(_.newId, R);
      }
      Ii(_.oldId, _.newId), U?.updateItemId?.(_.oldId, _.newId);
    }
    async function cn(_, R) {
      vf(_, R) && await Ea(!1);
    }
    async function Ea(_) {
      if (H.pendingItems.length === 0)
        return;
      const R = performance.now();
      if (!_ && zt && R - nt >= 8 && H.pendingItems.length < Vl.initialBatchSize && R - xt < Vl.initialMaxWait) {
        await Zi(), nt = performance.now();
        return;
      }
      const P = zt ? Vl.initialBatchSize : Vl.incrementalBatchSize, it = zt ? Vl.initialMaxWait : Vl.incrementalMaxWait;
      if (_ || H.pendingItems.length >= P || R - xt >= it) {
        lu(), await Zi(), nt = performance.now();
        return;
      }
    }
    function lu() {
      if (H.pendingItems.length === 0)
        return;
      const _ = H.pendingItems.splice(0, H.pendingItems.length);
      H.pendingItemById.clear();
      const R = _, P = m.length > 0;
      et.push(..._);
      for (const it of _)
        A.set(it.id, it);
      if (R.length > 0) {
        m.push(...R);
        for (const it of R)
          N.add(it.id);
        U ? U.addItems(R) : (U = new o(xa(), Z ?? void 0), U.setup(L), U.setItems(m), U.render(!0), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.codeView = U));
      }
      pf(_), Ne(B, !1, _.length), J.flushCount += 1, J.maxBatchSize = Math.max(J.maxBatchSize, _.length), J.fileCount = et.length, J.renderableFileCount = m.length, $a(J), xt = performance.now(), zt && (zt = !1, document.body.dataset.loading = "false", w.remove()), P || Ma(m[0]?.id ?? et[0]?.id ?? ""), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.items = et, window.__cmuxDiffViewer.codeViewItems = m, window.__cmuxDiffViewer.streamMetrics = J);
    }
    function Kl() {
      U && (U.syncContainerHeight?.(), U.render(!0));
    }
    function Ne(_, R, P = 1) {
      if (j.treesModule = _, j.dirtyCount += P, R || j.lastRefreshAt === 0) {
        Aa(j.treesModule);
        return;
      }
      const it = performance.now() - j.lastRefreshAt;
      if (j.dirtyCount >= 1e3 || it >= 1e3) {
        Aa(j.treesModule);
        return;
      }
      if (j.timeout !== 0)
        return;
      const Mt = Math.max(0, 1e3 - it);
      j.timeout = window.setTimeout(() => {
        j.timeout = 0, Aa(j.treesModule);
      }, Mt);
    }
    function Aa(_) {
      j.timeout !== 0 && (window.clearTimeout(j.timeout), j.timeout = 0), j.dirtyCount = 0, j.lastRefreshAt = performance.now(), J.treeRefreshCount += 1, at = Vi(H), Fn(at, _), Se(), $a(J);
    }
    const Ie = await fetch(C.patchURL, {
      cache: "no-store"
    });
    if (!Ie.ok)
      throw new Error(`${X("loadingDiff")} (${Ie.status})`);
    if (!Ie.body?.getReader) {
      const _ = await Ie.text();
      await va(_, d, cn), await Ea(!0), Kl(), Ne(B, !0), J.completedAt = performance.now();
      return;
    }
    const Pe = new TextDecoder(), Pn = Ie.body.getReader(), _a = "diff --git ", ti = `
` + _a, on = ti.length - 1, Da = /\S/;
    function Oa(_, R) {
      const P = Math.max(R, 0);
      if (P === 0 && _.startsWith(_a))
        return 0;
      const it = _.indexOf(ti, P);
      return it === -1 ? void 0 : it + 1;
    }
    function me(_, R) {
      return Math.max(R, _.length - on);
    }
    function El(_, R, P) {
      const it = Math.max(R, 0), Mt = Math.min(P, _.length);
      if (it >= Mt)
        return;
      let Et = _.lastIndexOf(`
From `, Mt - 1);
      for (; Et !== -1; ) {
        const Kt = Et + 1;
        if (Kt < it)
          return;
        if (Kt >= Mt) {
          Et = _.lastIndexOf(`
From `, Et - 1);
          continue;
        }
        const ze = _.indexOf(`
`, Kt + 1), Ba = _.slice(Kt, ze === -1 || ze > Mt ? Mt : ze);
        if (se.test(Ba))
          return Kt;
        Et = _.lastIndexOf(`
From `, Et - 1);
      }
    }
    function rn(_) {
      const R = Oa(_, 0);
      if (R == null || R <= 0)
        return;
      const P = _.slice(0, R);
      return se.test(P) ? P : void 0;
    }
    async function Jl(_) {
      if (_.trim() === "")
        return;
      const R = rn(_);
      R != null && (kl = Xi(R, Ua), Ua += 1);
      const P = `cmux-diff-file-${H.fileIndex}`;
      await cn(x(_, {
        cacheKey: P,
        isGitDiff: !0
      }), kl);
    }
    function bf() {
      let _, R = "", P = 0, it = !1;
      function Mt() {
        if (_ == null) {
          if (_ = Oa(R, P), _ == null)
            return P = me(R, 0), null;
          it = !0, P = _ + 1;
        }
        for (; ; ) {
          const Et = _;
          if (Et == null)
            return null;
          const Kt = Oa(R, P);
          if (Kt == null)
            return P = me(R, Et + 1), null;
          const ze = El(R, Et + 1, Kt) ?? Kt, Ba = R.slice(0, ze);
          if (R = R.slice(ze), _ = Oa(R, 0), P = _ == null ? 0 : _ + 1, Da.test(Ba))
            return Ba;
        }
      }
      return {
        push(Et) {
          Et.length > 0 && (R += Et);
        },
        takeAvailableFile: Mt,
        finish() {
          const Et = Mt();
          if (Et != null)
            return {
              fileText: Et
            };
          if (!Da.test(R))
            return R = "", {};
          if (!it) {
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
    async function Ca(_) {
      let R;
      for (; (R = _.takeAvailableFile()) != null; )
        await Jl(R);
    }
    const rl = bf();
    let kl, Ua = 0;
    for (; ; ) {
      const {
        done: _,
        value: R
      } = await Pn.read();
      if (_) {
        const P = Pe.decode();
        P.length > 0 && (rl.push(P), await Ca(rl));
        break;
      }
      rl.push(Pe.decode(R, {
        stream: !0
      })), await Ca(rl);
    }
    const Ra = rl.finish();
    Ra.fileText != null ? (await Jl(Ra.fileText), await Ca(rl)) : Ra.fallbackPatchContent != null && await va(Ra.fallbackPatchContent, d, cn), await Ea(!0), Kl(), Ne(B, !0), J.completedAt = performance.now(), $a(J);
  }
  function $a(o) {
    document.body.dataset.streamFileCount = String(o.fileCount ?? et.length), document.body.dataset.streamRenderableFileCount = String(o.renderableFileCount ?? m.length), document.body.dataset.streamFlushCount = String(o.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(o.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(o.treeRefreshCount ?? 0), Number.isFinite(o.completedAt) && o.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(o.completedAt - o.startedAt)));
  }
  async function va(o, d, x) {
    const B = d(o, "cmux-diff"), H = B.length > 1;
    for (const [j, J] of B.entries()) {
      const nt = H ? Xi(J.patchMetadata, j) : void 0;
      for (const xt of J.files ?? [])
        await x(xt, nt);
    }
  }
  function sf() {
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
  function Vi(o) {
    const d = o.lastTreeSource, x = df(o), B = {
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
  function df(o) {
    if (o.pendingGitStatusRemovePaths.size === 0 && o.pendingGitStatusSetByPath.size === 0)
      return;
    const d = {};
    return o.pendingGitStatusRemovePaths.size > 0 && (d.remove = Array.from(o.pendingGitStatusRemovePaths), o.pendingGitStatusRemovePaths.clear()), o.pendingGitStatusSetByPath.size > 0 && (d.set = Array.from(o.pendingGitStatusSetByPath.values()), o.pendingGitStatusSetByPath.clear()), d;
  }
  function Zi() {
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
  async function ba() {
    return Tt.value == null && (Tt.value = fetch(C.patchURL, {
      cache: "no-store"
    }).then(async (o) => {
      if (!o.ok)
        throw new Error(`${X("loadingDiff")} (${o.status})`);
      return o.text();
    })), Tt.value;
  }
  function xe() {
    mt.innerHTML = ve("files"), Ft.innerHTML = ve("search"), Vt.innerHTML = ve("sidebarCollapse"), Dt.innerHTML = ve(g.layout), Ct.innerHTML = ve("dots"), typeof C.externalURL == "string" && C.externalURL.length > 0 && (Yt.href = C.externalURL, Yt.innerHTML = ve("external"), Yt.hidden = !1), mt.addEventListener("click", () => ul(!g.filesVisible)), Vt.addEventListener("click", () => ul(!1)), Ft.addEventListener("click", () => Ji(!g.fileSearchOpen)), Dt.addEventListener("click", () => Kn(g.layout === "split" ? "unified" : "split")), Ct.addEventListener("click", () => en(ht.hidden)), document.addEventListener("click", (o) => {
      ht.hidden || o.target instanceof Node && tt.contains(o.target) || en(!1);
    }), document.addEventListener("keydown", (o) => {
      o.key === "Escape" && en(!1);
    }), nl(), Se();
  }
  function nl() {
    const o = C.shortcuts ?? {}, d = ue(o.diffViewerScrollDown), x = ue(o.diffViewerScrollUp), B = ue(o.diffViewerScrollToBottom), H = ue(o.diffViewerScrollToTop), j = ue(o.diffViewerOpenFileSearch);
    let J = null, nt = 0;
    document.addEventListener("keydown", (zt) => {
      if (!(zt.defaultPrevented || tn(zt.target))) {
        if (J && !yl(J.shortcut.second, zt) && xt(), J && yl(J.shortcut.second, zt)) {
          zt.preventDefault(), J.action(), xt();
          return;
        }
        if (Ia(d, zt)) {
          zt.preventDefault(), il(1);
          return;
        }
        if (Ia(x, zt)) {
          zt.preventDefault(), il(-1);
          return;
        }
        if (Ia(B, zt)) {
          zt.preventDefault(), L.scrollTo({
            top: L.scrollHeight,
            behavior: "auto"
          });
          return;
        }
        if (Ia(j, zt) && W) {
          zt.preventDefault(), ul(!0), Ji(!0);
          return;
        }
        H && mf(H, zt) && (zt.preventDefault(), J = {
          shortcut: H,
          action: () => L.scrollTo({
            top: 0,
            behavior: "auto"
          })
        }, nt = window.setTimeout(xt, 700));
      }
    });
    function xt() {
      J = null, nt !== 0 && (window.clearTimeout(nt), nt = 0);
    }
  }
  function ue(o) {
    return !o || o.unbound === !0 || !o.first ? null : {
      first: Ki(o.first),
      second: o.second ? Ki(o.second) : null
    };
  }
  function Ki(o) {
    return {
      key: String(o?.key ?? "").toLowerCase(),
      command: o?.command === !0,
      shift: o?.shift === !0,
      option: o?.option === !0,
      control: o?.control === !0
    };
  }
  function Ia(o, d) {
    return o && !o.second && yl(o.first, d);
  }
  function mf(o, d) {
    return o && o.second && yl(o.first, d);
  }
  function yl(o, d) {
    return !o || d.metaKey !== o.command || d.ctrlKey !== o.control || d.altKey !== o.option || d.shiftKey !== o.shift ? !1 : Pa(d) === o.key;
  }
  function Pa(o) {
    return o.code === "Space" ? "space" : typeof o.key != "string" || o.key.length === 0 ? "" : (o.key.length === 1, o.key.toLowerCase());
  }
  function tn(o) {
    const d = o instanceof Element ? o : null;
    return d ? !!d.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function il(o) {
    const d = Math.max(80, Math.floor(L.clientHeight * 0.38));
    L.scrollBy({
      top: o * d,
      behavior: "auto"
    });
  }
  function xa() {
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
      unsafeCSS: Sa(),
      theme: z.theme,
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
    const o = xa();
    if (!U) {
      Zn();
      return;
    }
    U.setOptions(o), Zn(), U.render(!0);
  }
  function Zn() {
    Z?.setRenderOptions && Z.setRenderOptions(Li()).then(() => U?.render(!0)).catch((o) => console.warn("cmux diff worker render options update failed", o));
  }
  function Kn(o) {
    g.layout = o === "unified" ? "unified" : "split", Se(), vl();
  }
  function ul(o) {
    g.filesVisible = o, document.body.dataset.filesHidden = o ? "false" : "true", $.setAttribute("aria-hidden", String(!o)), o ? $.removeAttribute("inert") : $.setAttribute("inert", ""), Se();
  }
  function Ji(o) {
    g.fileSearchOpen = !!o, W && (g.fileSearchOpen ? W.openSearch("") : W.closeSearch()), Se();
  }
  function ki(o) {
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
    m.splice(0, m.length, ...d), et.splice(0, et.length, ...B), U && (U.setItems(m), U.render(!0)), Se();
  }
  function Se() {
    mt.setAttribute("aria-pressed", String(g.filesVisible)), mt.title = g.filesVisible ? X("hideFiles") : X("showFiles"), mt.setAttribute("aria-label", mt.title), Vt.title = X("hideFiles"), Vt.setAttribute("aria-label", Vt.title), Dt.innerHTML = ve(g.layout), Dt.title = g.layout === "split" ? X("switchToUnifiedDiff") : X("switchToSplitDiff"), Dt.setAttribute("aria-label", Dt.title), Ct.setAttribute("aria-expanded", String(!ht.hidden)), document.documentElement.dataset.layout = g.layout, document.documentElement.dataset.wordWrap = String(g.wordWrap), document.documentElement.dataset.diffIndicators = g.diffIndicators, Ft.disabled = !W, Ft.setAttribute("aria-pressed", String(g.fileSearchOpen)), Ft.title = g.fileSearchOpen ? X("hideFileSearch") : X("showFileSearch"), Ft.setAttribute("aria-label", Ft.title);
  }
  function en(o) {
    o && Ta(), ht.hidden = !o, Se();
  }
  function Ta() {
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
        g.wordWrap = !g.wordWrap, vl();
      }
    }, {
      label: g.collapsed ? X("expandAllDiffs") : X("collapseAllDiffs"),
      icon: "collapse",
      checked: g.collapsed,
      action: () => ki(!g.collapsed)
    }, "separator", {
      label: g.filesVisible ? X("hideFiles") : X("showFiles"),
      icon: "files",
      checked: g.filesVisible,
      action: () => ul(!g.filesVisible)
    }, {
      label: g.expandUnchanged ? X("collapseUnchangedContext") : X("expandUnchangedContext"),
      icon: "document",
      checked: g.expandUnchanged,
      action: () => {
        g.expandUnchanged = !g.expandUnchanged, vl();
      }
    }, {
      label: g.showBackgrounds ? X("hideBackgrounds") : X("showBackgrounds"),
      icon: "background",
      checked: g.showBackgrounds,
      action: () => {
        g.showBackgrounds = !g.showBackgrounds, vl();
      }
    }, {
      label: g.lineNumbers ? X("hideLineNumbers") : X("showLineNumbers"),
      icon: "numbers",
      checked: g.lineNumbers,
      action: () => {
        g.lineNumbers = !g.lineNumbers, vl();
      }
    }, {
      label: g.wordDiffs ? X("disableWordDiffs") : X("enableWordDiffs"),
      icon: "word",
      checked: g.wordDiffs,
      action: () => {
        g.wordDiffs = !g.wordDiffs, vl();
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
      action: Fi
    }];
    for (const d of o) {
      if (d === "separator") {
        const H = document.createElement("div");
        H.className = "menu-separator", ht.append(H);
        continue;
      }
      if (d.kind === "segment") {
        const H = document.createElement("div");
        H.className = "menu-item menu-segment", H.setAttribute("role", "presentation"), H.innerHTML = `${ve(d.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
        const j = H.querySelector(".menu-label");
        j && (j.textContent = d.label);
        const J = H.querySelector(".menu-segment-controls");
        if (!J)
          continue;
        for (const nt of d.options) {
          const xt = document.createElement("button");
          xt.type = "button", xt.className = "segment-button", xt.title = nt.label, xt.setAttribute("aria-label", nt.label), xt.setAttribute("aria-pressed", String(g.diffIndicators === nt.value)), xt.innerHTML = ve(nt.icon), xt.addEventListener("click", () => {
            g.diffIndicators = nt.value, vl(), Ta(), Se();
          }), J.append(xt);
        }
        ht.append(H);
        continue;
      }
      const x = document.createElement("button");
      x.type = "button", x.className = "menu-item", x.setAttribute("role", d.checked == null ? "menuitem" : "menuitemcheckbox"), d.checked != null && x.setAttribute("aria-checked", String(!!d.checked)), x.disabled = !!d.disabled, x.innerHTML = `${ve(d.icon)}<span class="menu-label"></span><span class="menu-check">${d.checked ? ve("check") : ""}</span>`;
      const B = x.querySelector(".menu-label");
      B && (B.textContent = d.label), x.addEventListener("click", () => {
        x.disabled || (d.action?.(), Ta(), Se());
      }), ht.append(x);
    }
  }
  function Jn(o) {
    const d = new Set(o.split(/\r?\n/));
    let x = "CMUX_DIFF_PATCH", B = 0;
    for (; d.has(x); )
      B += 1, x = `CMUX_DIFF_PATCH_${B}`;
    return x;
  }
  async function Fi() {
    const d = await ba(), x = d.endsWith(`
`) ? d : `${d}
`, B = Jn(x), H = `git apply <<'${B}'
${x}${B}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(H);
      } catch {
        kn(H);
      }
    else
      kn(H);
    Ct.title = X("copiedGitApplyCommand"), Ct.setAttribute("aria-label", X("copiedGitApplyCommand"));
  }
  function kn(o) {
    const d = document.createElement("textarea");
    d.value = o, d.setAttribute("readonly", ""), d.style.position = "fixed", d.style.left = "-9999px", document.body.append(d), d.select(), document.execCommand("copy"), d.remove();
  }
  function fl(o) {
    if (Gt.textContent = te(), !Array.isArray(o) || o.length < 2)
      return;
    rt.textContent = "";
    const d = o.find((x) => x.selected) ?? o.find((x) => !x.disabled);
    for (const x of o) {
      const B = document.createElement("option");
      B.value = x.value, B.textContent = x.label, B.disabled = x.disabled || !x.url, B.selected = x.value === d?.value, x.message && (B.title = x.message), rt.append(B);
    }
    Gt.textContent = d?.sourceLabel ?? te(), rt.hidden = !1, rt.addEventListener("change", () => {
      const x = o.find((B) => B.value === rt.value);
      if (!x?.url) {
        rt.value = d?.value ?? "";
        return;
      }
      Be(X("loadingDiff"), {
        pending: !0
      }), window.location.href = x.url;
    });
  }
  function te() {
    return [C.sourceLabel, C.repoRoot, C.branchBaseRef].filter((d) => typeof d == "string" && d.trim() !== "").join(" | ");
  }
  function de(o, d, x, B) {
    if (!o || !Array.isArray(d) || d.length < 2)
      return;
    o.textContent = "";
    const H = d.find((j) => j.selected) ?? d.find((j) => !j.disabled);
    for (const j of d) {
      const J = document.createElement("option");
      J.value = j.value, J.textContent = j.label, J.disabled = j.disabled || !j.url, J.selected = j.value === H?.value, j.message && (J.title = j.message), o.append(J);
    }
    o.hidden = !1, o.title = B, o.addEventListener("change", () => {
      const j = d.find((J) => J.value === o.value);
      if (!j?.url) {
        o.value = H?.value ?? x ?? "";
        return;
      }
      Be(X("loadingDiff"), {
        pending: !0
      }), window.location.href = j.url;
    });
  }
  function Xl(o, d) {
    const x = Ql(o), B = Wi(d);
    if (ol(o, []), W && (W.cleanUp?.(), W = null), q = null, g.fileSearchOpen = !1, Ut.textContent = "", Pt.textContent = `${x}`, Wn(o), B)
      try {
        hf(o, d), Se();
        return;
      } catch (j) {
        console.warn("cmux diff file tree setup failed", j);
      }
    const H = za(o);
    ol(o, H), xl(H), Se();
  }
  function Fn(o, d) {
    const x = Ql(o);
    if (ol(o, []), Pt.textContent = `${x}`, Wn(o), W && Ut.dataset.treeMode === "pierre" && d?.preparePresortedFileTreeInput) {
      gf(o, d);
      return;
    }
    if (W || Ut.childElementCount === 0) {
      Xl(o, d);
      return;
    }
    const B = za(o);
    ol(o, B), Ut.textContent = "", xl(B);
  }
  function hf(o, d) {
    const {
      FileTree: x,
      preparePresortedFileTreeInput: B
    } = d, H = cl(o);
    q = o;
    const j = H[0];
    bl(o), Ut.dataset.treeMode = "pierre", W = new x({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: j ? [j] : [],
      initialVisibleRowCount: Wt(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: B(H),
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: o.gitStatus,
      renderRowDecoration(J) {
        if (J.item.kind !== "file")
          return null;
        const nt = ct.get(J.item.path);
        return nt == null || nt.added === 0 && nt.deleted === 0 ? null : {
          text: `+${nt.added} -${nt.deleted}`,
          title: `${nt.added} ${X("additions")}, ${nt.deleted} ${X("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: $i(),
      onSelectionChange(J) {
        if (gl)
          return;
        const nt = J[J.length - 1], xt = Xe.get(nt);
        xt && ln(xt);
      }
    }), W.render({
      containerWrapper: Ut
    });
  }
  function gf(o, d) {
    const x = q, B = cl(o);
    q = o, bl(o);
    let H = !1;
    const j = Mg(x, o, B);
    if (j.kind === "append") {
      const J = j.addedPaths;
      if (J.length > 0)
        try {
          W.batch(J.map((nt) => ({
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
  function Wi(o) {
    return !!(o?.FileTree && o?.preparePresortedFileTreeInput);
  }
  function Ql(o) {
    return o?.pathCount ?? o?.entries?.length ?? 0;
  }
  function za(o) {
    const d = o?.pathCount ?? o?.entries?.length ?? 0, x = o?.entries ?? [];
    if (x.length > 0)
      return x.length === d ? x : x.slice(0, d);
    const B = cl(o), H = o?.pathToItemId, j = o?.statsByPath;
    return B.map((J) => {
      const nt = H instanceof Map ? H.get(J) : void 0, xt = nt ? A.get(nt) : void 0, zt = xt?.fileDiff ?? {};
      return {
        item: xt ?? {
          id: nt ?? J,
          fileDiff: zt
        },
        path: J,
        status: Pi(zt),
        stats: j instanceof Map ? j.get(J) ?? zl(zt) : zl(zt)
      };
    });
  }
  function cl(o) {
    const d = o?.pathCount ?? o?.paths?.length ?? 0, x = o?.paths ?? [];
    return x.length === d ? x : x.slice(0, d);
  }
  function bl(o) {
    if (o?.statsByPath instanceof Map) {
      ct = o.statsByPath;
      return;
    }
    ct = /* @__PURE__ */ new Map();
    const d = za(o);
    for (const x of d)
      ct.set(x.path, x.stats);
  }
  function ol(o, d) {
    if (o?.pathToItemId instanceof Map && o?.treePathByItemId instanceof Map)
      Xe = o.pathToItemId, al = o.treePathByItemId;
    else if (o?.pathToItemId instanceof Map) {
      Xe = o.pathToItemId, al = /* @__PURE__ */ new Map();
      for (const [x, B] of Xe)
        al.set(B, x);
    } else {
      Xe = /* @__PURE__ */ new Map(), al = /* @__PURE__ */ new Map();
      for (const x of d) {
        const B = x.item?.id;
        B && (Xe.set(x.path, B), al.set(B, x.path));
      }
    }
    Rt && !Xe.has(Rt) && (Rt = "");
  }
  function xl(o) {
    delete Ut.dataset.treeMode;
    for (const d of o) {
      const x = d.item, B = x.fileDiff ?? {}, H = d.stats ?? zl(B), j = document.createElement("button");
      j.type = "button", j.className = "file-entry", j.dataset.itemId = x.id, j.title = Te(B), j.innerHTML = `
      <span class="file-status">${Ee(B)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${H.added}</span>
        <span class="stat-del">-${H.deleted}</span>
      </span>
    `;
      const J = j.querySelector(".file-name");
      J && (J.textContent = Te(B)), j.addEventListener("click", () => ln(x.id)), Ut.append(j);
    }
  }
  function Wt() {
    const o = window.visualViewport?.height ?? window.innerHeight;
    return !Number.isFinite(o) || o <= 0 ? 25 : Math.min(96, Math.max(25, Math.ceil(o / 24)));
  }
  function $i() {
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
  function Wn(o) {
    const d = o?.diffStats;
    if (d && Number.isFinite(d.addedLines) && Number.isFinite(d.deletedLines) && Number.isFinite(d.fileCount)) {
      Zt.textContent = `${d.fileCount}`, re.textContent = `+${d.addedLines}`, ie.textContent = `-${d.deletedLines}`;
      return;
    }
    Sl(o?.entries ?? []);
  }
  function Sl(o) {
    const d = o.reduce((x, B) => {
      const H = B.stats ?? zl(B.item?.fileDiff ?? {});
      return x.added += H.added, x.deleted += H.deleted, x;
    }, {
      added: 0,
      deleted: 0
    });
    Zt.textContent = `${o.length}`, re.textContent = `+${d.added}`, ie.textContent = `-${d.deleted}`;
  }
  function Tl(o) {
    ft.textContent = "";
    const d = document.createElement("option");
    d.value = "", d.textContent = X("jumpToFile"), ft.append(d), ft.dataset.initialized = "true";
    for (const x of o) {
      const B = document.createElement("option");
      B.value = x.id, B.textContent = Te(x.fileDiff ?? {}), ft.append(B);
    }
    ft.hidden = o.length === 0, ft.onchange = () => {
      ft.value && ln(ft.value);
    };
  }
  function pf(o) {
    if (o.length === 0)
      return;
    ft.dataset.initialized !== "true" && Tl([]);
    const d = document.createDocumentFragment();
    for (const x of o) {
      const B = document.createElement("option");
      B.value = x.id, B.textContent = Te(x.fileDiff ?? {}), d.append(B);
    }
    ft.append(d), ft.hidden = !1;
  }
  function Ii(o, d) {
    if (ft.dataset.initialized === "true") {
      for (const x of ft.options)
        if (x.value === o) {
          x.value = d;
          return;
        }
    }
  }
  function ln(o) {
    if (!U)
      return;
    const d = yf(o);
    d && (U.scrollTo({
      type: "item",
      id: d,
      align: "start",
      behavior: "smooth-auto"
    }), Ma(d));
  }
  function yf(o) {
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
  function Ma(o) {
    if (!(!o || ce === o)) {
      ce = o, an(o);
      for (const d of Ut.querySelectorAll(".file-entry"))
        d.setAttribute("aria-current", d.dataset.itemId === o ? "true" : "false");
      ft.value !== o && (ft.value = o);
    }
  }
  function an(o) {
    if (!W)
      return;
    const d = al.get(o);
    if (!(!d || d === Rt)) {
      gl = !0;
      try {
        Rt && W.getItem(Rt)?.deselect(), W.getItem(d)?.select(), W.scrollToPath(d, {
          focus: !1,
          offset: "nearest"
        }), Rt = d;
      } finally {
        Yn(() => {
          gl = !1;
        });
      }
    }
  }
  function Te(o) {
    return o.name ?? o.newName ?? o.oldName ?? o.prevName ?? X("untitled");
  }
  function Ee(o) {
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
  function Pi(o) {
    return tu(o.type);
  }
  function tu(o) {
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
  function zl(o) {
    const d = {
      added: 0,
      deleted: 0
    };
    for (const x of o.hunks ?? [])
      d.added += x.additionLines ?? 0, d.deleted += x.deletionLines ?? 0;
    return d;
  }
  function eu(o, d) {
    return o?.added === d.added && o?.deleted === d.deleted;
  }
  function ve(o) {
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
  function nn(o, d) {
    o(d.name, () => Promise.resolve($n(d)));
  }
  function Ae(o, d, x, B) {
    const H = Array.from(new Set([o.theme?.light, o.theme?.dark].filter(Boolean))), j = Array.from(new Set(d.flatMap((J) => {
      const nt = J.fileDiff ?? {}, xt = nt.name ?? nt.newName ?? nt.oldName ?? nt.prevName ?? "", zt = nt.lang ?? x(xt) ?? "text";
      return zt ? [zt] : [];
    })));
    return B({
      themes: H,
      langs: j.length > 0 ? j : ["text"]
    });
  }
  function $n(o) {
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
  const S = Wa.c(1);
  let f;
  return S[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ K.jsx("div", { className: "diff-loading-placeholder", "aria-hidden": "true", children: _g.map(Cg) }), S[0] = f) : f = S[0], f;
}
function Cg(S, f) {
  return /* @__PURE__ */ K.jsxs("div", { className: "grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]", children: [
    /* @__PURE__ */ K.jsx("span", { className: "size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ K.jsx("span", { className: "h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: S
    } }),
    /* @__PURE__ */ K.jsx("span", { className: "h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: {
      width: f % 2 === 0 ? "34px" : "24px"
    } })
  ] }, `${S}-${f}`);
}
function Ug() {
  const S = Wa.c(2);
  let f;
  S[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ K.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
    /* @__PURE__ */ K.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ K.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ K.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
  ] }), S[0] = f) : f = S[0];
  let D;
  return S[1] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (D = /* @__PURE__ */ K.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    f,
    /* @__PURE__ */ K.jsx("div", { className: "space-y-[13px] px-3 py-1", children: Dg.map(Rg) })
  ] }), S[1] = D) : D = S[1], D;
}
function Rg(S, f) {
  return /* @__PURE__ */ K.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
    /* @__PURE__ */ K.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
    /* @__PURE__ */ K.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: S
    } })
  ] }, `${S}-${f}`);
}
function Bg(S) {
  const f = Wa.c(8), {
    config: D,
    label: s
  } = S;
  let G;
  f[0] !== D.payload?.statusMessage || f[1] !== s ? (G = D.payload?.statusMessage ?? s("loadingDiff"), f[0] = D.payload?.statusMessage, f[1] = s, f[2] = G) : G = f[2];
  let k;
  f[3] !== G ? (k = /* @__PURE__ */ K.jsx("div", { id: "status", children: G }), f[3] = G, f[4] = k) : k = f[4];
  let Q;
  f[5] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Q = /* @__PURE__ */ K.jsx(Ug, {}), f[5] = Q) : Q = f[5];
  let lt;
  return f[6] !== k ? (lt = /* @__PURE__ */ K.jsxs("div", { id: "loading-layer", "aria-live": "polite", children: [
    k,
    Q
  ] }), f[6] = k, f[7] = lt) : lt = f[7], lt;
}
function Ng(S) {
  const f = Wa.c(17), {
    label: D
  } = S;
  let s;
  f[0] !== D ? (s = D("diffTarget"), f[0] = D, f[1] = s) : s = f[1];
  let G;
  f[2] !== s ? (G = /* @__PURE__ */ K.jsx("select", { id: "source-select", "aria-label": s, hidden: !0 }), f[2] = s, f[3] = G) : G = f[3];
  let k;
  f[4] !== D ? (k = D("repoPath"), f[4] = D, f[5] = k) : k = f[5];
  let Q;
  f[6] !== k ? (Q = /* @__PURE__ */ K.jsx("select", { id: "repo-select", "aria-label": k, hidden: !0 }), f[6] = k, f[7] = Q) : Q = f[7];
  let lt;
  f[8] !== D ? (lt = D("branchBase"), f[8] = D, f[9] = lt) : lt = f[9];
  let C;
  f[10] !== lt ? (C = /* @__PURE__ */ K.jsx("select", { id: "base-select", "aria-label": lt, hidden: !0 }), f[10] = lt, f[11] = C) : C = f[11];
  let z;
  f[12] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (z = /* @__PURE__ */ K.jsx("span", { id: "source-detail" }), f[12] = z) : z = f[12];
  let L;
  return f[13] !== G || f[14] !== Q || f[15] !== C ? (L = /* @__PURE__ */ K.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    G,
    Q,
    C,
    z
  ] }), f[13] = G, f[14] = Q, f[15] = C, f[16] = L) : L = f[16], L;
}
function wg(S) {
  const f = Wa.c(50), {
    config: D,
    label: s
  } = S;
  let G;
  f[0] !== D || f[1] !== s ? (G = /* @__PURE__ */ K.jsx(Ng, { config: D, label: s }), f[0] = D, f[1] = s, f[2] = G) : G = f[2];
  let k;
  f[3] !== s ? (k = s("jumpToFile"), f[3] = s, f[4] = k) : k = f[4];
  let Q;
  f[5] !== k ? (Q = /* @__PURE__ */ K.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ K.jsx("select", { id: "jump-select", "aria-label": k, hidden: !0 }) }), f[5] = k, f[6] = Q) : Q = f[6];
  const lt = D.payload?.externalURL ?? "#";
  let C;
  f[7] !== s ? (C = s("openSourceURL"), f[7] = s, f[8] = C) : C = f[8];
  let z;
  f[9] !== s ? (z = s("openSourceURL"), f[9] = s, f[10] = z) : z = f[10];
  let L;
  f[11] !== lt || f[12] !== C || f[13] !== z ? (L = /* @__PURE__ */ K.jsx("a", { id: "external-link", className: "toolbar-icon", href: lt, target: "_blank", rel: "noreferrer", title: C, "aria-label": z, hidden: !0 }), f[11] = lt, f[12] = C, f[13] = z, f[14] = L) : L = f[14];
  let w;
  f[15] !== s ? (w = s("hideFiles"), f[15] = s, f[16] = w) : w = f[16];
  let tt;
  f[17] !== s ? (tt = s("hideFiles"), f[17] = s, f[18] = tt) : tt = f[18];
  let rt;
  f[19] !== w || f[20] !== tt ? (rt = /* @__PURE__ */ K.jsx("button", { id: "files-toggle", className: "toolbar-icon", type: "button", title: w, "aria-label": tt, "aria-pressed": "true" }), f[19] = w, f[20] = tt, f[21] = rt) : rt = f[21];
  let dt;
  f[22] !== s ? (dt = s("switchToUnifiedDiff"), f[22] = s, f[23] = dt) : dt = f[23];
  let yt;
  f[24] !== s ? (yt = s("switchToUnifiedDiff"), f[24] = s, f[25] = yt) : yt = f[25];
  let Gt;
  f[26] !== dt || f[27] !== yt ? (Gt = /* @__PURE__ */ K.jsx("button", { id: "layout-toggle", className: "toolbar-icon", type: "button", title: dt, "aria-label": yt }), f[26] = dt, f[27] = yt, f[28] = Gt) : Gt = f[28];
  let ft;
  f[29] !== s ? (ft = s("options"), f[29] = s, f[30] = ft) : ft = f[30];
  let Yt;
  f[31] !== s ? (Yt = s("options"), f[31] = s, f[32] = Yt) : Yt = f[32];
  let mt;
  f[33] !== ft || f[34] !== Yt ? (mt = /* @__PURE__ */ K.jsx("button", { id: "options-button", className: "toolbar-icon", type: "button", title: ft, "aria-label": Yt, "aria-expanded": "false", "aria-haspopup": "menu" }), f[33] = ft, f[34] = Yt, f[35] = mt) : mt = f[35];
  let Dt;
  f[36] !== rt || f[37] !== Gt || f[38] !== mt || f[39] !== L ? (Dt = /* @__PURE__ */ K.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
    L,
    rt,
    Gt,
    mt
  ] }), f[36] = rt, f[37] = Gt, f[38] = mt, f[39] = L, f[40] = Dt) : Dt = f[40];
  let Ct;
  f[41] !== s ? (Ct = s("options"), f[41] = s, f[42] = Ct) : Ct = f[42];
  let ht;
  f[43] !== Ct ? (ht = /* @__PURE__ */ K.jsx("div", { id: "options-menu", role: "menu", "aria-label": Ct, hidden: !0 }), f[43] = Ct, f[44] = ht) : ht = f[44];
  let $;
  return f[45] !== G || f[46] !== Dt || f[47] !== ht || f[48] !== Q ? ($ = /* @__PURE__ */ K.jsxs("header", { id: "toolbar", children: [
    G,
    Q,
    Dt,
    ht
  ] }), f[45] = G, f[46] = Dt, f[47] = ht, f[48] = Q, f[49] = $) : $ = f[49], $;
}
function Hg(S) {
  const f = Wa.c(62), {
    label: D
  } = S;
  let s;
  f[0] !== D ? (s = D("changedFiles"), f[0] = D, f[1] = s) : s = f[1];
  let G;
  f[2] !== D ? (G = D("files"), f[2] = D, f[3] = G) : G = f[3];
  let k;
  f[4] !== G ? (k = /* @__PURE__ */ K.jsx("span", { children: G }), f[4] = G, f[5] = k) : k = f[5];
  let Q;
  f[6] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Q = /* @__PURE__ */ K.jsx("span", { id: "files-count" }), f[6] = Q) : Q = f[6];
  let lt;
  f[7] !== k ? (lt = /* @__PURE__ */ K.jsxs("span", { id: "files-title", children: [
    k,
    Q
  ] }), f[7] = k, f[8] = lt) : lt = f[8];
  let C;
  f[9] !== D ? (C = D("showFileSearch"), f[9] = D, f[10] = C) : C = f[10];
  let z;
  f[11] !== D ? (z = D("showFileSearch"), f[11] = D, f[12] = z) : z = f[12];
  let L;
  f[13] !== C || f[14] !== z ? (L = /* @__PURE__ */ K.jsx("button", { id: "file-search-toggle", type: "button", title: C, "aria-label": z, "aria-pressed": "false" }), f[13] = C, f[14] = z, f[15] = L) : L = f[15];
  let w;
  f[16] !== D ? (w = D("hideFiles"), f[16] = D, f[17] = w) : w = f[17];
  let tt;
  f[18] !== D ? (tt = D("hideFiles"), f[18] = D, f[19] = tt) : tt = f[19];
  let rt;
  f[20] !== tt || f[21] !== w ? (rt = /* @__PURE__ */ K.jsx("button", { id: "file-collapse-toggle", type: "button", title: w, "aria-label": tt }), f[20] = tt, f[21] = w, f[22] = rt) : rt = f[22];
  let dt;
  f[23] !== rt || f[24] !== L ? (dt = /* @__PURE__ */ K.jsxs("span", { id: "files-header-actions", children: [
    L,
    rt
  ] }), f[23] = rt, f[24] = L, f[25] = dt) : dt = f[25];
  let yt;
  f[26] !== dt || f[27] !== lt ? (yt = /* @__PURE__ */ K.jsxs("div", { id: "files-header", children: [
    lt,
    dt
  ] }), f[26] = dt, f[27] = lt, f[28] = yt) : yt = f[28];
  let Gt;
  f[29] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Gt = /* @__PURE__ */ K.jsx("div", { id: "file-list", children: /* @__PURE__ */ K.jsx(Og, {}) }), f[29] = Gt) : Gt = f[29];
  let ft;
  f[30] !== D ? (ft = D("diffStats"), f[30] = D, f[31] = ft) : ft = f[31];
  let Yt;
  f[32] !== D ? (Yt = D("files"), f[32] = D, f[33] = Yt) : Yt = f[33];
  let mt;
  f[34] !== Yt ? (mt = /* @__PURE__ */ K.jsx("span", { children: Yt }), f[34] = Yt, f[35] = mt) : mt = f[35];
  let Dt;
  f[36] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Dt = /* @__PURE__ */ K.jsx("strong", { id: "stats-files", children: "0" }), f[36] = Dt) : Dt = f[36];
  let Ct;
  f[37] !== mt ? (Ct = /* @__PURE__ */ K.jsxs("div", { className: "stats-row", children: [
    mt,
    Dt
  ] }), f[37] = mt, f[38] = Ct) : Ct = f[38];
  let ht;
  f[39] !== D ? (ht = D("additions"), f[39] = D, f[40] = ht) : ht = f[40];
  let $;
  f[41] !== ht ? ($ = /* @__PURE__ */ K.jsx("span", { children: ht }), f[41] = ht, f[42] = $) : $ = f[42];
  let Ut;
  f[43] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Ut = /* @__PURE__ */ K.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" }), f[43] = Ut) : Ut = f[43];
  let Pt;
  f[44] !== $ ? (Pt = /* @__PURE__ */ K.jsxs("div", { className: "stats-row", children: [
    $,
    Ut
  ] }), f[44] = $, f[45] = Pt) : Pt = f[45];
  let Ft;
  f[46] !== D ? (Ft = D("deletions"), f[46] = D, f[47] = Ft) : Ft = f[47];
  let Vt;
  f[48] !== Ft ? (Vt = /* @__PURE__ */ K.jsx("span", { children: Ft }), f[48] = Ft, f[49] = Vt) : Vt = f[49];
  let Zt;
  f[50] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Zt = /* @__PURE__ */ K.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" }), f[50] = Zt) : Zt = f[50];
  let re;
  f[51] !== Vt ? (re = /* @__PURE__ */ K.jsxs("div", { className: "stats-row", children: [
    Vt,
    Zt
  ] }), f[51] = Vt, f[52] = re) : re = f[52];
  let ie;
  f[53] !== ft || f[54] !== Ct || f[55] !== Pt || f[56] !== re ? (ie = /* @__PURE__ */ K.jsxs("div", { id: "files-footer", "aria-label": ft, children: [
    Ct,
    Pt,
    re
  ] }), f[53] = ft, f[54] = Ct, f[55] = Pt, f[56] = re, f[57] = ie) : ie = f[57];
  let X;
  return f[58] !== s || f[59] !== yt || f[60] !== ie ? (X = /* @__PURE__ */ K.jsxs("aside", { id: "files-sidebar", "aria-label": s, children: [
    yt,
    Gt,
    ie
  ] }), f[58] = s, f[59] = yt, f[60] = ie, f[61] = X) : X = f[61], X;
}
function jg(S) {
  const f = Wa.c(25), {
    config: D
  } = S, s = vg.useRef(!1), G = D.payload?.labels;
  let k;
  f[0] !== G ? (k = rm(G, {
    assertMissing: om()
  }), f[0] = G, f[1] = k) : k = f[1];
  const Q = k;
  let lt;
  f[2] !== D ? (lt = (Gt) => {
    !Gt || s.current || (s.current = !0, Ag(D));
  }, f[2] = D, f[3] = lt) : lt = f[3];
  const C = lt;
  let z;
  f[4] !== D || f[5] !== Q ? (z = /* @__PURE__ */ K.jsx(wg, { config: D, label: Q }), f[4] = D, f[5] = Q, f[6] = z) : z = f[6];
  let L;
  f[7] !== D || f[8] !== Q ? (L = /* @__PURE__ */ K.jsx(Hg, { config: D, label: Q }), f[7] = D, f[8] = Q, f[9] = L) : L = f[9];
  let w;
  f[10] !== Q ? (w = Q("diffViewer"), f[10] = Q, f[11] = w) : w = f[11];
  let tt;
  f[12] !== D || f[13] !== Q ? (tt = /* @__PURE__ */ K.jsx(Bg, { config: D, label: Q }), f[12] = D, f[13] = Q, f[14] = tt) : tt = f[14];
  let rt;
  f[15] !== w || f[16] !== tt ? (rt = /* @__PURE__ */ K.jsx("main", { id: "viewer", "aria-label": w, children: tt }), f[15] = w, f[16] = tt, f[17] = rt) : rt = f[17];
  let dt;
  f[18] !== L || f[19] !== rt ? (dt = /* @__PURE__ */ K.jsxs("section", { id: "content", children: [
    L,
    rt
  ] }), f[18] = L, f[19] = rt, f[20] = dt) : dt = f[20];
  let yt;
  return f[21] !== C || f[22] !== z || f[23] !== dt ? (yt = /* @__PURE__ */ K.jsxs("div", { id: "app", ref: C, children: [
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
const Ll = Gg();
Yg();
dm(sm(Ll.payload?.appearance));
typeof Ll.payload?.title == "string" && Ll.payload.title.trim() !== "" && (document.title = Ll.payload.title);
document.body.dataset.filesHidden = "false";
document.body.dataset.loading = Ll.payload?.pendingReplacement || !Ll.payload?.statusMessage ? "true" : "false";
document.body.dataset.statusOnly = Ll.payload?.statusMessage && !Ll.payload.pendingReplacement ? "true" : "false";
const hm = document.getElementById("root");
if (!hm)
  throw new Error("Missing cmux diff viewer root");
gg.createRoot(hm).render(/* @__PURE__ */ K.jsx(jg, { config: Ll }));
