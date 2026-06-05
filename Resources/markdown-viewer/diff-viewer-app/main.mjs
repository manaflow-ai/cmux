var vo = { exports: {} }, Yi = {};
var Id;
function ug() {
  if (Id) return Yi;
  Id = 1;
  var S = /* @__PURE__ */ Symbol.for("react.transitional.element"), f = /* @__PURE__ */ Symbol.for("react.fragment");
  function O(s, X, J) {
    var Q = null;
    if (J !== void 0 && (Q = "" + J), X.key !== void 0 && (Q = "" + X.key), "key" in X) {
      J = {};
      for (var et in X)
        et !== "key" && (J[et] = X[et]);
    } else J = X;
    return X = J.ref, {
      $$typeof: S,
      type: s,
      key: Q,
      ref: X !== void 0 ? X : null,
      props: J
    };
  }
  return Yi.Fragment = f, Yi.jsx = O, Yi.jsxs = O, Yi;
}
var Pd;
function fg() {
  return Pd || (Pd = 1, vo.exports = ug()), vo.exports;
}
var Z = fg(), bo = { exports: {} }, Li = {}, xo = { exports: {} }, So = {};
var tm;
function cg() {
  return tm || (tm = 1, (function(S) {
    function f(p, M) {
      var j = p.length;
      p.push(M);
      t: for (; 0 < j; ) {
        var ot = j - 1 >>> 1, W = p[ot];
        if (0 < X(W, M))
          p[ot] = M, p[j] = W, j = ot;
        else break t;
      }
    }
    function O(p) {
      return p.length === 0 ? null : p[0];
    }
    function s(p) {
      if (p.length === 0) return null;
      var M = p[0], j = p.pop();
      if (j !== M) {
        p[0] = j;
        t: for (var ot = 0, W = p.length, m = W >>> 1; ot < m; ) {
          var E = 2 * (ot + 1) - 1, B = p[E], q = E + 1, tt = p[q];
          if (0 > X(B, j))
            q < W && 0 > X(tt, B) ? (p[ot] = tt, p[q] = j, ot = q) : (p[ot] = B, p[E] = j, ot = E);
          else if (q < W && 0 > X(tt, j))
            p[ot] = tt, p[q] = j, ot = q;
          else break t;
        }
      }
      return M;
    }
    function X(p, M) {
      var j = p.sortIndex - M.sortIndex;
      return j !== 0 ? j : p.id - M.id;
    }
    if (S.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var J = performance;
      S.unstable_now = function() {
        return J.now();
      };
    } else {
      var Q = Date, et = Q.now();
      S.unstable_now = function() {
        return Q.now() - et;
      };
    }
    var U = [], z = [], L = 1, H = null, P = 3, mt = !1, nt = !1, ht = !1, qt = !1, Ct = typeof setTimeout == "function" ? setTimeout : null, rt = typeof clearTimeout == "function" ? clearTimeout : null, xt = typeof setImmediate < "u" ? setImmediate : null;
    function At(p) {
      for (var M = O(z); M !== null; ) {
        if (M.callback === null) s(z);
        else if (M.startTime <= p)
          s(z), M.sortIndex = M.expirationTime, f(U, M);
        else break;
        M = O(z);
      }
    }
    function _t(p) {
      if (ht = !1, At(p), !nt)
        if (O(U) !== null)
          nt = !0, St || (St = !0, Yt());
        else {
          var M = O(z);
          M !== null && ne(_t, M.startTime - p);
        }
    }
    var St = !1, k = -1, Zt = 5, Ht = -1;
    function be() {
      return qt ? !0 : !(S.unstable_now() - Ht < Zt);
    }
    function Gt() {
      if (qt = !1, St) {
        var p = S.unstable_now();
        Ht = p;
        var M = !0;
        try {
          t: {
            nt = !1, ht && (ht = !1, rt(k), k = -1), mt = !0;
            var j = P;
            try {
              e: {
                for (At(p), H = O(U); H !== null && !(H.expirationTime > p && be()); ) {
                  var ot = H.callback;
                  if (typeof ot == "function") {
                    H.callback = null, P = H.priorityLevel;
                    var W = ot(
                      H.expirationTime <= p
                    );
                    if (p = S.unstable_now(), typeof W == "function") {
                      H.callback = W, At(p), M = !0;
                      break e;
                    }
                    H === O(U) && s(U), At(p);
                  } else s(U);
                  H = O(U);
                }
                if (H !== null) M = !0;
                else {
                  var m = O(z);
                  m !== null && ne(
                    _t,
                    m.startTime - p
                  ), M = !1;
                }
              }
              break t;
            } finally {
              H = null, P = j, mt = !1;
            }
            M = void 0;
          }
        } finally {
          M ? Yt() : St = !1;
        }
      }
    }
    var Yt;
    if (typeof xt == "function")
      Yt = function() {
        xt(Gt);
      };
    else if (typeof MessageChannel < "u") {
      var se = new MessageChannel(), ae = se.port2;
      se.port1.onmessage = Gt, Yt = function() {
        ae.postMessage(null);
      };
    } else
      Yt = function() {
        Ct(Gt, 0);
      };
    function ne(p, M) {
      k = Ct(function() {
        p(S.unstable_now());
      }, M);
    }
    S.unstable_IdlePriority = 5, S.unstable_ImmediatePriority = 1, S.unstable_LowPriority = 4, S.unstable_NormalPriority = 3, S.unstable_Profiling = null, S.unstable_UserBlockingPriority = 2, S.unstable_cancelCallback = function(p) {
      p.callback = null;
    }, S.unstable_forceFrameRate = function(p) {
      0 > p || 125 < p ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : Zt = 0 < p ? Math.floor(1e3 / p) : 5;
    }, S.unstable_getCurrentPriorityLevel = function() {
      return P;
    }, S.unstable_next = function(p) {
      switch (P) {
        case 1:
        case 2:
        case 3:
          var M = 3;
          break;
        default:
          M = P;
      }
      var j = P;
      P = M;
      try {
        return p();
      } finally {
        P = j;
      }
    }, S.unstable_requestPaint = function() {
      qt = !0;
    }, S.unstable_runWithPriority = function(p, M) {
      switch (p) {
        case 1:
        case 2:
        case 3:
        case 4:
        case 5:
          break;
        default:
          p = 3;
      }
      var j = P;
      P = p;
      try {
        return M();
      } finally {
        P = j;
      }
    }, S.unstable_scheduleCallback = function(p, M, j) {
      var ot = S.unstable_now();
      switch (typeof j == "object" && j !== null ? (j = j.delay, j = typeof j == "number" && 0 < j ? ot + j : ot) : j = ot, p) {
        case 1:
          var W = -1;
          break;
        case 2:
          W = 250;
          break;
        case 5:
          W = 1073741823;
          break;
        case 4:
          W = 1e4;
          break;
        default:
          W = 5e3;
      }
      return W = j + W, p = {
        id: L++,
        callback: M,
        priorityLevel: p,
        startTime: j,
        expirationTime: W,
        sortIndex: -1
      }, j > ot ? (p.sortIndex = j, f(z, p), O(U) === null && p === O(z) && (ht ? (rt(k), k = -1) : ht = !0, ne(_t, j - ot))) : (p.sortIndex = W, f(U, p), nt || mt || (nt = !0, St || (St = !0, Yt()))), p;
    }, S.unstable_shouldYield = be, S.unstable_wrapCallback = function(p) {
      var M = P;
      return function() {
        var j = P;
        P = M;
        try {
          return p.apply(this, arguments);
        } finally {
          P = j;
        }
      };
    };
  })(So)), So;
}
var em;
function og() {
  return em || (em = 1, xo.exports = cg()), xo.exports;
}
var To = { exports: {} }, at = {};
var lm;
function rg() {
  if (lm) return at;
  lm = 1;
  var S = /* @__PURE__ */ Symbol.for("react.transitional.element"), f = /* @__PURE__ */ Symbol.for("react.portal"), O = /* @__PURE__ */ Symbol.for("react.fragment"), s = /* @__PURE__ */ Symbol.for("react.strict_mode"), X = /* @__PURE__ */ Symbol.for("react.profiler"), J = /* @__PURE__ */ Symbol.for("react.consumer"), Q = /* @__PURE__ */ Symbol.for("react.context"), et = /* @__PURE__ */ Symbol.for("react.forward_ref"), U = /* @__PURE__ */ Symbol.for("react.suspense"), z = /* @__PURE__ */ Symbol.for("react.memo"), L = /* @__PURE__ */ Symbol.for("react.lazy"), H = /* @__PURE__ */ Symbol.for("react.activity"), P = Symbol.iterator;
  function mt(m) {
    return m === null || typeof m != "object" ? null : (m = P && m[P] || m["@@iterator"], typeof m == "function" ? m : null);
  }
  var nt = {
    isMounted: function() {
      return !1;
    },
    enqueueForceUpdate: function() {
    },
    enqueueReplaceState: function() {
    },
    enqueueSetState: function() {
    }
  }, ht = Object.assign, qt = {};
  function Ct(m, E, B) {
    this.props = m, this.context = E, this.refs = qt, this.updater = B || nt;
  }
  Ct.prototype.isReactComponent = {}, Ct.prototype.setState = function(m, E) {
    if (typeof m != "object" && typeof m != "function" && m != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, m, E, "setState");
  }, Ct.prototype.forceUpdate = function(m) {
    this.updater.enqueueForceUpdate(this, m, "forceUpdate");
  };
  function rt() {
  }
  rt.prototype = Ct.prototype;
  function xt(m, E, B) {
    this.props = m, this.context = E, this.refs = qt, this.updater = B || nt;
  }
  var At = xt.prototype = new rt();
  At.constructor = xt, ht(At, Ct.prototype), At.isPureReactComponent = !0;
  var _t = Array.isArray;
  function St() {
  }
  var k = { H: null, A: null, T: null, S: null }, Zt = Object.prototype.hasOwnProperty;
  function Ht(m, E, B) {
    var q = B.ref;
    return {
      $$typeof: S,
      type: m,
      key: E,
      ref: q !== void 0 ? q : null,
      props: B
    };
  }
  function be(m, E) {
    return Ht(m.type, E, m.props);
  }
  function Gt(m) {
    return typeof m == "object" && m !== null && m.$$typeof === S;
  }
  function Yt(m) {
    var E = { "=": "=0", ":": "=2" };
    return "$" + m.replace(/[=:]/g, function(B) {
      return E[B];
    });
  }
  var se = /\/+/g;
  function ae(m, E) {
    return typeof m == "object" && m !== null && m.key != null ? Yt("" + m.key) : E.toString(36);
  }
  function ne(m) {
    switch (m.status) {
      case "fulfilled":
        return m.value;
      case "rejected":
        throw m.reason;
      default:
        switch (typeof m.status == "string" ? m.then(St, St) : (m.status = "pending", m.then(
          function(E) {
            m.status === "pending" && (m.status = "fulfilled", m.value = E);
          },
          function(E) {
            m.status === "pending" && (m.status = "rejected", m.reason = E);
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
  function p(m, E, B, q, tt) {
    var ct = typeof m;
    (ct === "undefined" || ct === "boolean") && (m = null);
    var vt = !1;
    if (m === null) vt = !0;
    else
      switch (ct) {
        case "bigint":
        case "string":
        case "number":
          vt = !0;
          break;
        case "object":
          switch (m.$$typeof) {
            case S:
            case f:
              vt = !0;
              break;
            case L:
              return vt = m._init, p(
                vt(m._payload),
                E,
                B,
                q,
                tt
              );
          }
      }
    if (vt)
      return tt = tt(m), vt = q === "" ? "." + ae(m, 0) : q, _t(tt) ? (B = "", vt != null && (B = vt.replace(se, "$&/") + "/"), p(tt, E, B, "", function(Ue) {
        return Ue;
      })) : tt != null && (Gt(tt) && (tt = be(
        tt,
        B + (tt.key == null || m && m.key === tt.key ? "" : ("" + tt.key).replace(
          se,
          "$&/"
        ) + "/") + vt
      )), E.push(tt)), 1;
    vt = 0;
    var ie = q === "" ? "." : q + ":";
    if (_t(m))
      for (var Qt = 0; Qt < m.length; Qt++)
        q = m[Qt], ct = ie + ae(q, Qt), vt += p(
          q,
          E,
          B,
          ct,
          tt
        );
    else if (Qt = mt(m), typeof Qt == "function")
      for (m = Qt.call(m), Qt = 0; !(q = m.next()).done; )
        q = q.value, ct = ie + ae(q, Qt++), vt += p(
          q,
          E,
          B,
          ct,
          tt
        );
    else if (ct === "object") {
      if (typeof m.then == "function")
        return p(
          ne(m),
          E,
          B,
          q,
          tt
        );
      throw E = String(m), Error(
        "Objects are not valid as a React child (found: " + (E === "[object Object]" ? "object with keys {" + Object.keys(m).join(", ") + "}" : E) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return vt;
  }
  function M(m, E, B) {
    if (m == null) return m;
    var q = [], tt = 0;
    return p(m, q, "", "", function(ct) {
      return E.call(B, ct, tt++);
    }), q;
  }
  function j(m) {
    if (m._status === -1) {
      var E = m._result;
      E = E(), E.then(
        function(B) {
          (m._status === 0 || m._status === -1) && (m._status = 1, m._result = B);
        },
        function(B) {
          (m._status === 0 || m._status === -1) && (m._status = 2, m._result = B);
        }
      ), m._status === -1 && (m._status = 0, m._result = E);
    }
    if (m._status === 1) return m._result.default;
    throw m._result;
  }
  var ot = typeof reportError == "function" ? reportError : function(m) {
    if (typeof window == "object" && typeof window.ErrorEvent == "function") {
      var E = new window.ErrorEvent("error", {
        bubbles: !0,
        cancelable: !0,
        message: typeof m == "object" && m !== null && typeof m.message == "string" ? String(m.message) : String(m),
        error: m
      });
      if (!window.dispatchEvent(E)) return;
    } else if (typeof process == "object" && typeof process.emit == "function") {
      process.emit("uncaughtException", m);
      return;
    }
    console.error(m);
  }, W = {
    map: M,
    forEach: function(m, E, B) {
      M(
        m,
        function() {
          E.apply(this, arguments);
        },
        B
      );
    },
    count: function(m) {
      var E = 0;
      return M(m, function() {
        E++;
      }), E;
    },
    toArray: function(m) {
      return M(m, function(E) {
        return E;
      }) || [];
    },
    only: function(m) {
      if (!Gt(m))
        throw Error(
          "React.Children.only expected to receive a single React element child."
        );
      return m;
    }
  };
  return at.Activity = H, at.Children = W, at.Component = Ct, at.Fragment = O, at.Profiler = X, at.PureComponent = xt, at.StrictMode = s, at.Suspense = U, at.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = k, at.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(m) {
      return k.H.useMemoCache(m);
    }
  }, at.cache = function(m) {
    return function() {
      return m.apply(null, arguments);
    };
  }, at.cacheSignal = function() {
    return null;
  }, at.cloneElement = function(m, E, B) {
    if (m == null)
      throw Error(
        "The argument must be a React element, but you passed " + m + "."
      );
    var q = ht({}, m.props), tt = m.key;
    if (E != null)
      for (ct in E.key !== void 0 && (tt = "" + E.key), E)
        !Zt.call(E, ct) || ct === "key" || ct === "__self" || ct === "__source" || ct === "ref" && E.ref === void 0 || (q[ct] = E[ct]);
    var ct = arguments.length - 2;
    if (ct === 1) q.children = B;
    else if (1 < ct) {
      for (var vt = Array(ct), ie = 0; ie < ct; ie++)
        vt[ie] = arguments[ie + 2];
      q.children = vt;
    }
    return Ht(m.type, tt, q);
  }, at.createContext = function(m) {
    return m = {
      $$typeof: Q,
      _currentValue: m,
      _currentValue2: m,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, m.Provider = m, m.Consumer = {
      $$typeof: J,
      _context: m
    }, m;
  }, at.createElement = function(m, E, B) {
    var q, tt = {}, ct = null;
    if (E != null)
      for (q in E.key !== void 0 && (ct = "" + E.key), E)
        Zt.call(E, q) && q !== "key" && q !== "__self" && q !== "__source" && (tt[q] = E[q]);
    var vt = arguments.length - 2;
    if (vt === 1) tt.children = B;
    else if (1 < vt) {
      for (var ie = Array(vt), Qt = 0; Qt < vt; Qt++)
        ie[Qt] = arguments[Qt + 2];
      tt.children = ie;
    }
    if (m && m.defaultProps)
      for (q in vt = m.defaultProps, vt)
        tt[q] === void 0 && (tt[q] = vt[q]);
    return Ht(m, ct, tt);
  }, at.createRef = function() {
    return { current: null };
  }, at.forwardRef = function(m) {
    return { $$typeof: et, render: m };
  }, at.isValidElement = Gt, at.lazy = function(m) {
    return {
      $$typeof: L,
      _payload: { _status: -1, _result: m },
      _init: j
    };
  }, at.memo = function(m, E) {
    return {
      $$typeof: z,
      type: m,
      compare: E === void 0 ? null : E
    };
  }, at.startTransition = function(m) {
    var E = k.T, B = {};
    k.T = B;
    try {
      var q = m(), tt = k.S;
      tt !== null && tt(B, q), typeof q == "object" && q !== null && typeof q.then == "function" && q.then(St, ot);
    } catch (ct) {
      ot(ct);
    } finally {
      E !== null && B.types !== null && (E.types = B.types), k.T = E;
    }
  }, at.unstable_useCacheRefresh = function() {
    return k.H.useCacheRefresh();
  }, at.use = function(m) {
    return k.H.use(m);
  }, at.useActionState = function(m, E, B) {
    return k.H.useActionState(m, E, B);
  }, at.useCallback = function(m, E) {
    return k.H.useCallback(m, E);
  }, at.useContext = function(m) {
    return k.H.useContext(m);
  }, at.useDebugValue = function() {
  }, at.useDeferredValue = function(m, E) {
    return k.H.useDeferredValue(m, E);
  }, at.useEffect = function(m, E) {
    return k.H.useEffect(m, E);
  }, at.useEffectEvent = function(m) {
    return k.H.useEffectEvent(m);
  }, at.useId = function() {
    return k.H.useId();
  }, at.useImperativeHandle = function(m, E, B) {
    return k.H.useImperativeHandle(m, E, B);
  }, at.useInsertionEffect = function(m, E) {
    return k.H.useInsertionEffect(m, E);
  }, at.useLayoutEffect = function(m, E) {
    return k.H.useLayoutEffect(m, E);
  }, at.useMemo = function(m, E) {
    return k.H.useMemo(m, E);
  }, at.useOptimistic = function(m, E) {
    return k.H.useOptimistic(m, E);
  }, at.useReducer = function(m, E, B) {
    return k.H.useReducer(m, E, B);
  }, at.useRef = function(m) {
    return k.H.useRef(m);
  }, at.useState = function(m) {
    return k.H.useState(m);
  }, at.useSyncExternalStore = function(m, E, B) {
    return k.H.useSyncExternalStore(
      m,
      E,
      B
    );
  }, at.useTransition = function() {
    return k.H.useTransition();
  }, at.version = "19.2.3", at;
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
  function f(U) {
    var z = "https://react.dev/errors/" + U;
    if (1 < arguments.length) {
      z += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var L = 2; L < arguments.length; L++)
        z += "&args[]=" + encodeURIComponent(arguments[L]);
    }
    return "Minified React error #" + U + "; visit " + z + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function O() {
  }
  var s = {
    d: {
      f: O,
      r: function() {
        throw Error(f(522));
      },
      D: O,
      C: O,
      L: O,
      m: O,
      X: O,
      S: O,
      M: O
    },
    p: 0,
    findDOMNode: null
  }, X = /* @__PURE__ */ Symbol.for("react.portal");
  function J(U, z, L) {
    var H = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: X,
      key: H == null ? null : "" + H,
      children: U,
      containerInfo: z,
      implementation: L
    };
  }
  var Q = S.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function et(U, z) {
    if (U === "font") return "";
    if (typeof z == "string")
      return z === "use-credentials" ? z : "";
  }
  return xe.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = s, xe.createPortal = function(U, z) {
    var L = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!z || z.nodeType !== 1 && z.nodeType !== 9 && z.nodeType !== 11)
      throw Error(f(299));
    return J(U, z, null, L);
  }, xe.flushSync = function(U) {
    var z = Q.T, L = s.p;
    try {
      if (Q.T = null, s.p = 2, U) return U();
    } finally {
      Q.T = z, s.p = L, s.d.f();
    }
  }, xe.preconnect = function(U, z) {
    typeof U == "string" && (z ? (z = z.crossOrigin, z = typeof z == "string" ? z === "use-credentials" ? z : "" : void 0) : z = null, s.d.C(U, z));
  }, xe.prefetchDNS = function(U) {
    typeof U == "string" && s.d.D(U);
  }, xe.preinit = function(U, z) {
    if (typeof U == "string" && z && typeof z.as == "string") {
      var L = z.as, H = et(L, z.crossOrigin), P = typeof z.integrity == "string" ? z.integrity : void 0, mt = typeof z.fetchPriority == "string" ? z.fetchPriority : void 0;
      L === "style" ? s.d.S(
        U,
        typeof z.precedence == "string" ? z.precedence : void 0,
        {
          crossOrigin: H,
          integrity: P,
          fetchPriority: mt
        }
      ) : L === "script" && s.d.X(U, {
        crossOrigin: H,
        integrity: P,
        fetchPriority: mt,
        nonce: typeof z.nonce == "string" ? z.nonce : void 0
      });
    }
  }, xe.preinitModule = function(U, z) {
    if (typeof U == "string")
      if (typeof z == "object" && z !== null) {
        if (z.as == null || z.as === "script") {
          var L = et(
            z.as,
            z.crossOrigin
          );
          s.d.M(U, {
            crossOrigin: L,
            integrity: typeof z.integrity == "string" ? z.integrity : void 0,
            nonce: typeof z.nonce == "string" ? z.nonce : void 0
          });
        }
      } else z == null && s.d.M(U);
  }, xe.preload = function(U, z) {
    if (typeof U == "string" && typeof z == "object" && z !== null && typeof z.as == "string") {
      var L = z.as, H = et(L, z.crossOrigin);
      s.d.L(U, L, {
        crossOrigin: H,
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
  }, xe.preloadModule = function(U, z) {
    if (typeof U == "string")
      if (z) {
        var L = et(z.as, z.crossOrigin);
        s.d.m(U, {
          as: typeof z.as == "string" && z.as !== "script" ? z.as : void 0,
          crossOrigin: L,
          integrity: typeof z.integrity == "string" ? z.integrity : void 0
        });
      } else s.d.m(U);
  }, xe.requestFormReset = function(U) {
    s.d.r(U);
  }, xe.unstable_batchedUpdates = function(U, z) {
    return U(z);
  }, xe.useFormState = function(U, z, L) {
    return Q.H.useFormState(U, z, L);
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
  var S = og(), f = mf(), O = dg();
  function s(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function X(t) {
    return !(!t || t.nodeType !== 1 && t.nodeType !== 9 && t.nodeType !== 11);
  }
  function J(t) {
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
  function et(t) {
    if (t.tag === 31) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function U(t) {
    if (J(t) !== t)
      throw Error(s(188));
  }
  function z(t) {
    var e = t.alternate;
    if (!e) {
      if (e = J(t), e === null) throw Error(s(188));
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
          if (i === l) return U(n), t;
          if (i === a) return U(n), e;
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
  var H = Object.assign, P = /* @__PURE__ */ Symbol.for("react.element"), mt = /* @__PURE__ */ Symbol.for("react.transitional.element"), nt = /* @__PURE__ */ Symbol.for("react.portal"), ht = /* @__PURE__ */ Symbol.for("react.fragment"), qt = /* @__PURE__ */ Symbol.for("react.strict_mode"), Ct = /* @__PURE__ */ Symbol.for("react.profiler"), rt = /* @__PURE__ */ Symbol.for("react.consumer"), xt = /* @__PURE__ */ Symbol.for("react.context"), At = /* @__PURE__ */ Symbol.for("react.forward_ref"), _t = /* @__PURE__ */ Symbol.for("react.suspense"), St = /* @__PURE__ */ Symbol.for("react.suspense_list"), k = /* @__PURE__ */ Symbol.for("react.memo"), Zt = /* @__PURE__ */ Symbol.for("react.lazy"), Ht = /* @__PURE__ */ Symbol.for("react.activity"), be = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), Gt = Symbol.iterator;
  function Yt(t) {
    return t === null || typeof t != "object" ? null : (t = Gt && t[Gt] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var se = /* @__PURE__ */ Symbol.for("react.client.reference");
  function ae(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === se ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case ht:
        return "Fragment";
      case Ct:
        return "Profiler";
      case qt:
        return "StrictMode";
      case _t:
        return "Suspense";
      case St:
        return "SuspenseList";
      case Ht:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case nt:
          return "Portal";
        case xt:
          return t.displayName || "Context";
        case rt:
          return (t._context.displayName || "Context") + ".Consumer";
        case At:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case k:
          return e = t.displayName || null, e !== null ? e : ae(t.type) || "Memo";
        case Zt:
          e = t._payload, t = t._init;
          try {
            return ae(t(e));
          } catch {
          }
      }
    return null;
  }
  var ne = Array.isArray, p = f.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, M = O.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, j = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, ot = [], W = -1;
  function m(t) {
    return { current: t };
  }
  function E(t) {
    0 > W || (t.current = ot[W], ot[W] = null, W--);
  }
  function B(t, e) {
    W++, ot[W] = t.current, t.current = e;
  }
  var q = m(null), tt = m(null), ct = m(null), vt = m(null);
  function ie(t, e) {
    switch (B(ct, e), B(tt, t), B(q, null), e.nodeType) {
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
    E(q), B(q, t);
  }
  function Qt() {
    E(q), E(tt), E(ct);
  }
  function Ue(t) {
    t.memoizedState !== null && B(vt, t);
    var e = q.current, l = Td(e, t.type);
    e !== l && (B(tt, t), B(q, l));
  }
  function Yl(t) {
    tt.current === t && (E(q), E(tt)), vt.current === t && (E(vt), Hi._currentValue = j);
  }
  var Ie, vl;
  function il(t) {
    if (Ie === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        Ie = e && e[1] || "", vl = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + Ie + t + vl;
  }
  var Yn = !1;
  function Re(t, e) {
    if (!t || Yn) return "";
    Yn = !0;
    var l = Error.prepareStackTrace;
    Error.prepareStackTrace = void 0;
    try {
      var a = {
        DetermineComponentFrameRoot: function() {
          try {
            if (e) {
              var C = function() {
                throw Error();
              };
              if (Object.defineProperty(C.prototype, "props", {
                set: function() {
                  throw Error();
                }
              }), typeof Reflect == "object" && Reflect.construct) {
                try {
                  Reflect.construct(C, []);
                } catch (T) {
                  var b = T;
                }
                Reflect.construct(t, [], C);
              } else {
                try {
                  C.call();
                } catch (T) {
                  b = T;
                }
                t.call(C.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (T) {
                b = T;
              }
              (C = t()) && typeof C.catch == "function" && C.catch(function() {
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
                  var A = `
` + r[a].replace(" at new ", " at ");
                  return t.displayName && A.includes("<anonymous>") && (A = A.replace("<anonymous>", t.displayName)), A;
                }
              while (1 <= a && 0 <= n);
            break;
          }
      }
    } finally {
      Yn = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? il(l) : "";
  }
  function hf(t, e) {
    switch (t.tag) {
      case 26:
      case 27:
      case 5:
        return il(t.type);
      case 16:
        return il("Lazy");
      case 13:
        return t.child !== e && e !== null ? il("Suspense Fallback") : il("Suspense");
      case 19:
        return il("SuspenseList");
      case 0:
      case 15:
        return Re(t.type, !1);
      case 11:
        return Re(t.type.render, !1);
      case 1:
        return Re(t.type, !0);
      case 31:
        return il("Activity");
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
  var Ln = Object.prototype.hasOwnProperty, Xn = S.unstable_scheduleCallback, ga = S.unstable_cancelCallback, Qn = S.unstable_shouldYield, Qi = S.unstable_requestPaint, de = S.unstable_now, Vi = S.unstable_getCurrentPriorityLevel, Zi = S.unstable_ImmediatePriority, Ja = S.unstable_UserBlockingPriority, pa = S.unstable_NormalPriority, gf = S.unstable_LowPriority, Ki = S.unstable_IdlePriority, pf = S.log, Ji = S.unstable_setDisableYieldValue, ya = null, Se = null;
  function ul(t) {
    if (typeof pf == "function" && Ji(t), Se && typeof Se.setStrictMode == "function")
      try {
        Se.setStrictMode(ya, t);
      } catch {
      }
  }
  var ue = Math.clz32 ? Math.clz32 : yf, ki = Math.log, ka = Math.LN2;
  function yf(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (ki(t) / ka | 0) | 0;
  }
  var bl = 256, Fa = 262144, Wa = 4194304;
  function fl(t) {
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
  function va(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, i = t.suspendedLanes, u = t.pingedLanes;
    t = t.warmLanes;
    var c = a & 134217727;
    return c !== 0 ? (a = c & ~i, a !== 0 ? n = fl(a) : (u &= c, u !== 0 ? n = fl(u) : l || (l = c & ~t, l !== 0 && (n = fl(l))))) : (c = a & ~i, c !== 0 ? n = fl(c) : u !== 0 ? n = fl(u) : l || (l = a & ~t, l !== 0 && (n = fl(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function ba(t, e) {
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
    var t = Wa;
    return Wa <<= 1, (Wa & 62914560) === 0 && (Wa = 4194304), t;
  }
  function Zn(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function cl(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function Fi(t, e, l, a, n, i) {
    var u = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var c = t.entanglements, r = t.expirationTimes, v = t.hiddenUpdates;
    for (l = u & ~l; 0 < l; ) {
      var A = 31 - ue(l), C = 1 << A;
      c[A] = 0, r[A] = -1;
      var b = v[A];
      if (b !== null)
        for (v[A] = null, A = 0; A < b.length; A++) {
          var T = b[A];
          T !== null && (T.lane &= -536870913);
        }
      l &= ~C;
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
  function $a(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : xa(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function xa(t) {
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
    var t = M.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Zd(t.type));
  }
  function Jn(t, e) {
    var l = M.p;
    try {
      return M.p = t, e();
    } finally {
      M.p = l;
    }
  }
  var ol = Math.random().toString(36).slice(2), It = "__reactFiber$" + ol, me = "__reactProps$" + ol, Sl = "__reactContainer$" + ol, kn = "__reactEvents$" + ol, vf = "__reactListeners$" + ol, bf = "__reactHandles$" + ol, Ii = "__reactResources$" + ol, Sa = "__reactMarker$" + ol;
  function Ia(t) {
    delete t[It], delete t[me], delete t[kn], delete t[vf], delete t[bf];
  }
  function rl(t) {
    var e = t[It];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[Sl] || l[It]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Od(t); t !== null; ) {
            if (l = t[It]) return l;
            t = Od(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function sl(t) {
    if (t = t[It] || t[Sl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function Ll(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(s(33));
  }
  function Pe(t) {
    var e = t[Ii];
    return e || (e = t[Ii] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function Ft(t) {
    t[Sa] = !0;
  }
  var Fn = /* @__PURE__ */ new Set(), Pi = {};
  function dl(t, e) {
    Xl(t, e), Xl(t + "Capture", e);
  }
  function Xl(t, e) {
    for (Pi[t] = e, t = 0; t < e.length; t++)
      Fn.add(e[t]);
  }
  var tu = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), eu = {}, lu = {};
  function Wn(t) {
    return Ln.call(lu, t) ? !0 : Ln.call(eu, t) ? !1 : tu.test(t) ? lu[t] = !0 : (eu[t] = !0, !1);
  }
  function Pa(t, e, l) {
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
  function Ta(t, e, l) {
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
  function tl(t, e, l, a) {
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
  function oe(t) {
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
  function tn(t) {
    if (!t._valueTracker) {
      var e = au(t) ? "checked" : "value";
      t._valueTracker = xf(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function Ql(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = au(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function en(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var we = /[\n"\\]/g;
  function he(t) {
    return t.replace(
      we,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function $n(t, e, l, a, n, i, u, c) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + oe(e)) : t.value !== "" + oe(e) && (t.value = "" + oe(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? o(t, u, oe(e)) : l != null ? o(t, u, oe(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), c != null && typeof c != "function" && typeof c != "symbol" && typeof c != "boolean" ? t.name = "" + oe(c) : t.removeAttribute("name");
  }
  function nu(t, e, l, a, n, i, u, c) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        tn(t);
        return;
      }
      l = l != null ? "" + oe(l) : "", e = e != null ? "" + oe(e) : l, c || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = c ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), tn(t);
  }
  function o(t, e, l) {
    e === "number" && en(t.ownerDocument) === t || t.defaultValue === "" + l || (t.defaultValue = "" + l);
  }
  function d(t, e, l, a) {
    if (t = t.options, e) {
      e = {};
      for (var n = 0; n < l.length; n++)
        e["$" + l[n]] = !0;
      for (l = 0; l < t.length; l++)
        n = e.hasOwnProperty("$" + t[l].value), t[l].selected !== n && (t[l].selected = n), n && a && (t[l].defaultSelected = !0);
    } else {
      for (l = "" + oe(l), e = null, n = 0; n < t.length; n++) {
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
    if (e != null && (e = "" + oe(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + oe(l) : "";
  }
  function w(t, e, l, a) {
    if (e == null) {
      if (a != null) {
        if (l != null) throw Error(s(92));
        if (ne(a)) {
          if (1 < a.length) throw Error(s(93));
          a = a[0];
        }
        l = a;
      }
      l == null && (l = ""), e = l;
    }
    l = oe(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), tn(t);
  }
  function N(t, e) {
    if (e) {
      var l = t.firstChild;
      if (l && l === t.lastChild && l.nodeType === 3) {
        l.nodeValue = e;
        return;
      }
    }
    t.textContent = e;
  }
  var G = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function K(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || G.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function lt(t, e, l) {
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
  function gt(t) {
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
  ]), Vl = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function ln(t) {
    return Vl.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function el() {
  }
  var In = null;
  function an(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Zl = null, Tl = null;
  function iu(t) {
    var e = sl(t);
    if (e && (t = e.stateNode)) {
      var l = t[me] || null;
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
              'input[name="' + he(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[me] || null;
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
              a = l[e], a.form === t.form && Ql(a);
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
  var za = !1;
  function nn(t, e, l) {
    if (za) return t(e, l);
    za = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (za = !1, (Zl !== null || Tl !== null) && (Qu(), Zl && (e = Zl, t = Tl, Tl = Zl = null, iu(e), t)))
        for (e = 0; e < t.length; e++) iu(t[e]);
    }
  }
  function Ma(t, e) {
    var l = t.stateNode;
    if (l === null) return null;
    var a = l[me] || null;
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
  var Xe = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), Ea = !1;
  if (Xe)
    try {
      var zl = {};
      Object.defineProperty(zl, "passive", {
        get: function() {
          Ea = !0;
        }
      }), window.addEventListener("test", zl, zl), window.removeEventListener("test", zl, zl);
    } catch {
      Ea = !1;
    }
  var Ee = null, un = null, fn = null;
  function Pn() {
    if (fn) return fn;
    var t, e = un, l = e.length, a, n = "value" in Ee ? Ee.value : Ee.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return fn = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function Aa(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function cn() {
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
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? cn : ti, this.isPropagationStopped = ti, this;
    }
    return H(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = cn);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = cn);
      },
      persist: function() {
      },
      isPersistent: cn
    }), e;
  }
  var ml = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, on = fe(ml), _a = H({}, ml, { view: 0, detail: 0 }), uu = fe(_a), ei, Da, Qe, Oa = H({}, _a, {
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
      return "movementX" in t ? t.movementX : (t !== Qe && (Qe && t.type === "mousemove" ? (ei = t.screenX - Qe.screenX, Da = t.screenY - Qe.screenY) : Da = ei = 0, Qe = t), ei);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : Da;
    }
  }), li = fe(Oa), rn = H({}, Oa, { dataTransfer: 0 }), D = fe(rn), R = H({}, _a, { relatedTarget: 0 }), I = fe(R), it = H({}, ml, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), Tt = fe(it), zt = H({}, ml, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), Kt = fe(zt), ze = H({}, ml, { data: 0 }), Kl = fe(ze), Be = {
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
  var ym = H({}, _a, {
    key: function(t) {
      if (t.key) {
        var e = Be[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = Aa(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? fu[t.keyCode] || "Unidentified" : "";
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
      return t.type === "keypress" ? Aa(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? Aa(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), vm = fe(ym), bm = H({}, Oa, {
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
  }), Ao = fe(bm), xm = H({}, _a, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: Tf
  }), Sm = fe(xm), Tm = H({}, ml, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), zm = fe(Tm), Mm = H({}, Oa, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), Em = fe(Mm), Am = H({}, ml, {
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
  var sn = !1;
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
    if (sn)
      return t === "compositionend" || !zf && Co(t, e) ? (t = Pn(), fn = un = Ee = null, sn = !1, t) : null;
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
  function wo(t, e, l, a) {
    Zl ? Tl ? Tl.push(a) : Tl = [a] : Zl = a, e = Wu(e, "onChange"), 0 < e.length && (l = new on(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var ni = null, ii = null;
  function wm(t) {
    gd(t, 0);
  }
  function cu(t) {
    var e = Ll(t);
    if (Ql(e)) return t;
  }
  function Bo(t, e) {
    if (t === "change") return e;
  }
  var No = !1;
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
    No = Mf && (!document.documentMode || 9 < document.documentMode);
  }
  function jo() {
    ni && (ni.detachEvent("onpropertychange", qo), ii = ni = null);
  }
  function qo(t) {
    if (t.propertyName === "value" && cu(ii)) {
      var e = [];
      wo(
        e,
        ii,
        t,
        an(t)
      ), nn(wm, e);
    }
  }
  function Bm(t, e, l) {
    t === "focusin" ? (jo(), ni = e, ii = l, ni.attachEvent("onpropertychange", qo)) : t === "focusout" && jo();
  }
  function Nm(t) {
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
    for (var e = en(t.document); e instanceof t.HTMLIFrameElement; ) {
      try {
        var l = typeof e.contentWindow.location.href == "string";
      } catch {
        l = !1;
      }
      if (l) t = e.contentWindow;
      else break;
      e = en(t.document);
    }
    return e;
  }
  function Af(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var Gm = Xe && "documentMode" in document && 11 >= document.documentMode, dn = null, _f = null, fi = null, Df = !1;
  function Qo(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Df || dn == null || dn !== en(a) || (a = dn, "selectionStart" in a && Af(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), fi && ui(fi, a) || (fi = a, a = Wu(_f, "onSelect"), 0 < a.length && (e = new on(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = dn)));
  }
  function Ca(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var mn = {
    animationend: Ca("Animation", "AnimationEnd"),
    animationiteration: Ca("Animation", "AnimationIteration"),
    animationstart: Ca("Animation", "AnimationStart"),
    transitionrun: Ca("Transition", "TransitionRun"),
    transitionstart: Ca("Transition", "TransitionStart"),
    transitioncancel: Ca("Transition", "TransitionCancel"),
    transitionend: Ca("Transition", "TransitionEnd")
  }, Of = {}, Vo = {};
  Xe && (Vo = document.createElement("div").style, "AnimationEvent" in window || (delete mn.animationend.animation, delete mn.animationiteration.animation, delete mn.animationstart.animation), "TransitionEvent" in window || delete mn.transitionend.transition);
  function Ua(t) {
    if (Of[t]) return Of[t];
    if (!mn[t]) return t;
    var e = mn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Vo)
        return Of[t] = e[l];
    return t;
  }
  var Zo = Ua("animationend"), Ko = Ua("animationiteration"), Jo = Ua("animationstart"), Ym = Ua("transitionrun"), Lm = Ua("transitionstart"), Xm = Ua("transitioncancel"), ko = Ua("transitionend"), Fo = /* @__PURE__ */ new Map(), Cf = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Cf.push("scrollEnd");
  function ll(t, e) {
    Fo.set(t, e), dl(e, [t]);
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
  }, Ve = [], hn = 0, Uf = 0;
  function ru() {
    for (var t = hn, e = Uf = hn = 0; e < t; ) {
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
    Ve[hn++] = t, Ve[hn++] = e, Ve[hn++] = l, Ve[hn++] = a, Uf |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Rf(t, e, l, a) {
    return su(t, e, l, a), du(t);
  }
  function Ra(t, e) {
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
  var gn = {};
  function Qm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function He(t, e, l, a) {
    return new Qm(t, e, l, a);
  }
  function wf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function Ml(t, e) {
    var l = t.alternate;
    return l === null ? (l = He(
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
    if (a = t, typeof t == "function") wf(t) && (u = 1);
    else if (typeof t == "string")
      u = kh(
        t,
        l,
        q.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case Ht:
          return t = He(31, l, e, n), t.elementType = Ht, t.lanes = i, t;
        case ht:
          return wa(l.children, n, i, e);
        case qt:
          u = 8, n |= 24;
          break;
        case Ct:
          return t = He(12, l, e, n | 2), t.elementType = Ct, t.lanes = i, t;
        case _t:
          return t = He(13, l, e, n), t.elementType = _t, t.lanes = i, t;
        case St:
          return t = He(19, l, e, n), t.elementType = St, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case xt:
                u = 10;
                break t;
              case rt:
                u = 9;
                break t;
              case At:
                u = 11;
                break t;
              case k:
                u = 14;
                break t;
              case Zt:
                u = 16, a = null;
                break t;
            }
          u = 29, l = Error(
            s(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = He(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function wa(t, e, l, a) {
    return t = He(7, t, a, e), t.lanes = l, t;
  }
  function Bf(t, e, l) {
    return t = He(6, t, null, e), t.lanes = l, t;
  }
  function Io(t) {
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
  var pn = [], yn = 0, hu = null, ci = 0, Ke = [], Je = 0, Jl = null, hl = 1, gl = "";
  function El(t, e) {
    pn[yn++] = ci, pn[yn++] = hu, hu = t, ci = e;
  }
  function tr(t, e, l) {
    Ke[Je++] = hl, Ke[Je++] = gl, Ke[Je++] = Jl, Jl = t;
    var a = hl;
    t = gl;
    var n = 32 - ue(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - ue(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, hl = 1 << 32 - ue(e) + n | l << n | a, gl = i + t;
    } else
      hl = 1 << i | l << n | a, gl = t;
  }
  function Hf(t) {
    t.return !== null && (El(t, 1), tr(t, 1, 0));
  }
  function jf(t) {
    for (; t === hu; )
      hu = pn[--yn], pn[yn] = null, ci = pn[--yn], pn[yn] = null;
    for (; t === Jl; )
      Jl = Ke[--Je], Ke[Je] = null, gl = Ke[--Je], Ke[Je] = null, hl = Ke[--Je], Ke[Je] = null;
  }
  function er(t, e) {
    Ke[Je++] = hl, Ke[Je++] = gl, Ke[Je++] = Jl, hl = e.id, gl = e.overflow, Jl = t;
  }
  var ge = null, Lt = null, bt = !1, kl = null, ke = !1, qf = Error(s(519));
  function Fl(t) {
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
    switch (e[It] = t, e[me] = a, l) {
      case "dialog":
        dt("cancel", e), dt("close", e);
        break;
      case "iframe":
      case "object":
      case "embed":
        dt("load", e);
        break;
      case "video":
      case "audio":
        for (l = 0; l < Ui.length; l++)
          dt(Ui[l], e);
        break;
      case "source":
        dt("error", e);
        break;
      case "img":
      case "image":
      case "link":
        dt("error", e), dt("load", e);
        break;
      case "details":
        dt("toggle", e);
        break;
      case "input":
        dt("invalid", e), nu(
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
        dt("invalid", e);
        break;
      case "textarea":
        dt("invalid", e), w(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || bd(e.textContent, l) ? (a.popover != null && (dt("beforetoggle", e), dt("toggle", e)), a.onScroll != null && dt("scroll", e), a.onScrollEnd != null && dt("scrollend", e), a.onClick != null && (e.onclick = el), e = !0) : e = !1, e || Fl(t, !0);
  }
  function ar(t) {
    for (ge = t.return; ge; )
      switch (ge.tag) {
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
          ge = ge.return;
      }
  }
  function vn(t) {
    if (t !== ge) return !1;
    if (!bt) return ar(t), bt = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || lo(t.type, t.memoizedProps)), l = !l), l && Lt && Fl(t), ar(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = Dd(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = Dd(t);
    } else
      e === 27 ? (e = Lt, oa(t.type) ? (t = fo, fo = null, Lt = t) : Lt = e) : Lt = ge ? We(t.stateNode.nextSibling) : null;
    return !0;
  }
  function Ba() {
    Lt = ge = null, bt = !1;
  }
  function Gf() {
    var t = kl;
    return t !== null && (Oe === null ? Oe = t : Oe.push.apply(
      Oe,
      t
    ), kl = null), t;
  }
  function oi(t) {
    kl === null ? kl = [t] : kl.push(t);
  }
  var Yf = m(null), Na = null, Al = null;
  function Wl(t, e, l) {
    B(Yf, e._currentValue), e._currentValue = l;
  }
  function _l(t) {
    t._currentValue = Yf.current, E(Yf);
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
          Ne(n.pendingProps.value, u.value) || (t !== null ? t.push(c) : t = [c]);
        }
      } else if (n === vt.current) {
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
  function Ha(t) {
    Na = t, Al = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function pe(t) {
    return nr(Na, t);
  }
  function pu(t, e) {
    return Na === null && Ha(t), nr(t, e);
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
  }, Zm = S.unstable_scheduleCallback, Km = S.unstable_NormalPriority, Pt = {
    $$typeof: xt,
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
  var si = null, Vf = 0, xn = 0, Sn = null;
  function Jm(t, e) {
    if (si === null) {
      var l = si = [];
      Vf = 0, xn = Jc(), Sn = {
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
      Sn !== null && (Sn.status = "fulfilled");
      var t = si;
      si = null, xn = 0, Sn = null;
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
  var ur = p.S;
  p.S = function(t, e) {
    Qs = de(), typeof e == "object" && e !== null && typeof e.then == "function" && Jm(t, e), ur !== null && ur(t, e);
  };
  var ja = m(null);
  function Zf() {
    var t = ja.current;
    return t !== null ? t : jt.pooledCache;
  }
  function yu(t, e) {
    e === null ? B(ja, ja.current) : B(ja, e.pool);
  }
  function fr() {
    var t = Zf();
    return t === null ? null : { parent: Pt._currentValue, pool: t };
  }
  var Tn = Error(s(460)), Kf = Error(s(474)), vu = Error(s(542)), bu = { then: function() {
  } };
  function cr(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function or(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(el, el), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, sr(t), t;
      default:
        if (typeof e.status == "string") e.then(el, el);
        else {
          if (t = jt, t !== null && 100 < t.shellSuspendCounter)
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
        throw Ga = e, Tn;
    }
  }
  function qa(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (Ga = l, Tn) : l;
    }
  }
  var Ga = null;
  function rr() {
    if (Ga === null) throw Error(s(459));
    var t = Ga;
    return Ga = null, t;
  }
  function sr(t) {
    if (t === Tn || t === vu)
      throw Error(s(483));
  }
  var zn = null, di = 0;
  function xu(t) {
    var e = di;
    return di += 1, zn === null && (zn = []), or(zn, t, e);
  }
  function mi(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function Su(t, e) {
    throw e.$$typeof === P ? Error(s(525)) : (t = Object.prototype.toString.call(e), Error(
      s(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function dr(t) {
    function e(g, h) {
      if (t) {
        var y = g.deletions;
        y === null ? (g.deletions = [h], g.flags |= 16) : y.push(h);
      }
    }
    function l(g, h) {
      if (!t) return null;
      for (; h !== null; )
        e(g, h), h = h.sibling;
      return null;
    }
    function a(g) {
      for (var h = /* @__PURE__ */ new Map(); g !== null; )
        g.key !== null ? h.set(g.key, g) : h.set(g.index, g), g = g.sibling;
      return h;
    }
    function n(g, h) {
      return g = Ml(g, h), g.index = 0, g.sibling = null, g;
    }
    function i(g, h, y) {
      return g.index = y, t ? (y = g.alternate, y !== null ? (y = y.index, y < h ? (g.flags |= 67108866, h) : y) : (g.flags |= 67108866, h)) : (g.flags |= 1048576, h);
    }
    function u(g) {
      return t && g.alternate === null && (g.flags |= 67108866), g;
    }
    function c(g, h, y, _) {
      return h === null || h.tag !== 6 ? (h = Bf(y, g.mode, _), h.return = g, h) : (h = n(h, y), h.return = g, h);
    }
    function r(g, h, y, _) {
      var F = y.type;
      return F === ht ? A(
        g,
        h,
        y.props.children,
        _,
        y.key
      ) : h !== null && (h.elementType === F || typeof F == "object" && F !== null && F.$$typeof === Zt && qa(F) === h.type) ? (h = n(h, y.props), mi(h, y), h.return = g, h) : (h = mu(
        y.type,
        y.key,
        y.props,
        null,
        g.mode,
        _
      ), mi(h, y), h.return = g, h);
    }
    function v(g, h, y, _) {
      return h === null || h.tag !== 4 || h.stateNode.containerInfo !== y.containerInfo || h.stateNode.implementation !== y.implementation ? (h = Nf(y, g.mode, _), h.return = g, h) : (h = n(h, y.children || []), h.return = g, h);
    }
    function A(g, h, y, _, F) {
      return h === null || h.tag !== 7 ? (h = wa(
        y,
        g.mode,
        _,
        F
      ), h.return = g, h) : (h = n(h, y), h.return = g, h);
    }
    function C(g, h, y) {
      if (typeof h == "string" && h !== "" || typeof h == "number" || typeof h == "bigint")
        return h = Bf(
          "" + h,
          g.mode,
          y
        ), h.return = g, h;
      if (typeof h == "object" && h !== null) {
        switch (h.$$typeof) {
          case mt:
            return y = mu(
              h.type,
              h.key,
              h.props,
              null,
              g.mode,
              y
            ), mi(y, h), y.return = g, y;
          case nt:
            return h = Nf(
              h,
              g.mode,
              y
            ), h.return = g, h;
          case Zt:
            return h = qa(h), C(g, h, y);
        }
        if (ne(h) || Yt(h))
          return h = wa(
            h,
            g.mode,
            y,
            null
          ), h.return = g, h;
        if (typeof h.then == "function")
          return C(g, xu(h), y);
        if (h.$$typeof === xt)
          return C(
            g,
            pu(g, h),
            y
          );
        Su(g, h);
      }
      return null;
    }
    function b(g, h, y, _) {
      var F = h !== null ? h.key : null;
      if (typeof y == "string" && y !== "" || typeof y == "number" || typeof y == "bigint")
        return F !== null ? null : c(g, h, "" + y, _);
      if (typeof y == "object" && y !== null) {
        switch (y.$$typeof) {
          case mt:
            return y.key === F ? r(g, h, y, _) : null;
          case nt:
            return y.key === F ? v(g, h, y, _) : null;
          case Zt:
            return y = qa(y), b(g, h, y, _);
        }
        if (ne(y) || Yt(y))
          return F !== null ? null : A(g, h, y, _, null);
        if (typeof y.then == "function")
          return b(
            g,
            h,
            xu(y),
            _
          );
        if (y.$$typeof === xt)
          return b(
            g,
            h,
            pu(g, y),
            _
          );
        Su(g, y);
      }
      return null;
    }
    function T(g, h, y, _, F) {
      if (typeof _ == "string" && _ !== "" || typeof _ == "number" || typeof _ == "bigint")
        return g = g.get(y) || null, c(h, g, "" + _, F);
      if (typeof _ == "object" && _ !== null) {
        switch (_.$$typeof) {
          case mt:
            return g = g.get(
              _.key === null ? y : _.key
            ) || null, r(h, g, _, F);
          case nt:
            return g = g.get(
              _.key === null ? y : _.key
            ) || null, v(h, g, _, F);
          case Zt:
            return _ = qa(_), T(
              g,
              h,
              y,
              _,
              F
            );
        }
        if (ne(_) || Yt(_))
          return g = g.get(y) || null, A(h, g, _, F, null);
        if (typeof _.then == "function")
          return T(
            g,
            h,
            y,
            xu(_),
            F
          );
        if (_.$$typeof === xt)
          return T(
            g,
            h,
            y,
            pu(h, _),
            F
          );
        Su(h, _);
      }
      return null;
    }
    function Y(g, h, y, _) {
      for (var F = null, Mt = null, V = h, ft = h = 0, yt = null; V !== null && ft < y.length; ft++) {
        V.index > ft ? (yt = V, V = null) : yt = V.sibling;
        var Et = b(
          g,
          V,
          y[ft],
          _
        );
        if (Et === null) {
          V === null && (V = yt);
          break;
        }
        t && V && Et.alternate === null && e(g, V), h = i(Et, h, ft), Mt === null ? F = Et : Mt.sibling = Et, Mt = Et, V = yt;
      }
      if (ft === y.length)
        return l(g, V), bt && El(g, ft), F;
      if (V === null) {
        for (; ft < y.length; ft++)
          V = C(g, y[ft], _), V !== null && (h = i(
            V,
            h,
            ft
          ), Mt === null ? F = V : Mt.sibling = V, Mt = V);
        return bt && El(g, ft), F;
      }
      for (V = a(V); ft < y.length; ft++)
        yt = T(
          V,
          g,
          ft,
          y[ft],
          _
        ), yt !== null && (t && yt.alternate !== null && V.delete(
          yt.key === null ? ft : yt.key
        ), h = i(
          yt,
          h,
          ft
        ), Mt === null ? F = yt : Mt.sibling = yt, Mt = yt);
      return t && V.forEach(function(ha) {
        return e(g, ha);
      }), bt && El(g, ft), F;
    }
    function $(g, h, y, _) {
      if (y == null) throw Error(s(151));
      for (var F = null, Mt = null, V = h, ft = h = 0, yt = null, Et = y.next(); V !== null && !Et.done; ft++, Et = y.next()) {
        V.index > ft ? (yt = V, V = null) : yt = V.sibling;
        var ha = b(g, V, Et.value, _);
        if (ha === null) {
          V === null && (V = yt);
          break;
        }
        t && V && ha.alternate === null && e(g, V), h = i(ha, h, ft), Mt === null ? F = ha : Mt.sibling = ha, Mt = ha, V = yt;
      }
      if (Et.done)
        return l(g, V), bt && El(g, ft), F;
      if (V === null) {
        for (; !Et.done; ft++, Et = y.next())
          Et = C(g, Et.value, _), Et !== null && (h = i(Et, h, ft), Mt === null ? F = Et : Mt.sibling = Et, Mt = Et);
        return bt && El(g, ft), F;
      }
      for (V = a(V); !Et.done; ft++, Et = y.next())
        Et = T(V, g, ft, Et.value, _), Et !== null && (t && Et.alternate !== null && V.delete(Et.key === null ? ft : Et.key), h = i(Et, h, ft), Mt === null ? F = Et : Mt.sibling = Et, Mt = Et);
      return t && V.forEach(function(ig) {
        return e(g, ig);
      }), bt && El(g, ft), F;
    }
    function Nt(g, h, y, _) {
      if (typeof y == "object" && y !== null && y.type === ht && y.key === null && (y = y.props.children), typeof y == "object" && y !== null) {
        switch (y.$$typeof) {
          case mt:
            t: {
              for (var F = y.key; h !== null; ) {
                if (h.key === F) {
                  if (F = y.type, F === ht) {
                    if (h.tag === 7) {
                      l(
                        g,
                        h.sibling
                      ), _ = n(
                        h,
                        y.props.children
                      ), _.return = g, g = _;
                      break t;
                    }
                  } else if (h.elementType === F || typeof F == "object" && F !== null && F.$$typeof === Zt && qa(F) === h.type) {
                    l(
                      g,
                      h.sibling
                    ), _ = n(h, y.props), mi(_, y), _.return = g, g = _;
                    break t;
                  }
                  l(g, h);
                  break;
                } else e(g, h);
                h = h.sibling;
              }
              y.type === ht ? (_ = wa(
                y.props.children,
                g.mode,
                _,
                y.key
              ), _.return = g, g = _) : (_ = mu(
                y.type,
                y.key,
                y.props,
                null,
                g.mode,
                _
              ), mi(_, y), _.return = g, g = _);
            }
            return u(g);
          case nt:
            t: {
              for (F = y.key; h !== null; ) {
                if (h.key === F)
                  if (h.tag === 4 && h.stateNode.containerInfo === y.containerInfo && h.stateNode.implementation === y.implementation) {
                    l(
                      g,
                      h.sibling
                    ), _ = n(h, y.children || []), _.return = g, g = _;
                    break t;
                  } else {
                    l(g, h);
                    break;
                  }
                else e(g, h);
                h = h.sibling;
              }
              _ = Nf(y, g.mode, _), _.return = g, g = _;
            }
            return u(g);
          case Zt:
            return y = qa(y), Nt(
              g,
              h,
              y,
              _
            );
        }
        if (ne(y))
          return Y(
            g,
            h,
            y,
            _
          );
        if (Yt(y)) {
          if (F = Yt(y), typeof F != "function") throw Error(s(150));
          return y = F.call(y), $(
            g,
            h,
            y,
            _
          );
        }
        if (typeof y.then == "function")
          return Nt(
            g,
            h,
            xu(y),
            _
          );
        if (y.$$typeof === xt)
          return Nt(
            g,
            h,
            pu(g, y),
            _
          );
        Su(g, y);
      }
      return typeof y == "string" && y !== "" || typeof y == "number" || typeof y == "bigint" ? (y = "" + y, h !== null && h.tag === 6 ? (l(g, h.sibling), _ = n(h, y), _.return = g, g = _) : (l(g, h), _ = Bf(y, g.mode, _), _.return = g, g = _), u(g)) : l(g, h);
    }
    return function(g, h, y, _) {
      try {
        di = 0;
        var F = Nt(
          g,
          h,
          y,
          _
        );
        return zn = null, F;
      } catch (V) {
        if (V === Tn || V === vu) throw V;
        var Mt = He(29, V, null, g.mode);
        return Mt.lanes = _, Mt.return = g, Mt;
      }
    };
  }
  var Ya = dr(!0), mr = dr(!1), $l = !1;
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
  function Il(t) {
    return { lane: t, tag: 0, payload: null, callback: null, next: null };
  }
  function Pl(t, e, l) {
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
      var t = Sn;
      if (t !== null) throw t;
    }
  }
  function pi(t, e, l, a) {
    Wf = !1;
    var n = t.updateQueue;
    $l = !1;
    var i = n.firstBaseUpdate, u = n.lastBaseUpdate, c = n.shared.pending;
    if (c !== null) {
      n.shared.pending = null;
      var r = c, v = r.next;
      r.next = null, u === null ? i = v : u.next = v, u = r;
      var A = t.alternate;
      A !== null && (A = A.updateQueue, c = A.lastBaseUpdate, c !== u && (c === null ? A.firstBaseUpdate = v : c.next = v, A.lastBaseUpdate = r));
    }
    if (i !== null) {
      var C = n.baseState;
      u = 0, A = v = r = null, c = i;
      do {
        var b = c.lane & -536870913, T = b !== c.lane;
        if (T ? (pt & b) === b : (a & b) === b) {
          b !== 0 && b === xn && (Wf = !0), A !== null && (A = A.next = {
            lane: 0,
            tag: c.tag,
            payload: c.payload,
            callback: null,
            next: null
          });
          t: {
            var Y = t, $ = c;
            b = e;
            var Nt = l;
            switch ($.tag) {
              case 1:
                if (Y = $.payload, typeof Y == "function") {
                  C = Y.call(Nt, C, b);
                  break t;
                }
                C = Y;
                break t;
              case 3:
                Y.flags = Y.flags & -65537 | 128;
              case 0:
                if (Y = $.payload, b = typeof Y == "function" ? Y.call(Nt, C, b) : Y, b == null) break t;
                C = H({}, C, b);
                break t;
              case 2:
                $l = !0;
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
          }, A === null ? (v = A = T, r = C) : A = A.next = T, u |= b;
        if (c = c.next, c === null) {
          if (c = n.shared.pending, c === null)
            break;
          T = c, c = T.next, T.next = null, n.lastBaseUpdate = T, n.shared.pending = null;
        }
      } while (!0);
      A === null && (r = C), n.baseState = r, n.firstBaseUpdate = v, n.lastBaseUpdate = A, i === null && (n.shared.lanes = 0), na |= u, t.lanes = u, t.memoizedState = C;
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
  var Mn = m(null), Tu = m(0);
  function pr(t, e) {
    t = Hl, B(Tu, t), B(Mn, e), Hl = t | e.baseLanes;
  }
  function $f() {
    B(Tu, Hl), B(Mn, Mn.current);
  }
  function If() {
    Hl = Tu.current, E(Mn), E(Tu);
  }
  var je = m(null), Fe = null;
  function ta(t) {
    var e = t.alternate;
    B(Wt, Wt.current & 1), B(je, t), Fe === null && (e === null || Mn.current !== null || e.memoizedState !== null) && (Fe = t);
  }
  function Pf(t) {
    B(Wt, Wt.current), B(je, t), Fe === null && (Fe = t);
  }
  function yr(t) {
    t.tag === 22 ? (B(Wt, Wt.current), B(je, t), Fe === null && (Fe = t)) : ea();
  }
  function ea() {
    B(Wt, Wt.current), B(je, je.current);
  }
  function qe(t) {
    E(je), Fe === t && (Fe = null), E(Wt);
  }
  var Wt = m(0);
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
  var Dl = 0, ut = null, wt = null, te = null, Mu = !1, En = !1, La = !1, Eu = 0, yi = 0, An = null, Fm = 0;
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
    return Dl = i, ut = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, p.H = t === null || t.memoizedState === null ? ts : pc, La = !1, i = l(a, n), La = !1, En && (i = br(
      e,
      l,
      a,
      n
    )), vr(t), i;
  }
  function vr(t) {
    p.H = xi;
    var e = wt !== null && wt.next !== null;
    if (Dl = 0, te = wt = ut = null, Mu = !1, yi = 0, An = null, e) throw Error(s(300));
    t === null || ee || (t = t.dependencies, t !== null && gu(t) && (ee = !0));
  }
  function br(t, e, l, a) {
    ut = t;
    var n = 0;
    do {
      if (En && (An = null), yi = 0, En = !1, 25 <= n) throw Error(s(301));
      if (n += 1, te = wt = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      p.H = es, i = e(l, a);
    } while (En);
    return i;
  }
  function Wm() {
    var t = p.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? vi(e) : e, t = t.useState()[0], (wt !== null ? wt.memoizedState : null) !== t && (ut.flags |= 1024), e;
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
    Dl = 0, te = wt = ut = null, En = !1, yi = Eu = 0, An = null;
  }
  function Me() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return te === null ? ut.memoizedState = te = t : te = te.next = t, te;
  }
  function $t() {
    if (wt === null) {
      var t = ut.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = wt.next;
    var e = te === null ? ut.memoizedState : te.next;
    if (e !== null)
      te = e, wt = t;
    else {
      if (t === null)
        throw ut.alternate === null ? Error(s(467)) : Error(s(310));
      wt = t, t = {
        memoizedState: wt.memoizedState,
        baseState: wt.baseState,
        baseQueue: wt.baseQueue,
        queue: wt.queue,
        next: null
      }, te === null ? ut.memoizedState = te = t : te = te.next = t;
    }
    return te;
  }
  function Au() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function vi(t) {
    var e = yi;
    return yi += 1, An === null && (An = []), t = or(An, t, e), e = ut, (te === null ? e.memoizedState : te.next) === null && (e = e.alternate, p.H = e === null || e.memoizedState === null ? ts : pc), t;
  }
  function _u(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return vi(t);
      if (t.$$typeof === xt) return pe(t);
    }
    throw Error(s(438, String(t)));
  }
  function ic(t) {
    var e = null, l = ut.updateQueue;
    if (l !== null && (e = l.memoCache), e == null) {
      var a = ut.alternate;
      a !== null && (a = a.updateQueue, a !== null && (a = a.memoCache, a != null && (e = {
        data: a.data.map(function(n) {
          return n.slice();
        }),
        index: 0
      })));
    }
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Au(), ut.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = be;
    return e.index++, l;
  }
  function Ol(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function Du(t) {
    var e = $t();
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
      var c = u = null, r = null, v = e, A = !1;
      do {
        var C = v.lane & -536870913;
        if (C !== v.lane ? (pt & C) === C : (Dl & C) === C) {
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
            }), C === xn && (A = !0);
          else if ((Dl & b) === b) {
            v = v.next, b === xn && (A = !0);
            continue;
          } else
            C = {
              lane: 0,
              revertLane: v.revertLane,
              gesture: null,
              action: v.action,
              hasEagerState: v.hasEagerState,
              eagerState: v.eagerState,
              next: null
            }, r === null ? (c = r = C, u = i) : r = r.next = C, ut.lanes |= b, na |= b;
          C = v.action, La && l(i, C), i = v.hasEagerState ? v.eagerState : l(i, C);
        } else
          b = {
            lane: C,
            revertLane: v.revertLane,
            gesture: v.gesture,
            action: v.action,
            hasEagerState: v.hasEagerState,
            eagerState: v.eagerState,
            next: null
          }, r === null ? (c = r = b, u = i) : r = r.next = b, ut.lanes |= C, na |= C;
        v = v.next;
      } while (v !== null && v !== e);
      if (r === null ? u = i : r.next = c, !Ne(i, t.memoizedState) && (ee = !0, A && (l = Sn, l !== null)))
        throw l;
      t.memoizedState = i, t.baseState = u, t.baseQueue = r, a.lastRenderedState = i;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function fc(t) {
    var e = $t(), l = e.queue;
    if (l === null) throw Error(s(311));
    l.lastRenderedReducer = t;
    var a = l.dispatch, n = l.pending, i = e.memoizedState;
    if (n !== null) {
      l.pending = null;
      var u = n = n.next;
      do
        i = t(i, u.action), u = u.next;
      while (u !== n);
      Ne(i, e.memoizedState) || (ee = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function xr(t, e, l) {
    var a = ut, n = $t(), i = bt;
    if (i) {
      if (l === void 0) throw Error(s(407));
      l = l();
    } else l = e();
    var u = !Ne(
      (wt || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, ee = !0), n = n.queue, rc(zr.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || te !== null && te.memoizedState.tag & 1) {
      if (a.flags |= 2048, _n(
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
      ), jt === null) throw Error(s(349));
      i || (Dl & 127) !== 0 || Sr(a, e, l);
    }
    return l;
  }
  function Sr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = ut.updateQueue, e === null ? (e = Au(), ut.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
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
    var e = Ra(t, 2);
    e !== null && Ce(e, t, 2);
  }
  function cc(t) {
    var e = Me();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), La) {
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
      p.T !== null ? l(!0) : i.isTransition = !1, a(i), l = e.pending, l === null ? (i.next = e.pending = i, _r(e, i)) : (i.next = l.next, e.pending = l.next = i);
    }
  }
  function _r(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var i = p.T, u = {};
      p.T = u;
      try {
        var c = l(n, a), r = p.S;
        r !== null && r(u, c), Dr(t, e, c);
      } catch (v) {
        oc(t, e, v);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), p.T = i;
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
    if (bt) {
      var l = jt.formState;
      if (l !== null) {
        t: {
          var a = ut;
          if (bt) {
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
            Fl(a);
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
      ut,
      a
    ), a.dispatch = l, a = cc(!1), i = gc.bind(
      null,
      ut,
      !1,
      a.queue
    ), a = Me(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = $m.bind(
      null,
      ut,
      n,
      i,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function wr(t) {
    var e = $t();
    return Br(e, wt, t);
  }
  function Br(t, e, l) {
    if (e = uc(
      t,
      e,
      Ur
    )[0], t = Du(Ol)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = vi(e);
      } catch (u) {
        throw u === Tn ? vu : u;
      }
    else a = e;
    e = $t();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (ut.flags |= 2048, _n(
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
    var e = $t(), l = wt;
    if (l !== null)
      return Br(e, l, t);
    $t(), e = e.memoizedState, l = $t();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function _n(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = ut.updateQueue, e === null && (e = Au(), ut.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Hr() {
    return $t().memoizedState;
  }
  function Ou(t, e, l, a) {
    var n = Me();
    ut.flags |= t, n.memoizedState = _n(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Cu(t, e, l, a) {
    var n = $t();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    wt !== null && a !== null && tc(a, wt.memoizedState.deps) ? n.memoizedState = _n(e, i, l, a) : (ut.flags |= t, n.memoizedState = _n(
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
    ut.flags |= 4;
    var e = ut.updateQueue;
    if (e === null)
      e = Au(), ut.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function qr(t) {
    var e = $t().memoizedState;
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
    var l = $t();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && tc(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Vr(t, e) {
    var l = $t();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && tc(e, a[1]))
      return a[0];
    if (a = t(), La) {
      ul(!0);
      try {
        t();
      } finally {
        ul(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function dc(t, e, l) {
    return l === void 0 || (Dl & 1073741824) !== 0 && (pt & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Zs(), ut.lanes |= t, na |= t, l);
  }
  function Zr(t, e, l, a) {
    return Ne(l, e) ? l : Mn.current !== null ? (t = dc(t, l, a), Ne(t, e) || (ee = !0), t) : (Dl & 42) === 0 || (Dl & 1073741824) !== 0 && (pt & 261930) === 0 ? (ee = !0, t.memoizedState = l) : (t = Zs(), ut.lanes |= t, na |= t, e);
  }
  function Kr(t, e, l, a, n) {
    var i = M.p;
    M.p = i !== 0 && 8 > i ? i : 8;
    var u = p.T, c = {};
    p.T = c, gc(t, !1, e, l);
    try {
      var r = n(), v = p.S;
      if (v !== null && v(c, r), r !== null && typeof r == "object" && typeof r.then == "function") {
        var A = km(
          r,
          a
        );
        bi(
          t,
          e,
          A,
          Le(t)
        );
      } else
        bi(
          t,
          e,
          a,
          Le(t)
        );
    } catch (C) {
      bi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: C },
        Le()
      );
    } finally {
      M.p = i, u !== null && c.types !== null && (u.types = c.types), p.T = u;
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
      j,
      l === null ? th : function() {
        return kr(t), l(a);
      }
    );
  }
  function Jr(t) {
    var e = t.memoizedState;
    if (e !== null) return e;
    e = {
      memoizedState: j,
      baseState: j,
      baseQueue: null,
      queue: {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: Ol,
        lastRenderedState: j
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
      Le()
    );
  }
  function hc() {
    return pe(Hi);
  }
  function Fr() {
    return $t().memoizedState;
  }
  function Wr() {
    return $t().memoizedState;
  }
  function eh(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = Le();
          t = Il(l);
          var a = Pl(e, t, l);
          a !== null && (Ce(a, e, l), hi(a, e, l)), e = { cache: Qf() }, t.payload = e;
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
    }, Uu(t) ? Ir(e, l) : (l = Rf(t, e, l, a), l !== null && (Ce(l, t, a), Pr(l, e, a)));
  }
  function $r(t, e, l) {
    var a = Le();
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
            return su(t, e, n, 0), jt === null && ru(), !1;
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
    return t === ut || e !== null && e === ut;
  }
  function Ir(t, e) {
    En = Mu = !0;
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
    readContext: pe,
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
    readContext: pe,
    use: _u,
    useCallback: function(t, e) {
      return Me().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: pe,
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
      if (La) {
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
      var a = Me();
      if (l !== void 0) {
        var n = l(e);
        if (La) {
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
      }, a.queue = t, t = t.dispatch = lh.bind(
        null,
        ut,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = Me();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = cc(t);
      var e = t.queue, l = $r.bind(null, ut, e);
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
        ut,
        t.queue,
        !0,
        !1
      ), Me().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = ut, n = Me();
      if (bt) {
        if (l === void 0)
          throw Error(s(407));
        l = l();
      } else {
        if (l = e(), jt === null)
          throw Error(s(349));
        (pt & 127) !== 0 || Sr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, jr(zr.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, _n(
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
      var t = Me(), e = jt.identifierPrefix;
      if (bt) {
        var l = gl, a = hl;
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
        ut,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: ic,
    useCacheRefresh: function() {
      return Me().memoizedState = eh.bind(
        null,
        ut
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
    readContext: pe,
    use: _u,
    useCallback: Qr,
    useContext: pe,
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
      var l = $t();
      return Zr(
        l,
        wt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = Du(Ol)[0], e = $t().memoizedState;
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
      var l = $t();
      return Ar(l, wt, t, e);
    },
    useMemoCache: ic,
    useCacheRefresh: Wr
  };
  pc.useEffectEvent = qr;
  var es = {
    readContext: pe,
    use: _u,
    useCallback: Qr,
    useContext: pe,
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
      var l = $t();
      return wt === null ? dc(l, t, e) : Zr(
        l,
        wt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = fc(Ol)[0], e = $t().memoizedState;
      return [
        typeof t == "boolean" ? t : vi(t),
        e
      ];
    },
    useSyncExternalStore: xr,
    useId: Fr,
    useHostTransitionStatus: hc,
    useFormState: Nr,
    useActionState: Nr,
    useOptimistic: function(t, e) {
      var l = $t();
      return wt !== null ? Ar(l, wt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ic,
    useCacheRefresh: Wr
  };
  es.useEffectEvent = qr;
  function yc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : H({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var vc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = Le(), n = Il(a);
      n.payload = e, l != null && (n.callback = l), e = Pl(t, n, a), e !== null && (Ce(e, t, a), hi(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = Le(), n = Il(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = Pl(t, n, a), e !== null && (Ce(e, t, a), hi(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = Le(), a = Il(l);
      a.tag = 2, e != null && (a.callback = e), e = Pl(t, a, l), e !== null && (Ce(e, t, l), hi(e, t, l));
    }
  };
  function ls(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ui(l, a) || !ui(n, i) : !0;
  }
  function as(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && vc.enqueueReplaceState(e, e.state, null);
  }
  function Xa(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = H({}, l));
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
    return l = Il(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Ru(t, e);
    }, l;
  }
  function cs(t) {
    return t = Il(t), t.tag = 3, t;
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
      fs(e, l, a), typeof n != "function" && (ia === null ? ia = /* @__PURE__ */ new Set([this]) : ia.add(this));
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
    if (bt)
      return e = je.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== qf && (t = Error(s(422), { cause: a }), oi(Ze(t, l)))) : (a !== qf && (e = Error(s(423), {
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
          if (e = l.type, i = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || i !== null && typeof i.componentDidCatch == "function" && (ia === null || !ia.has(i))))
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
  var xc = Error(s(461)), ee = !1;
  function ye(t, e, l, a) {
    e.child = t === null ? mr(e, null, l, a) : Ya(
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
    return Ha(e), a = ec(
      t,
      e,
      l,
      u,
      i,
      n
    ), c = lc(), t !== null && !ee ? (ac(t, e, n), Cl(t, e, n)) : (bt && c && Hf(e), e.flags |= 1, ye(t, e, a, n), e.child);
  }
  function ss(t, e, l, a, n) {
    if (t === null) {
      var i = l.type;
      return typeof i == "function" && !wf(i) && i.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = i, ds(
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
        if (ee = !1, e.pendingProps = a = i, Dc(t, n))
          (t.flags & 131072) !== 0 && (ee = !0);
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
      i !== null ? (yu(e, i.cachePool), pr(e, i), ea(), e.memoizedState = null) : (t !== null && yu(e, null), $f(), ea());
    return ye(t, e, n, l), e.child;
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
    return i = i === null ? null : { parent: Pt._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && yu(e, null), $f(), yr(e), t !== null && bn(t, e, a, !0), e.childLanes = n, null;
  }
  function wu(t, e) {
    return e = Nu(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function gs(t, e, l) {
    return Ya(e, t.child, null, l), t = wu(e, e.pendingProps), t.flags |= 2, qe(e), e.memoizedState = null, t;
  }
  function nh(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (bt) {
        if (a.mode === "hidden")
          return t = wu(e, a), e.lanes = 536870912, Si(null, t);
        if (Pf(e), (t = Lt) ? (t = _d(
          t,
          ke
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Jl !== null ? { id: hl, overflow: gl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Io(t), l.return = e, e.child = l, ge = e, Lt = null)) : t = null, t === null) throw Fl(e);
        return e.lanes = 536870912, null;
      }
      return wu(e, a);
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
      else if (ee || bn(t, e, l, !1), n = (l & t.childLanes) !== 0, ee || n) {
        if (a = jt, a !== null && (u = $a(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, Ra(t, u), Ce(a, t, u), xc;
        Vu(), e = gs(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, Lt = We(u.nextSibling), ge = e, bt = !0, kl = null, ke = !1, t !== null && er(e, t), e = wu(e, a), e.flags |= 4096;
      return e;
    }
    return t = Ml(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Bu(t, e) {
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
    return Ha(e), l = ec(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = lc(), t !== null && !ee ? (ac(t, e, n), Cl(t, e, n)) : (bt && a && Hf(e), e.flags |= 1, ye(t, e, l, n), e.child);
  }
  function ps(t, e, l, a, n, i) {
    return Ha(e), e.updateQueue = null, l = br(
      e,
      a,
      l,
      n
    ), vr(t), a = lc(), t !== null && !ee ? (ac(t, e, i), Cl(t, e, i)) : (bt && a && Hf(e), e.flags |= 1, ye(t, e, l, i), e.child);
  }
  function ys(t, e, l, a, n) {
    if (Ha(e), e.stateNode === null) {
      var i = gn, u = l.contextType;
      typeof u == "object" && u !== null && (i = pe(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = vc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Jf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? pe(u) : gn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (yc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && vc.enqueueReplaceState(i, i.state, null), pi(e, a, i, n), gi(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var c = e.memoizedProps, r = Xa(l, c);
      i.props = r;
      var v = i.context, A = l.contextType;
      u = gn, typeof A == "object" && A !== null && (u = pe(A));
      var C = l.getDerivedStateFromProps;
      A = typeof C == "function" || typeof i.getSnapshotBeforeUpdate == "function", c = e.pendingProps !== c, A || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (c || v !== u) && as(
        e,
        i,
        a,
        u
      ), $l = !1;
      var b = e.memoizedState;
      i.state = b, pi(e, a, i, n), gi(), v = e.memoizedState, c || b !== v || $l ? (typeof C == "function" && (yc(
        e,
        l,
        C,
        a
      ), v = e.memoizedState), (r = $l || ls(
        e,
        l,
        r,
        a,
        b,
        v,
        u
      )) ? (A || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = v), i.props = a, i.state = v, i.context = u, a = r) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, kf(t, e), u = e.memoizedProps, A = Xa(l, u), i.props = A, C = e.pendingProps, b = i.context, v = l.contextType, r = gn, typeof v == "object" && v !== null && (r = pe(v)), c = l.getDerivedStateFromProps, (v = typeof c == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== C || b !== r) && as(
        e,
        i,
        a,
        r
      ), $l = !1, b = e.memoizedState, i.state = b, pi(e, a, i, n), gi();
      var T = e.memoizedState;
      u !== C || b !== T || $l || t !== null && t.dependencies !== null && gu(t.dependencies) ? (typeof c == "function" && (yc(
        e,
        l,
        c,
        a
      ), T = e.memoizedState), (A = $l || ls(
        e,
        l,
        A,
        a,
        b,
        T,
        r
      ) || t !== null && t.dependencies !== null && gu(t.dependencies)) ? (v || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, T, r), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        T,
        r
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = T), i.props = a, i.state = T, i.context = r, a = A) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && b === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return i = a, Bu(t, e), a = (e.flags & 128) !== 0, i || a ? (i = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : i.render(), e.flags |= 1, t !== null && a ? (e.child = Ya(
      e,
      t.child,
      null,
      n
    ), e.child = Ya(
      e,
      null,
      l,
      n
    )) : ye(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = Cl(
      t,
      e,
      n
    ), t;
  }
  function vs(t, e, l, a) {
    return Ba(), e.flags |= 256, ye(t, e, l, a), e.child;
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
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= Ye), t;
  }
  function bs(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : (Wt.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (bt) {
        if (n ? ta(e) : ea(), (t = Lt) ? (t = _d(
          t,
          ke
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Jl !== null ? { id: hl, overflow: gl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Io(t), l.return = e, e.child = l, ge = e, Lt = null)) : t = null, t === null) throw Fl(e);
        return uo(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var c = a.children;
      return a = a.fallback, n ? (ea(), n = e.mode, c = Nu(
        { mode: "hidden", children: c },
        n
      ), a = wa(
        a,
        n,
        l,
        null
      ), c.return = e, a.return = e, c.sibling = a, e.child = c, a = e.child, a.memoizedState = zc(l), a.childLanes = Mc(
        t,
        u,
        l
      ), e.memoizedState = Tc, Si(null, a)) : (ta(e), Ec(e, c));
    }
    var r = t.memoizedState;
    if (r !== null && (c = r.dehydrated, c !== null)) {
      if (i)
        e.flags & 256 ? (ta(e), e.flags &= -257, e = Ac(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (ea(), e.child = t.child, e.flags |= 128, e = null) : (ea(), c = a.fallback, n = e.mode, a = Nu(
          { mode: "visible", children: a.children },
          n
        ), c = wa(
          c,
          n,
          l,
          null
        ), c.flags |= 2, a.return = e, c.return = e, a.sibling = c, e.child = a, Ya(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = zc(l), a.childLanes = Mc(
          t,
          u,
          l
        ), e.memoizedState = Tc, e = Si(null, a));
      else if (ta(e), uo(c)) {
        if (u = c.nextSibling && c.nextSibling.dataset, u) var v = u.dgst;
        u = v, a = Error(s(419)), a.stack = "", a.digest = u, oi({ value: a, source: null, stack: null }), e = Ac(
          t,
          e,
          l
        );
      } else if (ee || bn(t, e, l, !1), u = (l & t.childLanes) !== 0, ee || u) {
        if (u = jt, u !== null && (a = $a(u, l), a !== 0 && a !== r.retryLane))
          throw r.retryLane = a, Ra(t, a), Ce(u, t, a), xc;
        io(c) || Vu(), e = Ac(
          t,
          e,
          l
        );
      } else
        io(c) ? (e.flags |= 192, e.child = t.child, e = null) : (t = r.treeContext, Lt = We(
          c.nextSibling
        ), ge = e, bt = !0, kl = null, ke = !1, t !== null && er(e, t), e = Ec(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (ea(), c = a.fallback, n = e.mode, r = t.child, v = r.sibling, a = Ml(r, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = r.subtreeFlags & 65011712, v !== null ? c = Ml(
      v,
      c
    ) : (c = wa(
      c,
      n,
      l,
      null
    ), c.flags |= 2), c.return = e, a.return = e, a.sibling = c, e.child = a, Si(null, a), a = e.child, c = t.child.memoizedState, c === null ? c = zc(l) : (n = c.cachePool, n !== null ? (r = Pt._currentValue, n = n.parent !== r ? { parent: r, pool: r } : n) : n = fr(), c = {
      baseLanes: c.baseLanes | l,
      cachePool: n
    }), a.memoizedState = c, a.childLanes = Mc(
      t,
      u,
      l
    ), e.memoizedState = Tc, Si(t.child, a)) : (ta(e), l = t.child, t = l.sibling, l = Ml(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function Ec(t, e) {
    return e = Nu(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Nu(t, e) {
    return t = He(22, t, null, e), t.lanes = 0, t;
  }
  function Ac(t, e, l) {
    return Ya(e, t.child, null, l), t = Ec(
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
    var u = Wt.current, c = (u & 2) !== 0;
    if (c ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, B(Wt, u), ye(t, e, a, l), a = bt ? ci : 0, !c && t !== null && (t.flags & 128) !== 0)
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
    if (t !== null && (e.dependencies = t.dependencies), na |= e.lanes, (l & e.childLanes) === 0)
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
        ie(e, e.stateNode.containerInfo), Wl(e, Pt, t.memoizedState.cache), Ba();
        break;
      case 27:
      case 5:
        Ue(e);
        break;
      case 4:
        ie(e, e.stateNode.containerInfo);
        break;
      case 10:
        Wl(
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
          return a.dehydrated !== null ? (ta(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? bs(t, e, l) : (ta(e), t = Cl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        ta(e);
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
            return Ss(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), B(Wt, Wt.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, ms(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        Wl(e, Pt, t.memoizedState.cache);
    }
    return Cl(t, e, l);
  }
  function Ts(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        ee = !0;
      else {
        if (!Dc(t, l) && (e.flags & 128) === 0)
          return ee = !1, ih(
            t,
            e,
            l
          );
        ee = (t.flags & 131072) !== 0;
      }
    else
      ee = !1, bt && (e.flags & 1048576) !== 0 && tr(e, ci, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = qa(e.elementType), e.type = t, typeof t == "function")
            wf(t) ? (a = Xa(t, a), e.tag = 1, e = ys(
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
              if (n === At) {
                e.tag = 11, e = rs(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === k) {
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
            throw e = ae(t) || t, Error(s(306, e, ""));
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
        return a = e.type, n = Xa(
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
          if (ie(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(s(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, kf(t, e), pi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, Wl(e, Pt, a), a !== i.cache && Xf(
            e,
            [Pt],
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
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Lt = We(t.firstChild), ge = e, bt = !0, kl = null, ke = !0, l = mr(
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
            ye(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Bu(t, e), t === null ? (l = wd(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : bt || (l = e.type, t = e.pendingProps, a = $u(
          ct.current
        ).createElement(l), a[It] = e, a[me] = t, ve(a, l, t), Ft(a), e.stateNode = a) : e.memoizedState = wd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return Ue(e), t === null && bt && (a = e.stateNode = Cd(
          e.type,
          e.pendingProps,
          ct.current
        ), ge = e, ke = !0, n = Lt, oa(e.type) ? (fo = n, Lt = We(a.firstChild)) : Lt = n), ye(
          t,
          e,
          e.pendingProps.children,
          l
        ), Bu(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && bt && ((n = a = Lt) && (a = Nh(
          a,
          e.type,
          e.pendingProps,
          ke
        ), a !== null ? (e.stateNode = a, ge = e, Lt = We(a.firstChild), ke = !1, n = !0) : n = !1), n || Fl(e)), Ue(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, lo(n, i) ? a = null : u !== null && lo(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = ec(
          t,
          e,
          Wm,
          null,
          null,
          l
        ), Hi._currentValue = n), Bu(t, e), ye(t, e, a, l), e.child;
      case 6:
        return t === null && bt && ((t = l = Lt) && (l = Hh(
          l,
          e.pendingProps,
          ke
        ), l !== null ? (e.stateNode = l, ge = e, Lt = null, t = !0) : t = !1), t || Fl(e)), null;
      case 13:
        return bs(t, e, l);
      case 4:
        return ie(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = Ya(
          e,
          null,
          a,
          l
        ) : ye(t, e, a, l), e.child;
      case 11:
        return rs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return ye(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return ye(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return ye(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, Wl(e, e.type, a.value), ye(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, Ha(e), n = pe(n), a = a(n), e.flags |= 1, ye(t, e, a, l), e.child;
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
        return Ha(e), a = pe(Pt), t === null ? (n = Zf(), n === null && (n = jt, i = Qf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Jf(e), Wl(e, Pt, n)) : ((t.lanes & l) !== 0 && (kf(t, e), pi(e, null, null, l), gi()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), Wl(e, Pt, a)) : (a = i.cache, Wl(e, Pt, a), a !== n.cache && Xf(
          e,
          [Pt],
          l,
          !0
        ))), ye(
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
          throw Ga = bu, Kf;
    } else t.flags &= -16777217;
  }
  function zs(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !qd(e))
      if (Fs()) t.flags |= 8192;
      else
        throw Ga = bu, Kf;
  }
  function Hu(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? Vn() : 536870912, t.lanes |= e, Un |= e);
  }
  function Ti(t, e) {
    if (!bt)
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
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), _l(Pt), Qt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (vn(e) ? Ul(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, Gf())), Xt(e), null;
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
        if (Yl(e), l = ct.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Ul(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          t = q.current, vn(e) ? lr(e) : (t = Cd(n, a, l), e.stateNode = t, Ul(e));
        }
        return Xt(e), null;
      case 5:
        if (Yl(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Ul(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          if (i = q.current, vn(e))
            lr(e);
          else {
            var u = $u(
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
            i[It] = e, i[me] = a;
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
            t: switch (ve(i, n, a), n) {
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
          if (t = ct.current, vn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = ge, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[It] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || bd(t.nodeValue, l)), t || Fl(e, !0);
          } else
            t = $u(t).createTextNode(
              a
            ), t[It] = e, e.stateNode = t;
        }
        return Xt(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = vn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(s(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(557));
              t[It] = e;
            } else
              Ba(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), t = !1;
          } else
            l = Gf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
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
              n[It] = e;
            } else
              Ba(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), n = !1;
          } else
            n = Gf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (qe(e), e) : (qe(e), null);
        }
        return qe(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Hu(e, e.updateQueue), Xt(e), null);
      case 4:
        return Qt(), t === null && $c(e.stateNode.containerInfo), Xt(e), null;
      case 10:
        return _l(e.type), Xt(e), null;
      case 19:
        if (E(Wt), a = e.memoizedState, a === null) return Xt(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) Ti(a, !1);
          else {
            if (kt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = zu(t), i !== null) {
                  for (e.flags |= 128, Ti(a, !1), t = i.updateQueue, e.updateQueue = t, Hu(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    $o(l, t), l = l.sibling;
                  return B(
                    Wt,
                    Wt.current & 1 | 2
                  ), bt && El(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && de() > Lu && (e.flags |= 128, n = !0, Ti(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = zu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Hu(e, t), Ti(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !bt)
                return Xt(e), null;
            } else
              2 * de() - a.renderingStartTime > Lu && l !== 536870912 && (e.flags |= 128, n = !0, Ti(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = de(), t.sibling = null, l = Wt.current, B(
          Wt,
          n ? l & 1 | 2 : l & 1
        ), bt && El(e, a.treeForkCount), t) : (Xt(e), null);
      case 22:
      case 23:
        return qe(e), If(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Xt(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Xt(e), l = e.updateQueue, l !== null && Hu(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && E(ja), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), _l(Pt), Xt(e), null;
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
        return _l(Pt), Qt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return Yl(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (qe(e), e.alternate === null)
            throw Error(s(340));
          Ba();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (qe(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(s(340));
          Ba();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return E(Wt), null;
      case 4:
        return Qt(), null;
      case 10:
        return _l(e.type), null;
      case 22:
      case 23:
        return qe(e), If(), t !== null && E(ja), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return _l(Pt), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function Ms(t, e) {
    switch (jf(e), e.tag) {
      case 3:
        _l(Pt), Qt();
        break;
      case 26:
      case 27:
      case 5:
        Yl(e);
        break;
      case 4:
        Qt();
        break;
      case 31:
        e.memoizedState !== null && qe(e);
        break;
      case 13:
        qe(e);
        break;
      case 19:
        E(Wt);
        break;
      case 10:
        _l(e.type);
        break;
      case 22:
      case 23:
        qe(e), If(), t !== null && E(ja);
        break;
      case 24:
        _l(Pt);
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
      Rt(e, e.return, c);
    }
  }
  function la(t, e, l) {
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
              } catch (A) {
                Rt(
                  n,
                  r,
                  A
                );
              }
            }
          }
          a = a.next;
        } while (a !== i);
      }
    } catch (A) {
      Rt(e, e.return, A);
    }
  }
  function Es(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        gr(e, l);
      } catch (a) {
        Rt(t, t.return, a);
      }
    }
  }
  function As(t, e, l) {
    l.props = Xa(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      Rt(t, e, a);
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
      Rt(t, e, n);
    }
  }
  function pl(t, e) {
    var l = t.ref, a = t.refCleanup;
    if (l !== null)
      if (typeof a == "function")
        try {
          a();
        } catch (n) {
          Rt(t, e, n);
        } finally {
          t.refCleanup = null, t = t.alternate, t != null && (t.refCleanup = null);
        }
      else if (typeof l == "function")
        try {
          l(null);
        } catch (n) {
          Rt(t, e, n);
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
      Rt(t, t.return, n);
    }
  }
  function Cc(t, e, l) {
    try {
      var a = t.stateNode;
      Oh(a, t.type, l, e), a[me] = e;
    } catch (n) {
      Rt(t, t.return, n);
    }
  }
  function Ds(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && oa(t.type) || t.tag === 4;
  }
  function Uc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || Ds(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && oa(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Rc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = el));
    else if (a !== 4 && (a === 27 && oa(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Rc(t, e, l), t = t.sibling; t !== null; )
        Rc(t, e, l), t = t.sibling;
  }
  function ju(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && oa(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (ju(t, e, l), t = t.sibling; t !== null; )
        ju(t, e, l), t = t.sibling;
  }
  function Os(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      ve(e, a, l), e[It] = t, e[me] = l;
    } catch (i) {
      Rt(t, t.return, i);
    }
  }
  var Rl = !1, le = !1, wc = !1, Cs = typeof WeakSet == "function" ? WeakSet : Set, re = null;
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
            var u = 0, c = -1, r = -1, v = 0, A = 0, C = t, b = null;
            e: for (; ; ) {
              for (var T; C !== l || n !== 0 && C.nodeType !== 3 || (c = u + n), C !== i || a !== 0 && C.nodeType !== 3 || (r = u + a), C.nodeType === 3 && (u += C.nodeValue.length), (T = C.firstChild) !== null; )
                b = C, C = T;
              for (; ; ) {
                if (C === t) break e;
                if (b === l && ++v === n && (c = u), b === i && ++A === a && (r = u), (T = C.nextSibling) !== null) break;
                C = b, b = C.parentNode;
              }
              C = T;
            }
            l = c === -1 || r === -1 ? null : { start: c, end: r };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (eo = { focusedElem: t, selectionRange: l }, nf = !1, re = e; re !== null; )
      if (e = re, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, re = t;
      else
        for (; re !== null; ) {
          switch (e = re, i = e.alternate, t = e.flags, e.tag) {
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
                  var Y = Xa(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    Y,
                    i
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch ($) {
                  Rt(
                    l,
                    l.return,
                    $
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
            t.return = e.return, re = t;
            break;
          }
          re = e.return;
        }
  }
  function Us(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        Bl(t, l), a & 4 && zi(5, l);
        break;
      case 1:
        if (Bl(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              Rt(l, l.return, u);
            }
          else {
            var n = Xa(
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
              Rt(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && Es(l), a & 512 && Mi(l, l.return);
        break;
      case 3:
        if (Bl(t, l), a & 64 && (t = l.updateQueue, t !== null)) {
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
            Rt(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && Os(l);
      case 26:
      case 5:
        Bl(t, l), e === null && a & 4 && _s(l), a & 512 && Mi(l, l.return);
        break;
      case 12:
        Bl(t, l);
        break;
      case 31:
        Bl(t, l), a & 4 && Bs(t, l);
        break;
      case 13:
        Bl(t, l), a & 4 && Ns(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = yh.bind(
          null,
          l
        ), jh(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Rl, !a) {
          e = e !== null && e.memoizedState !== null || le, n = Rl;
          var i = le;
          Rl = a, (le = e) && !i ? Nl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : Bl(t, l), Rl = n, le = i;
        }
        break;
      case 30:
        break;
      default:
        Bl(t, l);
    }
  }
  function Rs(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Rs(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && Ia(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Vt = null, Ae = !1;
  function wl(t, e, l) {
    for (l = l.child; l !== null; )
      ws(t, e, l), l = l.sibling;
  }
  function ws(t, e, l) {
    if (Se && typeof Se.onCommitFiberUnmount == "function")
      try {
        Se.onCommitFiberUnmount(ya, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        le || pl(l, e), wl(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        le || pl(l, e);
        var a = Vt, n = Ae;
        oa(l.type) && (Vt = l.stateNode, Ae = !1), wl(
          t,
          e,
          l
        ), wi(l.stateNode), Vt = a, Ae = n;
        break;
      case 5:
        le || pl(l, e);
      case 6:
        if (a = Vt, n = Ae, Vt = null, wl(
          t,
          e,
          l
        ), Vt = a, Ae = n, Vt !== null)
          if (Ae)
            try {
              (Vt.nodeType === 9 ? Vt.body : Vt.nodeName === "HTML" ? Vt.ownerDocument.body : Vt).removeChild(l.stateNode);
            } catch (i) {
              Rt(
                l,
                e,
                i
              );
            }
          else
            try {
              Vt.removeChild(l.stateNode);
            } catch (i) {
              Rt(
                l,
                e,
                i
              );
            }
        break;
      case 18:
        Vt !== null && (Ae ? (t = Vt, Ed(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), Gn(t)) : Ed(Vt, l.stateNode));
        break;
      case 4:
        a = Vt, n = Ae, Vt = l.stateNode.containerInfo, Ae = !0, wl(
          t,
          e,
          l
        ), Vt = a, Ae = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        la(2, l, e), le || la(4, l, e), wl(
          t,
          e,
          l
        );
        break;
      case 1:
        le || (pl(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && As(
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
        le = (a = le) || l.memoizedState !== null, wl(
          t,
          e,
          l
        ), le = a;
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
        Rt(e, e.return, l);
      }
    }
  }
  function Ns(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        Gn(t);
      } catch (l) {
        Rt(e, e.return, l);
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
              if (oa(c.type)) {
                Vt = c.stateNode, Ae = !1;
                break t;
              }
              break;
            case 5:
              Vt = c.stateNode, Ae = !1;
              break t;
            case 3:
            case 4:
              Vt = c.stateNode.containerInfo, Ae = !0;
              break t;
          }
          c = c.return;
        }
        if (Vt === null) throw Error(s(160));
        ws(i, u, n), Vt = null, Ae = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Hs(e, t), e = e.sibling;
  }
  var al = null;
  function Hs(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        _e(e, t), De(t), a & 4 && (la(3, t, t.return), zi(3, t), la(5, t, t.return));
        break;
      case 1:
        _e(e, t), De(t), a & 512 && (le || l === null || pl(l, l.return)), a & 64 && Rl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = al;
        if (_e(e, t), De(t), a & 512 && (le || l === null || pl(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[Sa] || i[It] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), ve(i, a, l), i[It] = t, Ft(i), a = i;
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
                      i = n.createElement(a), ve(i, a, l), n.head.appendChild(i);
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
                      i = n.createElement(a), ve(i, a, l), n.head.appendChild(i);
                      break;
                    default:
                      throw Error(s(468, a));
                  }
                  i[It] = t, Ft(i), a = i;
                }
                t.stateNode = a;
              } else
                jd(
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
            i !== a ? (i === null ? l.stateNode !== null && (l = l.stateNode, l.parentNode.removeChild(l)) : i.count--, a === null ? jd(
              n,
              t.type,
              t.stateNode
            ) : Nd(
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
        _e(e, t), De(t), a & 512 && (le || l === null || pl(l, l.return)), l !== null && a & 4 && Cc(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (_e(e, t), De(t), a & 512 && (le || l === null || pl(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            N(n, "");
          } catch (Y) {
            Rt(t, t.return, Y);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Cc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (wc = !0);
        break;
      case 6:
        if (_e(e, t), De(t), a & 4) {
          if (t.stateNode === null)
            throw Error(s(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (Y) {
            Rt(t, t.return, Y);
          }
        }
        break;
      case 3:
        if (tf = null, n = al, al = Iu(e.containerInfo), _e(e, t), al = n, De(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            Gn(e.containerInfo);
          } catch (Y) {
            Rt(t, t.return, Y);
          }
        wc && (wc = !1, js(t));
        break;
      case 4:
        a = al, al = Iu(
          t.stateNode.containerInfo
        ), _e(e, t), De(t), al = a;
        break;
      case 12:
        _e(e, t), De(t);
        break;
      case 31:
        _e(e, t), De(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, qu(t, a)));
        break;
      case 13:
        _e(e, t), De(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Yu = de()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, qu(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var r = l !== null && l.memoizedState !== null, v = Rl, A = le;
        if (Rl = v || n, le = A || r, _e(e, t), le = A, Rl = v, De(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || r || Rl || le || Qa(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                r = l = e;
                try {
                  if (i = r.stateNode, n)
                    u = i.style, typeof u.setProperty == "function" ? u.setProperty("display", "none", "important") : u.display = "none";
                  else {
                    c = r.stateNode;
                    var C = r.memoizedProps.style, b = C != null && C.hasOwnProperty("display") ? C.display : null;
                    c.style.display = b == null || typeof b == "boolean" ? "" : ("" + b).trim();
                  }
                } catch (Y) {
                  Rt(r, r.return, Y);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                r = e;
                try {
                  r.stateNode.nodeValue = n ? "" : r.memoizedProps;
                } catch (Y) {
                  Rt(r, r.return, Y);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                r = e;
                try {
                  var T = r.stateNode;
                  n ? Ad(T, !0) : Ad(r.stateNode, !1);
                } catch (Y) {
                  Rt(r, r.return, Y);
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
            l.flags & 32 && (N(u, ""), l.flags &= -33);
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
      } catch (A) {
        Rt(t, t.return, A);
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
  function Bl(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        Us(t, e.alternate, e), e = e.sibling;
  }
  function Qa(t) {
    for (t = t.child; t !== null; ) {
      var e = t;
      switch (e.tag) {
        case 0:
        case 11:
        case 14:
        case 15:
          la(4, e, e.return), Qa(e);
          break;
        case 1:
          pl(e, e.return);
          var l = e.stateNode;
          typeof l.componentWillUnmount == "function" && As(
            e,
            e.return,
            l
          ), Qa(e);
          break;
        case 27:
          wi(e.stateNode);
        case 26:
        case 5:
          pl(e, e.return), Qa(e);
          break;
        case 22:
          e.memoizedState === null && Qa(e);
          break;
        case 30:
          Qa(e);
          break;
        default:
          Qa(e);
      }
      t = t.sibling;
    }
  }
  function Nl(t, e, l) {
    for (l = l && (e.subtreeFlags & 8772) !== 0, e = e.child; e !== null; ) {
      var a = e.alternate, n = t, i = e, u = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          Nl(
            n,
            i,
            l
          ), zi(4, i);
          break;
        case 1:
          if (Nl(
            n,
            i,
            l
          ), a = i, n = a.stateNode, typeof n.componentDidMount == "function")
            try {
              n.componentDidMount();
            } catch (v) {
              Rt(a, a.return, v);
            }
          if (a = i, n = a.updateQueue, n !== null) {
            var c = a.stateNode;
            try {
              var r = n.shared.hiddenCallbacks;
              if (r !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < r.length; n++)
                  hr(r[n], c);
            } catch (v) {
              Rt(a, a.return, v);
            }
          }
          l && u & 64 && Es(i), Mi(i, i.return);
          break;
        case 27:
          Os(i);
        case 26:
        case 5:
          Nl(
            n,
            i,
            l
          ), l && a === null && u & 4 && _s(i), Mi(i, i.return);
          break;
        case 12:
          Nl(
            n,
            i,
            l
          );
          break;
        case 31:
          Nl(
            n,
            i,
            l
          ), l && u & 4 && Bs(n, i);
          break;
        case 13:
          Nl(
            n,
            i,
            l
          ), l && u & 4 && Ns(n, i);
          break;
        case 22:
          i.memoizedState === null && Nl(
            n,
            i,
            l
          ), Mi(i, i.return);
          break;
        case 30:
          break;
        default:
          Nl(
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
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && ri(l));
  }
  function Nc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ri(t));
  }
  function nl(t, e, l, a) {
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
        nl(
          t,
          e,
          l,
          a
        ), n & 2048 && zi(9, e);
        break;
      case 1:
        nl(
          t,
          e,
          l,
          a
        );
        break;
      case 3:
        nl(
          t,
          e,
          l,
          a
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ri(t)));
        break;
      case 12:
        if (n & 2048) {
          nl(
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
            Rt(e, e.return, r);
          }
        } else
          nl(
            t,
            e,
            l,
            a
          );
        break;
      case 31:
        nl(
          t,
          e,
          l,
          a
        );
        break;
      case 13:
        nl(
          t,
          e,
          l,
          a
        );
        break;
      case 23:
        break;
      case 22:
        i = e.stateNode, u = e.alternate, e.memoizedState !== null ? i._visibility & 2 ? nl(
          t,
          e,
          l,
          a
        ) : Ei(t, e) : i._visibility & 2 ? nl(
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
        nl(
          t,
          e,
          l,
          a
        ), n & 2048 && Nc(e.alternate, e);
        break;
      default:
        nl(
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
          ), zi(8, u);
          break;
        case 23:
          break;
        case 22:
          var A = u.stateNode;
          u.memoizedState !== null ? A._visibility & 2 ? Dn(
            i,
            u,
            c,
            r,
            n
          ) : Ei(
            i,
            u
          ) : (A._visibility |= 2, Dn(
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
  function Ei(t, e) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; ) {
        var l = t, a = e, n = a.flags;
        switch (a.tag) {
          case 22:
            Ei(l, a), n & 2048 && Bc(
              a.alternate,
              a
            );
            break;
          case 24:
            Ei(l, a), n & 2048 && Nc(a.alternate, a);
            break;
          default:
            Ei(l, a);
        }
        e = e.sibling;
      }
  }
  var Ai = 8192;
  function On(t, e, l) {
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
        On(
          t,
          e,
          l
        ), t.flags & Ai && t.memoizedState !== null && Fh(
          l,
          al,
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
        var a = al;
        al = Iu(t.stateNode.containerInfo), On(
          t,
          e,
          l
        ), al = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = Ai, Ai = 16777216, On(
          t,
          e,
          l
        ), Ai = a) : On(
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
          re = a, Xs(
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
        _i(t), t.flags & 2048 && la(9, t, t.return);
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
          re = a, Xs(
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
          la(8, e, e.return), Gu(e);
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
    for (; re !== null; ) {
      var l = re;
      switch (l.tag) {
        case 0:
        case 11:
        case 15:
          la(8, l, e);
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
      if (a = l.child, a !== null) a.return = l, re = a;
      else
        t: for (l = t; re !== null; ) {
          a = re;
          var n = a.sibling, i = a.return;
          if (Rs(a), a === l) {
            re = null;
            break t;
          }
          if (n !== null) {
            n.return = i, re = n;
            break t;
          }
          re = i;
        }
    }
  }
  var rh = {
    getCacheForType: function(t) {
      var e = pe(Pt), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return pe(Pt).controller.signal;
    }
  }, sh = typeof WeakMap == "function" ? WeakMap : Map, Ot = 0, jt = null, st = null, pt = 0, Ut = 0, Ge = null, aa = !1, Cn = !1, Hc = !1, Hl = 0, kt = 0, na = 0, Va = 0, jc = 0, Ye = 0, Un = 0, Di = null, Oe = null, qc = !1, Yu = 0, Qs = 0, Lu = 1 / 0, Xu = null, ia = null, ce = 0, ua = null, Rn = null, jl = 0, Gc = 0, Yc = null, Vs = null, Oi = 0, Lc = null;
  function Le() {
    return (Ot & 2) !== 0 && pt !== 0 ? pt & -pt : p.T !== null ? Jc() : $i();
  }
  function Zs() {
    if (Ye === 0)
      if ((pt & 536870912) === 0 || bt) {
        var t = Fa;
        Fa <<= 1, (Fa & 3932160) === 0 && (Fa = 262144), Ye = t;
      } else Ye = 536870912;
    return t = je.current, t !== null && (t.flags |= 32), Ye;
  }
  function Ce(t, e, l) {
    (t === jt && (Ut === 2 || Ut === 9) || t.cancelPendingCommit !== null) && (wn(t, 0), fa(
      t,
      pt,
      Ye,
      !1
    )), cl(t, l), ((Ot & 2) === 0 || t !== jt) && (t === jt && ((Ot & 2) === 0 && (Va |= l), kt === 4 && fa(
      t,
      pt,
      Ye,
      !1
    )), yl(t));
  }
  function Ks(t, e, l) {
    if ((Ot & 6) !== 0) throw Error(s(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || ba(t, e), n = a ? hh(t, e) : Qc(t, e, !0), i = a;
    do {
      if (n === 0) {
        Cn && !a && fa(t, e, 0, !1);
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
              if (r && (wn(c, u).flags |= 256), u = Qc(
                c,
                u,
                !1
              ), u !== 2) {
                if (Hc && !r) {
                  c.errorRecoveryDisabledLanes |= i, Va |= i, n = 4;
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
          wn(t, 0), fa(t, e, 0, !0);
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
              fa(
                a,
                e,
                Ye,
                !aa
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
          if ((e & 62914560) === e && (n = Yu + 300 - de(), 10 < n)) {
            if (fa(
              a,
              e,
              Ye,
              !aa
            ), va(a, 0, !0) !== 0) break t;
            jl = e, a.timeoutHandle = zd(
              Js.bind(
                null,
                a,
                l,
                Oe,
                Xu,
                qc,
                e,
                Ye,
                Va,
                Un,
                aa,
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
            Ye,
            Va,
            Un,
            aa,
            i,
            null,
            -0,
            0
          );
        }
      }
      break;
    } while (!0);
    yl(t);
  }
  function Js(t, e, l, a, n, i, u, c, r, v, A, C, b, T) {
    if (t.timeoutHandle = -1, C = e.subtreeFlags, C & 8192 || (C & 16785408) === 16785408) {
      C = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: el
      }, Gs(
        e,
        i,
        C
      );
      var Y = (i & 62914560) === i ? Yu - de() : (i & 4194048) === i ? Qs - de() : 0;
      if (Y = Wh(
        C,
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
            A,
            C,
            null,
            b,
            T
          )
        ), fa(t, i, u, !v);
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
  function fa(t, e, l, a) {
    e &= ~jc, e &= ~Va, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
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
    if (st !== null) {
      if (Ut === 0)
        var t = st.return;
      else
        t = st, Al = Na = null, nc(t), zn = null, di = 0, t = st;
      for (; t !== null; )
        Ms(t.alternate, t), t = t.return;
      st = null;
    }
  }
  function wn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Rh(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), jl = 0, Xc(), jt = t, st = l = Ml(t.current, null), pt = e, Ut = 0, Ge = null, aa = !1, Cn = ba(t, e), Hc = !1, Un = Ye = jc = Va = na = kt = 0, Oe = Di = null, qc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - ue(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return Hl = e, ru(), l;
  }
  function ks(t, e) {
    ut = null, p.H = xi, e === Tn || e === vu ? (e = rr(), Ut = 3) : e === Kf ? (e = rr(), Ut = 4) : Ut = e === xc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, Ge = e, st === null && (kt = 1, Ru(
      t,
      Ze(e, t.current)
    ));
  }
  function Fs() {
    var t = je.current;
    return t === null ? !0 : (pt & 4194048) === pt ? Fe === null : (pt & 62914560) === pt || (pt & 536870912) !== 0 ? t === Fe : !1;
  }
  function Ws() {
    var t = p.H;
    return p.H = xi, t === null ? xi : t;
  }
  function $s() {
    var t = p.A;
    return p.A = rh, t;
  }
  function Vu() {
    kt = 4, aa || (pt & 4194048) !== pt && je.current !== null || (Cn = !0), (na & 134217727) === 0 && (Va & 134217727) === 0 || jt === null || fa(
      jt,
      pt,
      Ye,
      !1
    );
  }
  function Qc(t, e, l) {
    var a = Ot;
    Ot |= 2;
    var n = Ws(), i = $s();
    (jt !== t || pt !== e) && (Xu = null, wn(t, e)), e = !1;
    var u = kt;
    t: do
      try {
        if (Ut !== 0 && st !== null) {
          var c = st, r = Ge;
          switch (Ut) {
            case 8:
              Xc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              je.current === null && (e = !0);
              var v = Ut;
              if (Ut = 0, Ge = null, Bn(t, c, r, v), l && Cn) {
                u = 0;
                break t;
              }
              break;
            default:
              v = Ut, Ut = 0, Ge = null, Bn(t, c, r, v);
          }
        }
        mh(), u = kt;
        break;
      } catch (A) {
        ks(t, A);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Al = Na = null, Ot = a, p.H = n, p.A = i, st === null && (jt = null, pt = 0, ru()), u;
  }
  function mh() {
    for (; st !== null; ) Is(st);
  }
  function hh(t, e) {
    var l = Ot;
    Ot |= 2;
    var a = Ws(), n = $s();
    jt !== t || pt !== e ? (Xu = null, Lu = de() + 500, wn(t, e)) : Cn = ba(
      t,
      e
    );
    t: do
      try {
        if (Ut !== 0 && st !== null) {
          e = st;
          var i = Ge;
          e: switch (Ut) {
            case 1:
              Ut = 0, Ge = null, Bn(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (cr(i)) {
                Ut = 0, Ge = null, Ps(e);
                break;
              }
              e = function() {
                Ut !== 2 && Ut !== 9 || jt !== t || (Ut = 7), yl(t);
              }, i.then(e, e);
              break t;
            case 3:
              Ut = 7;
              break t;
            case 4:
              Ut = 5;
              break t;
            case 7:
              cr(i) ? (Ut = 0, Ge = null, Ps(e)) : (Ut = 0, Ge = null, Bn(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (st.tag) {
                case 26:
                  u = st.memoizedState;
                case 5:
                case 27:
                  var c = st;
                  if (u ? qd(u) : c.stateNode.complete) {
                    Ut = 0, Ge = null;
                    var r = c.sibling;
                    if (r !== null) st = r;
                    else {
                      var v = c.return;
                      v !== null ? (st = v, Zu(v)) : st = null;
                    }
                    break e;
                  }
              }
              Ut = 0, Ge = null, Bn(t, e, i, 5);
              break;
            case 6:
              Ut = 0, Ge = null, Bn(t, e, i, 6);
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
      } catch (A) {
        ks(t, A);
      }
    while (!0);
    return Al = Na = null, p.H = a, p.A = n, Ot = l, st !== null ? 0 : (jt = null, pt = 0, ru(), kt);
  }
  function gh() {
    for (; st !== null && !Qn(); )
      Is(st);
  }
  function Is(t) {
    var e = Ts(t.alternate, t, Hl);
    t.memoizedProps = t.pendingProps, e === null ? Zu(t) : st = e;
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
          pt
        );
        break;
      case 11:
        e = ps(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          pt
        );
        break;
      case 5:
        nc(e);
      default:
        Ms(l, e), e = st = $o(e, Hl), e = Ts(l, e, Hl);
    }
    t.memoizedProps = t.pendingProps, e === null ? Zu(t) : st = e;
  }
  function Bn(t, e, l, a) {
    Al = Na = null, nc(e), zn = null, di = 0;
    var n = e.return;
    try {
      if (ah(
        t,
        n,
        e,
        l,
        pt
      )) {
        kt = 1, Ru(
          t,
          Ze(l, t.current)
        ), st = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw st = n, i;
      kt = 1, Ru(
        t,
        Ze(l, t.current)
      ), st = null;
      return;
    }
    e.flags & 32768 ? (bt || a === 1 ? t = !0 : Cn || (pt & 536870912) !== 0 ? t = !1 : (aa = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = je.current, a !== null && a.tag === 13 && (a.flags |= 16384))), td(e, t)) : Zu(e);
  }
  function Zu(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        td(
          e,
          aa
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
        st = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        st = e;
        return;
      }
      st = e = t;
    } while (e !== null);
    kt === 0 && (kt = 5);
  }
  function td(t, e) {
    do {
      var l = fh(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, st = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        st = t;
        return;
      }
      st = t = l;
    } while (t !== null);
    kt = 6, st = null;
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
      ), t === jt && (st = jt = null, pt = 0), Rn = e, ua = t, jl = l, Gc = i, Yc = n, Vs = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, bh(pa, function() {
        return ud(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = p.T, p.T = null, n = M.p, M.p = 2, u = Ot, Ot |= 4;
        try {
          ch(t, e, l);
        } finally {
          Ot = u, M.p = n, p.T = a;
        }
      }
      ce = 1, ld(), ad(), nd();
    }
  }
  function ld() {
    if (ce === 1) {
      ce = 0;
      var t = ua, e = Rn, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = p.T, p.T = null;
        var a = M.p;
        M.p = 2;
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
              var v = r.start, A = r.end;
              if (A === void 0 && (A = v), "selectionStart" in c)
                c.selectionStart = v, c.selectionEnd = Math.min(
                  A,
                  c.value.length
                );
              else {
                var C = c.ownerDocument || document, b = C && C.defaultView || window;
                if (b.getSelection) {
                  var T = b.getSelection(), Y = c.textContent.length, $ = Math.min(r.start, Y), Nt = r.end === void 0 ? $ : Math.min(r.end, Y);
                  !T.extend && $ > Nt && (u = Nt, Nt = $, $ = u);
                  var g = Yo(
                    c,
                    $
                  ), h = Yo(
                    c,
                    Nt
                  );
                  if (g && h && (T.rangeCount !== 1 || T.anchorNode !== g.node || T.anchorOffset !== g.offset || T.focusNode !== h.node || T.focusOffset !== h.offset)) {
                    var y = C.createRange();
                    y.setStart(g.node, g.offset), T.removeAllRanges(), $ > Nt ? (T.addRange(y), T.extend(h.node, h.offset)) : (y.setEnd(h.node, h.offset), T.addRange(y));
                  }
                }
              }
            }
            for (C = [], T = c; T = T.parentNode; )
              T.nodeType === 1 && C.push({
                element: T,
                left: T.scrollLeft,
                top: T.scrollTop
              });
            for (typeof c.focus == "function" && c.focus(), c = 0; c < C.length; c++) {
              var _ = C[c];
              _.element.scrollLeft = _.left, _.element.scrollTop = _.top;
            }
          }
          nf = !!to, eo = to = null;
        } finally {
          Ot = n, M.p = a, p.T = l;
        }
      }
      t.current = e, ce = 2;
    }
  }
  function ad() {
    if (ce === 2) {
      ce = 0;
      var t = ua, e = Rn, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = p.T, p.T = null;
        var a = M.p;
        M.p = 2;
        var n = Ot;
        Ot |= 4;
        try {
          Us(t, e.alternate, e);
        } finally {
          Ot = n, M.p = a, p.T = l;
        }
      }
      ce = 3;
    }
  }
  function nd() {
    if (ce === 4 || ce === 3) {
      ce = 0, Qi();
      var t = ua, e = Rn, l = jl, a = Vs;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? ce = 5 : (ce = 0, Rn = ua = null, id(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (ia = null), Kn(l), e = e.stateNode, Se && typeof Se.onCommitFiberRoot == "function")
        try {
          Se.onCommitFiberRoot(
            ya,
            e,
            void 0,
            (e.current.flags & 128) === 128
          );
        } catch {
        }
      if (a !== null) {
        e = p.T, n = M.p, M.p = 2, p.T = null;
        try {
          for (var i = t.onRecoverableError, u = 0; u < a.length; u++) {
            var c = a[u];
            i(c.value, {
              componentStack: c.stack
            });
          }
        } finally {
          p.T = e, M.p = n;
        }
      }
      (jl & 3) !== 0 && Ku(), yl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Lc ? Oi++ : (Oi = 0, Lc = t) : Oi = 0, Ci(0);
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
    var t = ua, e = Gc;
    Gc = 0;
    var l = Kn(jl), a = p.T, n = M.p;
    try {
      M.p = 32 > l ? 32 : l, p.T = null, l = Yc, Yc = null;
      var i = ua, u = jl;
      if (ce = 0, Rn = ua = null, jl = 0, (Ot & 6) !== 0) throw Error(s(331));
      var c = Ot;
      if (Ot |= 4, Ls(i.current), qs(
        i,
        i.current,
        u,
        l
      ), Ot = c, Ci(0, !1), Se && typeof Se.onPostCommitFiberRoot == "function")
        try {
          Se.onPostCommitFiberRoot(ya, i);
        } catch {
        }
      return !0;
    } finally {
      M.p = n, p.T = a, id(t, e);
    }
  }
  function fd(t, e, l) {
    e = Ze(l, e), e = bc(t.stateNode, e, 2), t = Pl(t, e, 2), t !== null && (cl(t, 2), yl(t));
  }
  function Rt(t, e, l) {
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
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (ia === null || !ia.has(a))) {
            t = Ze(l, t), l = cs(2), a = Pl(e, l, 2), a !== null && (os(
              l,
              a,
              e,
              t
            ), cl(a, 2), yl(a));
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
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, jt === t && (pt & l) === l && (kt === 4 || kt === 3 && (pt & 62914560) === pt && 300 > de() - Yu ? (Ot & 2) === 0 && wn(t, 0) : jc |= l, Un === pt && (Un = 0)), yl(t);
  }
  function cd(t, e) {
    e === 0 && (e = Vn()), t = Ra(t, e), t !== null && (cl(t, e), yl(t));
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
  var Ju = null, Nn = null, Zc = !1, ku = !1, Kc = !1, ca = 0;
  function yl(t) {
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
            i = pt, i = va(
              a,
              a === jt ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || ba(a, i) || (l = !0, dd(a, i));
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
    ca !== 0 && Uh() && (t = ca);
    for (var e = de(), l = null, a = Ju; a !== null; ) {
      var n = a.next, i = rd(a, e);
      i === 0 ? (a.next = null, l === null ? Ju = n : l.next = n, n === null && (Nn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (ku = !0)), a = n;
    }
    ce !== 0 && ce !== 5 || Ci(t), ca !== 0 && (ca = 0);
  }
  function rd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - ue(i), c = 1 << u, r = n[u];
      r === -1 ? ((c & l) === 0 || (c & a) !== 0) && (n[u] = xl(c, e)) : r <= e && (t.expiredLanes |= c), i &= ~c;
    }
    if (e = jt, l = pt, l = va(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (Ut === 2 || Ut === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && ga(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || ba(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && ga(a), Kn(l)) {
        case 2:
        case 8:
          l = Ja;
          break;
        case 32:
          l = pa;
          break;
        case 268435456:
          l = Ki;
          break;
        default:
          l = pa;
      }
      return a = sd.bind(null, t), l = Xn(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && ga(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function sd(t, e) {
    if (ce !== 0 && ce !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Ku() && t.callbackNode !== l)
      return null;
    var a = pt;
    return a = va(
      t,
      t === jt ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Ks(t, a, e), rd(t, de()), t.callbackNode != null && t.callbackNode === l ? sd.bind(null, t) : null);
  }
  function dd(t, e) {
    if (Ku()) return null;
    Ks(t, e, !0);
  }
  function Sh() {
    wh(function() {
      (Ot & 6) !== 0 ? Xn(
        Zi,
        xh
      ) : od();
    });
  }
  function Jc() {
    if (ca === 0) {
      var t = xn;
      t === 0 && (t = bl, bl <<= 1, (bl & 261888) === 0 && (bl = 256)), ca = t;
    }
    return ca;
  }
  function md(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : ln("" + t);
  }
  function hd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function Th(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = md(
        (n[me] || null).action
      ), u = a.submitter;
      u && (e = (e = u[me] || null) ? md(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
      var c = new on(
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
                if (ca !== 0) {
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
    ll(
      zh,
      "on" + Mh
    );
  }
  ll(Zo, "onAnimationEnd"), ll(Ko, "onAnimationIteration"), ll(Jo, "onAnimationStart"), ll("dblclick", "onDoubleClick"), ll("focusin", "onFocus"), ll("focusout", "onBlur"), ll(Ym, "onTransitionRun"), ll(Lm, "onTransitionStart"), ll(Xm, "onTransitionCancel"), ll(ko, "onTransitionEnd"), Xl("onMouseEnter", ["mouseout", "mouseover"]), Xl("onMouseLeave", ["mouseout", "mouseover"]), Xl("onPointerEnter", ["pointerout", "pointerover"]), Xl("onPointerLeave", ["pointerout", "pointerover"]), dl(
    "onChange",
    "change click focusin focusout input keydown keyup selectionchange".split(" ")
  ), dl(
    "onSelect",
    "focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(
      " "
    )
  ), dl("onBeforeInput", [
    "compositionend",
    "keypress",
    "textInput",
    "paste"
  ]), dl(
    "onCompositionEnd",
    "compositionend focusout keydown keypress keyup mousedown".split(" ")
  ), dl(
    "onCompositionStart",
    "compositionstart focusout keydown keypress keyup mousedown".split(" ")
  ), dl(
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
            } catch (A) {
              ou(A);
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
            } catch (A) {
              ou(A);
            }
            n.currentTarget = null, i = r;
          }
      }
    }
  }
  function dt(t, e) {
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
    ), n = void 0, !Ea || e !== "touchstart" && e !== "touchmove" && e !== "wheel" || (n = !0), a ? n !== void 0 ? t.addEventListener(e, l, {
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
            if (u = rl(c), u === null) return;
            if (r = u.tag, r === 5 || r === 6 || r === 26 || r === 27) {
              a = i = u;
              continue t;
            }
            c = c.parentNode;
          }
        }
        a = a.return;
      }
    nn(function() {
      var v = i, A = an(l), C = [];
      t: {
        var b = Fo.get(t);
        if (b !== void 0) {
          var T = on, Y = t;
          switch (t) {
            case "keypress":
              if (Aa(l) === 0) break t;
            case "keydown":
            case "keyup":
              T = vm;
              break;
            case "focusin":
              Y = "focus", T = I;
              break;
            case "focusout":
              Y = "blur", T = I;
              break;
            case "beforeblur":
            case "afterblur":
              T = I;
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
              T = D;
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
              T = Tt;
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
          var $ = (e & 4) !== 0, Nt = !$ && (t === "scroll" || t === "scrollend"), g = $ ? b !== null ? b + "Capture" : null : b;
          $ = [];
          for (var h = v, y; h !== null; ) {
            var _ = h;
            if (y = _.stateNode, _ = _.tag, _ !== 5 && _ !== 26 && _ !== 27 || y === null || g === null || (_ = Ma(h, g), _ != null && $.push(
              Ri(h, _, y)
            )), Nt) break;
            h = h.return;
          }
          0 < $.length && (b = new T(
            b,
            Y,
            null,
            l,
            A
          ), C.push({ event: b, listeners: $ }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (b = t === "mouseover" || t === "pointerover", T = t === "mouseout" || t === "pointerout", b && l !== In && (Y = l.relatedTarget || l.fromElement) && (rl(Y) || Y[Sl]))
            break t;
          if ((T || b) && (b = A.window === A ? A : (b = A.ownerDocument) ? b.defaultView || b.parentWindow : window, T ? (Y = l.relatedTarget || l.toElement, T = v, Y = Y ? rl(Y) : null, Y !== null && (Nt = J(Y), $ = Y.tag, Y !== Nt || $ !== 5 && $ !== 27 && $ !== 6) && (Y = null)) : (T = null, Y = v), T !== Y)) {
            if ($ = li, _ = "onMouseLeave", g = "onMouseEnter", h = "mouse", (t === "pointerout" || t === "pointerover") && ($ = Ao, _ = "onPointerLeave", g = "onPointerEnter", h = "pointer"), Nt = T == null ? b : Ll(T), y = Y == null ? b : Ll(Y), b = new $(
              _,
              h + "leave",
              T,
              l,
              A
            ), b.target = Nt, b.relatedTarget = y, _ = null, rl(A) === v && ($ = new $(
              g,
              h + "enter",
              Y,
              l,
              A
            ), $.target = y, $.relatedTarget = Nt, _ = $), Nt = _, T && Y)
              e: {
                for ($ = Ah, g = T, h = Y, y = 0, _ = g; _; _ = $(_))
                  y++;
                _ = 0;
                for (var F = h; F; F = $(F))
                  _++;
                for (; 0 < y - _; )
                  g = $(g), y--;
                for (; 0 < _ - y; )
                  h = $(h), _--;
                for (; y--; ) {
                  if (g === h || h !== null && g === h.alternate) {
                    $ = g;
                    break e;
                  }
                  g = $(g), h = $(h);
                }
                $ = null;
              }
            else $ = null;
            T !== null && yd(
              C,
              b,
              T,
              $,
              !1
            ), Y !== null && Nt !== null && yd(
              C,
              Nt,
              Y,
              $,
              !0
            );
          }
        }
        t: {
          if (b = v ? Ll(v) : window, T = b.nodeName && b.nodeName.toLowerCase(), T === "select" || T === "input" && b.type === "file")
            var Mt = Bo;
          else if (Ro(b))
            if (No)
              Mt = jm;
            else {
              Mt = Nm;
              var V = Bm;
            }
          else
            T = b.nodeName, !T || T.toLowerCase() !== "input" || b.type !== "checkbox" && b.type !== "radio" ? v && gt(v.elementType) && (Mt = Bo) : Mt = Hm;
          if (Mt && (Mt = Mt(t, v))) {
            wo(
              C,
              Mt,
              l,
              A
            );
            break t;
          }
          V && V(t, b, v), t === "focusout" && v && b.type === "number" && v.memoizedProps.value != null && o(b, "number", b.value);
        }
        switch (V = v ? Ll(v) : window, t) {
          case "focusin":
            (Ro(V) || V.contentEditable === "true") && (dn = V, _f = v, fi = null);
            break;
          case "focusout":
            fi = _f = dn = null;
            break;
          case "mousedown":
            Df = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Df = !1, Qo(C, l, A);
            break;
          case "selectionchange":
            if (Gm) break;
          case "keydown":
          case "keyup":
            Qo(C, l, A);
        }
        var ft;
        if (zf)
          t: {
            switch (t) {
              case "compositionstart":
                var yt = "onCompositionStart";
                break t;
              case "compositionend":
                yt = "onCompositionEnd";
                break t;
              case "compositionupdate":
                yt = "onCompositionUpdate";
                break t;
            }
            yt = void 0;
          }
        else
          sn ? Co(t, l) && (yt = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (yt = "onCompositionStart");
        yt && (_o && l.locale !== "ko" && (sn || yt !== "onCompositionStart" ? yt === "onCompositionEnd" && sn && (ft = Pn()) : (Ee = A, un = "value" in Ee ? Ee.value : Ee.textContent, sn = !0)), V = Wu(v, yt), 0 < V.length && (yt = new Kl(
          yt,
          t,
          null,
          l,
          A
        ), C.push({ event: yt, listeners: V }), ft ? yt.data = ft : (ft = Uo(l), ft !== null && (yt.data = ft)))), (ft = Om ? Cm(t, l) : Um(t, l)) && (yt = Wu(v, "onBeforeInput"), 0 < yt.length && (V = new Kl(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          A
        ), C.push({
          event: V,
          listeners: yt
        }), V.data = ft)), Th(
          C,
          t,
          v,
          l,
          A
        );
      }
      gd(C, e);
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
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = Ma(t, l), n != null && a.unshift(
        Ri(t, n, i)
      ), n = Ma(t, e), n != null && a.push(
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
      c !== 5 && c !== 26 && c !== 27 || v === null || (r = v, n ? (v = Ma(l, i), v != null && u.unshift(
        Ri(l, v, r)
      )) : n || (v = Ma(l, i), v != null && u.push(
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
  function Bt(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || N(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && N(t, "" + a);
        break;
      case "className":
        Ta(t, "class", a);
        break;
      case "tabIndex":
        Ta(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        Ta(t, l, a);
        break;
      case "style":
        lt(t, a, i);
        break;
      case "data":
        if (e !== "object") {
          Ta(t, "data", a);
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
        a = ln("" + a), t.setAttribute(l, a);
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
          typeof i == "function" && (l === "formAction" ? (e !== "input" && Bt(t, e, "name", n.name, n, null), Bt(
            t,
            e,
            "formEncType",
            n.formEncType,
            n,
            null
          ), Bt(
            t,
            e,
            "formMethod",
            n.formMethod,
            n,
            null
          ), Bt(
            t,
            e,
            "formTarget",
            n.formTarget,
            n,
            null
          )) : (Bt(t, e, "encType", n.encType, n, null), Bt(t, e, "method", n.method, n, null), Bt(t, e, "target", n.target, n, null)));
        if (a == null || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = ln("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = el);
        break;
      case "onScroll":
        a != null && dt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && dt("scrollend", t);
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
        l = ln("" + a), t.setAttributeNS(
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
        dt("beforetoggle", t), dt("toggle", t), Pa(t, "popover", a);
        break;
      case "xlinkActuate":
        tl(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:actuate",
          a
        );
        break;
      case "xlinkArcrole":
        tl(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:arcrole",
          a
        );
        break;
      case "xlinkRole":
        tl(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:role",
          a
        );
        break;
      case "xlinkShow":
        tl(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:show",
          a
        );
        break;
      case "xlinkTitle":
        tl(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:title",
          a
        );
        break;
      case "xlinkType":
        tl(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:type",
          a
        );
        break;
      case "xmlBase":
        tl(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:base",
          a
        );
        break;
      case "xmlLang":
        tl(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:lang",
          a
        );
        break;
      case "xmlSpace":
        tl(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:space",
          a
        );
        break;
      case "is":
        Pa(t, "is", a);
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = Dt.get(l) || l, Pa(t, l, a));
    }
  }
  function Pc(t, e, l, a, n, i) {
    switch (l) {
      case "style":
        lt(t, a, i);
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
        typeof a == "string" ? N(t, a) : (typeof a == "number" || typeof a == "bigint") && N(t, "" + a);
        break;
      case "onScroll":
        a != null && dt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && dt("scrollend", t);
        break;
      case "onClick":
        a != null && (t.onclick = el);
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
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[me] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : Pa(t, l, a);
          }
    }
  }
  function ve(t, e, l) {
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
        dt("error", t), dt("load", t);
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
                  Bt(t, e, i, u, l, null);
              }
          }
        n && Bt(t, e, "srcSet", l.srcSet, l, null), a && Bt(t, e, "src", l.src, l, null);
        return;
      case "input":
        dt("invalid", t);
        var c = i = u = n = null, r = null, v = null;
        for (a in l)
          if (l.hasOwnProperty(a)) {
            var A = l[a];
            if (A != null)
              switch (a) {
                case "name":
                  n = A;
                  break;
                case "type":
                  u = A;
                  break;
                case "checked":
                  r = A;
                  break;
                case "defaultChecked":
                  v = A;
                  break;
                case "value":
                  i = A;
                  break;
                case "defaultValue":
                  c = A;
                  break;
                case "children":
                case "dangerouslySetInnerHTML":
                  if (A != null)
                    throw Error(s(137, e));
                  break;
                default:
                  Bt(t, e, a, A, l, null);
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
        dt("invalid", t), a = u = i = null;
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
                Bt(t, e, n, c, l, null);
            }
        e = i, l = u, t.multiple = !!a, e != null ? d(t, !!a, e, !1) : l != null && d(t, !!a, l, !0);
        return;
      case "textarea":
        dt("invalid", t), i = n = a = null;
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
                Bt(t, e, u, c, l, null);
            }
        w(t, a, n, i);
        return;
      case "option":
        for (r in l)
          l.hasOwnProperty(r) && (a = l[r], a != null) && (r === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : Bt(t, e, r, a, l, null));
        return;
      case "dialog":
        dt("beforetoggle", t), dt("toggle", t), dt("cancel", t), dt("close", t);
        break;
      case "iframe":
      case "object":
        dt("load", t);
        break;
      case "video":
      case "audio":
        for (a = 0; a < Ui.length; a++)
          dt(Ui[a], t);
        break;
      case "image":
        dt("error", t), dt("load", t);
        break;
      case "details":
        dt("toggle", t);
        break;
      case "embed":
      case "source":
      case "link":
        dt("error", t), dt("load", t);
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
                Bt(t, e, v, a, l, null);
            }
        return;
      default:
        if (gt(e)) {
          for (A in l)
            l.hasOwnProperty(A) && (a = l[A], a !== void 0 && Pc(
              t,
              e,
              A,
              a,
              l,
              void 0
            ));
          return;
        }
    }
    for (c in l)
      l.hasOwnProperty(c) && (a = l[c], a != null && Bt(t, e, c, a, l, null));
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
        var n = null, i = null, u = null, c = null, r = null, v = null, A = null;
        for (T in l) {
          var C = l[T];
          if (l.hasOwnProperty(T) && C != null)
            switch (T) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                r = C;
              default:
                a.hasOwnProperty(T) || Bt(t, e, T, null, a, C);
            }
        }
        for (var b in a) {
          var T = a[b];
          if (C = l[b], a.hasOwnProperty(b) && (T != null || C != null))
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
                A = T;
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
                T !== C && Bt(
                  t,
                  e,
                  b,
                  T,
                  a,
                  C
                );
            }
        }
        $n(
          t,
          u,
          c,
          r,
          v,
          A,
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
                a.hasOwnProperty(i) || Bt(
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
                i !== r && Bt(
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
                Bt(t, e, c, null, a, n);
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
                n !== i && Bt(t, e, u, n, a, i);
            }
        x(t, b, T);
        return;
      case "option":
        for (var Y in l)
          b = l[Y], l.hasOwnProperty(Y) && b != null && !a.hasOwnProperty(Y) && (Y === "selected" ? t.selected = !1 : Bt(
            t,
            e,
            Y,
            null,
            a,
            b
          ));
        for (r in a)
          b = a[r], T = l[r], a.hasOwnProperty(r) && b !== T && (b != null || T != null) && (r === "selected" ? t.selected = b && typeof b != "function" && typeof b != "symbol" : Bt(
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
        for (var $ in l)
          b = l[$], l.hasOwnProperty($) && b != null && !a.hasOwnProperty($) && Bt(t, e, $, null, a, b);
        for (v in a)
          if (b = a[v], T = l[v], a.hasOwnProperty(v) && b !== T && (b != null || T != null))
            switch (v) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (b != null)
                  throw Error(s(137, e));
                break;
              default:
                Bt(
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
        if (gt(e)) {
          for (var Nt in l)
            b = l[Nt], l.hasOwnProperty(Nt) && b !== void 0 && !a.hasOwnProperty(Nt) && Pc(
              t,
              e,
              Nt,
              void 0,
              a,
              b
            );
          for (A in a)
            b = a[A], T = l[A], !a.hasOwnProperty(A) || b === T || b === void 0 && T === void 0 || Pc(
              t,
              e,
              A,
              b,
              a,
              T
            );
          return;
        }
    }
    for (var g in l)
      b = l[g], l.hasOwnProperty(g) && b != null && !a.hasOwnProperty(g) && Bt(t, e, g, null, a, b);
    for (C in a)
      b = a[C], T = l[C], !a.hasOwnProperty(C) || b === T || b == null && T == null || Bt(t, e, C, b, a, T);
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
            var A = r.transferSize, C = r.initiatorType;
            A && xd(C) && (r = r.responseEnd, u += A * (r < c ? 1 : (c - v) / (r - v)));
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
  var zd = typeof setTimeout == "function" ? setTimeout : void 0, Rh = typeof clearTimeout == "function" ? clearTimeout : void 0, Md = typeof Promise == "function" ? Promise : void 0, wh = typeof queueMicrotask == "function" ? queueMicrotask : typeof Md < "u" ? function(t) {
    return Md.resolve(null).then(t).catch(Bh);
  } : zd;
  function Bh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function oa(t) {
    return t === "head";
  }
  function Ed(t, e) {
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
          wi(t.ownerDocument.documentElement);
        else if (l === "head") {
          l = t.ownerDocument.head, wi(l);
          for (var i = l.firstChild; i; ) {
            var u = i.nextSibling, c = i.nodeName;
            i[Sa] || c === "SCRIPT" || c === "STYLE" || c === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && wi(t.ownerDocument.body);
      l = n;
    } while (l);
    Gn(e);
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
          no(l), Ia(l);
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
        if (!t[Sa])
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
  function wi(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    Ia(t);
  }
  var $e = /* @__PURE__ */ new Map(), Ud = /* @__PURE__ */ new Set();
  function Iu(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var ql = M.d;
  M.d = {
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
    var e = sl(t);
    e !== null && e.tag === 5 && e.type === "form" ? kr(e) : ql.r(t);
  }
  var Hn = typeof document > "u" ? null : document;
  function Rd(t, e, l) {
    var a = Hn;
    if (a && typeof e == "string" && e) {
      var n = he(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Ud.has(n) || (Ud.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), ve(e, "link", t), Ft(e), a.head.appendChild(e)));
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
    var a = Hn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + he(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + he(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + he(
        l.imageSizes
      ) + '"]')) : n += '[href="' + he(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = jn(t);
          break;
        case "script":
          i = qn(t);
      }
      $e.has(i) || (t = H(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), $e.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Bi(i)) || e === "script" && a.querySelector(Ni(i)) || (e = a.createElement("link"), ve(e, "link", t), Ft(e), a.head.appendChild(e)));
    }
  }
  function Qh(t, e) {
    ql.m(t, e);
    var l = Hn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + he(a) + '"][href="' + he(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = qn(t);
      }
      if (!$e.has(i) && (t = H({ rel: "modulepreload", href: t }, e), $e.set(i, t), l.querySelector(n) === null)) {
        switch (a) {
          case "audioworklet":
          case "paintworklet":
          case "serviceworker":
          case "sharedworker":
          case "worker":
          case "script":
            if (l.querySelector(Ni(i)))
              return;
        }
        a = l.createElement("link"), ve(a, "link", t), Ft(a), l.head.appendChild(a);
      }
    }
  }
  function Vh(t, e, l) {
    ql.S(t, e, l);
    var a = Hn;
    if (a && t) {
      var n = Pe(a).hoistableStyles, i = jn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var c = { loading: 0, preload: null };
        if (u = a.querySelector(
          Bi(i)
        ))
          c.loading = 5;
        else {
          t = H(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = $e.get(i)) && co(t, l);
          var r = u = a.createElement("link");
          Ft(r), ve(r, "link", t), r._p = new Promise(function(v, A) {
            r.onload = v, r.onerror = A;
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
    var l = Hn;
    if (l && t) {
      var a = Pe(l).hoistableScripts, n = qn(t), i = a.get(n);
      i || (i = l.querySelector(Ni(n)), i || (t = H({ src: t, async: !0 }, e), (e = $e.get(n)) && oo(t, e), i = l.createElement("script"), Ft(i), ve(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Kh(t, e) {
    ql.M(t, e);
    var l = Hn;
    if (l && t) {
      var a = Pe(l).hoistableScripts, n = qn(t), i = a.get(n);
      i || (i = l.querySelector(Ni(n)), i || (t = H({ src: t, async: !0, type: "module" }, e), (e = $e.get(n)) && oo(t, e), i = l.createElement("script"), Ft(i), ve(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function wd(t, e, l, a) {
    var n = (n = ct.current) ? Iu(n) : null;
    if (!n) throw Error(s(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = jn(l.href), l = Pe(
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
          var i = Pe(
            n
          ).hoistableStyles, u = i.get(t);
          if (u || (n = n.ownerDocument || n, u = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, i.set(t, u), (i = n.querySelector(
            Bi(t)
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
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = qn(l), l = Pe(
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
    return 'href="' + he(t) + '"';
  }
  function Bi(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Bd(t) {
    return H({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function Jh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), ve(e, "link", l), Ft(e), t.head.appendChild(e));
  }
  function qn(t) {
    return '[src="' + he(t) + '"]';
  }
  function Ni(t) {
    return "script[async]" + t;
  }
  function Nd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + he(l.href) + '"]'
          );
          if (a)
            return e.instance = a, Ft(a), a;
          var n = H({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), Ft(a), ve(a, "style", n), Pu(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = jn(l.href);
          var i = t.querySelector(
            Bi(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, Ft(i), i;
          a = Bd(l), (n = $e.get(n)) && co(a, n), i = (t.ownerDocument || t).createElement("link"), Ft(i);
          var u = i;
          return u._p = new Promise(function(c, r) {
            u.onload = c, u.onerror = r;
          }), ve(i, "link", a), e.state.loading |= 4, Pu(i, l.precedence, t), e.instance = i;
        case "script":
          return i = qn(l.src), (n = t.querySelector(
            Ni(i)
          )) ? (e.instance = n, Ft(n), n) : (a = l, (n = $e.get(i)) && (a = H({}, l), oo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Ft(n), ve(n, "link", a), t.head.appendChild(n), e.instance = n);
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
      if (!(i[Sa] || i[It] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
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
        var n = jn(a.href), i = e.querySelector(
          Bi(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = ef.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, Ft(i);
          return;
        }
        i = e.ownerDocument || e, a = Bd(a), (n = $e.get(n)) && co(a, n), i = i.createElement("link"), Ft(i);
        var u = i;
        u._p = new Promise(function(c, r) {
          u.onload = c, u.onerror = r;
        }), ve(i, "link", a), l.instance = i;
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
    $$typeof: xt,
    Provider: null,
    Consumer: null,
    _currentValue: j,
    _currentValue2: j,
    _threadCount: 0
  };
  function Ih(t, e, l, a, n, i, u, c, r) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Zn(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Zn(0), this.hiddenUpdates = Zn(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = r, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function Gd(t, e, l, a, n, i, u, c, r, v, A, C) {
    return t = new Ih(
      t,
      e,
      l,
      u,
      r,
      v,
      A,
      C,
      c
    ), e = 1, i === !0 && (e |= 24), i = He(3, null, null, e), t.current = i, i.stateNode = t, e = Qf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Jf(i), t;
  }
  function Yd(t) {
    return t ? (t = gn, t) : gn;
  }
  function Ld(t, e, l, a, n, i) {
    n = Yd(n), a.context === null ? a.context = n : a.pendingContext = n, a = Il(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = Pl(t, a, e), l !== null && (Ce(l, t, e), hi(l, t, e));
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
      var e = Ra(t, 67108864);
      e !== null && Ce(e, t, 67108864), so(t, 67108864);
    }
  }
  function Vd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Le();
      e = xa(e);
      var l = Ra(t, e);
      l !== null && Ce(l, t, e), so(t, e);
    }
  }
  var nf = !0;
  function Ph(t, e, l, a) {
    var n = p.T;
    p.T = null;
    var i = M.p;
    try {
      M.p = 2, mo(t, e, l, a);
    } finally {
      M.p = i, p.T = n;
    }
  }
  function tg(t, e, l, a) {
    var n = p.T;
    p.T = null;
    var i = M.p;
    try {
      M.p = 8, mo(t, e, l, a);
    } finally {
      M.p = i, p.T = n;
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
          var i = sl(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = fl(i.pendingLanes);
                  if (u !== 0) {
                    var c = i;
                    for (c.pendingLanes |= 2, c.entangledLanes |= 2; u; ) {
                      var r = 1 << 31 - ue(u);
                      c.entanglements[1] |= r, u &= ~r;
                    }
                    yl(i), (Ot & 6) === 0 && (Lu = de() + 500, Ci(0));
                  }
                }
                break;
              case 31:
              case 13:
                c = Ra(i, 2), c !== null && Ce(c, i, 2), Qu(), so(i, 2);
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
    return t = an(t), go(t);
  }
  var uf = null;
  function go(t) {
    if (uf = null, t = rl(t), t !== null) {
      var e = J(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = Q(e), t !== null) return t;
          t = null;
        } else if (l === 31) {
          if (t = et(e), t !== null) return t;
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
          case Ja:
            return 8;
          case pa:
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
  var po = !1, ra = null, sa = null, da = null, ji = /* @__PURE__ */ new Map(), qi = /* @__PURE__ */ new Map(), ma = [], eg = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Kd(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        ra = null;
        break;
      case "dragenter":
      case "dragleave":
        sa = null;
        break;
      case "mouseover":
      case "mouseout":
        da = null;
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
    }, e !== null && (e = sl(e), e !== null && Qd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function lg(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return ra = Gi(
          ra,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return sa = Gi(
          sa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return da = Gi(
          da,
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
    var e = rl(t.target);
    if (e !== null) {
      var l = J(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = Q(l), e !== null) {
            t.blockedOn = e, Jn(t.priority, function() {
              Vd(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = et(l), e !== null) {
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
        return e = sl(l), e !== null && Qd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function kd(t, e, l) {
    ff(t) && l.delete(e);
  }
  function ag() {
    po = !1, ra !== null && ff(ra) && (ra = null), sa !== null && ff(sa) && (sa = null), da !== null && ff(da) && (da = null), ji.forEach(kd), qi.forEach(kd);
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
          var i = sl(l);
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
  function Gn(t) {
    function e(r) {
      return cf(r, t);
    }
    ra !== null && cf(ra, t), sa !== null && cf(sa, t), da !== null && cf(da, t), ji.forEach(e), qi.forEach(e);
    for (var l = 0; l < ma.length; l++) {
      var a = ma[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < ma.length && (l = ma[0], l.blockedOn === null); )
      Jd(l), l.blockedOn === null && ma.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[me] || null;
        if (typeof i == "function")
          u || Fd(l);
        else if (u) {
          var c = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[me] || null)
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
    var l = e.current, a = Le();
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
      for (var l = 0; l < ma.length && e !== 0 && e < ma[l].priority; l++) ;
      ma.splice(l, 0, t), l === 0 && Jd(t);
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
  M.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(s(188)) : (t = Object.keys(t).join(","), Error(s(268, t)));
    return t = z(e), t = t !== null ? L(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var ng = {
    bundleType: 0,
    version: "19.2.3",
    rendererPackageName: "react-dom",
    currentDispatcherRef: p,
    reconcilerVersion: "19.2.3"
  };
  if (typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ < "u") {
    var sf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!sf.isDisabled && sf.supportsFiber)
      try {
        ya = sf.inject(
          ng
        ), Se = sf;
      } catch {
      }
  }
  return Li.createRoot = function(t, e) {
    if (!X(t)) throw Error(s(299));
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
    if (!X(t)) throw Error(s(299));
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
    ), e.context = Yd(null), l = e.current, a = Le(), a = xa(a), n = Il(a), n.callback = null, Pl(l, n, a), l = a, e.current.lanes = l, cl(e, l), yl(e), t[Sl] = e.current, $c(t), new rf(e);
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
var Ka = yg(), vg = mf();
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
  const O = /* @__PURE__ */ new Set();
  return (s) => {
    const X = S?.[s];
    if (typeof X == "string" && X.trim() !== "")
      return X;
    if (f.assertMissing && !O.has(s))
      throw O.add(s), new Error(`Missing cmux diff viewer label: ${s}`);
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
  }, O = {
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
      dark: S?.theme?.dark ?? O.name ?? "cmux-ghostty-dark"
    },
    themes: {
      light: f,
      dark: O
    }
  };
}
function mm(S) {
  if (!S)
    return;
  const f = S.themes?.light ?? {}, O = S.themes?.dark ?? {}, s = document.documentElement.style;
  s.setProperty("--cmux-diff-bg-light", Za(f.background, "#ffffff")), s.setProperty("--cmux-diff-bg-dark", Za(O.background, "#000000")), s.setProperty("--cmux-diff-fg-light", Za(f.foreground, "#000000")), s.setProperty("--cmux-diff-fg-dark", Za(O.foreground, "#ffffff")), s.setProperty("--cmux-diff-selection-bg-light", Za(f.selectionBackground, "#abd8ff")), s.setProperty("--cmux-diff-selection-bg-dark", Za(O.selectionBackground, "#3f638b")), s.setProperty("--cmux-diff-code-font-family", zg(S.fontFamily)), s.setProperty("--cmux-diff-font-size", `${df(S.fontSize, 10)}px`), s.setProperty("--cmux-diff-line-height", `${df(S.lineHeight, 20)}px`);
}
function Tg(S, f) {
  return hm(f?.backgroundOpacity) < 0.999 ? "transparent" : Za(S, "#000000");
}
function Za(S, f) {
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
function Mg(S, f, O) {
  if (!S)
    return {
      kind: "reset"
    };
  const s = S.pathCount ?? S.paths?.length ?? 0, X = f.pathCount ?? O.length;
  return !(f.previousSource === S || Eg(S, f)) || X < s ? {
    kind: "reset"
  } : {
    addedPaths: O.slice(s, X),
    kind: "append"
  };
}
function Eg(S, f) {
  const O = S.paths, s = f.paths, X = S.pathCount ?? O?.length ?? 0, J = f.pathCount ?? s?.length ?? 0;
  if (!Array.isArray(O) || !Array.isArray(s) || X > J)
    return !1;
  for (let Q = 0; Q < X; Q += 1)
    if (O[Q] !== s[Q])
      return !1;
  return !0;
}
function Ag(S) {
  const f = (o) => {
    const d = document.getElementById(o);
    if (!d)
      throw new Error(`Missing cmux diff viewer element: ${o}`);
    return d;
  }, O = S.assets ?? {}, s = (o, d) => {
    if (typeof o != "string" || o.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${d}`);
    return new URL(o, window.location.href).href;
  }, X = s(O.diffsModuleURL, "diffsModuleURL"), J = s(O.treesModuleURL, "treesModuleURL"), Q = s(O.workerPoolModuleURL, "workerPoolModuleURL"), et = s(O.workerModuleURL, "workerModuleURL"), U = S.payload ?? {}, z = dm(U.appearance), L = f("viewer"), H = f("status"), P = f("status-text"), mt = f("toolbar"), nt = f("source-select"), ht = f("repo-select"), qt = f("base-select"), Ct = f("source-detail"), rt = f("jump-select"), xt = f("external-link"), At = f("files-toggle"), _t = f("layout-toggle"), St = f("options-button"), k = f("options-menu"), Zt = f("files-sidebar"), Ht = f("file-list"), be = f("files-count"), Gt = f("file-search-toggle"), Yt = f("file-collapse-toggle"), se = f("stats-files"), ae = f("stats-added"), ne = f("stats-deleted"), p = sm(U.labels, {
    assertMissing: rm()
  }), M = {
    layout: U.layout === "unified" ? "unified" : "split",
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
  let j, ot, W;
  const m = [], E = [], B = /* @__PURE__ */ new Map();
  let q = /* @__PURE__ */ new Set(), tt = null, ct = null, vt = /* @__PURE__ */ new Map(), ie = {
    value: null
  }, Qt = "", Ue = "", Yl = !1, Ie = /* @__PURE__ */ new Map(), vl = /* @__PURE__ */ new Map();
  typeof U.title == "string" && U.title.trim() !== "" && (document.title = U.title), mm(z), Se(), ol(U.sourceOptions ?? []), Sl(ht, U.repoOptions ?? [], U.repoRoot ?? "", p("repoPath")), Sl(qt, U.baseOptions ?? [], U.branchBaseRef ?? "", p("branchBase"));
  const il = globalThis.queueMicrotask ?? ((o) => setTimeout(o, 0));
  U.pendingReplacement === !0 ? (Re(U.statusMessage ?? p("loadingDiff"), {
    loading: !0,
    pending: !0
  }), Xi()) : typeof U.statusMessage == "string" && U.statusMessage.length > 0 ? Re(U.statusMessage, {
    error: U.statusIsError === !0,
    loading: !1,
    statusOnly: !0
  }) : il(() => {
    Yn().catch((o) => {
      console.error("cmux diff viewer render failed", o), Re(p("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      });
    });
  });
  async function Yn() {
    Re(p("loadingRenderer"), {
      loading: !0
    });
    const [{
      CodeView: o,
      getFiletypeFromFileName: d,
      parsePatchFiles: x,
      preloadHighlighter: w,
      processFile: N,
      registerCustomTheme: G
    }, K] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(X),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(J).catch((gt) => (console.warn("cmux diff file tree import failed", gt), null))
    ]);
    if (he(G, z.themes.light), he(G, z.themes.dark), Re(p("parsingDiff"), {
      loading: !0
    }), ga("loading"), ot = await Ln(), tu(m), Te(), window.__cmuxDiffViewer = {
      codeView: j,
      items: m,
      state: M,
      workerPool: ot
    }, Xn(ot), ot?.initialize?.()?.then?.(() => Qn(ot?.getStats?.()))?.catch?.((gt) => console.warn("cmux diff worker pool initialization failed", gt)), window.addEventListener("pagehide", () => ot?.terminate?.(), {
      once: !0
    }), await Zi({
      CodeView: o,
      parsePatchFiles: x,
      processFile: N,
      treesModule: K
    }), m.length === 0)
      throw new Error(p("noFileDiffs"));
    ot || $n(z, E.length > 0 ? E : m, d, w).catch((gt) => console.warn("cmux diff highlighter preload failed", gt));
  }
  function Re(o, d = {}) {
    H.isConnected || L.replaceChildren(H), document.body.dataset.loading = d.loading === !0 || d.pending === !0 ? "true" : "false", document.body.dataset.statusOnly = d.statusOnly === !0 ? "true" : "false", H.dataset.error = d.error === !0 ? "true" : "false", H.dataset.pending = d.pending === !0 ? "true" : "false", P.textContent = o;
  }
  async function hf(o) {
    return o.ok ? (await o.text()).includes('data-cmux-diff-pending="true"') ? !1 : (window.location.reload(), !0) : (Re(p("renderFailed"), {
      error: !0,
      loading: !1,
      statusOnly: !0
    }), !1);
  }
  async function Xi() {
    try {
      const o = await fetch("/__cmux_diff_viewer_wait" + location.pathname, {
        cache: "no-store"
      });
      await hf(o);
    } catch (o) {
      document.documentElement.dataset.cmuxDiffWait = "failed", Re(p("renderFailed"), {
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
      he(o.registerCustomTheme, z.themes.light), he(o.registerCustomTheme, z.themes.dark);
      const d = new URL(et, window.location.href).href;
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
      ga("fallback");
      return;
    }
    ga("enabled"), Qn(o.getStats?.());
    const d = o.subscribeToStatChanges?.((x) => {
      Qn(x);
    });
    typeof d == "function" && window.addEventListener("pagehide", d, {
      once: !0
    });
  }
  function ga(o) {
    document.body.dataset.workerPool = o;
  }
  function Qn(o) {
    !o || typeof o != "object" || (typeof o.managerState == "string" && (document.body.dataset.workerPoolState = o.managerState), Number.isFinite(o.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(o.totalWorkers)), typeof o.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(o.workersFailed)));
  }
  function Qi() {
    return {
      theme: z.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: M.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const de = /^From\s+([a-f0-9]+)\s/im;
  function Vi(o, d) {
    const x = o?.match(de);
    return x?.[1] ? new TextDecoder().decode(new TextEncoder().encode(x[1].slice(0, 5))) : `${p("commit")} ${d + 1}`;
  }
  async function Zi({
    CodeView: o,
    parsePatchFiles: d,
    processFile: x,
    treesModule: w
  }) {
    const N = gf(), G = {
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
    let lt = performance.now(), gt = performance.now(), Dt = !0;
    const Vl = {
      initialBatchSize: Fn(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function ln(D, R) {
      const I = el(N, D, R);
      return I?.renamedItem && iu(I.renamedItem), I?.item;
    }
    function el(D, R, I) {
      if (!R)
        return null;
      const it = oe(R), Tt = I == null ? it : `${I}/${it}`, zt = it.length === 0 ? void 0 : D.pathStateByTreePath.get(Tt), Kt = zt == null ? void 0 : In(D, Tt, zt), ze = Ql(R), Be = {
        id: D.itemIdToFile.has(Tt) ? an(D, `${Tt}?2`) : Tt,
        type: "diff",
        fileDiff: R,
        version: 0,
        // Inherit the current collapse state so items flushed after "Collapse all
        // diffs" (while a large diff is still streaming) render collapsed too.
        collapsed: M.collapsed
      }, fu = D.items.length;
      D.fileIndex += 1, D.items.push(Be), D.pendingItems.push(Be), D.pendingItemById.set(Be.id, Be), D.itemIdToFile.set(Be.id, {
        fileOrder: fu,
        path: it
      }), D.itemIdByTreePath.set(Tt, Be.id), D.treePathByItemId.set(Be.id, Tt), D.diffStats.addedLines += ze.added, D.diffStats.deletedLines += ze.deleted, D.diffStats.fileCount += 1, D.diffStats.totalLinesOfCode += R.unifiedLineCount ?? R.splitLineCount ?? 0;
      const Sf = D.statsByPath.get(Tt);
      return D.statsByPath.set(Tt, ze), zt != null && !en(Sf, ze) && (D.pendingStatsChanged = !0), it.length > 0 && (zt == null && D.paths.push(Tt), D.pathToItemId.set(Tt, Be.id), Zl(D, Tt, R.type, zt?.sawDeleted === !0), D.pathStateByTreePath.set(Tt, {
        currentItem: Be,
        currentItemId: Be.id,
        currentType: R.type,
        fileOrder: fu,
        sawDeleted: zt?.sawDeleted === !0 || R.type === "deleted"
      })), {
        item: Be,
        renamedItem: Kt
      };
    }
    function In(D, R, I) {
      const it = I.currentItemId, Tt = I.currentType === "deleted" ? "?deleted" : "?previous", zt = an(D, `${R}${Tt}`);
      if (I.currentItem.id = zt, I.currentItemId = zt, D.itemIdToFile.has(it)) {
        const Kt = D.itemIdToFile.get(it);
        D.itemIdToFile.delete(it), D.itemIdToFile.set(zt, Kt);
      }
      if (D.treePathByItemId.has(it) && (D.treePathByItemId.delete(it), D.treePathByItemId.set(zt, R)), D.pendingItemById.has(it)) {
        const Kt = D.pendingItemById.get(it);
        D.pendingItemById.delete(it), D.pendingItemById.set(zt, Kt);
        return;
      }
      return {
        oldId: it,
        newId: zt
      };
    }
    function an(D, R) {
      if (!D.itemIdToFile.has(R))
        return R;
      let I = D.nextCollisionSuffixByBase.get(R) ?? 2, it = `${R}-${I}`;
      for (; D.itemIdToFile.has(it); )
        I += 1, it = `${R}-${I}`;
      return D.nextCollisionSuffixByBase.set(R, I + 1), it;
    }
    function Zl(D, R, I, it) {
      if (it && I !== "deleted") {
        D.gitStatusByPath.delete(R) && Tl(D, R);
        return;
      }
      const Tt = tn(I);
      if (Tt === "modified") {
        D.gitStatusByPath.delete(R) && Tl(D, R);
        return;
      }
      if (D.gitStatusByPath.get(R)?.status === Tt)
        return;
      const Kt = {
        path: R,
        status: Tt
      };
      D.gitStatusByPath.set(R, Kt), D.pendingGitStatusRemovePaths.delete(R), D.pendingGitStatusSetByPath.set(R, Kt);
    }
    function Tl(D, R) {
      D.pendingGitStatusSetByPath.delete(R), D.pendingGitStatusRemovePaths.add(R);
    }
    function iu(D) {
      if (q.delete(D.oldId) && q.add(D.newId), B.has(D.oldId)) {
        const R = B.get(D.oldId);
        B.delete(D.oldId), R && B.set(D.newId, R);
      }
      lu(D.oldId, D.newId), j?.updateItemId?.(D.oldId, D.newId);
    }
    async function za(D, R) {
      ln(D, R) && await nn(!1);
    }
    async function nn(D) {
      if (N.pendingItems.length === 0)
        return;
      const R = performance.now();
      if (!D && Dt && R - lt >= 8 && N.pendingItems.length < Vl.initialBatchSize && R - gt < Vl.initialMaxWait) {
        await Ji(), lt = performance.now();
        return;
      }
      const I = Dt ? Vl.initialBatchSize : Vl.incrementalBatchSize, it = Dt ? Vl.initialMaxWait : Vl.incrementalMaxWait;
      if (D || N.pendingItems.length >= I || R - gt >= it) {
        Ma(), await Ji(), lt = performance.now();
        return;
      }
    }
    function Ma() {
      if (N.pendingItems.length === 0)
        return;
      const D = N.pendingItems.splice(0, N.pendingItems.length);
      N.pendingItemById.clear();
      const R = D, I = E.length > 0;
      m.push(...D);
      for (const it of D)
        B.set(it.id, it);
      if (R.length > 0) {
        E.push(...R);
        for (const it of R)
          q.add(it.id);
        j ? j.addItems(R) : (j = new o(va(), ot ?? void 0), j.setup(L), j.setItems(E), j.render(!0), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.codeView = j));
      }
      eu(D), Ea(w, !1, D.length), K.flushCount += 1, K.maxBatchSize = Math.max(K.maxBatchSize, D.length), K.fileCount = m.length, K.renderableFileCount = E.length, Ja(K), gt = performance.now(), Dt && (Dt = !1, document.body.dataset.loading = "false", H.remove()), I || Ta(E[0]?.id ?? m[0]?.id ?? ""), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.items = m, window.__cmuxDiffViewer.codeViewItems = E, window.__cmuxDiffViewer.streamMetrics = K);
    }
    function Xe() {
      j && (j.syncContainerHeight?.(), j.render(!0));
    }
    function Ea(D, R, I = 1) {
      if (G.treesModule = D, G.dirtyCount += I, R || G.lastRefreshAt === 0) {
        zl(G.treesModule);
        return;
      }
      const it = performance.now() - G.lastRefreshAt;
      if (G.dirtyCount >= 1e3 || it >= 1e3) {
        zl(G.treesModule);
        return;
      }
      if (G.timeout !== 0)
        return;
      const Tt = Math.max(0, 1e3 - it);
      G.timeout = window.setTimeout(() => {
        G.timeout = 0, zl(G.treesModule);
      }, Tt);
    }
    function zl(D) {
      G.timeout !== 0 && (window.clearTimeout(G.timeout), G.timeout = 0), G.dirtyCount = 0, G.lastRefreshAt = performance.now(), K.treeRefreshCount += 1, ct = Ki(N), vf(ct, D), Te(), Ja(K);
    }
    const Ee = await fetch(U.patchURL, {
      cache: "no-store"
    });
    if (!Ee.ok)
      throw new Error(`${p("loadingDiff")} (${Ee.status})`);
    if (!Ee.body?.getReader) {
      const D = await Ee.text();
      await pa(D, d, za), await nn(!0), Xe(), Ea(w, !0), K.completedAt = performance.now();
      return;
    }
    const un = new TextDecoder(), fn = Ee.body.getReader(), Pn = "diff --git ", Aa = `
` + Pn, cn = Aa.length - 1, ti = /\S/;
    function fe(D, R) {
      const I = Math.max(R, 0);
      if (I === 0 && D.startsWith(Pn))
        return 0;
      const it = D.indexOf(Aa, I);
      return it === -1 ? void 0 : it + 1;
    }
    function ml(D, R) {
      return Math.max(R, D.length - cn);
    }
    function on(D, R, I) {
      const it = Math.max(R, 0), Tt = Math.min(I, D.length);
      if (it >= Tt)
        return;
      let zt = D.lastIndexOf(`
From `, Tt - 1);
      for (; zt !== -1; ) {
        const Kt = zt + 1;
        if (Kt < it)
          return;
        if (Kt >= Tt) {
          zt = D.lastIndexOf(`
From `, zt - 1);
          continue;
        }
        const ze = D.indexOf(`
`, Kt + 1), Kl = D.slice(Kt, ze === -1 || ze > Tt ? Tt : ze);
        if (de.test(Kl))
          return Kt;
        zt = D.lastIndexOf(`
From `, zt - 1);
      }
    }
    function _a(D) {
      const R = fe(D, 0);
      if (R == null || R <= 0)
        return;
      const I = D.slice(0, R);
      return de.test(I) ? I : void 0;
    }
    async function uu(D) {
      if (D.trim() === "")
        return;
      const R = _a(D);
      R != null && (Oa = Vi(R, li), li += 1);
      const I = `cmux-diff-file-${N.fileIndex}`;
      await za(x(D, {
        cacheKey: I,
        isGitDiff: !0
      }), Oa);
    }
    function ei() {
      let D, R = "", I = 0, it = !1;
      function Tt() {
        if (D == null) {
          if (D = fe(R, I), D == null)
            return I = ml(R, 0), null;
          it = !0, I = D + 1;
        }
        for (; ; ) {
          const zt = D;
          if (zt == null)
            return null;
          const Kt = fe(R, I);
          if (Kt == null)
            return I = ml(R, zt + 1), null;
          const ze = on(R, zt + 1, Kt) ?? Kt, Kl = R.slice(0, ze);
          if (R = R.slice(ze), D = fe(R, 0), I = D == null ? 0 : D + 1, ti.test(Kl))
            return Kl;
        }
      }
      return {
        push(zt) {
          zt.length > 0 && (R += zt);
        },
        takeAvailableFile: Tt,
        finish() {
          const zt = Tt();
          if (zt != null)
            return {
              fileText: zt
            };
          if (!ti.test(R))
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
    async function Da(D) {
      let R;
      for (; (R = D.takeAvailableFile()) != null; )
        await uu(R);
    }
    const Qe = ei();
    let Oa, li = 0;
    for (; ; ) {
      const {
        done: D,
        value: R
      } = await fn.read();
      if (D) {
        const I = un.decode();
        I.length > 0 && (Qe.push(I), await Da(Qe));
        break;
      }
      Qe.push(un.decode(R, {
        stream: !0
      })), await Da(Qe);
    }
    const rn = Qe.finish();
    rn.fileText != null ? (await uu(rn.fileText), await Da(Qe)) : rn.fallbackPatchContent != null && await pa(rn.fallbackPatchContent, d, za), await nn(!0), Xe(), Ea(w, !0), K.completedAt = performance.now(), Ja(K);
  }
  function Ja(o) {
    document.body.dataset.streamFileCount = String(o.fileCount ?? m.length), document.body.dataset.streamRenderableFileCount = String(o.renderableFileCount ?? E.length), document.body.dataset.streamFlushCount = String(o.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(o.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(o.treeRefreshCount ?? 0), Number.isFinite(o.completedAt) && o.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(o.completedAt - o.startedAt)));
  }
  async function pa(o, d, x) {
    const w = d(o, "cmux-diff"), N = w.length > 1;
    for (const [G, K] of w.entries()) {
      const lt = N ? Vi(K.patchMetadata, G) : void 0;
      for (const gt of K.files ?? [])
        await x(gt, lt);
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
    const d = o.lastTreeSource, x = pf(o), w = {
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
    return o.pendingStatsChanged = !1, o.lastTreeSource = w, w;
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
      const w = () => {
        d || (d = !0, x !== 0 && window.clearTimeout(x), o());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        x = window.setTimeout(w, 50), window.requestAnimationFrame(w);
      else if (typeof MessageChannel < "u") {
        const N = new MessageChannel();
        N.port1.onmessage = w, N.port2.postMessage(void 0);
      } else
        queueMicrotask(w);
    });
  }
  async function ya() {
    return ie.value == null && (ie.value = fetch(U.patchURL, {
      cache: "no-store"
    }).then(async (o) => {
      if (!o.ok)
        throw new Error(`${p("loadingDiff")} (${o.status})`);
      return o.text();
    })), ie.value;
  }
  function Se() {
    At.innerHTML = we("files"), Gt.innerHTML = we("search"), Yt.innerHTML = we("sidebarCollapse"), _t.innerHTML = we(M.layout), St.innerHTML = we("dots"), typeof U.externalURL == "string" && U.externalURL.length > 0 && (xt.href = U.externalURL, xt.innerHTML = we("external"), xt.hidden = !1), At.addEventListener("click", () => cl(!M.filesVisible)), Yt.addEventListener("click", () => cl(!1)), Gt.addEventListener("click", () => Fi(!M.fileSearchOpen)), _t.addEventListener("click", () => Zn(M.layout === "split" ? "unified" : "split")), St.addEventListener("click", () => $a(k.hidden)), document.addEventListener("click", (o) => {
      k.hidden || o.target instanceof Node && mt.contains(o.target) || $a(!1);
    }), document.addEventListener("keydown", (o) => {
      o.key === "Escape" && $a(!1);
    }), ul(), Te();
  }
  function ul() {
    const o = U.shortcuts ?? {}, d = ue(o.diffViewerScrollDown), x = ue(o.diffViewerScrollUp), w = ue(o.diffViewerScrollToBottom), N = ue(o.diffViewerScrollToTop), G = ue(o.diffViewerOpenFileSearch);
    let K = null, lt = 0;
    document.addEventListener("keydown", (Dt) => {
      if (!(Dt.defaultPrevented || Wa(Dt.target))) {
        if (K && !bl(K.shortcut.second, Dt) && gt(), K && bl(K.shortcut.second, Dt)) {
          Dt.preventDefault(), K.action(), gt();
          return;
        }
        if (ka(d, Dt)) {
          Dt.preventDefault(), fl(1);
          return;
        }
        if (ka(x, Dt)) {
          Dt.preventDefault(), fl(-1);
          return;
        }
        if (ka(w, Dt)) {
          Dt.preventDefault(), L.scrollTo({
            top: L.scrollHeight,
            behavior: "auto"
          });
          return;
        }
        if (ka(G, Dt) && W) {
          Dt.preventDefault(), cl(!0), Fi(!0);
          return;
        }
        N && yf(N, Dt) && (Dt.preventDefault(), K = {
          shortcut: N,
          action: () => L.scrollTo({
            top: 0,
            behavior: "auto"
          })
        }, lt = window.setTimeout(gt, 700));
      }
    });
    function gt() {
      K = null, lt !== 0 && (window.clearTimeout(lt), lt = 0);
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
  function ka(o, d) {
    return o && !o.second && bl(o.first, d);
  }
  function yf(o, d) {
    return o && o.second && bl(o.first, d);
  }
  function bl(o, d) {
    return !o || d.metaKey !== o.command || d.ctrlKey !== o.control || d.altKey !== o.option || d.shiftKey !== o.shift ? !1 : Fa(d) === o.key;
  }
  function Fa(o) {
    return o.code === "Space" ? "space" : typeof o.key != "string" || o.key.length === 0 ? "" : (o.key.length === 1, o.key.toLowerCase());
  }
  function Wa(o) {
    const d = o instanceof Element ? o : null;
    return d ? !!d.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function fl(o) {
    const d = Math.max(80, Math.floor(L.clientHeight * 0.38));
    L.scrollBy({
      top: o * d,
      behavior: "auto"
    });
  }
  function va() {
    return {
      layout: {
        paddingTop: 0,
        gap: 1,
        paddingBottom: 0
      },
      diffStyle: M.layout,
      diffIndicators: M.diffIndicators,
      overflow: M.wordWrap ? "wrap" : "scroll",
      expandUnchanged: M.expandUnchanged,
      disableBackground: !M.showBackgrounds,
      disableLineNumbers: !M.lineNumbers,
      lineHoverHighlight: "number",
      enableLineSelection: !0,
      enableGutterUtility: !0,
      lineDiffType: M.wordDiffs ? "word" : "none",
      stickyHeaders: !0,
      unsafeCSS: ba(),
      theme: z.theme,
      themeType: "system"
    };
  }
  function ba() {
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
    const o = va();
    if (!j) {
      Vn();
      return;
    }
    j.setOptions(o), Vn(), j.render(!0);
  }
  function Vn() {
    ot?.setRenderOptions && ot.setRenderOptions(Qi()).then(() => j?.render(!0)).catch((o) => console.warn("cmux diff worker render options update failed", o));
  }
  function Zn(o) {
    M.layout = o === "unified" ? "unified" : "split", Te(), xl();
  }
  function cl(o) {
    M.filesVisible = o, document.body.dataset.filesHidden = o ? "false" : "true", Zt.setAttribute("aria-hidden", String(!o)), o ? Zt.removeAttribute("inert") : Zt.setAttribute("inert", ""), Te();
  }
  function Fi(o) {
    M.fileSearchOpen = !!o, W && (M.fileSearchOpen ? W.openSearch("") : W.closeSearch()), Te();
  }
  function Wi(o) {
    M.collapsed = o;
    const d = E.map((N) => ({
      ...N,
      collapsed: o,
      version: (N.version ?? 0) + 1
    })), x = new Map(d.map((N) => [N.id, N])), w = m.map((N) => x.get(N.id) ?? {
      ...N,
      collapsed: o,
      version: (N.version ?? 0) + 1
    });
    E.splice(0, E.length, ...d), m.splice(0, m.length, ...w), j && (j.setItems(E), j.render(!0)), Te();
  }
  function Te() {
    At.setAttribute("aria-pressed", String(M.filesVisible)), At.title = M.filesVisible ? p("hideFiles") : p("showFiles"), At.setAttribute("aria-label", At.title), Yt.title = p("hideFiles"), Yt.setAttribute("aria-label", Yt.title), _t.innerHTML = we(M.layout), _t.title = M.layout === "split" ? p("switchToUnifiedDiff") : p("switchToSplitDiff"), _t.setAttribute("aria-label", _t.title), St.setAttribute("aria-expanded", String(!k.hidden)), document.documentElement.dataset.layout = M.layout, document.documentElement.dataset.wordWrap = String(M.wordWrap), document.documentElement.dataset.diffIndicators = M.diffIndicators, Gt.disabled = !W, Gt.setAttribute("aria-pressed", String(M.fileSearchOpen)), Gt.title = M.fileSearchOpen ? p("hideFileSearch") : p("showFileSearch"), Gt.setAttribute("aria-label", Gt.title);
  }
  function $a(o) {
    o && xa(), k.hidden = !o, Te();
  }
  function xa() {
    k.textContent = "";
    const o = [{
      label: p("refresh"),
      icon: "refresh",
      action: () => window.location.reload()
    }, {
      label: M.wordWrap ? p("disableWordWrap") : p("enableWordWrap"),
      icon: "wrap",
      checked: M.wordWrap,
      action: () => {
        M.wordWrap = !M.wordWrap, xl();
      }
    }, {
      label: M.collapsed ? p("expandAllDiffs") : p("collapseAllDiffs"),
      icon: "collapse",
      checked: M.collapsed,
      action: () => Wi(!M.collapsed)
    }, "separator", {
      label: M.filesVisible ? p("hideFiles") : p("showFiles"),
      icon: "files",
      checked: M.filesVisible,
      action: () => cl(!M.filesVisible)
    }, {
      label: M.expandUnchanged ? p("collapseUnchangedContext") : p("expandUnchangedContext"),
      icon: "document",
      checked: M.expandUnchanged,
      action: () => {
        M.expandUnchanged = !M.expandUnchanged, xl();
      }
    }, {
      label: M.showBackgrounds ? p("hideBackgrounds") : p("showBackgrounds"),
      icon: "background",
      checked: M.showBackgrounds,
      action: () => {
        M.showBackgrounds = !M.showBackgrounds, xl();
      }
    }, {
      label: M.lineNumbers ? p("hideLineNumbers") : p("showLineNumbers"),
      icon: "numbers",
      checked: M.lineNumbers,
      action: () => {
        M.lineNumbers = !M.lineNumbers, xl();
      }
    }, {
      label: M.wordDiffs ? p("disableWordDiffs") : p("enableWordDiffs"),
      icon: "word",
      checked: M.wordDiffs,
      action: () => {
        M.wordDiffs = !M.wordDiffs, xl();
      }
    }, {
      kind: "segment",
      label: p("indicatorStyle"),
      icon: "bars",
      options: [{
        value: "bars",
        icon: "bars",
        label: p("bars")
      }, {
        value: "classic",
        icon: "classic",
        label: p("classic")
      }, {
        value: "none",
        icon: "eye",
        label: p("none")
      }]
    }, "separator", {
      label: p("copyGitApplyCommand"),
      icon: "clipboard",
      action: $i
    }];
    for (const d of o) {
      if (d === "separator") {
        const N = document.createElement("div");
        N.className = "menu-separator", k.append(N);
        continue;
      }
      if (d.kind === "segment") {
        const N = document.createElement("div");
        N.className = "menu-item menu-segment", N.setAttribute("role", "presentation"), N.innerHTML = `${we(d.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
        const G = N.querySelector(".menu-label");
        G && (G.textContent = d.label);
        const K = N.querySelector(".menu-segment-controls");
        if (!K)
          continue;
        for (const lt of d.options) {
          const gt = document.createElement("button");
          gt.type = "button", gt.className = "segment-button", gt.title = lt.label, gt.setAttribute("aria-label", lt.label), gt.setAttribute("aria-pressed", String(M.diffIndicators === lt.value)), gt.innerHTML = we(lt.icon), gt.addEventListener("click", () => {
            M.diffIndicators = lt.value, xl(), xa(), Te();
          }), K.append(gt);
        }
        k.append(N);
        continue;
      }
      const x = document.createElement("button");
      x.type = "button", x.className = "menu-item", x.setAttribute("role", d.checked == null ? "menuitem" : "menuitemcheckbox"), d.checked != null && x.setAttribute("aria-checked", String(!!d.checked)), x.disabled = !!d.disabled, x.innerHTML = `${we(d.icon)}<span class="menu-label"></span><span class="menu-check">${d.checked ? we("check") : ""}</span>`;
      const w = x.querySelector(".menu-label");
      w && (w.textContent = d.label), x.addEventListener("click", () => {
        x.disabled || (d.action?.(), xa(), Te());
      }), k.append(x);
    }
  }
  function Kn(o) {
    const d = new Set(o.split(/\r?\n/));
    let x = "CMUX_DIFF_PATCH", w = 0;
    for (; d.has(x); )
      w += 1, x = `CMUX_DIFF_PATCH_${w}`;
    return x;
  }
  async function $i() {
    const d = await ya(), x = d.endsWith(`
`) ? d : `${d}
`, w = Kn(x), N = `git apply <<'${w}'
${x}${w}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(N);
      } catch {
        Jn(N);
      }
    else
      Jn(N);
    St.title = p("copiedGitApplyCommand"), St.setAttribute("aria-label", p("copiedGitApplyCommand"));
  }
  function Jn(o) {
    const d = document.createElement("textarea");
    d.value = o, d.setAttribute("readonly", ""), d.style.position = "fixed", d.style.left = "-9999px", document.body.append(d), d.select(), document.execCommand("copy"), d.remove();
  }
  function ol(o) {
    if (Ct.textContent = me(), !Array.isArray(o) || o.length < 2)
      return;
    nt.textContent = "";
    const d = o.find((x) => x.selected) ?? o.find((x) => !x.disabled);
    for (const x of o) {
      const w = document.createElement("option");
      w.value = x.value, w.textContent = x.label, w.disabled = x.disabled || !x.url, w.selected = x.value === d?.value, x.message && (w.title = x.message), nt.append(w);
    }
    Ct.textContent = d?.sourceLabel ?? me(), nt.hidden = !1, nt.addEventListener("change", () => {
      const x = o.find((w) => w.value === nt.value);
      if (!x?.url) {
        nt.value = d?.value ?? "";
        return;
      }
      Re(p("loadingDiff"), {
        pending: !0
      }), window.location.href = It(x.url);
    });
  }
  function It(o) {
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
  function me() {
    return [U.sourceLabel, U.repoRoot, U.branchBaseRef].filter((d) => typeof d == "string" && d.trim() !== "").join(" | ");
  }
  function Sl(o, d, x, w) {
    if (!o || !Array.isArray(d) || d.length < 2)
      return;
    o.textContent = "";
    const N = d.find((G) => G.selected) ?? d.find((G) => !G.disabled);
    for (const G of d) {
      const K = document.createElement("option");
      K.value = G.value, K.textContent = G.label, K.disabled = G.disabled || !G.url, K.selected = G.value === N?.value, G.message && (K.title = G.message), o.append(K);
    }
    o.hidden = !1, o.title = w, o.addEventListener("change", () => {
      const G = d.find((K) => K.value === o.value);
      if (!G?.url) {
        o.value = N?.value ?? x ?? "";
        return;
      }
      Re(p("loadingDiff"), {
        pending: !0
      }), window.location.href = It(G.url);
    });
  }
  function kn(o, d) {
    const x = Ia(o), w = Sa(d);
    if (Pe(o, []), W && (W.cleanUp?.(), W = null), tt = null, M.fileSearchOpen = !1, Ht.textContent = "", be.textContent = `${x}`, dl(o), w)
      try {
        bf(o, d), Te();
        return;
      } catch (G) {
        console.warn("cmux diff file tree setup failed", G);
      }
    const N = rl(o);
    Pe(o, N), Ft(N), Te();
  }
  function vf(o, d) {
    const x = Ia(o);
    if (Pe(o, []), be.textContent = `${x}`, dl(o), W && Ht.dataset.treeMode === "pierre" && d?.preparePresortedFileTreeInput) {
      Ii(o, d);
      return;
    }
    if (W || Ht.childElementCount === 0) {
      kn(o, d);
      return;
    }
    const w = rl(o);
    Pe(o, w), Ht.textContent = "", Ft(w);
  }
  function bf(o, d) {
    const {
      FileTree: x,
      preparePresortedFileTreeInput: w
    } = d, N = sl(o);
    tt = o;
    const G = N[0];
    Ll(o), Ht.dataset.treeMode = "pierre", W = new x({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: G ? [G] : [],
      initialVisibleRowCount: Fn(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: w(N),
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: o.gitStatus,
      renderRowDecoration(K) {
        if (K.item.kind !== "file")
          return null;
        const lt = vt.get(K.item.path);
        return lt == null || lt.added === 0 && lt.deleted === 0 ? null : {
          text: `+${lt.added} -${lt.deleted}`,
          title: `${lt.added} ${p("additions")}, ${lt.deleted} ${p("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Pi(),
      onSelectionChange(K) {
        if (Yl)
          return;
        const lt = K[K.length - 1], gt = Ie.get(lt);
        gt && Wn(gt);
      }
    }), W.render({
      containerWrapper: Ht
    });
  }
  function Ii(o, d) {
    const x = tt, w = sl(o);
    tt = o, Ll(o);
    let N = !1;
    const G = Mg(x, o, w);
    if (G.kind === "append") {
      const K = G.addedPaths;
      if (K.length > 0)
        try {
          W.batch(K.map((lt) => ({
            type: "add",
            path: lt
          })));
        } catch (lt) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", lt), W.resetPaths(w, {
            preparedInput: d.preparePresortedFileTreeInput(w)
          }), N = !0;
        }
    } else
      W.resetPaths(w, {
        preparedInput: d.preparePresortedFileTreeInput(w)
      }), N = !0;
    o.gitStatusPatch ? typeof W.applyGitStatusPatch == "function" ? W.applyGitStatusPatch(o.gitStatusPatch) : W.setGitStatus(o.gitStatus) : (N || o.statsChanged === !0) && W.setGitStatus(o.gitStatus);
  }
  function Sa(o) {
    return !!(o?.FileTree && o?.preparePresortedFileTreeInput);
  }
  function Ia(o) {
    return o?.pathCount ?? o?.entries?.length ?? 0;
  }
  function rl(o) {
    const d = o?.pathCount ?? o?.entries?.length ?? 0, x = o?.entries ?? [];
    if (x.length > 0)
      return x.length === d ? x : x.slice(0, d);
    const w = sl(o), N = o?.pathToItemId, G = o?.statsByPath;
    return w.map((K) => {
      const lt = N instanceof Map ? N.get(K) : void 0, gt = lt ? B.get(lt) : void 0, Dt = gt?.fileDiff ?? {};
      return {
        item: gt ?? {
          id: lt ?? K,
          fileDiff: Dt
        },
        path: K,
        status: xf(Dt),
        stats: G instanceof Map ? G.get(K) ?? Ql(Dt) : Ql(Dt)
      };
    });
  }
  function sl(o) {
    const d = o?.pathCount ?? o?.paths?.length ?? 0, x = o?.paths ?? [];
    return x.length === d ? x : x.slice(0, d);
  }
  function Ll(o) {
    if (o?.statsByPath instanceof Map) {
      vt = o.statsByPath;
      return;
    }
    vt = /* @__PURE__ */ new Map();
    const d = rl(o);
    for (const x of d)
      vt.set(x.path, x.stats);
  }
  function Pe(o, d) {
    if (o?.pathToItemId instanceof Map && o?.treePathByItemId instanceof Map)
      Ie = o.pathToItemId, vl = o.treePathByItemId;
    else if (o?.pathToItemId instanceof Map) {
      Ie = o.pathToItemId, vl = /* @__PURE__ */ new Map();
      for (const [x, w] of Ie)
        vl.set(w, x);
    } else {
      Ie = /* @__PURE__ */ new Map(), vl = /* @__PURE__ */ new Map();
      for (const x of d) {
        const w = x.item?.id;
        w && (Ie.set(x.path, w), vl.set(w, x.path));
      }
    }
    Ue && !Ie.has(Ue) && (Ue = "");
  }
  function Ft(o) {
    delete Ht.dataset.treeMode;
    for (const d of o) {
      const x = d.item, w = x.fileDiff ?? {}, N = d.stats ?? Ql(w), G = document.createElement("button");
      G.type = "button", G.className = "file-entry", G.dataset.itemId = x.id, G.title = oe(w), G.innerHTML = `
      <span class="file-status">${au(w)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${N.added}</span>
        <span class="stat-del">-${N.deleted}</span>
      </span>
    `;
      const K = G.querySelector(".file-name");
      K && (K.textContent = oe(w)), G.addEventListener("click", () => Wn(x.id)), Ht.append(G);
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
  function dl(o) {
    const d = o?.diffStats;
    if (d && Number.isFinite(d.addedLines) && Number.isFinite(d.deletedLines) && Number.isFinite(d.fileCount)) {
      se.textContent = `${d.fileCount}`, ae.textContent = `+${d.addedLines}`, ne.textContent = `-${d.deletedLines}`;
      return;
    }
    Xl(o?.entries ?? []);
  }
  function Xl(o) {
    const d = o.reduce((x, w) => {
      const N = w.stats ?? Ql(w.item?.fileDiff ?? {});
      return x.added += N.added, x.deleted += N.deleted, x;
    }, {
      added: 0,
      deleted: 0
    });
    se.textContent = `${o.length}`, ae.textContent = `+${d.added}`, ne.textContent = `-${d.deleted}`;
  }
  function tu(o) {
    rt.textContent = "";
    const d = document.createElement("option");
    d.value = "", d.textContent = p("jumpToFile"), rt.append(d), rt.dataset.initialized = "true";
    for (const x of o) {
      const w = document.createElement("option");
      w.value = x.id, w.textContent = oe(x.fileDiff ?? {}), rt.append(w);
    }
    rt.hidden = o.length === 0, rt.onchange = () => {
      rt.value && Wn(rt.value);
    };
  }
  function eu(o) {
    if (o.length === 0)
      return;
    rt.dataset.initialized !== "true" && tu([]);
    const d = document.createDocumentFragment();
    for (const x of o) {
      const w = document.createElement("option");
      w.value = x.id, w.textContent = oe(x.fileDiff ?? {}), d.append(w);
    }
    rt.append(d), rt.hidden = !1;
  }
  function lu(o, d) {
    if (rt.dataset.initialized === "true") {
      for (const x of rt.options)
        if (x.value === o) {
          x.value = d;
          return;
        }
    }
  }
  function Wn(o) {
    if (!j)
      return;
    const d = Pa(o);
    d && (j.scrollTo({
      type: "item",
      id: d,
      align: "start",
      behavior: "smooth-auto"
    }), Ta(d));
  }
  function Pa(o) {
    if (q.has(o))
      return o;
    const d = m.findIndex((x) => x.id === o);
    if (d === -1)
      return E[0]?.id ?? "";
    for (let x = d + 1; x < m.length; x += 1)
      if (q.has(m[x].id))
        return m[x].id;
    for (let x = d - 1; x >= 0; x -= 1)
      if (q.has(m[x].id))
        return m[x].id;
    return "";
  }
  function Ta(o) {
    if (!(!o || Qt === o)) {
      Qt = o, tl(o);
      for (const d of Ht.querySelectorAll(".file-entry"))
        d.setAttribute("aria-current", d.dataset.itemId === o ? "true" : "false");
      rt.value !== o && (rt.value = o);
    }
  }
  function tl(o) {
    if (!W)
      return;
    const d = vl.get(o);
    if (!(!d || d === Ue)) {
      Yl = !0;
      try {
        Ue && W.getItem(Ue)?.deselect(), W.getItem(d)?.select(), W.scrollToPath(d, {
          focus: !1,
          offset: "nearest"
        }), Ue = d;
      } finally {
        il(() => {
          Yl = !1;
        });
      }
    }
  }
  function oe(o) {
    return o.name ?? o.newName ?? o.oldName ?? o.prevName ?? p("untitled");
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
    return tn(o.type);
  }
  function tn(o) {
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
  function Ql(o) {
    const d = {
      added: 0,
      deleted: 0
    };
    for (const x of o.hunks ?? [])
      d.added += x.additionLines ?? 0, d.deleted += x.deletionLines ?? 0;
    return d;
  }
  function en(o, d) {
    return o?.added === d.added && o?.deleted === d.deleted;
  }
  function we(o) {
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
  function he(o, d) {
    o(d.name, () => Promise.resolve(nu(d)));
  }
  function $n(o, d, x, w) {
    const N = Array.from(new Set([o.theme?.light, o.theme?.dark].filter(Boolean))), G = Array.from(new Set(d.flatMap((K) => {
      const lt = K.fileDiff ?? {}, gt = lt.name ?? lt.newName ?? lt.oldName ?? lt.prevName ?? "", Dt = lt.lang ?? x(gt) ?? "text";
      return Dt ? [Dt] : [];
    })));
    return w({
      themes: N,
      langs: G.length > 0 ? G : ["text"]
    });
  }
  function nu(o) {
    const d = o.palette ?? {}, x = o.foreground, w = Tg(o.background, z);
    return {
      name: o.name,
      displayName: o.ghosttyName,
      type: o.type,
      colors: {
        "editor.background": w,
        "editor.foreground": x,
        "terminal.background": w,
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
          background: w
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
  const S = Ka.c(1);
  let f;
  return S[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ Z.jsx("div", { className: "diff-loading-placeholder", "aria-hidden": "true", children: _g.map(Cg) }), S[0] = f) : f = S[0], f;
}
function Cg(S, f) {
  return /* @__PURE__ */ Z.jsxs("div", { className: "grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]", children: [
    /* @__PURE__ */ Z.jsx("span", { className: "size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ Z.jsx("span", { className: "h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: S
    } }),
    /* @__PURE__ */ Z.jsx("span", { className: "h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: {
      width: f % 2 === 0 ? "34px" : "24px"
    } })
  ] }, `${S}-${f}`);
}
function Ug() {
  const S = Ka.c(2);
  let f;
  S[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ Z.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
    /* @__PURE__ */ Z.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ Z.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ Z.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
  ] }), S[0] = f) : f = S[0];
  let O;
  return S[1] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (O = /* @__PURE__ */ Z.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    f,
    /* @__PURE__ */ Z.jsx("div", { className: "space-y-[13px] px-3 py-1", children: Dg.map(Rg) })
  ] }), S[1] = O) : O = S[1], O;
}
function Rg(S, f) {
  return /* @__PURE__ */ Z.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
    /* @__PURE__ */ Z.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
    /* @__PURE__ */ Z.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: S
    } })
  ] }, `${S}-${f}`);
}
function wg(S) {
  const f = Ka.c(9), {
    config: O,
    label: s
  } = S;
  let X;
  f[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (X = /* @__PURE__ */ Z.jsx("span", { id: "status-icon", "aria-hidden": "true" }), f[0] = X) : X = f[0];
  let J;
  f[1] !== O.payload?.statusMessage || f[2] !== s ? (J = O.payload?.statusMessage ?? s("loadingDiff"), f[1] = O.payload?.statusMessage, f[2] = s, f[3] = J) : J = f[3];
  let Q;
  f[4] !== J ? (Q = /* @__PURE__ */ Z.jsxs("div", { id: "status", children: [
    X,
    /* @__PURE__ */ Z.jsx("span", { id: "status-text", children: J })
  ] }), f[4] = J, f[5] = Q) : Q = f[5];
  let et;
  f[6] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (et = /* @__PURE__ */ Z.jsx(Ug, {}), f[6] = et) : et = f[6];
  let U;
  return f[7] !== Q ? (U = /* @__PURE__ */ Z.jsxs("div", { id: "loading-layer", "aria-live": "polite", children: [
    Q,
    et
  ] }), f[7] = Q, f[8] = U) : U = f[8], U;
}
function Bg(S) {
  const f = Ka.c(17), {
    label: O
  } = S;
  let s;
  f[0] !== O ? (s = O("diffTarget"), f[0] = O, f[1] = s) : s = f[1];
  let X;
  f[2] !== s ? (X = /* @__PURE__ */ Z.jsx("select", { id: "source-select", "aria-label": s, hidden: !0 }), f[2] = s, f[3] = X) : X = f[3];
  let J;
  f[4] !== O ? (J = O("repoPath"), f[4] = O, f[5] = J) : J = f[5];
  let Q;
  f[6] !== J ? (Q = /* @__PURE__ */ Z.jsx("select", { id: "repo-select", "aria-label": J, hidden: !0 }), f[6] = J, f[7] = Q) : Q = f[7];
  let et;
  f[8] !== O ? (et = O("branchBase"), f[8] = O, f[9] = et) : et = f[9];
  let U;
  f[10] !== et ? (U = /* @__PURE__ */ Z.jsx("select", { id: "base-select", "aria-label": et, hidden: !0 }), f[10] = et, f[11] = U) : U = f[11];
  let z;
  f[12] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (z = /* @__PURE__ */ Z.jsx("span", { id: "source-detail" }), f[12] = z) : z = f[12];
  let L;
  return f[13] !== X || f[14] !== Q || f[15] !== U ? (L = /* @__PURE__ */ Z.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    X,
    Q,
    U,
    z
  ] }), f[13] = X, f[14] = Q, f[15] = U, f[16] = L) : L = f[16], L;
}
function Ng(S) {
  const f = Ka.c(50), {
    config: O,
    label: s
  } = S;
  let X;
  f[0] !== O || f[1] !== s ? (X = /* @__PURE__ */ Z.jsx(Bg, { config: O, label: s }), f[0] = O, f[1] = s, f[2] = X) : X = f[2];
  let J;
  f[3] !== s ? (J = s("jumpToFile"), f[3] = s, f[4] = J) : J = f[4];
  let Q;
  f[5] !== J ? (Q = /* @__PURE__ */ Z.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ Z.jsx("select", { id: "jump-select", "aria-label": J, hidden: !0 }) }), f[5] = J, f[6] = Q) : Q = f[6];
  const et = O.payload?.externalURL ?? "#";
  let U;
  f[7] !== s ? (U = s("openSourceURL"), f[7] = s, f[8] = U) : U = f[8];
  let z;
  f[9] !== s ? (z = s("openSourceURL"), f[9] = s, f[10] = z) : z = f[10];
  let L;
  f[11] !== et || f[12] !== U || f[13] !== z ? (L = /* @__PURE__ */ Z.jsx("a", { id: "external-link", className: "toolbar-icon", href: et, target: "_blank", rel: "noreferrer", title: U, "aria-label": z, hidden: !0 }), f[11] = et, f[12] = U, f[13] = z, f[14] = L) : L = f[14];
  let H;
  f[15] !== s ? (H = s("hideFiles"), f[15] = s, f[16] = H) : H = f[16];
  let P;
  f[17] !== s ? (P = s("hideFiles"), f[17] = s, f[18] = P) : P = f[18];
  let mt;
  f[19] !== H || f[20] !== P ? (mt = /* @__PURE__ */ Z.jsx("button", { id: "files-toggle", className: "toolbar-icon", type: "button", title: H, "aria-label": P, "aria-pressed": "true" }), f[19] = H, f[20] = P, f[21] = mt) : mt = f[21];
  let nt;
  f[22] !== s ? (nt = s("switchToUnifiedDiff"), f[22] = s, f[23] = nt) : nt = f[23];
  let ht;
  f[24] !== s ? (ht = s("switchToUnifiedDiff"), f[24] = s, f[25] = ht) : ht = f[25];
  let qt;
  f[26] !== nt || f[27] !== ht ? (qt = /* @__PURE__ */ Z.jsx("button", { id: "layout-toggle", className: "toolbar-icon", type: "button", title: nt, "aria-label": ht }), f[26] = nt, f[27] = ht, f[28] = qt) : qt = f[28];
  let Ct;
  f[29] !== s ? (Ct = s("options"), f[29] = s, f[30] = Ct) : Ct = f[30];
  let rt;
  f[31] !== s ? (rt = s("options"), f[31] = s, f[32] = rt) : rt = f[32];
  let xt;
  f[33] !== Ct || f[34] !== rt ? (xt = /* @__PURE__ */ Z.jsx("button", { id: "options-button", className: "toolbar-icon", type: "button", title: Ct, "aria-label": rt, "aria-expanded": "false", "aria-haspopup": "menu" }), f[33] = Ct, f[34] = rt, f[35] = xt) : xt = f[35];
  let At;
  f[36] !== mt || f[37] !== qt || f[38] !== xt || f[39] !== L ? (At = /* @__PURE__ */ Z.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
    L,
    mt,
    qt,
    xt
  ] }), f[36] = mt, f[37] = qt, f[38] = xt, f[39] = L, f[40] = At) : At = f[40];
  let _t;
  f[41] !== s ? (_t = s("options"), f[41] = s, f[42] = _t) : _t = f[42];
  let St;
  f[43] !== _t ? (St = /* @__PURE__ */ Z.jsx("div", { id: "options-menu", role: "menu", "aria-label": _t, hidden: !0 }), f[43] = _t, f[44] = St) : St = f[44];
  let k;
  return f[45] !== X || f[46] !== At || f[47] !== St || f[48] !== Q ? (k = /* @__PURE__ */ Z.jsxs("header", { id: "toolbar", children: [
    X,
    Q,
    At,
    St
  ] }), f[45] = X, f[46] = At, f[47] = St, f[48] = Q, f[49] = k) : k = f[49], k;
}
function Hg(S) {
  const f = Ka.c(62), {
    label: O
  } = S;
  let s;
  f[0] !== O ? (s = O("changedFiles"), f[0] = O, f[1] = s) : s = f[1];
  let X;
  f[2] !== O ? (X = O("files"), f[2] = O, f[3] = X) : X = f[3];
  let J;
  f[4] !== X ? (J = /* @__PURE__ */ Z.jsx("span", { children: X }), f[4] = X, f[5] = J) : J = f[5];
  let Q;
  f[6] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Q = /* @__PURE__ */ Z.jsx("span", { id: "files-count" }), f[6] = Q) : Q = f[6];
  let et;
  f[7] !== J ? (et = /* @__PURE__ */ Z.jsxs("span", { id: "files-title", children: [
    J,
    Q
  ] }), f[7] = J, f[8] = et) : et = f[8];
  let U;
  f[9] !== O ? (U = O("showFileSearch"), f[9] = O, f[10] = U) : U = f[10];
  let z;
  f[11] !== O ? (z = O("showFileSearch"), f[11] = O, f[12] = z) : z = f[12];
  let L;
  f[13] !== U || f[14] !== z ? (L = /* @__PURE__ */ Z.jsx("button", { id: "file-search-toggle", type: "button", title: U, "aria-label": z, "aria-pressed": "false" }), f[13] = U, f[14] = z, f[15] = L) : L = f[15];
  let H;
  f[16] !== O ? (H = O("hideFiles"), f[16] = O, f[17] = H) : H = f[17];
  let P;
  f[18] !== O ? (P = O("hideFiles"), f[18] = O, f[19] = P) : P = f[19];
  let mt;
  f[20] !== P || f[21] !== H ? (mt = /* @__PURE__ */ Z.jsx("button", { id: "file-collapse-toggle", type: "button", title: H, "aria-label": P }), f[20] = P, f[21] = H, f[22] = mt) : mt = f[22];
  let nt;
  f[23] !== mt || f[24] !== L ? (nt = /* @__PURE__ */ Z.jsxs("span", { id: "files-header-actions", children: [
    L,
    mt
  ] }), f[23] = mt, f[24] = L, f[25] = nt) : nt = f[25];
  let ht;
  f[26] !== nt || f[27] !== et ? (ht = /* @__PURE__ */ Z.jsxs("div", { id: "files-header", children: [
    et,
    nt
  ] }), f[26] = nt, f[27] = et, f[28] = ht) : ht = f[28];
  let qt;
  f[29] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (qt = /* @__PURE__ */ Z.jsx("div", { id: "file-list", children: /* @__PURE__ */ Z.jsx(Og, {}) }), f[29] = qt) : qt = f[29];
  let Ct;
  f[30] !== O ? (Ct = O("diffStats"), f[30] = O, f[31] = Ct) : Ct = f[31];
  let rt;
  f[32] !== O ? (rt = O("files"), f[32] = O, f[33] = rt) : rt = f[33];
  let xt;
  f[34] !== rt ? (xt = /* @__PURE__ */ Z.jsx("span", { children: rt }), f[34] = rt, f[35] = xt) : xt = f[35];
  let At;
  f[36] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (At = /* @__PURE__ */ Z.jsx("strong", { id: "stats-files", children: "0" }), f[36] = At) : At = f[36];
  let _t;
  f[37] !== xt ? (_t = /* @__PURE__ */ Z.jsxs("div", { className: "stats-row", children: [
    xt,
    At
  ] }), f[37] = xt, f[38] = _t) : _t = f[38];
  let St;
  f[39] !== O ? (St = O("additions"), f[39] = O, f[40] = St) : St = f[40];
  let k;
  f[41] !== St ? (k = /* @__PURE__ */ Z.jsx("span", { children: St }), f[41] = St, f[42] = k) : k = f[42];
  let Zt;
  f[43] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Zt = /* @__PURE__ */ Z.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" }), f[43] = Zt) : Zt = f[43];
  let Ht;
  f[44] !== k ? (Ht = /* @__PURE__ */ Z.jsxs("div", { className: "stats-row", children: [
    k,
    Zt
  ] }), f[44] = k, f[45] = Ht) : Ht = f[45];
  let be;
  f[46] !== O ? (be = O("deletions"), f[46] = O, f[47] = be) : be = f[47];
  let Gt;
  f[48] !== be ? (Gt = /* @__PURE__ */ Z.jsx("span", { children: be }), f[48] = be, f[49] = Gt) : Gt = f[49];
  let Yt;
  f[50] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Yt = /* @__PURE__ */ Z.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" }), f[50] = Yt) : Yt = f[50];
  let se;
  f[51] !== Gt ? (se = /* @__PURE__ */ Z.jsxs("div", { className: "stats-row", children: [
    Gt,
    Yt
  ] }), f[51] = Gt, f[52] = se) : se = f[52];
  let ae;
  f[53] !== Ct || f[54] !== _t || f[55] !== Ht || f[56] !== se ? (ae = /* @__PURE__ */ Z.jsxs("div", { id: "files-footer", "aria-label": Ct, children: [
    _t,
    Ht,
    se
  ] }), f[53] = Ct, f[54] = _t, f[55] = Ht, f[56] = se, f[57] = ae) : ae = f[57];
  let ne;
  return f[58] !== s || f[59] !== ht || f[60] !== ae ? (ne = /* @__PURE__ */ Z.jsxs("aside", { id: "files-sidebar", "aria-label": s, children: [
    ht,
    qt,
    ae
  ] }), f[58] = s, f[59] = ht, f[60] = ae, f[61] = ne) : ne = f[61], ne;
}
function jg(S) {
  const f = Ka.c(25), {
    config: O
  } = S, s = vg.useRef(!1), X = O.payload?.labels;
  let J;
  f[0] !== X ? (J = sm(X, {
    assertMissing: rm()
  }), f[0] = X, f[1] = J) : J = f[1];
  const Q = J;
  let et;
  f[2] !== O ? (et = (qt) => {
    !qt || s.current || (s.current = !0, Ag(O));
  }, f[2] = O, f[3] = et) : et = f[3];
  const U = et;
  let z;
  f[4] !== O || f[5] !== Q ? (z = /* @__PURE__ */ Z.jsx(Ng, { config: O, label: Q }), f[4] = O, f[5] = Q, f[6] = z) : z = f[6];
  let L;
  f[7] !== O || f[8] !== Q ? (L = /* @__PURE__ */ Z.jsx(Hg, { config: O, label: Q }), f[7] = O, f[8] = Q, f[9] = L) : L = f[9];
  let H;
  f[10] !== Q ? (H = Q("diffViewer"), f[10] = Q, f[11] = H) : H = f[11];
  let P;
  f[12] !== O || f[13] !== Q ? (P = /* @__PURE__ */ Z.jsx(wg, { config: O, label: Q }), f[12] = O, f[13] = Q, f[14] = P) : P = f[14];
  let mt;
  f[15] !== H || f[16] !== P ? (mt = /* @__PURE__ */ Z.jsx("main", { id: "viewer", "aria-label": H, children: P }), f[15] = H, f[16] = P, f[17] = mt) : mt = f[17];
  let nt;
  f[18] !== L || f[19] !== mt ? (nt = /* @__PURE__ */ Z.jsxs("section", { id: "content", children: [
    L,
    mt
  ] }), f[18] = L, f[19] = mt, f[20] = nt) : nt = f[20];
  let ht;
  return f[21] !== U || f[22] !== z || f[23] !== nt ? (ht = /* @__PURE__ */ Z.jsxs("div", { id: "app", ref: U, children: [
    z,
    nt
  ] }), f[21] = U, f[22] = z, f[23] = nt, f[24] = ht) : ht = f[24], ht;
}
const qg = `@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-space-y-reverse:0;--tw-border-style:solid}}}@layer theme{:root,:host{--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--spacing:.25rem;--radius-md:.375rem;--default-font-family:var(--font-sans);--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab,red,red)){::placeholder{color:color-mix(in oklab,currentcolor 50%,transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}}@layer components;@layer utilities{.\\@container{container-type:inline-size}.collapse{visibility:collapse}.visible{visibility:visible}.fixed{position:fixed}.static{position:static}.mx-3\\.5{margin-inline:calc(var(--spacing) * 3.5)}.mt-3\\.5{margin-top:calc(var(--spacing) * 3.5)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.flex{display:flex}.grid{display:grid}.hidden{display:none}.size-4{width:calc(var(--spacing) * 4);height:calc(var(--spacing) * 4)}.h-3{height:calc(var(--spacing) * 3)}.h-6{height:calc(var(--spacing) * 6)}.h-9{height:calc(var(--spacing) * 9)}.h-\\[11px\\]{height:11px}.h-px{height:1px}.w-2\\/5{width:40%}.min-w-0{min-width:calc(var(--spacing) * 0)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.grid-cols-\\[16px_minmax\\(0\\,1fr\\)_44px\\]{grid-template-columns:16px minmax(0,1fr) 44px}.grid-cols-\\[42px_minmax\\(0\\,1fr\\)\\]{grid-template-columns:42px minmax(0,1fr)}.grid-cols-\\[72px_minmax\\(0\\,1fr\\)_96px\\]{grid-template-columns:72px minmax(0,1fr) 96px}.items-center{align-items:center}.justify-center{justify-content:center}.gap-1\\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}:where(.space-y-\\[13px\\]>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(13px * var(--tw-space-y-reverse));margin-block-end:calc(13px * calc(1 - var(--tw-space-y-reverse)))}.justify-self-end{justify-self:flex-end}.rounded{border-radius:.25rem}.rounded-\\[5px\\]{border-radius:5px}.rounded-md{border-radius:var(--radius-md)}.border{border-style:var(--tw-border-style);border-width:1px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:color-mix(in lab,var(--cmux-diff-fg) 18%,transparent)}}.border-\\[var\\(--cmux-diff-border\\)\\]{border-color:var(--cmux-diff-border)}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.bg-\\[var\\(--cmux-diff-muted-bg\\)\\]{background-color:var(--cmux-diff-muted-bg)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-\\[7px\\]{padding-inline:7px}.py-1{padding-block:calc(var(--spacing) * 1)}.pt-3{padding-top:calc(var(--spacing) * 3)}.italic{font-style:italic}.opacity-70{opacity:.7}}:root{color-scheme:light dark;--cmux-diff-bg-light:#fff;--cmux-diff-bg-dark:#000;--cmux-diff-fg-light:#000;--cmux-diff-fg-dark:#fff;--cmux-diff-selection-bg-light:#abd8ff;--cmux-diff-selection-bg-dark:#3f638b;--cmux-diff-ui-font-family:system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size:12px;--cmux-diff-ui-line-height:16px;--cmux-diff-code-font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size:10px;--cmux-diff-line-height:20px;--cmux-diff-bg:var(--cmux-diff-bg-light);--cmux-diff-fg:var(--cmux-diff-fg-light);--cmux-diff-border:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-border:color-mix(in lab, var(--cmux-diff-fg) 12%, transparent)}}:root{--cmux-diff-sidebar-bg:transparent;--cmux-diff-muted-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-muted-bg:color-mix(in lab, var(--cmux-diff-fg) 8%, transparent)}}:root{--cmux-diff-hover-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-hover-bg:color-mix(in lab, var(--cmux-diff-fg) 10%, transparent)}}:root{--cmux-diff-accent:light-dark(#0a84ff,#7ab7ff);color:var(--cmux-diff-fg);background:0 0}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg:var(--cmux-diff-bg-dark);--cmux-diff-fg:var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{background:0 0;height:100%;overflow:hidden}body{height:100vh;min-height:0;color:var(--cmux-diff-fg);font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height);background:0 0;flex-direction:column;margin:0;display:flex;overflow:hidden}#root{background:0 0;height:100%;min-height:0}#app{overscroll-behavior:contain;contain:strict;height:100vh;min-height:0;color:inherit;background:0 0;grid-template-rows:auto minmax(0,1fr);grid-template-columns:minmax(0,1fr);display:grid;overflow:hidden}#toolbar{border-bottom:1px solid var(--cmux-diff-fg);flex:none;align-items:center;gap:7px;min-height:32px;padding:3px 8px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#toolbar{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}#toolbar{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#toolbar{color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg))}}#toolbar{z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{align-items:center;gap:6px;min-width:0;display:flex}.toolbar-left{flex:0 36%}.toolbar-middle{flex:auto;justify-content:center}.toolbar-actions{flex:none}#source-select,#repo-select,#base-select,#jump-select{appearance:none;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,var(--cmux-diff-fg);border:1px solid #0000;border-radius:6px;min-width:118px;max-width:min(30vw,320px);height:24px;padding:0 24px 0 9px}@supports (color:color-mix(in lab,red,red)){#source-select,#repo-select,#base-select,#jump-select{background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent)}}#source-select,#repo-select,#base-select,#jump-select{color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent)}}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent)}}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline-offset:1px}#source-detail{text-overflow:ellipsis;white-space:nowrap;min-width:0;color:var(--cmux-diff-fg);overflow:hidden}@supports (color:color-mix(in lab,red,red)){#source-detail{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}.toolbar-icon{width:28px;height:26px;color:var(--cmux-diff-fg);background:0 0;border:1px solid #0000;border-radius:6px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.toolbar-icon{color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg))}}.toolbar-icon{cursor:pointer;padding:0}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true],.toolbar-icon[aria-pressed=true]{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:16px;height:16px;display:block}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{border:1px solid var(--cmux-diff-fg);min-width:246px;padding:8px;position:absolute;top:calc(100% + 7px);right:10px}@supports (color:color-mix(in lab,red,red)){#options-menu{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent)}}#options-menu{background:var(--cmux-diff-bg);z-index:100;border-radius:8px;box-shadow:0 16px 34px lab(0% none none/.28)}#options-menu[hidden]{display:none}.menu-separator{background:var(--cmux-diff-fg);height:1px;margin:7px 6px}@supports (color:color-mix(in lab,red,red)){.menu-separator{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.menu-item{width:100%;min-height:31px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:6px;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;display:grid}@supports (color:color-mix(in lab,red,red)){.menu-item{color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg))}}.menu-item{font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.menu-item:hover:not(:disabled){color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:0 0}.menu-segment-controls{background:0 0;border-radius:7px;justify-self:end;align-items:center;gap:2px;padding:2px;display:inline-flex}.segment-button{width:27px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.segment-button{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.segment-button{padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.segment-button:hover,.segment-button[aria-pressed=true],.menu-item:disabled{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}}.menu-label{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.menu-check{justify-self:end}#content{--cmux-diff-files-width:clamp(190px, 22vw, 252px);grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);overscroll-behavior:contain;contain:strict;background:0 0;flex:auto;grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";min-width:0;min-height:0;display:grid;position:relative;overflow:hidden}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{border-left:1px solid var(--cmux-diff-border);contain:strict;opacity:1;background:0 0;flex-direction:column;grid-area:files;width:100%;min-width:0;height:100%;min-height:0;transition:opacity .1s,visibility linear;display:flex;position:relative;overflow:hidden}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s,visibility 0s linear .1s}body[data-status-only=true] #files-sidebar{display:none}#files-header{z-index:1;border-bottom:1px solid var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:8px;min-height:30px;padding:0 7px 0 10px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#files-header{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-header{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#files-header{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}#files-title{align-items:center;gap:6px;min-width:0;display:inline-flex}#files-header-actions{flex:none;align-items:center;gap:2px;display:inline-flex}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;flex:none;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){#file-search-toggle,#file-collapse-toggle{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}#file-search-toggle,#file-collapse-toggle{padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:15px;height:15px}#file-list{--trees-bg-override:var(--cmux-diff-sidebar-bg);--trees-fg-override:var(--cmux-diff-fg);flex:auto;min-height:0;padding:6px 4px 6px 6px;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-override:color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg))}}#file-list{--trees-fg-muted-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-muted-override:color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg))}}#file-list{--trees-bg-muted-override:var(--cmux-diff-hover-bg);--trees-selected-bg-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-selected-bg-override:color-mix(in lab, var(--cmux-diff-fg) 11%, transparent)}}#file-list{--trees-selected-fg-override:var(--cmux-diff-fg);--trees-selected-focused-border-color-override:transparent;--trees-border-color-override:var(--cmux-diff-border);--trees-focus-ring-color-override:var(--cmux-diff-accent)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-focus-ring-color-override:color-mix(in lab, var(--cmux-diff-accent) 72%, transparent)}}#file-list{--trees-font-family-override:var(--cmux-diff-ui-font-family);--trees-font-size-override:var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override:500;--trees-density-override:.78;--trees-border-radius-override:5px;--trees-item-padding-x-override:7px;--trees-item-margin-x-override:0;--trees-padding-inline-override:0;--trees-search-bg-override:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-search-bg-override:color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))}}#file-list{--trees-status-added-override:light-dark(#257a3e,#8fd88f);--trees-status-modified-override:var(--cmux-diff-accent);--trees-status-renamed-override:light-dark(#a26300,#ffd166);--trees-status-deleted-override:light-dark(#b42318,#ff8a80)}body[data-loading=false] .diff-loading-placeholder,body[data-loading=false]:not([data-status-only=true]) #loading-layer{display:none}#file-list file-tree-container{width:100%;height:100%}#files-footer{border-top:1px solid var(--cmux-diff-fg);flex:none;padding:7px 10px 8px}@supports (color:color-mix(in lab,red,red)){#files-footer{border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-footer{background:0 0}.stats-row{min-height:19px;color:var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:10px;display:flex}@supports (color:color-mix(in lab,red,red)){.stats-row{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}.stats-row strong{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg))}}.stats-row strong{font-weight:600}.file-entry{width:100%;min-height:30px;color:inherit;font:inherit;text-align:left;background:0 0;border:0;border-radius:6px;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;padding:3px 7px;display:grid}.file-entry:hover,.file-entry[aria-current=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.file-status{width:17px;height:17px;color:var(--cmux-diff-fg);border:1px solid;border-radius:5px;justify-content:center;align-items:center;font-size:9px;line-height:1;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-status{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.file-name{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.file-stats{color:var(--cmux-diff-fg);gap:5px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-stats{color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));overscroll-behavior:contain;overflow-anchor:none;contain:strict;border-bottom:1px solid var(--cmux-diff-border);background:0 0;grid-area:viewer;width:100%;min-width:0;height:100%;min-height:0;position:relative;overflow:clip auto}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border);display:block;overflow:clip}#loading-layer{z-index:4;pointer-events:none;contain:strict;background:0 0;position:absolute;inset:0;overflow:hidden}body[data-status-only=true] #loading-layer{pointer-events:auto;justify-content:center;align-items:center;width:100%;height:100%;padding:32px;display:flex;position:static}#status{z-index:5;border:1px solid var(--cmux-diff-fg);align-items:center;gap:10px;max-width:calc(100% - 24px);min-height:32px;padding:8px 12px;display:flex;position:absolute;top:10px;left:12px}@supports (color:color-mix(in lab,red,red)){#status{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#status{background:var(--cmux-diff-bg);font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:var(--cmux-diff-fg);border-radius:7px}@supports (color:color-mix(in lab,red,red)){#status{color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}body[data-status-only=true] #status{text-align:center;text-wrap:balance;width:auto;max-width:340px;min-height:0;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:0;flex-direction:column;justify-content:center;align-items:center;gap:14px;padding:0;font-size:14px;line-height:1.55;position:static}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status{color:color-mix(in lab,var(--cmux-diff-fg) 58%,var(--cmux-diff-bg))}}body[data-status-only=true] #status-text{letter-spacing:.005em;font-weight:500}#status-icon{display:none}body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{background:var(--cmux-diff-fg);border-radius:16px;justify-content:center;align-items:center;width:56px;height:56px;display:flex}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{background:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{border:1px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 8%,transparent)}}body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon:before{content:"";opacity:.8;background-color:currentColor;width:26px;height:26px;display:block;-webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23000' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z'/%3E%3Cpath d='M14 2v6h6'/%3E%3Cpath d='M9 13h6'/%3E%3Cpath d='M9 17h4'/%3E%3C/svg%3E") 50%/contain no-repeat;mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23000' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z'/%3E%3Cpath d='M14 2v6h6'/%3E%3Cpath d='M9 13h6'/%3E%3Cpath d='M9 17h4'/%3E%3C/svg%3E") 50%/contain no-repeat}#status[data-pending=true]:before,body[data-loading=true] #status:before{content:"";border:2px solid var(--cmux-diff-fg);flex:none;width:14px;height:14px}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent)}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-radius:50%;animation:.8s linear infinite cmuxDiffPendingSpin}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before,body[data-loading=true] #status:before{animation:none}}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}`;
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
gg.createRoot(gm).render(/* @__PURE__ */ Z.jsx(jg, { config: Gl }));
