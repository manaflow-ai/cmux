var po = { exports: {} }, qi = {};
var Fd;
function Wh() {
  if (Fd) return qi;
  Fd = 1;
  var A = /* @__PURE__ */ Symbol.for("react.transitional.element"), K = /* @__PURE__ */ Symbol.for("react.fragment");
  function rt(b, Bt, qt) {
    var kt = null;
    if (qt !== void 0 && (kt = "" + qt), Bt.key !== void 0 && (kt = "" + Bt.key), "key" in Bt) {
      qt = {};
      for (var Pt in Bt)
        Pt !== "key" && (qt[Pt] = Bt[Pt]);
    } else qt = Bt;
    return Bt = qt.ref, {
      $$typeof: A,
      type: b,
      key: kt,
      ref: Bt !== void 0 ? Bt : null,
      props: qt
    };
  }
  return qi.Fragment = K, qi.jsx = rt, qi.jsxs = rt, qi;
}
var Wd;
function $h() {
  return Wd || (Wd = 1, po.exports = Wh()), po.exports;
}
var L = $h(), vo = { exports: {} }, Yi = {}, yo = { exports: {} }, bo = {};
var $d;
function Ih() {
  return $d || ($d = 1, (function(A) {
    function K(m, D) {
      var Y = m.length;
      m.push(D);
      t: for (; 0 < Y; ) {
        var V = Y - 1 >>> 1, k = m[V];
        if (0 < Bt(k, D))
          m[V] = D, m[Y] = k, Y = V;
        else break t;
      }
    }
    function rt(m) {
      return m.length === 0 ? null : m[0];
    }
    function b(m) {
      if (m.length === 0) return null;
      var D = m[0], Y = m.pop();
      if (Y !== D) {
        m[0] = Y;
        t: for (var V = 0, k = m.length, s = k >>> 1; V < s; ) {
          var M = 2 * (V + 1) - 1, B = m[M], H = M + 1, F = m[H];
          if (0 > Bt(B, Y))
            H < k && 0 > Bt(F, B) ? (m[V] = F, m[H] = Y, V = H) : (m[V] = B, m[M] = Y, V = M);
          else if (H < k && 0 > Bt(F, Y))
            m[V] = F, m[H] = Y, V = H;
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
      var qt = performance;
      A.unstable_now = function() {
        return qt.now();
      };
    } else {
      var kt = Date, Pt = kt.now();
      A.unstable_now = function() {
        return kt.now() - Pt;
      };
    }
    var U = [], _ = [], lt = 1, X = null, Et = 3, Xt = !1, fe = !1, te = !1, Ye = !1, vt = typeof setTimeout == "function" ? setTimeout : null, Ge = typeof clearTimeout == "function" ? clearTimeout : null, Nt = typeof setImmediate < "u" ? setImmediate : null;
    function Ft(m) {
      for (var D = rt(_); D !== null; ) {
        if (D.callback === null) b(_);
        else if (D.startTime <= m)
          b(_), D.sortIndex = D.expirationTime, K(U, D);
        else break;
        D = rt(_);
      }
    }
    function ce(m) {
      if (te = !1, Ft(m), !fe)
        if (rt(U) !== null)
          fe = !0, Rt || (Rt = !0, ee());
        else {
          var D = rt(_);
          D !== null && G(ce, D.startTime - m);
        }
    }
    var Rt = !1, et = -1, Ct = 5, De = -1;
    function Se() {
      return Ye ? !0 : !(A.unstable_now() - De < Ct);
    }
    function oe() {
      if (Ye = !1, Rt) {
        var m = A.unstable_now();
        De = m;
        var D = !0;
        try {
          t: {
            fe = !1, te && (te = !1, Ge(et), et = -1), Xt = !0;
            var Y = Et;
            try {
              e: {
                for (Ft(m), X = rt(U); X !== null && !(X.expirationTime > m && Se()); ) {
                  var V = X.callback;
                  if (typeof V == "function") {
                    X.callback = null, Et = X.priorityLevel;
                    var k = V(
                      X.expirationTime <= m
                    );
                    if (m = A.unstable_now(), typeof k == "function") {
                      X.callback = k, Ft(m), D = !0;
                      break e;
                    }
                    X === rt(U) && b(U), Ft(m);
                  } else b(U);
                  X = rt(U);
                }
                if (X !== null) D = !0;
                else {
                  var s = rt(_);
                  s !== null && G(
                    ce,
                    s.startTime - m
                  ), D = !1;
                }
              }
              break t;
            } finally {
              X = null, Et = Y, Xt = !1;
            }
            D = void 0;
          }
        } finally {
          D ? ee() : Rt = !1;
        }
      }
    }
    var ee;
    if (typeof Nt == "function")
      ee = function() {
        Nt(oe);
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
      ) : Ct = 0 < m ? Math.floor(1e3 / m) : 5;
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
      var V = A.unstable_now();
      switch (typeof Y == "object" && Y !== null ? (Y = Y.delay, Y = typeof Y == "number" && 0 < Y ? V + Y : V) : Y = V, m) {
        case 1:
          var k = -1;
          break;
        case 2:
          k = 250;
          break;
        case 5:
          k = 1073741823;
          break;
        case 4:
          k = 1e4;
          break;
        default:
          k = 5e3;
      }
      return k = Y + k, m = {
        id: lt++,
        callback: D,
        priorityLevel: m,
        startTime: Y,
        expirationTime: k,
        sortIndex: -1
      }, Y > V ? (m.sortIndex = Y, K(_, m), rt(U) === null && m === rt(_) && (te ? (Ge(et), et = -1) : te = !0, G(ce, Y - V))) : (m.sortIndex = k, K(U, m), fe || Xt || (fe = !0, Rt || (Rt = !0, ee()))), m;
    }, A.unstable_shouldYield = Se, A.unstable_wrapCallback = function(m) {
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
  return Id || (Id = 1, yo.exports = Ih()), yo.exports;
}
var xo = { exports: {} }, W = {};
var Pd;
function tg() {
  if (Pd) return W;
  Pd = 1;
  var A = /* @__PURE__ */ Symbol.for("react.transitional.element"), K = /* @__PURE__ */ Symbol.for("react.portal"), rt = /* @__PURE__ */ Symbol.for("react.fragment"), b = /* @__PURE__ */ Symbol.for("react.strict_mode"), Bt = /* @__PURE__ */ Symbol.for("react.profiler"), qt = /* @__PURE__ */ Symbol.for("react.consumer"), kt = /* @__PURE__ */ Symbol.for("react.context"), Pt = /* @__PURE__ */ Symbol.for("react.forward_ref"), U = /* @__PURE__ */ Symbol.for("react.suspense"), _ = /* @__PURE__ */ Symbol.for("react.memo"), lt = /* @__PURE__ */ Symbol.for("react.lazy"), X = /* @__PURE__ */ Symbol.for("react.activity"), Et = Symbol.iterator;
  function Xt(s) {
    return s === null || typeof s != "object" ? null : (s = Et && s[Et] || s["@@iterator"], typeof s == "function" ? s : null);
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
  function vt(s, M, B) {
    this.props = s, this.context = M, this.refs = Ye, this.updater = B || fe;
  }
  vt.prototype.isReactComponent = {}, vt.prototype.setState = function(s, M) {
    if (typeof s != "object" && typeof s != "function" && s != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, s, M, "setState");
  }, vt.prototype.forceUpdate = function(s) {
    this.updater.enqueueForceUpdate(this, s, "forceUpdate");
  };
  function Ge() {
  }
  Ge.prototype = vt.prototype;
  function Nt(s, M, B) {
    this.props = s, this.context = M, this.refs = Ye, this.updater = B || fe;
  }
  var Ft = Nt.prototype = new Ge();
  Ft.constructor = Nt, te(Ft, vt.prototype), Ft.isPureReactComponent = !0;
  var ce = Array.isArray;
  function Rt() {
  }
  var et = { H: null, A: null, T: null, S: null }, Ct = Object.prototype.hasOwnProperty;
  function De(s, M, B) {
    var H = B.ref;
    return {
      $$typeof: A,
      type: s,
      key: M,
      ref: H !== void 0 ? H : null,
      props: B
    };
  }
  function Se(s, M) {
    return De(s.type, M, s.props);
  }
  function oe(s) {
    return typeof s == "object" && s !== null && s.$$typeof === A;
  }
  function ee(s) {
    var M = { "=": "=0", ":": "=2" };
    return "$" + s.replace(/[=:]/g, function(B) {
      return M[B];
    });
  }
  var al = /\/+/g;
  function Le(s, M) {
    return typeof s == "object" && s !== null && s.key != null ? ee("" + s.key) : M.toString(36);
  }
  function G(s) {
    switch (s.status) {
      case "fulfilled":
        return s.value;
      case "rejected":
        throw s.reason;
      default:
        switch (typeof s.status == "string" ? s.then(Rt, Rt) : (s.status = "pending", s.then(
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
  function m(s, M, B, H, F) {
    var $ = typeof s;
    ($ === "undefined" || $ === "boolean") && (s = null);
    var ct = !1;
    if (s === null) ct = !0;
    else
      switch ($) {
        case "bigint":
        case "string":
        case "number":
          ct = !0;
          break;
        case "object":
          switch (s.$$typeof) {
            case A:
            case K:
              ct = !0;
              break;
            case lt:
              return ct = s._init, m(
                ct(s._payload),
                M,
                B,
                H,
                F
              );
          }
      }
    if (ct)
      return F = F(s), ct = H === "" ? "." + Le(s, 0) : H, ce(F) ? (B = "", ct != null && (B = ct.replace(al, "$&/") + "/"), m(F, M, B, "", function(gl) {
        return gl;
      })) : F != null && (oe(F) && (F = Se(
        F,
        B + (F.key == null || s && s.key === F.key ? "" : ("" + F.key).replace(
          al,
          "$&/"
        ) + "/") + ct
      )), M.push(F)), 1;
    ct = 0;
    var $t = H === "" ? "." : H + ":";
    if (ce(s))
      for (var yt = 0; yt < s.length; yt++)
        H = s[yt], $ = $t + Le(H, yt), ct += m(
          H,
          M,
          B,
          $,
          F
        );
    else if (yt = Xt(s), typeof yt == "function")
      for (s = yt.call(s), yt = 0; !(H = s.next()).done; )
        H = H.value, $ = $t + Le(H, yt++), ct += m(
          H,
          M,
          B,
          $,
          F
        );
    else if ($ === "object") {
      if (typeof s.then == "function")
        return m(
          G(s),
          M,
          B,
          H,
          F
        );
      throw M = String(s), Error(
        "Objects are not valid as a React child (found: " + (M === "[object Object]" ? "object with keys {" + Object.keys(s).join(", ") + "}" : M) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return ct;
  }
  function D(s, M, B) {
    if (s == null) return s;
    var H = [], F = 0;
    return m(s, H, "", "", function($) {
      return M.call(B, $, F++);
    }), H;
  }
  function Y(s) {
    if (s._status === -1) {
      var M = s._result;
      M = M(), M.then(
        function(B) {
          (s._status === 0 || s._status === -1) && (s._status = 1, s._result = B);
        },
        function(B) {
          (s._status === 0 || s._status === -1) && (s._status = 2, s._result = B);
        }
      ), s._status === -1 && (s._status = 0, s._result = M);
    }
    if (s._status === 1) return s._result.default;
    throw s._result;
  }
  var V = typeof reportError == "function" ? reportError : function(s) {
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
  }, k = {
    map: D,
    forEach: function(s, M, B) {
      D(
        s,
        function() {
          M.apply(this, arguments);
        },
        B
      );
    },
    count: function(s) {
      var M = 0;
      return D(s, function() {
        M++;
      }), M;
    },
    toArray: function(s) {
      return D(s, function(M) {
        return M;
      }) || [];
    },
    only: function(s) {
      if (!oe(s))
        throw Error(
          "React.Children.only expected to receive a single React element child."
        );
      return s;
    }
  };
  return W.Activity = X, W.Children = k, W.Component = vt, W.Fragment = rt, W.Profiler = Bt, W.PureComponent = Nt, W.StrictMode = b, W.Suspense = U, W.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = et, W.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(s) {
      return et.H.useMemoCache(s);
    }
  }, W.cache = function(s) {
    return function() {
      return s.apply(null, arguments);
    };
  }, W.cacheSignal = function() {
    return null;
  }, W.cloneElement = function(s, M, B) {
    if (s == null)
      throw Error(
        "The argument must be a React element, but you passed " + s + "."
      );
    var H = te({}, s.props), F = s.key;
    if (M != null)
      for ($ in M.key !== void 0 && (F = "" + M.key), M)
        !Ct.call(M, $) || $ === "key" || $ === "__self" || $ === "__source" || $ === "ref" && M.ref === void 0 || (H[$] = M[$]);
    var $ = arguments.length - 2;
    if ($ === 1) H.children = B;
    else if (1 < $) {
      for (var ct = Array($), $t = 0; $t < $; $t++)
        ct[$t] = arguments[$t + 2];
      H.children = ct;
    }
    return De(s.type, F, H);
  }, W.createContext = function(s) {
    return s = {
      $$typeof: kt,
      _currentValue: s,
      _currentValue2: s,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, s.Provider = s, s.Consumer = {
      $$typeof: qt,
      _context: s
    }, s;
  }, W.createElement = function(s, M, B) {
    var H, F = {}, $ = null;
    if (M != null)
      for (H in M.key !== void 0 && ($ = "" + M.key), M)
        Ct.call(M, H) && H !== "key" && H !== "__self" && H !== "__source" && (F[H] = M[H]);
    var ct = arguments.length - 2;
    if (ct === 1) F.children = B;
    else if (1 < ct) {
      for (var $t = Array(ct), yt = 0; yt < ct; yt++)
        $t[yt] = arguments[yt + 2];
      F.children = $t;
    }
    if (s && s.defaultProps)
      for (H in ct = s.defaultProps, ct)
        F[H] === void 0 && (F[H] = ct[H]);
    return De(s, $, F);
  }, W.createRef = function() {
    return { current: null };
  }, W.forwardRef = function(s) {
    return { $$typeof: Pt, render: s };
  }, W.isValidElement = oe, W.lazy = function(s) {
    return {
      $$typeof: lt,
      _payload: { _status: -1, _result: s },
      _init: Y
    };
  }, W.memo = function(s, M) {
    return {
      $$typeof: _,
      type: s,
      compare: M === void 0 ? null : M
    };
  }, W.startTransition = function(s) {
    var M = et.T, B = {};
    et.T = B;
    try {
      var H = s(), F = et.S;
      F !== null && F(B, H), typeof H == "object" && H !== null && typeof H.then == "function" && H.then(Rt, V);
    } catch ($) {
      V($);
    } finally {
      M !== null && B.types !== null && (M.types = B.types), et.T = M;
    }
  }, W.unstable_useCacheRefresh = function() {
    return et.H.useCacheRefresh();
  }, W.use = function(s) {
    return et.H.use(s);
  }, W.useActionState = function(s, M, B) {
    return et.H.useActionState(s, M, B);
  }, W.useCallback = function(s, M) {
    return et.H.useCallback(s, M);
  }, W.useContext = function(s) {
    return et.H.useContext(s);
  }, W.useDebugValue = function() {
  }, W.useDeferredValue = function(s, M) {
    return et.H.useDeferredValue(s, M);
  }, W.useEffect = function(s, M) {
    return et.H.useEffect(s, M);
  }, W.useEffectEvent = function(s) {
    return et.H.useEffectEvent(s);
  }, W.useId = function() {
    return et.H.useId();
  }, W.useImperativeHandle = function(s, M, B) {
    return et.H.useImperativeHandle(s, M, B);
  }, W.useInsertionEffect = function(s, M) {
    return et.H.useInsertionEffect(s, M);
  }, W.useLayoutEffect = function(s, M) {
    return et.H.useLayoutEffect(s, M);
  }, W.useMemo = function(s, M) {
    return et.H.useMemo(s, M);
  }, W.useOptimistic = function(s, M) {
    return et.H.useOptimistic(s, M);
  }, W.useReducer = function(s, M, B) {
    return et.H.useReducer(s, M, B);
  }, W.useRef = function(s) {
    return et.H.useRef(s);
  }, W.useState = function(s) {
    return et.H.useState(s);
  }, W.useSyncExternalStore = function(s, M, B) {
    return et.H.useSyncExternalStore(
      s,
      M,
      B
    );
  }, W.useTransition = function() {
    return et.H.useTransition();
  }, W.version = "19.2.3", W;
}
var tm;
function To() {
  return tm || (tm = 1, xo.exports = tg()), xo.exports;
}
var So = { exports: {} }, he = {};
var em;
function eg() {
  if (em) return he;
  em = 1;
  var A = To();
  function K(U) {
    var _ = "https://react.dev/errors/" + U;
    if (1 < arguments.length) {
      _ += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var lt = 2; lt < arguments.length; lt++)
        _ += "&args[]=" + encodeURIComponent(arguments[lt]);
    }
    return "Minified React error #" + U + "; visit " + _ + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function rt() {
  }
  var b = {
    d: {
      f: rt,
      r: function() {
        throw Error(K(522));
      },
      D: rt,
      C: rt,
      L: rt,
      m: rt,
      X: rt,
      S: rt,
      M: rt
    },
    p: 0,
    findDOMNode: null
  }, Bt = /* @__PURE__ */ Symbol.for("react.portal");
  function qt(U, _, lt) {
    var X = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: Bt,
      key: X == null ? null : "" + X,
      children: U,
      containerInfo: _,
      implementation: lt
    };
  }
  var kt = A.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function Pt(U, _) {
    if (U === "font") return "";
    if (typeof _ == "string")
      return _ === "use-credentials" ? _ : "";
  }
  return he.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = b, he.createPortal = function(U, _) {
    var lt = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!_ || _.nodeType !== 1 && _.nodeType !== 9 && _.nodeType !== 11)
      throw Error(K(299));
    return qt(U, _, null, lt);
  }, he.flushSync = function(U) {
    var _ = kt.T, lt = b.p;
    try {
      if (kt.T = null, b.p = 2, U) return U();
    } finally {
      kt.T = _, b.p = lt, b.d.f();
    }
  }, he.preconnect = function(U, _) {
    typeof U == "string" && (_ ? (_ = _.crossOrigin, _ = typeof _ == "string" ? _ === "use-credentials" ? _ : "" : void 0) : _ = null, b.d.C(U, _));
  }, he.prefetchDNS = function(U) {
    typeof U == "string" && b.d.D(U);
  }, he.preinit = function(U, _) {
    if (typeof U == "string" && _ && typeof _.as == "string") {
      var lt = _.as, X = Pt(lt, _.crossOrigin), Et = typeof _.integrity == "string" ? _.integrity : void 0, Xt = typeof _.fetchPriority == "string" ? _.fetchPriority : void 0;
      lt === "style" ? b.d.S(
        U,
        typeof _.precedence == "string" ? _.precedence : void 0,
        {
          crossOrigin: X,
          integrity: Et,
          fetchPriority: Xt
        }
      ) : lt === "script" && b.d.X(U, {
        crossOrigin: X,
        integrity: Et,
        fetchPriority: Xt,
        nonce: typeof _.nonce == "string" ? _.nonce : void 0
      });
    }
  }, he.preinitModule = function(U, _) {
    if (typeof U == "string")
      if (typeof _ == "object" && _ !== null) {
        if (_.as == null || _.as === "script") {
          var lt = Pt(
            _.as,
            _.crossOrigin
          );
          b.d.M(U, {
            crossOrigin: lt,
            integrity: typeof _.integrity == "string" ? _.integrity : void 0,
            nonce: typeof _.nonce == "string" ? _.nonce : void 0
          });
        }
      } else _ == null && b.d.M(U);
  }, he.preload = function(U, _) {
    if (typeof U == "string" && typeof _ == "object" && _ !== null && typeof _.as == "string") {
      var lt = _.as, X = Pt(lt, _.crossOrigin);
      b.d.L(U, lt, {
        crossOrigin: X,
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
  }, he.preloadModule = function(U, _) {
    if (typeof U == "string")
      if (_) {
        var lt = Pt(_.as, _.crossOrigin);
        b.d.m(U, {
          as: typeof _.as == "string" && _.as !== "script" ? _.as : void 0,
          crossOrigin: lt,
          integrity: typeof _.integrity == "string" ? _.integrity : void 0
        });
      } else b.d.m(U);
  }, he.requestFormReset = function(U) {
    b.d.r(U);
  }, he.unstable_batchedUpdates = function(U, _) {
    return U(_);
  }, he.useFormState = function(U, _, lt) {
    return kt.H.useFormState(U, _, lt);
  }, he.useFormStatus = function() {
    return kt.H.useHostTransitionStatus();
  }, he.version = "19.2.3", he;
}
var lm;
function lg() {
  if (lm) return So.exports;
  lm = 1;
  function A() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(A);
      } catch (K) {
        console.error(K);
      }
  }
  return A(), So.exports = eg(), So.exports;
}
var am;
function ag() {
  if (am) return Yi;
  am = 1;
  var A = Ph(), K = To(), rt = lg();
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
  function qt(t) {
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
  function U(t) {
    if (qt(t) !== t)
      throw Error(b(188));
  }
  function _(t) {
    var e = t.alternate;
    if (!e) {
      if (e = qt(t), e === null) throw Error(b(188));
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
        throw Error(b(188));
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
          if (!u) throw Error(b(189));
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
  var X = Object.assign, Et = /* @__PURE__ */ Symbol.for("react.element"), Xt = /* @__PURE__ */ Symbol.for("react.transitional.element"), fe = /* @__PURE__ */ Symbol.for("react.portal"), te = /* @__PURE__ */ Symbol.for("react.fragment"), Ye = /* @__PURE__ */ Symbol.for("react.strict_mode"), vt = /* @__PURE__ */ Symbol.for("react.profiler"), Ge = /* @__PURE__ */ Symbol.for("react.consumer"), Nt = /* @__PURE__ */ Symbol.for("react.context"), Ft = /* @__PURE__ */ Symbol.for("react.forward_ref"), ce = /* @__PURE__ */ Symbol.for("react.suspense"), Rt = /* @__PURE__ */ Symbol.for("react.suspense_list"), et = /* @__PURE__ */ Symbol.for("react.memo"), Ct = /* @__PURE__ */ Symbol.for("react.lazy"), De = /* @__PURE__ */ Symbol.for("react.activity"), Se = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), oe = Symbol.iterator;
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
      case Rt:
        return "SuspenseList";
      case De:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case fe:
          return "Portal";
        case Nt:
          return t.displayName || "Context";
        case Ge:
          return (t._context.displayName || "Context") + ".Consumer";
        case Ft:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case et:
          return e = t.displayName || null, e !== null ? e : Le(t.type) || "Memo";
        case Ct:
          e = t._payload, t = t._init;
          try {
            return Le(t(e));
          } catch {
          }
      }
    return null;
  }
  var G = Array.isArray, m = K.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, D = rt.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, Y = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, V = [], k = -1;
  function s(t) {
    return { current: t };
  }
  function M(t) {
    0 > k || (t.current = V[k], V[k] = null, k--);
  }
  function B(t, e) {
    k++, V[k] = t.current, t.current = e;
  }
  var H = s(null), F = s(null), $ = s(null), ct = s(null);
  function $t(t, e) {
    switch (B($, e), B(F, t), B(H, null), e.nodeType) {
      case 9:
      case 11:
        t = (t = e.documentElement) && (t = t.namespaceURI) ? yd(t) : 0;
        break;
      default:
        if (t = e.tagName, e = e.namespaceURI)
          e = yd(e), t = bd(e, t);
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
  function yt() {
    M(H), M(F), M($);
  }
  function gl(t) {
    t.memoizedState !== null && B(ct, t);
    var e = H.current, l = bd(e, t.type);
    e !== l && (B(F, t), B(H, l));
  }
  function Xe(t) {
    F.current === t && (M(H), M(F)), ct.current === t && (M(ct), Ri._currentValue = Y);
  }
  var nl, jn;
  function pl(t) {
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
  function qn(t, e) {
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
                } catch (x) {
                  var y = x;
                }
                Reflect.construct(t, [], E);
              } else {
                try {
                  E.call();
                } catch (x) {
                  y = x;
                }
                t.call(E.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (x) {
                y = x;
              }
              (E = t()) && typeof E.catch == "function" && E.catch(function() {
              });
            }
          } catch (x) {
            if (x && y && typeof x.stack == "string")
              return [x.stack, y.stack];
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
        var r = u.split(`
`), v = f.split(`
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
                  var S = `
` + r[a].replace(" at new ", " at ");
                  return t.displayName && S.includes("<anonymous>") && (S = S.replace("<anonymous>", t.displayName)), S;
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
  function df(t, e) {
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
        return qn(t.type, !1);
      case 11:
        return qn(t.type.render, !1);
      case 1:
        return qn(t.type, !0);
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
        e += df(t, l), l = t, t = t.return;
      while (t);
      return e;
    } catch (a) {
      return `
Error generating stack: ` + a.message + `
` + a.stack;
    }
  }
  var Yn = Object.prototype.hasOwnProperty, Gn = A.unstable_scheduleCallback, xa = A.unstable_cancelCallback, Ln = A.unstable_shouldYield, Li = A.unstable_requestPaint, le = A.unstable_now, Xi = A.unstable_getCurrentPriorityLevel, Qi = A.unstable_ImmediatePriority, $a = A.unstable_UserBlockingPriority, Sa = A.unstable_NormalPriority, mf = A.unstable_LowPriority, Vi = A.unstable_IdlePriority, hf = A.log, Zi = A.unstable_setDisableYieldValue, Ta = null, ge = null;
  function il(t) {
    if (typeof hf == "function" && Zi(t), ge && typeof ge.setStrictMode == "function")
      try {
        ge.setStrictMode(Ta, t);
      } catch {
      }
  }
  var pe = Math.clz32 ? Math.clz32 : Ki, gf = Math.log, za = Math.LN2;
  function Ki(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (gf(t) / za | 0) | 0;
  }
  var vl = 256, Ia = 262144, yl = 4194304;
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
    var n = 0, i = t.suspendedLanes, u = t.pingedLanes;
    t = t.warmLanes;
    var f = a & 134217727;
    return f !== 0 ? (a = f & ~i, a !== 0 ? n = bl(a) : (u &= f, u !== 0 ? n = bl(u) : l || (l = f & ~t, l !== 0 && (n = bl(l))))) : (f = a & ~i, f !== 0 ? n = bl(f) : u !== 0 ? n = bl(u) : l || (l = a & ~t, l !== 0 && (n = bl(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function Xl(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function Ji(t, e) {
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
  function ki() {
    var t = yl;
    return yl <<= 1, (yl & 62914560) === 0 && (yl = 4194304), t;
  }
  function Ie(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function Ql(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function pf(t, e, l, a, n, i) {
    var u = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var f = t.entanglements, r = t.expirationTimes, v = t.hiddenUpdates;
    for (l = u & ~l; 0 < l; ) {
      var S = 31 - pe(l), E = 1 << S;
      f[S] = 0, r[S] = -1;
      var y = v[S];
      if (y !== null)
        for (v[S] = null, S = 0; S < y.length; S++) {
          var x = y[S];
          x !== null && (x.lane &= -536870913);
        }
      l &= ~E;
    }
    a !== 0 && Ma(t, a, 0), i !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= i & ~(u & ~e));
  }
  function Ma(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - pe(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function Xn(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - pe(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function Fi(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : re(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function re(t) {
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
  function Wi(t, e) {
    var l = D.p;
    try {
      return D.p = t, e();
    } finally {
      D.p = l;
    }
  }
  var ul = Math.random().toString(36).slice(2), Qt = "__reactFiber$" + ul, se = "__reactProps$" + ul, xl = "__reactContainer$" + ul, en = "__reactEvents$" + ul, vf = "__reactListeners$" + ul, yf = "__reactHandles$" + ul, $i = "__reactResources$" + ul, Aa = "__reactMarker$" + ul;
  function Qn(t) {
    delete t[Qt], delete t[se], delete t[en], delete t[vf], delete t[yf];
  }
  function Sl(t) {
    var e = t[Qt];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[xl] || l[Qt]) {
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
    if (t = t[Qt] || t[xl]) {
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
    var e = t[$i];
    return e || (e = t[$i] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
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
  var Ii = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), Pi = {}, Zn = {};
  function bf(t) {
    return Yn.call(Zn, t) ? !0 : Yn.call(Pi, t) ? !1 : Ii.test(t) ? Zn[t] = !0 : (Pi[t] = !0, !1);
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
  function tu(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function Da(t, e, l) {
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
  function Kn(t) {
    if (!t._valueTracker) {
      var e = tu(t) ? "checked" : "value";
      t._valueTracker = Da(
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
    return t && (a = tu(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function Oa(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var Ca = /[\n"\\]/g;
  function Te(t) {
    return t.replace(
      Ca,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function ye(t, e, l, a, n, i, u, f) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + ve(e)) : t.value !== "" + ve(e) && (t.value = "" + ve(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? Jn(t, u, ve(e)) : l != null ? Jn(t, u, ve(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), f != null && typeof f != "function" && typeof f != "symbol" && typeof f != "boolean" ? t.name = "" + ve(f) : t.removeAttribute("name");
  }
  function Ua(t, e, l, a, n, i, u, f) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        Kn(t);
        return;
      }
      l = l != null ? "" + ve(l) : "", e = e != null ? "" + ve(e) : l, f || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = f ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), Kn(t);
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
  function g(t, e) {
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
  function w(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || O.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function N(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(b(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && w(t, n, a);
    } else
      for (var i in e)
        e.hasOwnProperty(i) && w(t, i, e[i]);
  }
  function R(t) {
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
  var st = /* @__PURE__ */ new Map([
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
  function lu(t) {
    var e = fl(t);
    if (e && (t = e.stateNode)) {
      var l = t[se] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if (ye(
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
                var n = a[se] || null;
                if (!n) throw Error(b(90));
                ye(
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
          c(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && Jl(t, !!l.multiple, e, !1);
      }
    }
  }
  var an = !1;
  function au(t, e, l) {
    if (an) return t(e, l);
    an = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (an = !1, (kl !== null || zl !== null) && (Xu(), kl && (e = kl, t = zl, zl = kl = null, lu(e), t)))
        for (e = 0; e < t.length; e++) lu(t[e]);
    }
  }
  function Ml(t, e) {
    var l = t.stateNode;
    if (l === null) return null;
    var a = l[se] || null;
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
  var Ce = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), Wn = !1;
  if (Ce)
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
    var t, e = Ba, l = e.length, a, n = "value" in Qe ? Qe.value : Qe.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return ol = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function nn(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function Na() {
    return !0;
  }
  function In() {
    return !1;
  }
  function me(t) {
    function e(l, a, n, i, u) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = i, this.target = u, this.currentTarget = null;
      for (var f in t)
        t.hasOwnProperty(f) && (l = t[f], this[f] = l ? l(i) : i[f]);
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? Na : In, this.isPropagationStopped = In, this;
    }
    return X(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = Na);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = Na);
      },
      persist: function() {
      },
      isPersistent: Na
    }), e;
  }
  var rl = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, El = me(rl), Wl = X({}, rl, { view: 0, detail: 0 }), xf = me(Wl), Pn, un, Ra, $l = X({}, Wl, {
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
    getModifierState: ti,
    button: 0,
    buttons: 0,
    relatedTarget: function(t) {
      return t.relatedTarget === void 0 ? t.fromElement === t.srcElement ? t.toElement : t.fromElement : t.relatedTarget;
    },
    movementX: function(t) {
      return "movementX" in t ? t.movementX : (t !== Ra && (Ra && t.type === "mousemove" ? (Pn = t.screenX - Ra.screenX, un = t.screenY - Ra.screenY) : un = Pn = 0, Ra = t), Pn);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : un;
    }
  }), Al = me($l), nu = X({}, $l, { dataTransfer: 0 }), iu = me(nu), fn = X({}, Wl, { relatedTarget: 0 }), T = me(fn), C = X({}, rl, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), J = me(C), I = X({}, rl, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), dt = me(I), mt = X({}, rl, { data: 0 }), Ht = me(mt), be = {
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
  }, Ue = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function uu(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = Ue[t]) ? !!e[t] : !1;
  }
  function ti() {
    return uu;
  }
  var fm = X({}, Wl, {
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
    getModifierState: ti,
    charCode: function(t) {
      return t.type === "keypress" ? nn(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? nn(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), cm = me(fm), om = X({}, $l, {
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
  }), zo = me(om), rm = X({}, Wl, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: ti
  }), sm = me(rm), dm = X({}, rl, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), mm = me(dm), hm = X({}, $l, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), gm = me(hm), pm = X({}, rl, {
    newState: 0,
    oldState: 0
  }), vm = me(pm), ym = [9, 13, 27, 32], Sf = Ce && "CompositionEvent" in window, ei = null;
  Ce && "documentMode" in document && (ei = document.documentMode);
  var bm = Ce && "TextEvent" in window && !ei, Mo = Ce && (!Sf || ei && 8 < ei && 11 >= ei), Eo = " ", Ao = !1;
  function _o(t, e) {
    switch (t) {
      case "keyup":
        return ym.indexOf(e.keyCode) !== -1;
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
  function xm(t, e) {
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
  function Sm(t, e) {
    if (cn)
      return t === "compositionend" || !Sf && _o(t, e) ? (t = $n(), ol = Ba = Qe = null, cn = !1, t) : null;
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
  function Co(t, e, l, a) {
    kl ? zl ? zl.push(a) : zl = [a] : kl = a, e = Fu(e, "onChange"), 0 < e.length && (l = new El(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var li = null, ai = null;
  function zm(t) {
    dd(t, 0);
  }
  function fu(t) {
    var e = Tl(t);
    if (eu(e)) return t;
  }
  function Uo(t, e) {
    if (t === "change") return e;
  }
  var Bo = !1;
  if (Ce) {
    var Tf;
    if (Ce) {
      var zf = "oninput" in document;
      if (!zf) {
        var No = document.createElement("div");
        No.setAttribute("oninput", "return;"), zf = typeof No.oninput == "function";
      }
      Tf = zf;
    } else Tf = !1;
    Bo = Tf && (!document.documentMode || 9 < document.documentMode);
  }
  function Ro() {
    li && (li.detachEvent("onpropertychange", Ho), ai = li = null);
  }
  function Ho(t) {
    if (t.propertyName === "value" && fu(ai)) {
      var e = [];
      Co(
        e,
        ai,
        t,
        Fn(t)
      ), au(zm, e);
    }
  }
  function Mm(t, e, l) {
    t === "focusin" ? (Ro(), li = e, ai = l, li.attachEvent("onpropertychange", Ho)) : t === "focusout" && Ro();
  }
  function Em(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return fu(ai);
  }
  function Am(t, e) {
    if (t === "click") return fu(e);
  }
  function _m(t, e) {
    if (t === "input" || t === "change")
      return fu(e);
  }
  function Dm(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var Be = typeof Object.is == "function" ? Object.is : Dm;
  function ni(t, e) {
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
  function wo(t) {
    for (; t && t.firstChild; ) t = t.firstChild;
    return t;
  }
  function jo(t, e) {
    var l = wo(t);
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
      l = wo(l);
    }
  }
  function qo(t, e) {
    return t && e ? t === e ? !0 : t && t.nodeType === 3 ? !1 : e && e.nodeType === 3 ? qo(t, e.parentNode) : "contains" in t ? t.contains(e) : t.compareDocumentPosition ? !!(t.compareDocumentPosition(e) & 16) : !1 : !1;
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
  var Om = Ce && "documentMode" in document && 11 >= document.documentMode, on = null, Ef = null, ii = null, Af = !1;
  function Go(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Af || on == null || on !== Oa(a) || (a = on, "selectionStart" in a && Mf(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), ii && ni(ii, a) || (ii = a, a = Fu(Ef, "onSelect"), 0 < a.length && (e = new El(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = on)));
  }
  function wa(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var rn = {
    animationend: wa("Animation", "AnimationEnd"),
    animationiteration: wa("Animation", "AnimationIteration"),
    animationstart: wa("Animation", "AnimationStart"),
    transitionrun: wa("Transition", "TransitionRun"),
    transitionstart: wa("Transition", "TransitionStart"),
    transitioncancel: wa("Transition", "TransitionCancel"),
    transitionend: wa("Transition", "TransitionEnd")
  }, _f = {}, Lo = {};
  Ce && (Lo = document.createElement("div").style, "AnimationEvent" in window || (delete rn.animationend.animation, delete rn.animationiteration.animation, delete rn.animationstart.animation), "TransitionEvent" in window || delete rn.transitionend.transition);
  function ja(t) {
    if (_f[t]) return _f[t];
    if (!rn[t]) return t;
    var e = rn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Lo)
        return _f[t] = e[l];
    return t;
  }
  var Xo = ja("animationend"), Qo = ja("animationiteration"), Vo = ja("animationstart"), Cm = ja("transitionrun"), Um = ja("transitionstart"), Bm = ja("transitioncancel"), Zo = ja("transitionend"), Ko = /* @__PURE__ */ new Map(), Df = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Df.push("scrollEnd");
  function tl(t, e) {
    Ko.set(t, e), cl(e, [t]);
  }
  var cu = typeof reportError == "function" ? reportError : function(t) {
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
  }, Ve = [], sn = 0, Of = 0;
  function ou() {
    for (var t = sn, e = Of = sn = 0; e < t; ) {
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
      i !== 0 && Jo(l, n, i);
    }
  }
  function ru(t, e, l, a) {
    Ve[sn++] = t, Ve[sn++] = e, Ve[sn++] = l, Ve[sn++] = a, Of |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Cf(t, e, l, a) {
    return ru(t, e, l, a), su(t);
  }
  function qa(t, e) {
    return ru(t, null, null, e), su(t);
  }
  function Jo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, i = t.return; i !== null; )
      i.childLanes |= l, a = i.alternate, a !== null && (a.childLanes |= l), i.tag === 22 && (t = i.stateNode, t === null || t._visibility & 1 || (n = !0)), t = i, i = i.return;
    return t.tag === 3 ? (i = t.stateNode, n && e !== null && (n = 31 - pe(l), t = i.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), i) : null;
  }
  function su(t) {
    if (50 < _i)
      throw _i = 0, Yc = null, Error(b(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var dn = {};
  function Nm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function Ne(t, e, l, a) {
    return new Nm(t, e, l, a);
  }
  function Uf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function _l(t, e) {
    var l = t.alternate;
    return l === null ? (l = Ne(
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
  function du(t, e, l, a, n, i) {
    var u = 0;
    if (a = t, typeof t == "function") Uf(t) && (u = 1);
    else if (typeof t == "string")
      u = qh(
        t,
        l,
        H.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case De:
          return t = Ne(31, l, e, n), t.elementType = De, t.lanes = i, t;
        case te:
          return Ya(l.children, n, i, e);
        case Ye:
          u = 8, n |= 24;
          break;
        case vt:
          return t = Ne(12, l, e, n | 2), t.elementType = vt, t.lanes = i, t;
        case ce:
          return t = Ne(13, l, e, n), t.elementType = ce, t.lanes = i, t;
        case Rt:
          return t = Ne(19, l, e, n), t.elementType = Rt, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case Nt:
                u = 10;
                break t;
              case Ge:
                u = 9;
                break t;
              case Ft:
                u = 11;
                break t;
              case et:
                u = 14;
                break t;
              case Ct:
                u = 16, a = null;
                break t;
            }
          u = 29, l = Error(
            b(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = Ne(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function Ya(t, e, l, a) {
    return t = Ne(7, t, a, e), t.lanes = l, t;
  }
  function Bf(t, e, l) {
    return t = Ne(6, t, null, e), t.lanes = l, t;
  }
  function Fo(t) {
    var e = Ne(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function Nf(t, e, l) {
    return e = Ne(
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
        stack: Gi(e)
      }, Wo.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Gi(e)
    };
  }
  var mn = [], hn = 0, mu = null, ui = 0, Ke = [], Je = 0, Il = null, sl = 1, dl = "";
  function Dl(t, e) {
    mn[hn++] = ui, mn[hn++] = mu, mu = t, ui = e;
  }
  function $o(t, e, l) {
    Ke[Je++] = sl, Ke[Je++] = dl, Ke[Je++] = Il, Il = t;
    var a = sl;
    t = dl;
    var n = 32 - pe(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - pe(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, sl = 1 << 32 - pe(e) + n | l << n | a, dl = i + t;
    } else
      sl = 1 << i | l << n | a, dl = t;
  }
  function Rf(t) {
    t.return !== null && (Dl(t, 1), $o(t, 1, 0));
  }
  function Hf(t) {
    for (; t === mu; )
      mu = mn[--hn], mn[hn] = null, ui = mn[--hn], mn[hn] = null;
    for (; t === Il; )
      Il = Ke[--Je], Ke[Je] = null, dl = Ke[--Je], Ke[Je] = null, sl = Ke[--Je], Ke[Je] = null;
  }
  function Io(t, e) {
    Ke[Je++] = sl, Ke[Je++] = dl, Ke[Je++] = Il, sl = e.id, dl = e.overflow, Il = t;
  }
  var ae = null, _t = null, ft = !1, Pl = null, ke = !1, wf = Error(b(519));
  function ta(t) {
    var e = Error(
      b(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw fi(Ze(e, t)), wf;
  }
  function Po(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[Qt] = t, e[se] = a, l) {
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
        for (l = 0; l < Oi.length; l++)
          nt(Oi[l], e);
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
        nt("invalid", e), Ua(
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
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || pd(e.textContent, l) ? (a.popover != null && (nt("beforetoggle", e), nt("toggle", e)), a.onScroll != null && nt("scroll", e), a.onScrollEnd != null && nt("scrollend", e), a.onClick != null && (e.onclick = de), e = !0) : e = !1, e || ta(t, !0);
  }
  function tr(t) {
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
  function gn(t) {
    if (t !== ae) return !1;
    if (!ft) return tr(t), ft = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || to(t.type, t.memoizedProps)), l = !l), l && _t && ta(t), tr(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(b(317));
      _t = Ed(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(b(317));
      _t = Ed(t);
    } else
      e === 27 ? (e = _t, ha(t.type) ? (t = io, io = null, _t = t) : _t = e) : _t = ae ? We(t.stateNode.nextSibling) : null;
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
  function fi(t) {
    Pl === null ? Pl = [t] : Pl.push(t);
  }
  var qf = s(null), La = null, Ol = null;
  function ea(t, e, l) {
    B(qf, e._currentValue), e._currentValue = l;
  }
  function Cl(t) {
    t._currentValue = qf.current, M(qf);
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
      var i = n.dependencies;
      if (i !== null) {
        var u = n.child;
        i = i.firstContext;
        t: for (; i !== null; ) {
          var f = i;
          i = n;
          for (var r = 0; r < e.length; r++)
            if (f.context === e[r]) {
              i.lanes |= l, f = i.alternate, f !== null && (f.lanes |= l), Yf(
                i.return,
                l,
                t
              ), a || (u = null);
              break t;
            }
          i = f.next;
        }
      } else if (n.tag === 18) {
        if (u = n.return, u === null) throw Error(b(341));
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
  function pn(t, e, l, a) {
    t = null;
    for (var n = e, i = !1; n !== null; ) {
      if (!i) {
        if ((n.flags & 524288) !== 0) i = !0;
        else if ((n.flags & 262144) !== 0) break;
      }
      if (n.tag === 10) {
        var u = n.alternate;
        if (u === null) throw Error(b(387));
        if (u = u.memoizedProps, u !== null) {
          var f = n.type;
          Be(n.pendingProps.value, u.value) || (t !== null ? t.push(f) : t = [f]);
        }
      } else if (n === ct.current) {
        if (u = n.alternate, u === null) throw Error(b(387));
        u.memoizedState.memoizedState !== n.memoizedState.memoizedState && (t !== null ? t.push(Ri) : t = [Ri]);
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
  function hu(t) {
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
    return er(La, t);
  }
  function gu(t, e) {
    return La === null && Xa(t), er(t, e);
  }
  function er(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Ol === null) {
      if (t === null) throw Error(b(308));
      Ol = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else Ol = Ol.next = e;
    return l;
  }
  var Rm = typeof AbortController < "u" ? AbortController : function() {
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
  }, Hm = A.unstable_scheduleCallback, wm = A.unstable_NormalPriority, Vt = {
    $$typeof: Nt,
    Consumer: null,
    Provider: null,
    _currentValue: null,
    _currentValue2: null,
    _threadCount: 0
  };
  function Lf() {
    return {
      controller: new Rm(),
      data: /* @__PURE__ */ new Map(),
      refCount: 0
    };
  }
  function ci(t) {
    t.refCount--, t.refCount === 0 && Hm(wm, function() {
      t.controller.abort();
    });
  }
  var oi = null, Xf = 0, vn = 0, yn = null;
  function jm(t, e) {
    if (oi === null) {
      var l = oi = [];
      Xf = 0, vn = Zc(), yn = {
        status: "pending",
        value: void 0,
        then: function(a) {
          l.push(a);
        }
      };
    }
    return Xf++, e.then(lr, lr), e;
  }
  function lr() {
    if (--Xf === 0 && oi !== null) {
      yn !== null && (yn.status = "fulfilled");
      var t = oi;
      oi = null, vn = 0, yn = null;
      for (var e = 0; e < t.length; e++) (0, t[e])();
    }
  }
  function qm(t, e) {
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
    Gs = le(), typeof e == "object" && e !== null && typeof e.then == "function" && jm(t, e), ar !== null && ar(t, e);
  };
  var Qa = s(null);
  function Qf() {
    var t = Qa.current;
    return t !== null ? t : Mt.pooledCache;
  }
  function pu(t, e) {
    e === null ? B(Qa, Qa.current) : B(Qa, e.pool);
  }
  function nr() {
    var t = Qf();
    return t === null ? null : { parent: Vt._currentValue, pool: t };
  }
  var bn = Error(b(460)), Vf = Error(b(474)), vu = Error(b(542)), yu = { then: function() {
  } };
  function ir(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function ur(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(de, de), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, cr(t), t;
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
            throw t = e.reason, cr(t), t;
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
  function fr() {
    if (Za === null) throw Error(b(459));
    var t = Za;
    return Za = null, t;
  }
  function cr(t) {
    if (t === bn || t === vu)
      throw Error(b(483));
  }
  var xn = null, ri = 0;
  function bu(t) {
    var e = ri;
    return ri += 1, xn === null && (xn = []), ur(xn, t, e);
  }
  function si(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function xu(t, e) {
    throw e.$$typeof === Et ? Error(b(525)) : (t = Object.prototype.toString.call(e), Error(
      b(
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
      return h = _l(h, d), h.index = 0, h.sibling = null, h;
    }
    function i(h, d, p) {
      return h.index = p, t ? (p = h.alternate, p !== null ? (p = p.index, p < d ? (h.flags |= 67108866, d) : p) : (h.flags |= 67108866, d)) : (h.flags |= 1048576, d);
    }
    function u(h) {
      return t && h.alternate === null && (h.flags |= 67108866), h;
    }
    function f(h, d, p, z) {
      return d === null || d.tag !== 6 ? (d = Bf(p, h.mode, z), d.return = h, d) : (d = n(d, p), d.return = h, d);
    }
    function r(h, d, p, z) {
      var Q = p.type;
      return Q === te ? S(
        h,
        d,
        p.props.children,
        z,
        p.key
      ) : d !== null && (d.elementType === Q || typeof Q == "object" && Q !== null && Q.$$typeof === Ct && Va(Q) === d.type) ? (d = n(d, p.props), si(d, p), d.return = h, d) : (d = du(
        p.type,
        p.key,
        p.props,
        null,
        h.mode,
        z
      ), si(d, p), d.return = h, d);
    }
    function v(h, d, p, z) {
      return d === null || d.tag !== 4 || d.stateNode.containerInfo !== p.containerInfo || d.stateNode.implementation !== p.implementation ? (d = Nf(p, h.mode, z), d.return = h, d) : (d = n(d, p.children || []), d.return = h, d);
    }
    function S(h, d, p, z, Q) {
      return d === null || d.tag !== 7 ? (d = Ya(
        p,
        h.mode,
        z,
        Q
      ), d.return = h, d) : (d = n(d, p), d.return = h, d);
    }
    function E(h, d, p) {
      if (typeof d == "string" && d !== "" || typeof d == "number" || typeof d == "bigint")
        return d = Bf(
          "" + d,
          h.mode,
          p
        ), d.return = h, d;
      if (typeof d == "object" && d !== null) {
        switch (d.$$typeof) {
          case Xt:
            return p = du(
              d.type,
              d.key,
              d.props,
              null,
              h.mode,
              p
            ), si(p, d), p.return = h, p;
          case fe:
            return d = Nf(
              d,
              h.mode,
              p
            ), d.return = h, d;
          case Ct:
            return d = Va(d), E(h, d, p);
        }
        if (G(d) || ee(d))
          return d = Ya(
            d,
            h.mode,
            p,
            null
          ), d.return = h, d;
        if (typeof d.then == "function")
          return E(h, bu(d), p);
        if (d.$$typeof === Nt)
          return E(
            h,
            gu(h, d),
            p
          );
        xu(h, d);
      }
      return null;
    }
    function y(h, d, p, z) {
      var Q = d !== null ? d.key : null;
      if (typeof p == "string" && p !== "" || typeof p == "number" || typeof p == "bigint")
        return Q !== null ? null : f(h, d, "" + p, z);
      if (typeof p == "object" && p !== null) {
        switch (p.$$typeof) {
          case Xt:
            return p.key === Q ? r(h, d, p, z) : null;
          case fe:
            return p.key === Q ? v(h, d, p, z) : null;
          case Ct:
            return p = Va(p), y(h, d, p, z);
        }
        if (G(p) || ee(p))
          return Q !== null ? null : S(h, d, p, z, null);
        if (typeof p.then == "function")
          return y(
            h,
            d,
            bu(p),
            z
          );
        if (p.$$typeof === Nt)
          return y(
            h,
            d,
            gu(h, p),
            z
          );
        xu(h, p);
      }
      return null;
    }
    function x(h, d, p, z, Q) {
      if (typeof z == "string" && z !== "" || typeof z == "number" || typeof z == "bigint")
        return h = h.get(p) || null, f(d, h, "" + z, Q);
      if (typeof z == "object" && z !== null) {
        switch (z.$$typeof) {
          case Xt:
            return h = h.get(
              z.key === null ? p : z.key
            ) || null, r(d, h, z, Q);
          case fe:
            return h = h.get(
              z.key === null ? p : z.key
            ) || null, v(d, h, z, Q);
          case Ct:
            return z = Va(z), x(
              h,
              d,
              p,
              z,
              Q
            );
        }
        if (G(z) || ee(z))
          return h = h.get(p) || null, S(d, h, z, Q, null);
        if (typeof z.then == "function")
          return x(
            h,
            d,
            p,
            bu(z),
            Q
          );
        if (z.$$typeof === Nt)
          return x(
            h,
            d,
            p,
            gu(d, z),
            Q
          );
        xu(d, z);
      }
      return null;
    }
    function j(h, d, p, z) {
      for (var Q = null, ht = null, q = d, tt = d = 0, ut = null; q !== null && tt < p.length; tt++) {
        q.index > tt ? (ut = q, q = null) : ut = q.sibling;
        var gt = y(
          h,
          q,
          p[tt],
          z
        );
        if (gt === null) {
          q === null && (q = ut);
          break;
        }
        t && q && gt.alternate === null && e(h, q), d = i(gt, d, tt), ht === null ? Q = gt : ht.sibling = gt, ht = gt, q = ut;
      }
      if (tt === p.length)
        return l(h, q), ft && Dl(h, tt), Q;
      if (q === null) {
        for (; tt < p.length; tt++)
          q = E(h, p[tt], z), q !== null && (d = i(
            q,
            d,
            tt
          ), ht === null ? Q = q : ht.sibling = q, ht = q);
        return ft && Dl(h, tt), Q;
      }
      for (q = a(q); tt < p.length; tt++)
        ut = x(
          q,
          h,
          tt,
          p[tt],
          z
        ), ut !== null && (t && ut.alternate !== null && q.delete(
          ut.key === null ? tt : ut.key
        ), d = i(
          ut,
          d,
          tt
        ), ht === null ? Q = ut : ht.sibling = ut, ht = ut);
      return t && q.forEach(function(ba) {
        return e(h, ba);
      }), ft && Dl(h, tt), Q;
    }
    function Z(h, d, p, z) {
      if (p == null) throw Error(b(151));
      for (var Q = null, ht = null, q = d, tt = d = 0, ut = null, gt = p.next(); q !== null && !gt.done; tt++, gt = p.next()) {
        q.index > tt ? (ut = q, q = null) : ut = q.sibling;
        var ba = y(h, q, gt.value, z);
        if (ba === null) {
          q === null && (q = ut);
          break;
        }
        t && q && ba.alternate === null && e(h, q), d = i(ba, d, tt), ht === null ? Q = ba : ht.sibling = ba, ht = ba, q = ut;
      }
      if (gt.done)
        return l(h, q), ft && Dl(h, tt), Q;
      if (q === null) {
        for (; !gt.done; tt++, gt = p.next())
          gt = E(h, gt.value, z), gt !== null && (d = i(gt, d, tt), ht === null ? Q = gt : ht.sibling = gt, ht = gt);
        return ft && Dl(h, tt), Q;
      }
      for (q = a(q); !gt.done; tt++, gt = p.next())
        gt = x(q, h, tt, gt.value, z), gt !== null && (t && gt.alternate !== null && q.delete(gt.key === null ? tt : gt.key), d = i(gt, d, tt), ht === null ? Q = gt : ht.sibling = gt, ht = gt);
      return t && q.forEach(function(Fh) {
        return e(h, Fh);
      }), ft && Dl(h, tt), Q;
    }
    function zt(h, d, p, z) {
      if (typeof p == "object" && p !== null && p.type === te && p.key === null && (p = p.props.children), typeof p == "object" && p !== null) {
        switch (p.$$typeof) {
          case Xt:
            t: {
              for (var Q = p.key; d !== null; ) {
                if (d.key === Q) {
                  if (Q = p.type, Q === te) {
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
                  } else if (d.elementType === Q || typeof Q == "object" && Q !== null && Q.$$typeof === Ct && Va(Q) === d.type) {
                    l(
                      h,
                      d.sibling
                    ), z = n(d, p.props), si(z, p), z.return = h, h = z;
                    break t;
                  }
                  l(h, d);
                  break;
                } else e(h, d);
                d = d.sibling;
              }
              p.type === te ? (z = Ya(
                p.props.children,
                h.mode,
                z,
                p.key
              ), z.return = h, h = z) : (z = du(
                p.type,
                p.key,
                p.props,
                null,
                h.mode,
                z
              ), si(z, p), z.return = h, h = z);
            }
            return u(h);
          case fe:
            t: {
              for (Q = p.key; d !== null; ) {
                if (d.key === Q)
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
              z = Nf(p, h.mode, z), z.return = h, h = z;
            }
            return u(h);
          case Ct:
            return p = Va(p), zt(
              h,
              d,
              p,
              z
            );
        }
        if (G(p))
          return j(
            h,
            d,
            p,
            z
          );
        if (ee(p)) {
          if (Q = ee(p), typeof Q != "function") throw Error(b(150));
          return p = Q.call(p), Z(
            h,
            d,
            p,
            z
          );
        }
        if (typeof p.then == "function")
          return zt(
            h,
            d,
            bu(p),
            z
          );
        if (p.$$typeof === Nt)
          return zt(
            h,
            d,
            gu(h, p),
            z
          );
        xu(h, p);
      }
      return typeof p == "string" && p !== "" || typeof p == "number" || typeof p == "bigint" ? (p = "" + p, d !== null && d.tag === 6 ? (l(h, d.sibling), z = n(d, p), z.return = h, h = z) : (l(h, d), z = Bf(p, h.mode, z), z.return = h, h = z), u(h)) : l(h, d);
    }
    return function(h, d, p, z) {
      try {
        ri = 0;
        var Q = zt(
          h,
          d,
          p,
          z
        );
        return xn = null, Q;
      } catch (q) {
        if (q === bn || q === vu) throw q;
        var ht = Ne(29, q, null, h.mode);
        return ht.lanes = z, ht.return = h, ht;
      }
    };
  }
  var Ka = or(!0), rr = or(!1), la = !1;
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
    if (a = a.shared, (pt & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = su(t), Jo(t, null, l), e;
    }
    return ru(t, a, e, l), su(t);
  }
  function di(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Xn(t, l);
    }
  }
  function Jf(t, e) {
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
  var kf = !1;
  function mi() {
    if (kf) {
      var t = yn;
      if (t !== null) throw t;
    }
  }
  function hi(t, e, l, a) {
    kf = !1;
    var n = t.updateQueue;
    la = !1;
    var i = n.firstBaseUpdate, u = n.lastBaseUpdate, f = n.shared.pending;
    if (f !== null) {
      n.shared.pending = null;
      var r = f, v = r.next;
      r.next = null, u === null ? i = v : u.next = v, u = r;
      var S = t.alternate;
      S !== null && (S = S.updateQueue, f = S.lastBaseUpdate, f !== u && (f === null ? S.firstBaseUpdate = v : f.next = v, S.lastBaseUpdate = r));
    }
    if (i !== null) {
      var E = n.baseState;
      u = 0, S = v = r = null, f = i;
      do {
        var y = f.lane & -536870913, x = y !== f.lane;
        if (x ? (it & y) === y : (a & y) === y) {
          y !== 0 && y === vn && (kf = !0), S !== null && (S = S.next = {
            lane: 0,
            tag: f.tag,
            payload: f.payload,
            callback: null,
            next: null
          });
          t: {
            var j = t, Z = f;
            y = e;
            var zt = l;
            switch (Z.tag) {
              case 1:
                if (j = Z.payload, typeof j == "function") {
                  E = j.call(zt, E, y);
                  break t;
                }
                E = j;
                break t;
              case 3:
                j.flags = j.flags & -65537 | 128;
              case 0:
                if (j = Z.payload, y = typeof j == "function" ? j.call(zt, E, y) : j, y == null) break t;
                E = X({}, E, y);
                break t;
              case 2:
                la = !0;
            }
          }
          y = f.callback, y !== null && (t.flags |= 64, x && (t.flags |= 8192), x = n.callbacks, x === null ? n.callbacks = [y] : x.push(y));
        } else
          x = {
            lane: y,
            tag: f.tag,
            payload: f.payload,
            callback: f.callback,
            next: null
          }, S === null ? (v = S = x, r = E) : S = S.next = x, u |= y;
        if (f = f.next, f === null) {
          if (f = n.shared.pending, f === null)
            break;
          x = f, f = x.next, x.next = null, n.lastBaseUpdate = x, n.shared.pending = null;
        }
      } while (!0);
      S === null && (r = E), n.baseState = r, n.firstBaseUpdate = v, n.lastBaseUpdate = S, i === null && (n.shared.lanes = 0), oa |= u, t.lanes = u, t.memoizedState = E;
    }
  }
  function sr(t, e) {
    if (typeof t != "function")
      throw Error(b(191, t));
    t.call(e);
  }
  function dr(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        sr(l[t], e);
  }
  var Sn = s(null), Su = s(0);
  function mr(t, e) {
    t = Yl, B(Su, t), B(Sn, e), Yl = t | e.baseLanes;
  }
  function Ff() {
    B(Su, Yl), B(Sn, Sn.current);
  }
  function Wf() {
    Yl = Su.current, M(Sn), M(Su);
  }
  var Re = s(null), Fe = null;
  function ia(t) {
    var e = t.alternate;
    B(Gt, Gt.current & 1), B(Re, t), Fe === null && (e === null || Sn.current !== null || e.memoizedState !== null) && (Fe = t);
  }
  function $f(t) {
    B(Gt, Gt.current), B(Re, t), Fe === null && (Fe = t);
  }
  function hr(t) {
    t.tag === 22 ? (B(Gt, Gt.current), B(Re, t), Fe === null && (Fe = t)) : ua();
  }
  function ua() {
    B(Gt, Gt.current), B(Re, Re.current);
  }
  function He(t) {
    M(Re), Fe === t && (Fe = null), M(Gt);
  }
  var Gt = s(0);
  function Tu(t) {
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
  var Ul = 0, P = null, St = null, Zt = null, zu = !1, Tn = !1, Ja = !1, Mu = 0, gi = 0, zn = null, Ym = 0;
  function wt() {
    throw Error(b(321));
  }
  function If(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!Be(t[l], e[l])) return !1;
    return !0;
  }
  function Pf(t, e, l, a, n, i) {
    return Ul = i, P = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, m.H = t === null || t.memoizedState === null ? $r : hc, Ja = !1, i = l(a, n), Ja = !1, Tn && (i = pr(
      e,
      l,
      a,
      n
    )), gr(t), i;
  }
  function gr(t) {
    m.H = yi;
    var e = St !== null && St.next !== null;
    if (Ul = 0, Zt = St = P = null, zu = !1, gi = 0, zn = null, e) throw Error(b(300));
    t === null || Kt || (t = t.dependencies, t !== null && hu(t) && (Kt = !0));
  }
  function pr(t, e, l, a) {
    P = t;
    var n = 0;
    do {
      if (Tn && (zn = null), gi = 0, Tn = !1, 25 <= n) throw Error(b(301));
      if (n += 1, Zt = St = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      m.H = Ir, i = e(l, a);
    } while (Tn);
    return i;
  }
  function Gm() {
    var t = m.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? pi(e) : e, t = t.useState()[0], (St !== null ? St.memoizedState : null) !== t && (P.flags |= 1024), e;
  }
  function tc() {
    var t = Mu !== 0;
    return Mu = 0, t;
  }
  function ec(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function lc(t) {
    if (zu) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      zu = !1;
    }
    Ul = 0, Zt = St = P = null, Tn = !1, gi = Mu = 0, zn = null;
  }
  function xe() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return Zt === null ? P.memoizedState = Zt = t : Zt = Zt.next = t, Zt;
  }
  function Lt() {
    if (St === null) {
      var t = P.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = St.next;
    var e = Zt === null ? P.memoizedState : Zt.next;
    if (e !== null)
      Zt = e, St = t;
    else {
      if (t === null)
        throw P.alternate === null ? Error(b(467)) : Error(b(310));
      St = t, t = {
        memoizedState: St.memoizedState,
        baseState: St.baseState,
        baseQueue: St.baseQueue,
        queue: St.queue,
        next: null
      }, Zt === null ? P.memoizedState = Zt = t : Zt = Zt.next = t;
    }
    return Zt;
  }
  function Eu() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function pi(t) {
    var e = gi;
    return gi += 1, zn === null && (zn = []), t = ur(zn, t, e), e = P, (Zt === null ? e.memoizedState : Zt.next) === null && (e = e.alternate, m.H = e === null || e.memoizedState === null ? $r : hc), t;
  }
  function Au(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return pi(t);
      if (t.$$typeof === Nt) return ne(t);
    }
    throw Error(b(438, String(t)));
  }
  function ac(t) {
    var e = null, l = P.updateQueue;
    if (l !== null && (e = l.memoCache), e == null) {
      var a = P.alternate;
      a !== null && (a = a.updateQueue, a !== null && (a = a.memoCache, a != null && (e = {
        data: a.data.map(function(n) {
          return n.slice();
        }),
        index: 0
      })));
    }
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Eu(), P.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = Se;
    return e.index++, l;
  }
  function Bl(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function _u(t) {
    var e = Lt();
    return nc(e, St, t);
  }
  function nc(t, e, l) {
    var a = t.queue;
    if (a === null) throw Error(b(311));
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
      var f = u = null, r = null, v = e, S = !1;
      do {
        var E = v.lane & -536870913;
        if (E !== v.lane ? (it & E) === E : (Ul & E) === E) {
          var y = v.revertLane;
          if (y === 0)
            r !== null && (r = r.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: v.action,
              hasEagerState: v.hasEagerState,
              eagerState: v.eagerState,
              next: null
            }), E === vn && (S = !0);
          else if ((Ul & y) === y) {
            v = v.next, y === vn && (S = !0);
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
            }, r === null ? (f = r = E, u = i) : r = r.next = E, P.lanes |= y, oa |= y;
          E = v.action, Ja && l(i, E), i = v.hasEagerState ? v.eagerState : l(i, E);
        } else
          y = {
            lane: E,
            revertLane: v.revertLane,
            gesture: v.gesture,
            action: v.action,
            hasEagerState: v.hasEagerState,
            eagerState: v.eagerState,
            next: null
          }, r === null ? (f = r = y, u = i) : r = r.next = y, P.lanes |= E, oa |= E;
        v = v.next;
      } while (v !== null && v !== e);
      if (r === null ? u = i : r.next = f, !Be(i, t.memoizedState) && (Kt = !0, S && (l = yn, l !== null)))
        throw l;
      t.memoizedState = i, t.baseState = u, t.baseQueue = r, a.lastRenderedState = i;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function ic(t) {
    var e = Lt(), l = e.queue;
    if (l === null) throw Error(b(311));
    l.lastRenderedReducer = t;
    var a = l.dispatch, n = l.pending, i = e.memoizedState;
    if (n !== null) {
      l.pending = null;
      var u = n = n.next;
      do
        i = t(i, u.action), u = u.next;
      while (u !== n);
      Be(i, e.memoizedState) || (Kt = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function vr(t, e, l) {
    var a = P, n = Lt(), i = ft;
    if (i) {
      if (l === void 0) throw Error(b(407));
      l = l();
    } else l = e();
    var u = !Be(
      (St || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, Kt = !0), n = n.queue, cc(xr.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || Zt !== null && Zt.memoizedState.tag & 1) {
      if (a.flags |= 2048, Mn(
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
      ), Mt === null) throw Error(b(349));
      i || (Ul & 127) !== 0 || yr(a, e, l);
    }
    return l;
  }
  function yr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = P.updateQueue, e === null ? (e = Eu(), P.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
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
      return !Be(t, l);
    } catch {
      return !0;
    }
  }
  function Tr(t) {
    var e = qa(t, 2);
    e !== null && _e(e, t, 2);
  }
  function uc(t) {
    var e = xe();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Ja) {
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
      lastRenderedReducer: Bl,
      lastRenderedState: t
    }, e;
  }
  function zr(t, e, l, a) {
    return t.baseState = l, nc(
      t,
      St,
      typeof a == "function" ? a : Bl
    );
  }
  function Lm(t, e, l, a, n) {
    if (Cu(t)) throw Error(b(485));
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
        var f = l(n, a), r = m.S;
        r !== null && r(u, f), Er(t, e, f);
      } catch (v) {
        fc(t, e, v);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), m.T = i;
      }
    } else
      try {
        i = l(n, a), Er(t, e, i);
      } catch (v) {
        fc(t, e, v);
      }
  }
  function Er(t, e, l) {
    l !== null && typeof l == "object" && typeof l.then == "function" ? l.then(
      function(a) {
        Ar(t, e, a);
      },
      function(a) {
        return fc(t, e, a);
      }
    ) : Ar(t, e, l);
  }
  function Ar(t, e, l) {
    e.status = "fulfilled", e.value = l, _r(e), t.state = l, e = t.pending, e !== null && (l = e.next, l === e ? t.pending = null : (l = l.next, e.next = l, Mr(t, l)));
  }
  function fc(t, e, l) {
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
    if (ft) {
      var l = Mt.formState;
      if (l !== null) {
        t: {
          var a = P;
          if (ft) {
            if (_t) {
              e: {
                for (var n = _t, i = ke; n.nodeType !== 8; ) {
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
    return l = xe(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Dr,
      lastRenderedState: e
    }, l.queue = a, l = kr.bind(
      null,
      P,
      a
    ), a.dispatch = l, a = uc(!1), i = mc.bind(
      null,
      P,
      !1,
      a.queue
    ), a = xe(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = Lm.bind(
      null,
      P,
      n,
      i,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Cr(t) {
    var e = Lt();
    return Ur(e, St, t);
  }
  function Ur(t, e, l) {
    if (e = nc(
      t,
      e,
      Dr
    )[0], t = _u(Bl)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = pi(e);
      } catch (u) {
        throw u === bn ? vu : u;
      }
    else a = e;
    e = Lt();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (P.flags |= 2048, Mn(
      9,
      { destroy: void 0 },
      Xm.bind(null, n, l),
      null
    )), [a, i, t];
  }
  function Xm(t, e) {
    t.action = e;
  }
  function Br(t) {
    var e = Lt(), l = St;
    if (l !== null)
      return Ur(e, l, t);
    Lt(), e = e.memoizedState, l = Lt();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function Mn(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = P.updateQueue, e === null && (e = Eu(), P.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Nr() {
    return Lt().memoizedState;
  }
  function Du(t, e, l, a) {
    var n = xe();
    P.flags |= t, n.memoizedState = Mn(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Ou(t, e, l, a) {
    var n = Lt();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    St !== null && a !== null && If(a, St.memoizedState.deps) ? n.memoizedState = Mn(e, i, l, a) : (P.flags |= t, n.memoizedState = Mn(
      1 | e,
      i,
      l,
      a
    ));
  }
  function Rr(t, e) {
    Du(8390656, 8, t, e);
  }
  function cc(t, e) {
    Ou(2048, 8, t, e);
  }
  function Qm(t) {
    P.flags |= 4;
    var e = P.updateQueue;
    if (e === null)
      e = Eu(), P.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function Hr(t) {
    var e = Lt().memoizedState;
    return Qm({ ref: e, nextImpl: t }), function() {
      if ((pt & 2) !== 0) throw Error(b(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function wr(t, e) {
    return Ou(4, 2, t, e);
  }
  function jr(t, e) {
    return Ou(4, 4, t, e);
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
  function Yr(t, e, l) {
    l = l != null ? l.concat([t]) : null, Ou(4, 4, qr.bind(null, e, t), l);
  }
  function oc() {
  }
  function Gr(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && If(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Lr(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && If(e, a[1]))
      return a[0];
    if (a = t(), Ja) {
      il(!0);
      try {
        t();
      } finally {
        il(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function rc(t, e, l) {
    return l === void 0 || (Ul & 1073741824) !== 0 && (it & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Xs(), P.lanes |= t, oa |= t, l);
  }
  function Xr(t, e, l, a) {
    return Be(l, e) ? l : Sn.current !== null ? (t = rc(t, l, a), Be(t, e) || (Kt = !0), t) : (Ul & 42) === 0 || (Ul & 1073741824) !== 0 && (it & 261930) === 0 ? (Kt = !0, t.memoizedState = l) : (t = Xs(), P.lanes |= t, oa |= t, e);
  }
  function Qr(t, e, l, a, n) {
    var i = D.p;
    D.p = i !== 0 && 8 > i ? i : 8;
    var u = m.T, f = {};
    m.T = f, mc(t, !1, e, l);
    try {
      var r = n(), v = m.S;
      if (v !== null && v(f, r), r !== null && typeof r == "object" && typeof r.then == "function") {
        var S = qm(
          r,
          a
        );
        vi(
          t,
          e,
          S,
          qe(t)
        );
      } else
        vi(
          t,
          e,
          a,
          qe(t)
        );
    } catch (E) {
      vi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: E },
        qe()
      );
    } finally {
      D.p = i, u !== null && f.types !== null && (u.types = f.types), m.T = u;
    }
  }
  function Vm() {
  }
  function sc(t, e, l, a) {
    if (t.tag !== 5) throw Error(b(476));
    var n = Vr(t).queue;
    Qr(
      t,
      n,
      e,
      Y,
      l === null ? Vm : function() {
        return Zr(t), l(a);
      }
    );
  }
  function Vr(t) {
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
  function Zr(t) {
    var e = Vr(t);
    e.next === null && (e = t.alternate.memoizedState), vi(
      t,
      e.next.queue,
      {},
      qe()
    );
  }
  function dc() {
    return ne(Ri);
  }
  function Kr() {
    return Lt().memoizedState;
  }
  function Jr() {
    return Lt().memoizedState;
  }
  function Zm(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = qe();
          t = aa(l);
          var a = na(e, t, l);
          a !== null && (_e(a, e, l), di(a, e, l)), e = { cache: Lf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function Km(t, e, l) {
    var a = qe();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Cu(t) ? Fr(e, l) : (l = Cf(t, e, l, a), l !== null && (_e(l, t, a), Wr(l, e, a)));
  }
  function kr(t, e, l) {
    var a = qe();
    vi(t, e, l, a);
  }
  function vi(t, e, l, a) {
    var n = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    };
    if (Cu(t)) Fr(e, n);
    else {
      var i = t.alternate;
      if (t.lanes === 0 && (i === null || i.lanes === 0) && (i = e.lastRenderedReducer, i !== null))
        try {
          var u = e.lastRenderedState, f = i(u, l);
          if (n.hasEagerState = !0, n.eagerState = f, Be(f, u))
            return ru(t, e, n, 0), Mt === null && ou(), !1;
        } catch {
        }
      if (l = Cf(t, e, n, a), l !== null)
        return _e(l, t, a), Wr(l, e, a), !0;
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
    }, Cu(t)) {
      if (e) throw Error(b(479));
    } else
      e = Cf(
        t,
        l,
        a,
        2
      ), e !== null && _e(e, t, 2);
  }
  function Cu(t) {
    var e = t.alternate;
    return t === P || e !== null && e === P;
  }
  function Fr(t, e) {
    Tn = zu = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function Wr(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Xn(t, l);
    }
  }
  var yi = {
    readContext: ne,
    use: Au,
    useCallback: wt,
    useContext: wt,
    useEffect: wt,
    useImperativeHandle: wt,
    useLayoutEffect: wt,
    useInsertionEffect: wt,
    useMemo: wt,
    useReducer: wt,
    useRef: wt,
    useState: wt,
    useDebugValue: wt,
    useDeferredValue: wt,
    useTransition: wt,
    useSyncExternalStore: wt,
    useId: wt,
    useHostTransitionStatus: wt,
    useFormState: wt,
    useActionState: wt,
    useOptimistic: wt,
    useMemoCache: wt,
    useCacheRefresh: wt
  };
  yi.useEffectEvent = wt;
  var $r = {
    readContext: ne,
    use: Au,
    useCallback: function(t, e) {
      return xe().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: ne,
    useEffect: Rr,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, Du(
        4194308,
        4,
        qr.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return Du(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      Du(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = xe();
      e = e === void 0 ? null : e;
      var a = t();
      if (Ja) {
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
      var a = xe();
      if (l !== void 0) {
        var n = l(e);
        if (Ja) {
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
      }, a.queue = t, t = t.dispatch = Km.bind(
        null,
        P,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = xe();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = uc(t);
      var e = t.queue, l = kr.bind(null, P, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = xe();
      return rc(l, t, e);
    },
    useTransition: function() {
      var t = uc(!1);
      return t = Qr.bind(
        null,
        P,
        t.queue,
        !0,
        !1
      ), xe().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = P, n = xe();
      if (ft) {
        if (l === void 0)
          throw Error(b(407));
        l = l();
      } else {
        if (l = e(), Mt === null)
          throw Error(b(349));
        (it & 127) !== 0 || yr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, Rr(xr.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, Mn(
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
      var t = xe(), e = Mt.identifierPrefix;
      if (ft) {
        var l = dl, a = sl;
        l = (a & ~(1 << 32 - pe(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = Mu++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Ym++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: dc,
    useFormState: Or,
    useActionState: Or,
    useOptimistic: function(t) {
      var e = xe();
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
        P,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: ac,
    useCacheRefresh: function() {
      return xe().memoizedState = Zm.bind(
        null,
        P
      );
    },
    useEffectEvent: function(t) {
      var e = xe(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((pt & 2) !== 0)
          throw Error(b(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, hc = {
    readContext: ne,
    use: Au,
    useCallback: Gr,
    useContext: ne,
    useEffect: cc,
    useImperativeHandle: Yr,
    useInsertionEffect: wr,
    useLayoutEffect: jr,
    useMemo: Lr,
    useReducer: _u,
    useRef: Nr,
    useState: function() {
      return _u(Bl);
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return Xr(
        l,
        St.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = _u(Bl)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : pi(t),
        e
      ];
    },
    useSyncExternalStore: vr,
    useId: Kr,
    useHostTransitionStatus: dc,
    useFormState: Cr,
    useActionState: Cr,
    useOptimistic: function(t, e) {
      var l = Lt();
      return zr(l, St, t, e);
    },
    useMemoCache: ac,
    useCacheRefresh: Jr
  };
  hc.useEffectEvent = Hr;
  var Ir = {
    readContext: ne,
    use: Au,
    useCallback: Gr,
    useContext: ne,
    useEffect: cc,
    useImperativeHandle: Yr,
    useInsertionEffect: wr,
    useLayoutEffect: jr,
    useMemo: Lr,
    useReducer: ic,
    useRef: Nr,
    useState: function() {
      return ic(Bl);
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return St === null ? rc(l, t, e) : Xr(
        l,
        St.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = ic(Bl)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : pi(t),
        e
      ];
    },
    useSyncExternalStore: vr,
    useId: Kr,
    useHostTransitionStatus: dc,
    useFormState: Br,
    useActionState: Br,
    useOptimistic: function(t, e) {
      var l = Lt();
      return St !== null ? zr(l, St, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ac,
    useCacheRefresh: Jr
  };
  Ir.useEffectEvent = Hr;
  function gc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : X({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var pc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = qe(), n = aa(a);
      n.payload = e, l != null && (n.callback = l), e = na(t, n, a), e !== null && (_e(e, t, a), di(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = qe(), n = aa(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = na(t, n, a), e !== null && (_e(e, t, a), di(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = qe(), a = aa(l);
      a.tag = 2, e != null && (a.callback = e), e = na(t, a, l), e !== null && (_e(e, t, l), di(e, t, l));
    }
  };
  function Pr(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ni(l, a) || !ni(n, i) : !0;
  }
  function ts(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && pc.enqueueReplaceState(e, e.state, null);
  }
  function ka(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = X({}, l));
      for (var n in t)
        l[n] === void 0 && (l[n] = t[n]);
    }
    return l;
  }
  function es(t) {
    cu(t);
  }
  function ls(t) {
    console.error(t);
  }
  function as(t) {
    cu(t);
  }
  function Uu(t, e) {
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
  function vc(t, e, l) {
    return l = aa(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Uu(t, e);
    }, l;
  }
  function is(t) {
    return t = aa(t), t.tag = 3, t;
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
      ns(e, l, a), typeof n != "function" && (ra === null ? ra = /* @__PURE__ */ new Set([this]) : ra.add(this));
      var f = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: f !== null ? f : ""
      });
    });
  }
  function Jm(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && pn(
        e,
        l,
        n,
        !0
      ), l = Re.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return Fe === null ? Qu() : l.alternate === null && jt === 0 && (jt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === yu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Xc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === yu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Xc(t, a, n)), !1;
        }
        throw Error(b(435, l.tag));
      }
      return Xc(t, a, n), Qu(), !1;
    }
    if (ft)
      return e = Re.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== wf && (t = Error(b(422), { cause: a }), fi(Ze(t, l)))) : (a !== wf && (e = Error(b(423), {
        cause: a
      }), fi(
        Ze(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ze(a, l), n = vc(
        t.stateNode,
        a,
        n
      ), Jf(t, n), jt !== 4 && (jt = 2)), !1;
    var i = Error(b(520), { cause: a });
    if (i = Ze(i, l), Ai === null ? Ai = [i] : Ai.push(i), jt !== 4 && (jt = 2), e === null) return !0;
    a = Ze(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = vc(l.stateNode, a, t), Jf(l, t), !1;
        case 1:
          if (e = l.type, i = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || i !== null && typeof i.componentDidCatch == "function" && (ra === null || !ra.has(i))))
            return l.flags |= 65536, n &= -n, l.lanes |= n, n = is(n), us(
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
  var yc = Error(b(461)), Kt = !1;
  function ie(t, e, l, a) {
    e.child = t === null ? rr(e, null, l, a) : Ka(
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
    return Xa(e), a = Pf(
      t,
      e,
      l,
      u,
      i,
      n
    ), f = tc(), t !== null && !Kt ? (ec(t, e, n), Nl(t, e, n)) : (ft && f && Rf(e), e.flags |= 1, ie(t, e, a, n), e.child);
  }
  function cs(t, e, l, a, n) {
    if (t === null) {
      var i = l.type;
      return typeof i == "function" && !Uf(i) && i.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = i, os(
        t,
        e,
        i,
        a,
        n
      )) : (t = du(
        l.type,
        null,
        a,
        e,
        e.mode,
        n
      ), t.ref = e.ref, t.return = e, e.child = t);
    }
    if (i = t.child, !Ac(t, n)) {
      var u = i.memoizedProps;
      if (l = l.compare, l = l !== null ? l : ni, l(u, a) && t.ref === e.ref)
        return Nl(t, e, n);
    }
    return e.flags |= 1, t = _l(i, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function os(t, e, l, a, n) {
    if (t !== null) {
      var i = t.memoizedProps;
      if (ni(i, a) && t.ref === e.ref)
        if (Kt = !1, e.pendingProps = a = i, Ac(t, n))
          (t.flags & 131072) !== 0 && (Kt = !0);
        else
          return e.lanes = t.lanes, Nl(t, e, n);
    }
    return bc(
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
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && pu(
          e,
          i !== null ? i.cachePool : null
        ), i !== null ? mr(e, i) : Ff(), hr(e);
      else
        return a = e.lanes = 536870912, ss(
          t,
          e,
          i !== null ? i.baseLanes | l : l,
          l,
          a
        );
    } else
      i !== null ? (pu(e, i.cachePool), mr(e, i), ua(), e.memoizedState = null) : (t !== null && pu(e, null), Ff(), ua());
    return ie(t, e, n, l), e.child;
  }
  function bi(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function ss(t, e, l, a, n) {
    var i = Qf();
    return i = i === null ? null : { parent: Vt._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && pu(e, null), Ff(), hr(e), t !== null && pn(t, e, a, !0), e.childLanes = n, null;
  }
  function Bu(t, e) {
    return e = Ru(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function ds(t, e, l) {
    return Ka(e, t.child, null, l), t = Bu(e, e.pendingProps), t.flags |= 2, He(e), e.memoizedState = null, t;
  }
  function km(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (ft) {
        if (a.mode === "hidden")
          return t = Bu(e, a), e.lanes = 536870912, bi(null, t);
        if ($f(e), (t = _t) ? (t = Md(
          t,
          ke
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Il !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ae = e, _t = null)) : t = null, t === null) throw ta(e);
        return e.lanes = 536870912, null;
      }
      return Bu(e, a);
    }
    var i = t.memoizedState;
    if (i !== null) {
      var u = i.dehydrated;
      if ($f(e), n)
        if (e.flags & 256)
          e.flags &= -257, e = ds(
            t,
            e,
            l
          );
        else if (e.memoizedState !== null)
          e.child = t.child, e.flags |= 128, e = null;
        else throw Error(b(558));
      else if (Kt || pn(t, e, l, !1), n = (l & t.childLanes) !== 0, Kt || n) {
        if (a = Mt, a !== null && (u = Fi(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, qa(t, u), _e(a, t, u), yc;
        Qu(), e = ds(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, _t = We(u.nextSibling), ae = e, ft = !0, Pl = null, ke = !1, t !== null && Io(e, t), e = Bu(e, a), e.flags |= 4096;
      return e;
    }
    return t = _l(t.child, {
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
    ), a = tc(), t !== null && !Kt ? (ec(t, e, n), Nl(t, e, n)) : (ft && a && Rf(e), e.flags |= 1, ie(t, e, l, n), e.child);
  }
  function ms(t, e, l, a, n, i) {
    return Xa(e), e.updateQueue = null, l = pr(
      e,
      a,
      l,
      n
    ), gr(t), a = tc(), t !== null && !Kt ? (ec(t, e, i), Nl(t, e, i)) : (ft && a && Rf(e), e.flags |= 1, ie(t, e, l, i), e.child);
  }
  function hs(t, e, l, a, n) {
    if (Xa(e), e.stateNode === null) {
      var i = dn, u = l.contextType;
      typeof u == "object" && u !== null && (i = ne(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = pc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Zf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? ne(u) : dn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (gc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && pc.enqueueReplaceState(i, i.state, null), hi(e, a, i, n), mi(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var f = e.memoizedProps, r = ka(l, f);
      i.props = r;
      var v = i.context, S = l.contextType;
      u = dn, typeof S == "object" && S !== null && (u = ne(S));
      var E = l.getDerivedStateFromProps;
      S = typeof E == "function" || typeof i.getSnapshotBeforeUpdate == "function", f = e.pendingProps !== f, S || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (f || v !== u) && ts(
        e,
        i,
        a,
        u
      ), la = !1;
      var y = e.memoizedState;
      i.state = y, hi(e, a, i, n), mi(), v = e.memoizedState, f || y !== v || la ? (typeof E == "function" && (gc(
        e,
        l,
        E,
        a
      ), v = e.memoizedState), (r = la || Pr(
        e,
        l,
        r,
        a,
        y,
        v,
        u
      )) ? (S || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = v), i.props = a, i.state = v, i.context = u, a = r) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, Kf(t, e), u = e.memoizedProps, S = ka(l, u), i.props = S, E = e.pendingProps, y = i.context, v = l.contextType, r = dn, typeof v == "object" && v !== null && (r = ne(v)), f = l.getDerivedStateFromProps, (v = typeof f == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== E || y !== r) && ts(
        e,
        i,
        a,
        r
      ), la = !1, y = e.memoizedState, i.state = y, hi(e, a, i, n), mi();
      var x = e.memoizedState;
      u !== E || y !== x || la || t !== null && t.dependencies !== null && hu(t.dependencies) ? (typeof f == "function" && (gc(
        e,
        l,
        f,
        a
      ), x = e.memoizedState), (S = la || Pr(
        e,
        l,
        S,
        a,
        y,
        x,
        r
      ) || t !== null && t.dependencies !== null && hu(t.dependencies)) ? (v || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, x, r), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        x,
        r
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = x), i.props = a, i.state = x, i.context = r, a = S) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return i = a, Nu(t, e), a = (e.flags & 128) !== 0, i || a ? (i = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : i.render(), e.flags |= 1, t !== null && a ? (e.child = Ka(
      e,
      t.child,
      null,
      n
    ), e.child = Ka(
      e,
      null,
      l,
      n
    )) : ie(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = Nl(
      t,
      e,
      n
    ), t;
  }
  function gs(t, e, l, a) {
    return Ga(), e.flags |= 256, ie(t, e, l, a), e.child;
  }
  var xc = {
    dehydrated: null,
    treeContext: null,
    retryLane: 0,
    hydrationErrors: null
  };
  function Sc(t) {
    return { baseLanes: t, cachePool: nr() };
  }
  function Tc(t, e, l) {
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= je), t;
  }
  function ps(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : (Gt.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (ft) {
        if (n ? ia(e) : ua(), (t = _t) ? (t = Md(
          t,
          ke
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Il !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ae = e, _t = null)) : t = null, t === null) throw ta(e);
        return no(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var f = a.children;
      return a = a.fallback, n ? (ua(), n = e.mode, f = Ru(
        { mode: "hidden", children: f },
        n
      ), a = Ya(
        a,
        n,
        l,
        null
      ), f.return = e, a.return = e, f.sibling = a, e.child = f, a = e.child, a.memoizedState = Sc(l), a.childLanes = Tc(
        t,
        u,
        l
      ), e.memoizedState = xc, bi(null, a)) : (ia(e), zc(e, f));
    }
    var r = t.memoizedState;
    if (r !== null && (f = r.dehydrated, f !== null)) {
      if (i)
        e.flags & 256 ? (ia(e), e.flags &= -257, e = Mc(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (ua(), e.child = t.child, e.flags |= 128, e = null) : (ua(), f = a.fallback, n = e.mode, a = Ru(
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
        ), a = e.child, a.memoizedState = Sc(l), a.childLanes = Tc(
          t,
          u,
          l
        ), e.memoizedState = xc, e = bi(null, a));
      else if (ia(e), no(f)) {
        if (u = f.nextSibling && f.nextSibling.dataset, u) var v = u.dgst;
        u = v, a = Error(b(419)), a.stack = "", a.digest = u, fi({ value: a, source: null, stack: null }), e = Mc(
          t,
          e,
          l
        );
      } else if (Kt || pn(t, e, l, !1), u = (l & t.childLanes) !== 0, Kt || u) {
        if (u = Mt, u !== null && (a = Fi(u, l), a !== 0 && a !== r.retryLane))
          throw r.retryLane = a, qa(t, a), _e(u, t, a), yc;
        ao(f) || Qu(), e = Mc(
          t,
          e,
          l
        );
      } else
        ao(f) ? (e.flags |= 192, e.child = t.child, e = null) : (t = r.treeContext, _t = We(
          f.nextSibling
        ), ae = e, ft = !0, Pl = null, ke = !1, t !== null && Io(e, t), e = zc(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (ua(), f = a.fallback, n = e.mode, r = t.child, v = r.sibling, a = _l(r, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = r.subtreeFlags & 65011712, v !== null ? f = _l(
      v,
      f
    ) : (f = Ya(
      f,
      n,
      l,
      null
    ), f.flags |= 2), f.return = e, a.return = e, a.sibling = f, e.child = a, bi(null, a), a = e.child, f = t.child.memoizedState, f === null ? f = Sc(l) : (n = f.cachePool, n !== null ? (r = Vt._currentValue, n = n.parent !== r ? { parent: r, pool: r } : n) : n = nr(), f = {
      baseLanes: f.baseLanes | l,
      cachePool: n
    }), a.memoizedState = f, a.childLanes = Tc(
      t,
      u,
      l
    ), e.memoizedState = xc, bi(t.child, a)) : (ia(e), l = t.child, t = l.sibling, l = _l(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function zc(t, e) {
    return e = Ru(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Ru(t, e) {
    return t = Ne(22, t, null, e), t.lanes = 0, t;
  }
  function Mc(t, e, l) {
    return Ka(e, t.child, null, l), t = zc(
      e,
      e.pendingProps.children
    ), t.flags |= 2, e.memoizedState = null, t;
  }
  function vs(t, e, l) {
    t.lanes |= e;
    var a = t.alternate;
    a !== null && (a.lanes |= e), Yf(t.return, e, l);
  }
  function Ec(t, e, l, a, n, i) {
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
  function ys(t, e, l) {
    var a = e.pendingProps, n = a.revealOrder, i = a.tail;
    a = a.children;
    var u = Gt.current, f = (u & 2) !== 0;
    if (f ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, B(Gt, u), ie(t, e, a, l), a = ft ? ui : 0, !f && t !== null && (t.flags & 128) !== 0)
      t: for (t = e.child; t !== null; ) {
        if (t.tag === 13)
          t.memoizedState !== null && vs(t, l, e);
        else if (t.tag === 19)
          vs(t, l, e);
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
          t = l.alternate, t !== null && Tu(t) === null && (n = l), l = l.sibling;
        l = n, l === null ? (n = e.child, e.child = null) : (n = l.sibling, l.sibling = null), Ec(
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
          if (t = n.alternate, t !== null && Tu(t) === null) {
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
          i,
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
  function Nl(t, e, l) {
    if (t !== null && (e.dependencies = t.dependencies), oa |= e.lanes, (l & e.childLanes) === 0)
      if (t !== null) {
        if (pn(
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
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && hu(t)));
  }
  function Fm(t, e, l) {
    switch (e.tag) {
      case 3:
        $t(e, e.stateNode.containerInfo), ea(e, Vt, t.memoizedState.cache), Ga();
        break;
      case 27:
      case 5:
        gl(e);
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
          return a.dehydrated !== null ? (ia(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? ps(t, e, l) : (ia(e), t = Nl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        ia(e);
        break;
      case 19:
        var n = (t.flags & 128) !== 0;
        if (a = (l & e.childLanes) !== 0, a || (pn(
          t,
          e,
          l,
          !1
        ), a = (l & e.childLanes) !== 0), n) {
          if (a)
            return ys(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), B(Gt, Gt.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, rs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        ea(e, Vt, t.memoizedState.cache);
    }
    return Nl(t, e, l);
  }
  function bs(t, e, l) {
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
      Kt = !1, ft && (e.flags & 1048576) !== 0 && $o(e, ui, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = Va(e.elementType), e.type = t, typeof t == "function")
            Uf(t) ? (a = ka(t, a), e.tag = 1, e = hs(
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
                e.tag = 11, e = fs(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === et) {
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
          ), t === null) throw Error(b(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, Kf(t, e), hi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, ea(e, Vt, a), a !== i.cache && Gf(
            e,
            [Vt],
            l,
            !0
          ), mi(), a = u.element, i.isDehydrated)
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
              n = Ze(
                Error(b(424)),
                e
              ), fi(n), e = gs(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, _t = We(t.firstChild), ae = e, ft = !0, Pl = null, ke = !0, l = rr(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (Ga(), a === n) {
              e = Nl(
                t,
                e,
                l
              );
              break t;
            }
            ie(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Nu(t, e), t === null ? (l = Cd(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : ft || (l = e.type, t = e.pendingProps, a = Wu(
          $.current
        ).createElement(l), a[Qt] = e, a[se] = t, ue(a, l, t), Yt(a), e.stateNode = a) : e.memoizedState = Cd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return gl(e), t === null && ft && (a = e.stateNode = _d(
          e.type,
          e.pendingProps,
          $.current
        ), ae = e, ke = !0, n = _t, ha(e.type) ? (io = n, _t = We(a.firstChild)) : _t = n), ie(
          t,
          e,
          e.pendingProps.children,
          l
        ), Nu(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && ft && ((n = a = _t) && (a = Eh(
          a,
          e.type,
          e.pendingProps,
          ke
        ), a !== null ? (e.stateNode = a, ae = e, _t = We(a.firstChild), ke = !1, n = !0) : n = !1), n || ta(e)), gl(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, to(n, i) ? a = null : u !== null && to(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = Pf(
          t,
          e,
          Gm,
          null,
          null,
          l
        ), Ri._currentValue = n), Nu(t, e), ie(t, e, a, l), e.child;
      case 6:
        return t === null && ft && ((t = l = _t) && (l = Ah(
          l,
          e.pendingProps,
          ke
        ), l !== null ? (e.stateNode = l, ae = e, _t = null, t = !0) : t = !1), t || ta(e)), null;
      case 13:
        return ps(t, e, l);
      case 4:
        return $t(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = Ka(
          e,
          null,
          a,
          l
        ) : ie(t, e, a, l), e.child;
      case 11:
        return fs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return ie(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return ie(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return ie(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, ea(e, e.type, a.value), ie(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, Xa(e), n = ne(n), a = a(n), e.flags |= 1, ie(t, e, a, l), e.child;
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
        return ys(t, e, l);
      case 31:
        return km(t, e, l);
      case 22:
        return rs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return Xa(e), a = ne(Vt), t === null ? (n = Qf(), n === null && (n = Mt, i = Lf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Zf(e), ea(e, Vt, n)) : ((t.lanes & l) !== 0 && (Kf(t, e), hi(e, null, null, l), mi()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), ea(e, Vt, a)) : (a = i.cache, ea(e, Vt, a), a !== n.cache && Gf(
          e,
          [Vt],
          l,
          !0
        ))), ie(
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
  function Rl(t) {
    t.flags |= 4;
  }
  function _c(t, e, l, a, n) {
    if ((e = (t.mode & 32) !== 0) && (e = !1), e) {
      if (t.flags |= 16777216, (n & 335544128) === n)
        if (t.stateNode.complete) t.flags |= 8192;
        else if (Ks()) t.flags |= 8192;
        else
          throw Za = yu, Vf;
    } else t.flags &= -16777217;
  }
  function xs(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !Hd(e))
      if (Ks()) t.flags |= 8192;
      else
        throw Za = yu, Vf;
  }
  function Hu(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? ki() : 536870912, t.lanes |= e, Dn |= e);
  }
  function xi(t, e) {
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
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), Cl(Vt), yt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (gn(e) ? Rl(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, jf())), Dt(e), null;
      case 26:
        var n = e.type, i = e.memoizedState;
        return t === null ? (Rl(e), i !== null ? (Dt(e), xs(e, i)) : (Dt(e), _c(
          e,
          n,
          null,
          a,
          l
        ))) : i ? i !== t.memoizedState ? (Rl(e), Dt(e), xs(e, i)) : (Dt(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Rl(e), Dt(e), _c(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if (Xe(e), l = $.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Rl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(b(166));
            return Dt(e), null;
          }
          t = H.current, gn(e) ? Po(e) : (t = _d(n, a, l), e.stateNode = t, Rl(e));
        }
        return Dt(e), null;
      case 5:
        if (Xe(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Rl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(b(166));
            return Dt(e), null;
          }
          if (i = H.current, gn(e))
            Po(e);
          else {
            var u = Wu(
              $.current
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
            i[Qt] = e, i[se] = a;
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
            t: switch (ue(i, n, a), n) {
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
            a && Rl(e);
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
          t.memoizedProps !== a && Rl(e);
        else {
          if (typeof a != "string" && e.stateNode === null)
            throw Error(b(166));
          if (t = $.current, gn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = ae, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[Qt] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || pd(t.nodeValue, l)), t || ta(e, !0);
          } else
            t = Wu(t).createTextNode(
              a
            ), t[Qt] = e, e.stateNode = t;
        }
        return Dt(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = gn(e), l !== null) {
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
          if (n = gn(e), a !== null && a.dehydrated !== null) {
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
        return He(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Hu(e, e.updateQueue), Dt(e), null);
      case 4:
        return yt(), t === null && Fc(e.stateNode.containerInfo), Dt(e), null;
      case 10:
        return Cl(e.type), Dt(e), null;
      case 19:
        if (M(Gt), a = e.memoizedState, a === null) return Dt(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) xi(a, !1);
          else {
            if (jt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = Tu(t), i !== null) {
                  for (e.flags |= 128, xi(a, !1), t = i.updateQueue, e.updateQueue = t, Hu(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    ko(l, t), l = l.sibling;
                  return B(
                    Gt,
                    Gt.current & 1 | 2
                  ), ft && Dl(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && le() > Gu && (e.flags |= 128, n = !0, xi(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = Tu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Hu(e, t), xi(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !ft)
                return Dt(e), null;
            } else
              2 * le() - a.renderingStartTime > Gu && l !== 536870912 && (e.flags |= 128, n = !0, xi(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = le(), t.sibling = null, l = Gt.current, B(
          Gt,
          n ? l & 1 | 2 : l & 1
        ), ft && Dl(e, a.treeForkCount), t) : (Dt(e), null);
      case 22:
      case 23:
        return He(e), Wf(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Dt(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Dt(e), l = e.updateQueue, l !== null && Hu(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && M(Qa), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), Cl(Vt), Dt(e), null;
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
        return Cl(Vt), yt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
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
        return yt(), null;
      case 10:
        return Cl(e.type), null;
      case 22:
      case 23:
        return He(e), Wf(), t !== null && M(Qa), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return Cl(Vt), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function Ss(t, e) {
    switch (Hf(e), e.tag) {
      case 3:
        Cl(Vt), yt();
        break;
      case 26:
      case 27:
      case 5:
        Xe(e);
        break;
      case 4:
        yt();
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
        Cl(e.type);
        break;
      case 22:
      case 23:
        He(e), Wf(), t !== null && M(Qa);
        break;
      case 24:
        Cl(Vt);
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
    } catch (f) {
      xt(e, e.return, f);
    }
  }
  function fa(t, e, l) {
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
              var r = l, v = f;
              try {
                v();
              } catch (S) {
                xt(
                  n,
                  r,
                  S
                );
              }
            }
          }
          a = a.next;
        } while (a !== i);
      }
    } catch (S) {
      xt(e, e.return, S);
    }
  }
  function Ts(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        dr(e, l);
      } catch (a) {
        xt(t, t.return, a);
      }
    }
  }
  function zs(t, e, l) {
    l.props = ka(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      xt(t, e, a);
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
      xt(t, e, n);
    }
  }
  function ml(t, e) {
    var l = t.ref, a = t.refCleanup;
    if (l !== null)
      if (typeof a == "function")
        try {
          a();
        } catch (n) {
          xt(t, e, n);
        } finally {
          t.refCleanup = null, t = t.alternate, t != null && (t.refCleanup = null);
        }
      else if (typeof l == "function")
        try {
          l(null);
        } catch (n) {
          xt(t, e, n);
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
      xt(t, t.return, n);
    }
  }
  function Dc(t, e, l) {
    try {
      var a = t.stateNode;
      bh(a, t.type, l, e), a[se] = e;
    } catch (n) {
      xt(t, t.return, n);
    }
  }
  function Es(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && ha(t.type) || t.tag === 4;
  }
  function Oc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || Es(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && ha(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Cc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = de));
    else if (a !== 4 && (a === 27 && ha(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Cc(t, e, l), t = t.sibling; t !== null; )
        Cc(t, e, l), t = t.sibling;
  }
  function wu(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && ha(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (wu(t, e, l), t = t.sibling; t !== null; )
        wu(t, e, l), t = t.sibling;
  }
  function As(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      ue(e, a, l), e[Qt] = t, e[se] = l;
    } catch (i) {
      xt(t, t.return, i);
    }
  }
  var Hl = !1, Jt = !1, Uc = !1, _s = typeof WeakSet == "function" ? WeakSet : Set, It = null;
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
            var n = a.anchorOffset, i = a.focusNode;
            a = a.focusOffset;
            try {
              l.nodeType, i.nodeType;
            } catch {
              l = null;
              break t;
            }
            var u = 0, f = -1, r = -1, v = 0, S = 0, E = t, y = null;
            e: for (; ; ) {
              for (var x; E !== l || n !== 0 && E.nodeType !== 3 || (f = u + n), E !== i || a !== 0 && E.nodeType !== 3 || (r = u + a), E.nodeType === 3 && (u += E.nodeValue.length), (x = E.firstChild) !== null; )
                y = E, E = x;
              for (; ; ) {
                if (E === t) break e;
                if (y === l && ++v === n && (f = u), y === i && ++S === a && (r = u), (x = E.nextSibling) !== null) break;
                E = y, y = E.parentNode;
              }
              E = x;
            }
            l = f === -1 || r === -1 ? null : { start: f, end: r };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (Pc = { focusedElem: t, selectionRange: l }, af = !1, It = e; It !== null; )
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
                  var j = ka(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    j,
                    i
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch (Z) {
                  xt(
                    l,
                    l.return,
                    Z
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
  function Ds(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        jl(t, l), a & 4 && Si(5, l);
        break;
      case 1:
        if (jl(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              xt(l, l.return, u);
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
            } catch (u) {
              xt(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && Ts(l), a & 512 && Ti(l, l.return);
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
            dr(t, e);
          } catch (u) {
            xt(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && As(l);
      case 26:
      case 5:
        jl(t, l), e === null && a & 4 && Ms(l), a & 512 && Ti(l, l.return);
        break;
      case 12:
        jl(t, l);
        break;
      case 31:
        jl(t, l), a & 4 && Us(t, l);
        break;
      case 13:
        jl(t, l), a & 4 && Bs(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = fh.bind(
          null,
          l
        ), _h(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Hl, !a) {
          e = e !== null && e.memoizedState !== null || Jt, n = Hl;
          var i = Jt;
          Hl = a, (Jt = e) && !i ? ql(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : jl(t, l), Hl = n, Jt = i;
        }
        break;
      case 30:
        break;
      default:
        jl(t, l);
    }
  }
  function Os(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Os(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && Qn(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Ut = null, ze = !1;
  function wl(t, e, l) {
    for (l = l.child; l !== null; )
      Cs(t, e, l), l = l.sibling;
  }
  function Cs(t, e, l) {
    if (ge && typeof ge.onCommitFiberUnmount == "function")
      try {
        ge.onCommitFiberUnmount(Ta, l);
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
        var a = Ut, n = ze;
        ha(l.type) && (Ut = l.stateNode, ze = !1), wl(
          t,
          e,
          l
        ), Ui(l.stateNode), Ut = a, ze = n;
        break;
      case 5:
        Jt || ml(l, e);
      case 6:
        if (a = Ut, n = ze, Ut = null, wl(
          t,
          e,
          l
        ), Ut = a, ze = n, Ut !== null)
          if (ze)
            try {
              (Ut.nodeType === 9 ? Ut.body : Ut.nodeName === "HTML" ? Ut.ownerDocument.body : Ut).removeChild(l.stateNode);
            } catch (i) {
              xt(
                l,
                e,
                i
              );
            }
          else
            try {
              Ut.removeChild(l.stateNode);
            } catch (i) {
              xt(
                l,
                e,
                i
              );
            }
        break;
      case 18:
        Ut !== null && (ze ? (t = Ut, Td(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), wn(t)) : Td(Ut, l.stateNode));
        break;
      case 4:
        a = Ut, n = ze, Ut = l.stateNode.containerInfo, ze = !0, wl(
          t,
          e,
          l
        ), Ut = a, ze = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        fa(2, l, e), Jt || fa(4, l, e), wl(
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
        wn(t);
      } catch (l) {
        xt(e, e.return, l);
      }
    }
  }
  function Bs(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        wn(t);
      } catch (l) {
        xt(e, e.return, l);
      }
  }
  function Pm(t) {
    switch (t.tag) {
      case 31:
      case 13:
      case 19:
        var e = t.stateNode;
        return e === null && (e = t.stateNode = new _s()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new _s()), e;
      default:
        throw Error(b(435, t.tag));
    }
  }
  function ju(t, e) {
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
        var n = l[a], i = t, u = e, f = u;
        t: for (; f !== null; ) {
          switch (f.tag) {
            case 27:
              if (ha(f.type)) {
                Ut = f.stateNode, ze = !1;
                break t;
              }
              break;
            case 5:
              Ut = f.stateNode, ze = !1;
              break t;
            case 3:
            case 4:
              Ut = f.stateNode.containerInfo, ze = !0;
              break t;
          }
          f = f.return;
        }
        if (Ut === null) throw Error(b(160));
        Cs(i, u, n), Ut = null, ze = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Ns(e, t), e = e.sibling;
  }
  var el = null;
  function Ns(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Me(e, t), Ee(t), a & 4 && (fa(3, t, t.return), Si(3, t), fa(5, t, t.return));
        break;
      case 1:
        Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), a & 64 && Hl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = el;
        if (Me(e, t), Ee(t), a & 512 && (Jt || l === null || ml(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[Aa] || i[Qt] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), ue(i, a, l), i[Qt] = t, Yt(i), a = i;
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
                      i = n.createElement(a), ue(i, a, l), n.head.appendChild(i);
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
                      i = n.createElement(a), ue(i, a, l), n.head.appendChild(i);
                      break;
                    default:
                      throw Error(b(468, a));
                  }
                  i[Qt] = t, Yt(i), a = i;
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
            g(n, "");
          } catch (j) {
            xt(t, t.return, j);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Dc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Uc = !0);
        break;
      case 6:
        if (Me(e, t), Ee(t), a & 4) {
          if (t.stateNode === null)
            throw Error(b(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (j) {
            xt(t, t.return, j);
          }
        }
        break;
      case 3:
        if (Pu = null, n = el, el = $u(e.containerInfo), Me(e, t), el = n, Ee(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            wn(e.containerInfo);
          } catch (j) {
            xt(t, t.return, j);
          }
        Uc && (Uc = !1, Rs(t));
        break;
      case 4:
        a = el, el = $u(
          t.stateNode.containerInfo
        ), Me(e, t), Ee(t), el = a;
        break;
      case 12:
        Me(e, t), Ee(t);
        break;
      case 31:
        Me(e, t), Ee(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, ju(t, a)));
        break;
      case 13:
        Me(e, t), Ee(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Yu = le()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, ju(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var r = l !== null && l.memoizedState !== null, v = Hl, S = Jt;
        if (Hl = v || n, Jt = S || r, Me(e, t), Jt = S, Hl = v, Ee(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || r || Hl || Jt || Fa(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                r = l = e;
                try {
                  if (i = r.stateNode, n)
                    u = i.style, typeof u.setProperty == "function" ? u.setProperty("display", "none", "important") : u.display = "none";
                  else {
                    f = r.stateNode;
                    var E = r.memoizedProps.style, y = E != null && E.hasOwnProperty("display") ? E.display : null;
                    f.style.display = y == null || typeof y == "boolean" ? "" : ("" + y).trim();
                  }
                } catch (j) {
                  xt(r, r.return, j);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                r = e;
                try {
                  r.stateNode.nodeValue = n ? "" : r.memoizedProps;
                } catch (j) {
                  xt(r, r.return, j);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                r = e;
                try {
                  var x = r.stateNode;
                  n ? zd(x, !0) : zd(r.stateNode, !1);
                } catch (j) {
                  xt(r, r.return, j);
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
        a & 4 && (a = t.updateQueue, a !== null && (l = a.retryQueue, l !== null && (a.retryQueue = null, ju(t, l))));
        break;
      case 19:
        Me(e, t), Ee(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, ju(t, a)));
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
        if (l == null) throw Error(b(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, i = Oc(t);
            wu(t, i, n);
            break;
          case 5:
            var u = l.stateNode;
            l.flags & 32 && (g(u, ""), l.flags &= -33);
            var f = Oc(t);
            wu(t, f, u);
            break;
          case 3:
          case 4:
            var r = l.stateNode.containerInfo, v = Oc(t);
            Cc(
              t,
              v,
              r
            );
            break;
          default:
            throw Error(b(161));
        }
      } catch (S) {
        xt(t, t.return, S);
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
  function jl(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        Ds(t, e.alternate, e), e = e.sibling;
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
          typeof l.componentWillUnmount == "function" && zs(
            e,
            e.return,
            l
          ), Fa(e);
          break;
        case 27:
          Ui(e.stateNode);
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
  function ql(t, e, l) {
    for (l = l && (e.subtreeFlags & 8772) !== 0, e = e.child; e !== null; ) {
      var a = e.alternate, n = t, i = e, u = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          ql(
            n,
            i,
            l
          ), Si(4, i);
          break;
        case 1:
          if (ql(
            n,
            i,
            l
          ), a = i, n = a.stateNode, typeof n.componentDidMount == "function")
            try {
              n.componentDidMount();
            } catch (v) {
              xt(a, a.return, v);
            }
          if (a = i, n = a.updateQueue, n !== null) {
            var f = a.stateNode;
            try {
              var r = n.shared.hiddenCallbacks;
              if (r !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < r.length; n++)
                  sr(r[n], f);
            } catch (v) {
              xt(a, a.return, v);
            }
          }
          l && u & 64 && Ts(i), Ti(i, i.return);
          break;
        case 27:
          As(i);
        case 26:
        case 5:
          ql(
            n,
            i,
            l
          ), l && a === null && u & 4 && Ms(i), Ti(i, i.return);
          break;
        case 12:
          ql(
            n,
            i,
            l
          );
          break;
        case 31:
          ql(
            n,
            i,
            l
          ), l && u & 4 && Us(n, i);
          break;
        case 13:
          ql(
            n,
            i,
            l
          ), l && u & 4 && Bs(n, i);
          break;
        case 22:
          i.memoizedState === null && ql(
            n,
            i,
            l
          ), Ti(i, i.return);
          break;
        case 30:
          break;
        default:
          ql(
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
        Hs(
          t,
          e,
          l,
          a
        ), e = e.sibling;
  }
  function Hs(t, e, l, a) {
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
            var i = e.memoizedProps, u = i.id, f = i.onPostCommit;
            typeof f == "function" && f(
              u,
              e.alternate === null ? "mount" : "update",
              t.passiveEffectDuration,
              -0
            );
          } catch (r) {
            xt(e, e.return, r);
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
        ) : (i._visibility |= 2, En(
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
  function En(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var i = t, u = e, f = l, r = a, v = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          En(
            i,
            u,
            f,
            r,
            n
          ), Si(8, u);
          break;
        case 23:
          break;
        case 22:
          var S = u.stateNode;
          u.memoizedState !== null ? S._visibility & 2 ? En(
            i,
            u,
            f,
            r,
            n
          ) : zi(
            i,
            u
          ) : (S._visibility |= 2, En(
            i,
            u,
            f,
            r,
            n
          )), n && v & 2048 && Bc(
            u.alternate,
            u
          );
          break;
        case 24:
          En(
            i,
            u,
            f,
            r,
            n
          ), n && v & 2048 && Nc(u.alternate, u);
          break;
        default:
          En(
            i,
            u,
            f,
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
  function An(t, e, l) {
    if (t.subtreeFlags & Mi)
      for (t = t.child; t !== null; )
        ws(
          t,
          e,
          l
        ), t = t.sibling;
  }
  function ws(t, e, l) {
    switch (t.tag) {
      case 26:
        An(
          t,
          e,
          l
        ), t.flags & Mi && t.memoizedState !== null && Yh(
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
        el = $u(t.stateNode.containerInfo), An(
          t,
          e,
          l
        ), el = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = Mi, Mi = 16777216, An(
          t,
          e,
          l
        ), Mi = a) : An(
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
  function js(t) {
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
          It = a, Ys(
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
        Ei(t), t.flags & 2048 && fa(9, t, t.return);
        break;
      case 3:
        Ei(t);
        break;
      case 12:
        Ei(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, qu(t)) : Ei(t);
        break;
      default:
        Ei(t);
    }
  }
  function qu(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          It = a, Ys(
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
          fa(8, e, e.return), qu(e);
          break;
        case 22:
          l = e.stateNode, l._visibility & 2 && (l._visibility &= -3, qu(e));
          break;
        default:
          qu(e);
      }
      t = t.sibling;
    }
  }
  function Ys(t, e) {
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
          ci(l.memoizedState.cache);
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
  var th = {
    getCacheForType: function(t) {
      var e = ne(Vt), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return ne(Vt).controller.signal;
    }
  }, eh = typeof WeakMap == "function" ? WeakMap : Map, pt = 0, Mt = null, at = null, it = 0, bt = 0, we = null, ca = !1, _n = !1, Rc = !1, Yl = 0, jt = 0, oa = 0, Wa = 0, Hc = 0, je = 0, Dn = 0, Ai = null, Ae = null, wc = !1, Yu = 0, Gs = 0, Gu = 1 / 0, Lu = null, ra = null, Wt = 0, sa = null, On = null, Gl = 0, jc = 0, qc = null, Ls = null, _i = 0, Yc = null;
  function qe() {
    return (pt & 2) !== 0 && it !== 0 ? it & -it : m.T !== null ? Zc() : tn();
  }
  function Xs() {
    if (je === 0)
      if ((it & 536870912) === 0 || ft) {
        var t = Ia;
        Ia <<= 1, (Ia & 3932160) === 0 && (Ia = 262144), je = t;
      } else je = 536870912;
    return t = Re.current, t !== null && (t.flags |= 32), je;
  }
  function _e(t, e, l) {
    (t === Mt && (bt === 2 || bt === 9) || t.cancelPendingCommit !== null) && (Cn(t, 0), da(
      t,
      it,
      je,
      !1
    )), Ql(t, l), ((pt & 2) === 0 || t !== Mt) && (t === Mt && ((pt & 2) === 0 && (Wa |= l), jt === 4 && da(
      t,
      it,
      je,
      !1
    )), hl(t));
  }
  function Qs(t, e, l) {
    if ((pt & 6) !== 0) throw Error(b(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Xl(t, e), n = a ? nh(t, e) : Lc(t, e, !0), i = a;
    do {
      if (n === 0) {
        _n && !a && da(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, i && !lh(l)) {
          n = Lc(t, e, !1), i = !1;
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
              n = Ai;
              var r = f.current.memoizedState.isDehydrated;
              if (r && (Cn(f, u).flags |= 256), u = Lc(
                f,
                u,
                !1
              ), u !== 2) {
                if (Rc && !r) {
                  f.errorRecoveryDisabledLanes |= i, Wa |= i, n = 4;
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
          Cn(t, 0), da(t, e, 0, !0);
          break;
        }
        t: {
          switch (a = t, i = n, i) {
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
          if ((e & 62914560) === e && (n = Yu + 300 - le(), 10 < n)) {
            if (da(
              a,
              e,
              je,
              !ca
            ), Pa(a, 0, !0) !== 0) break t;
            Gl = e, a.timeoutHandle = xd(
              Vs.bind(
                null,
                a,
                l,
                Ae,
                Lu,
                wc,
                e,
                je,
                Wa,
                Dn,
                ca,
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
            Lu,
            wc,
            e,
            je,
            Wa,
            Dn,
            ca,
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
  function Vs(t, e, l, a, n, i, u, f, r, v, S, E, y, x) {
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
      }, ws(
        e,
        i,
        E
      );
      var j = (i & 62914560) === i ? Yu - le() : (i & 4194048) === i ? Gs - le() : 0;
      if (j = Gh(
        E,
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
            r,
            S,
            E,
            null,
            y,
            x
          )
        ), da(t, i, u, !v);
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
      r
    );
  }
  function lh(t) {
    for (var e = t; ; ) {
      var l = e.tag;
      if ((l === 0 || l === 11 || l === 15) && e.flags & 16384 && (l = e.updateQueue, l !== null && (l = l.stores, l !== null)))
        for (var a = 0; a < l.length; a++) {
          var n = l[a], i = n.getSnapshot;
          n = n.value;
          try {
            if (!Be(i(), n)) return !1;
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
      var i = 31 - pe(n), u = 1 << i;
      a[i] = -1, n &= ~u;
    }
    l !== 0 && Ma(t, l, e);
  }
  function Xu() {
    return (pt & 6) === 0 ? (Di(0), !1) : !0;
  }
  function Gc() {
    if (at !== null) {
      if (bt === 0)
        var t = at.return;
      else
        t = at, Ol = La = null, lc(t), xn = null, ri = 0, t = at;
      for (; t !== null; )
        Ss(t.alternate, t), t = t.return;
      at = null;
    }
  }
  function Cn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Th(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), Gl = 0, Gc(), Mt = t, at = l = _l(t.current, null), it = e, bt = 0, we = null, ca = !1, _n = Xl(t, e), Rc = !1, Dn = je = Hc = Wa = oa = jt = 0, Ae = Ai = null, wc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - pe(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return Yl = e, ou(), l;
  }
  function Zs(t, e) {
    P = null, m.H = yi, e === bn || e === vu ? (e = fr(), bt = 3) : e === Vf ? (e = fr(), bt = 4) : bt = e === yc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, we = e, at === null && (jt = 1, Uu(
      t,
      Ze(e, t.current)
    ));
  }
  function Ks() {
    var t = Re.current;
    return t === null ? !0 : (it & 4194048) === it ? Fe === null : (it & 62914560) === it || (it & 536870912) !== 0 ? t === Fe : !1;
  }
  function Js() {
    var t = m.H;
    return m.H = yi, t === null ? yi : t;
  }
  function ks() {
    var t = m.A;
    return m.A = th, t;
  }
  function Qu() {
    jt = 4, ca || (it & 4194048) !== it && Re.current !== null || (_n = !0), (oa & 134217727) === 0 && (Wa & 134217727) === 0 || Mt === null || da(
      Mt,
      it,
      je,
      !1
    );
  }
  function Lc(t, e, l) {
    var a = pt;
    pt |= 2;
    var n = Js(), i = ks();
    (Mt !== t || it !== e) && (Lu = null, Cn(t, e)), e = !1;
    var u = jt;
    t: do
      try {
        if (bt !== 0 && at !== null) {
          var f = at, r = we;
          switch (bt) {
            case 8:
              Gc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              Re.current === null && (e = !0);
              var v = bt;
              if (bt = 0, we = null, Un(t, f, r, v), l && _n) {
                u = 0;
                break t;
              }
              break;
            default:
              v = bt, bt = 0, we = null, Un(t, f, r, v);
          }
        }
        ah(), u = jt;
        break;
      } catch (S) {
        Zs(t, S);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Ol = La = null, pt = a, m.H = n, m.A = i, at === null && (Mt = null, it = 0, ou()), u;
  }
  function ah() {
    for (; at !== null; ) Fs(at);
  }
  function nh(t, e) {
    var l = pt;
    pt |= 2;
    var a = Js(), n = ks();
    Mt !== t || it !== e ? (Lu = null, Gu = le() + 500, Cn(t, e)) : _n = Xl(
      t,
      e
    );
    t: do
      try {
        if (bt !== 0 && at !== null) {
          e = at;
          var i = we;
          e: switch (bt) {
            case 1:
              bt = 0, we = null, Un(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (ir(i)) {
                bt = 0, we = null, Ws(e);
                break;
              }
              e = function() {
                bt !== 2 && bt !== 9 || Mt !== t || (bt = 7), hl(t);
              }, i.then(e, e);
              break t;
            case 3:
              bt = 7;
              break t;
            case 4:
              bt = 5;
              break t;
            case 7:
              ir(i) ? (bt = 0, we = null, Ws(e)) : (bt = 0, we = null, Un(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (at.tag) {
                case 26:
                  u = at.memoizedState;
                case 5:
                case 27:
                  var f = at;
                  if (u ? Hd(u) : f.stateNode.complete) {
                    bt = 0, we = null;
                    var r = f.sibling;
                    if (r !== null) at = r;
                    else {
                      var v = f.return;
                      v !== null ? (at = v, Vu(v)) : at = null;
                    }
                    break e;
                  }
              }
              bt = 0, we = null, Un(t, e, i, 5);
              break;
            case 6:
              bt = 0, we = null, Un(t, e, i, 6);
              break;
            case 8:
              Gc(), jt = 6;
              break t;
            default:
              throw Error(b(462));
          }
        }
        ih();
        break;
      } catch (S) {
        Zs(t, S);
      }
    while (!0);
    return Ol = La = null, m.H = a, m.A = n, pt = l, at !== null ? 0 : (Mt = null, it = 0, ou(), jt);
  }
  function ih() {
    for (; at !== null && !Ln(); )
      Fs(at);
  }
  function Fs(t) {
    var e = bs(t.alternate, t, Yl);
    t.memoizedProps = t.pendingProps, e === null ? Vu(t) : at = e;
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
          it
        );
        break;
      case 11:
        e = ms(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          it
        );
        break;
      case 5:
        lc(e);
      default:
        Ss(l, e), e = at = ko(e, Yl), e = bs(l, e, Yl);
    }
    t.memoizedProps = t.pendingProps, e === null ? Vu(t) : at = e;
  }
  function Un(t, e, l, a) {
    Ol = La = null, lc(e), xn = null, ri = 0;
    var n = e.return;
    try {
      if (Jm(
        t,
        n,
        e,
        l,
        it
      )) {
        jt = 1, Uu(
          t,
          Ze(l, t.current)
        ), at = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw at = n, i;
      jt = 1, Uu(
        t,
        Ze(l, t.current)
      ), at = null;
      return;
    }
    e.flags & 32768 ? (ft || a === 1 ? t = !0 : _n || (it & 536870912) !== 0 ? t = !1 : (ca = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = Re.current, a !== null && a.tag === 13 && (a.flags |= 16384))), $s(e, t)) : Vu(e);
  }
  function Vu(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        $s(
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
  function $s(t, e) {
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
  function Is(t, e, l, a, n, i, u, f, r) {
    t.cancelPendingCommit = null;
    do
      Zu();
    while (Wt !== 0);
    if ((pt & 6) !== 0) throw Error(b(327));
    if (e !== null) {
      if (e === t.current) throw Error(b(177));
      if (i = e.lanes | e.childLanes, i |= Of, pf(
        t,
        l,
        i,
        u,
        f,
        r
      ), t === Mt && (at = Mt = null, it = 0), On = e, sa = t, Gl = l, jc = i, qc = n, Ls = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, oh(Sa, function() {
        return ad(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = m.T, m.T = null, n = D.p, D.p = 2, u = pt, pt |= 4;
        try {
          Im(t, e, l);
        } finally {
          pt = u, D.p = n, m.T = a;
        }
      }
      Wt = 1, Ps(), td(), ed();
    }
  }
  function Ps() {
    if (Wt === 1) {
      Wt = 0;
      var t = sa, e = On, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = m.T, m.T = null;
        var a = D.p;
        D.p = 2;
        var n = pt;
        pt |= 4;
        try {
          Ns(e, t);
          var i = Pc, u = Yo(t.containerInfo), f = i.focusedElem, r = i.selectionRange;
          if (u !== f && f && f.ownerDocument && qo(
            f.ownerDocument.documentElement,
            f
          )) {
            if (r !== null && Mf(f)) {
              var v = r.start, S = r.end;
              if (S === void 0 && (S = v), "selectionStart" in f)
                f.selectionStart = v, f.selectionEnd = Math.min(
                  S,
                  f.value.length
                );
              else {
                var E = f.ownerDocument || document, y = E && E.defaultView || window;
                if (y.getSelection) {
                  var x = y.getSelection(), j = f.textContent.length, Z = Math.min(r.start, j), zt = r.end === void 0 ? Z : Math.min(r.end, j);
                  !x.extend && Z > zt && (u = zt, zt = Z, Z = u);
                  var h = jo(
                    f,
                    Z
                  ), d = jo(
                    f,
                    zt
                  );
                  if (h && d && (x.rangeCount !== 1 || x.anchorNode !== h.node || x.anchorOffset !== h.offset || x.focusNode !== d.node || x.focusOffset !== d.offset)) {
                    var p = E.createRange();
                    p.setStart(h.node, h.offset), x.removeAllRanges(), Z > zt ? (x.addRange(p), x.extend(d.node, d.offset)) : (p.setEnd(d.node, d.offset), x.addRange(p));
                  }
                }
              }
            }
            for (E = [], x = f; x = x.parentNode; )
              x.nodeType === 1 && E.push({
                element: x,
                left: x.scrollLeft,
                top: x.scrollTop
              });
            for (typeof f.focus == "function" && f.focus(), f = 0; f < E.length; f++) {
              var z = E[f];
              z.element.scrollLeft = z.left, z.element.scrollTop = z.top;
            }
          }
          af = !!Ic, Pc = Ic = null;
        } finally {
          pt = n, D.p = a, m.T = l;
        }
      }
      t.current = e, Wt = 2;
    }
  }
  function td() {
    if (Wt === 2) {
      Wt = 0;
      var t = sa, e = On, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = m.T, m.T = null;
        var a = D.p;
        D.p = 2;
        var n = pt;
        pt |= 4;
        try {
          Ds(t, e.alternate, e);
        } finally {
          pt = n, D.p = a, m.T = l;
        }
      }
      Wt = 3;
    }
  }
  function ed() {
    if (Wt === 4 || Wt === 3) {
      Wt = 0, Li();
      var t = sa, e = On, l = Gl, a = Ls;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? Wt = 5 : (Wt = 0, On = sa = null, ld(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (ra = null), Ea(l), e = e.stateNode, ge && typeof ge.onCommitFiberRoot == "function")
        try {
          ge.onCommitFiberRoot(
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
          for (var i = t.onRecoverableError, u = 0; u < a.length; u++) {
            var f = a[u];
            i(f.value, {
              componentStack: f.stack
            });
          }
        } finally {
          m.T = e, D.p = n;
        }
      }
      (Gl & 3) !== 0 && Zu(), hl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Yc ? _i++ : (_i = 0, Yc = t) : _i = 0, Di(0);
    }
  }
  function ld(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, ci(e)));
  }
  function Zu() {
    return Ps(), td(), ed(), ad();
  }
  function ad() {
    if (Wt !== 5) return !1;
    var t = sa, e = jc;
    jc = 0;
    var l = Ea(Gl), a = m.T, n = D.p;
    try {
      D.p = 32 > l ? 32 : l, m.T = null, l = qc, qc = null;
      var i = sa, u = Gl;
      if (Wt = 0, On = sa = null, Gl = 0, (pt & 6) !== 0) throw Error(b(331));
      var f = pt;
      if (pt |= 4, qs(i.current), Hs(
        i,
        i.current,
        u,
        l
      ), pt = f, Di(0, !1), ge && typeof ge.onPostCommitFiberRoot == "function")
        try {
          ge.onPostCommitFiberRoot(Ta, i);
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
  function xt(t, e, l) {
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
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (ra === null || !ra.has(a))) {
            t = Ze(l, t), l = is(2), a = na(e, l, 2), a !== null && (us(
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
    n.has(l) || (Rc = !0, n.add(l), t = uh.bind(null, t, e, l), e.then(t, t));
  }
  function uh(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, Mt === t && (it & l) === l && (jt === 4 || jt === 3 && (it & 62914560) === it && 300 > le() - Yu ? (pt & 2) === 0 && Cn(t, 0) : Hc |= l, Dn === it && (Dn = 0)), hl(t);
  }
  function id(t, e) {
    e === 0 && (e = ki()), t = qa(t, e), t !== null && (Ql(t, e), hl(t));
  }
  function fh(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), id(t, l);
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
    a !== null && a.delete(e), id(t, l);
  }
  function oh(t, e) {
    return Gn(t, e);
  }
  var Ku = null, Bn = null, Qc = !1, Ju = !1, Vc = !1, ma = 0;
  function hl(t) {
    t !== Bn && t.next === null && (Bn === null ? Ku = Bn = t : Bn = Bn.next = t), Ju = !0, Qc || (Qc = !0, sh());
  }
  function Di(t, e) {
    if (!Vc && Ju) {
      Vc = !0;
      do
        for (var l = !1, a = Ku; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var i = 0;
            else {
              var u = a.suspendedLanes, f = a.pingedLanes;
              i = (1 << 31 - pe(42 | t) + 1) - 1, i &= n & ~(u & ~f), i = i & 201326741 ? i & 201326741 | 1 : i ? i | 2 : 0;
            }
            i !== 0 && (l = !0, od(a, i));
          } else
            i = it, i = Pa(
              a,
              a === Mt ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || Xl(a, i) || (l = !0, od(a, i));
          a = a.next;
        }
      while (l);
      Vc = !1;
    }
  }
  function rh() {
    ud();
  }
  function ud() {
    Ju = Qc = !1;
    var t = 0;
    ma !== 0 && Sh() && (t = ma);
    for (var e = le(), l = null, a = Ku; a !== null; ) {
      var n = a.next, i = fd(a, e);
      i === 0 ? (a.next = null, l === null ? Ku = n : l.next = n, n === null && (Bn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (Ju = !0)), a = n;
    }
    Wt !== 0 && Wt !== 5 || Di(t), ma !== 0 && (ma = 0);
  }
  function fd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - pe(i), f = 1 << u, r = n[u];
      r === -1 ? ((f & l) === 0 || (f & a) !== 0) && (n[u] = Ji(f, e)) : r <= e && (t.expiredLanes |= f), i &= ~f;
    }
    if (e = Mt, l = it, l = Pa(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (bt === 2 || bt === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && xa(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Xl(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && xa(a), Ea(l)) {
        case 2:
        case 8:
          l = $a;
          break;
        case 32:
          l = Sa;
          break;
        case 268435456:
          l = Vi;
          break;
        default:
          l = Sa;
      }
      return a = cd.bind(null, t), l = Gn(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && xa(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function cd(t, e) {
    if (Wt !== 0 && Wt !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Zu() && t.callbackNode !== l)
      return null;
    var a = it;
    return a = Pa(
      t,
      t === Mt ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Qs(t, a, e), fd(t, le()), t.callbackNode != null && t.callbackNode === l ? cd.bind(null, t) : null);
  }
  function od(t, e) {
    if (Zu()) return null;
    Qs(t, e, !0);
  }
  function sh() {
    zh(function() {
      (pt & 6) !== 0 ? Gn(
        Qi,
        rh
      ) : ud();
    });
  }
  function Zc() {
    if (ma === 0) {
      var t = vn;
      t === 0 && (t = vl, vl <<= 1, (vl & 261888) === 0 && (vl = 256)), ma = t;
    }
    return ma;
  }
  function rd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : ot("" + t);
  }
  function sd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function dh(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = rd(
        (n[se] || null).action
      ), u = a.submitter;
      u && (e = (e = u[se] || null) ? rd(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
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
                  var r = u ? sd(n, u) : new FormData(n);
                  sc(
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
                typeof i == "function" && (f.preventDefault(), r = u ? sd(n, u) : new FormData(n), sc(
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
  for (var Kc = 0; Kc < Df.length; Kc++) {
    var Jc = Df[Kc], mh = Jc.toLowerCase(), hh = Jc[0].toUpperCase() + Jc.slice(1);
    tl(
      mh,
      "on" + hh
    );
  }
  tl(Xo, "onAnimationEnd"), tl(Qo, "onAnimationIteration"), tl(Vo, "onAnimationStart"), tl("dblclick", "onDoubleClick"), tl("focusin", "onFocus"), tl("focusout", "onBlur"), tl(Cm, "onTransitionRun"), tl(Um, "onTransitionStart"), tl(Bm, "onTransitionCancel"), tl(Zo, "onTransitionEnd"), Zl("onMouseEnter", ["mouseout", "mouseover"]), Zl("onMouseLeave", ["mouseout", "mouseover"]), Zl("onPointerEnter", ["pointerout", "pointerover"]), Zl("onPointerLeave", ["pointerout", "pointerover"]), cl(
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
  var Oi = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), gh = new Set(
    "beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(Oi)
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
            var f = a[u], r = f.instance, v = f.currentTarget;
            if (f = f.listener, r !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = v;
            try {
              i(n);
            } catch (S) {
              cu(S);
            }
            n.currentTarget = null, i = r;
          }
        else
          for (u = 0; u < a.length; u++) {
            if (f = a[u], r = f.instance, v = f.currentTarget, f = f.listener, r !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = v;
            try {
              i(n);
            } catch (S) {
              cu(S);
            }
            n.currentTarget = null, i = r;
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
  var ku = "_reactListening" + Math.random().toString(36).slice(2);
  function Fc(t) {
    if (!t[ku]) {
      t[ku] = !0, _a.forEach(function(l) {
        l !== "selectionchange" && (gh.has(l) || kc(l, !1, t), kc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[ku] || (e[ku] = !0, kc("selectionchange", !1, e));
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
        n = ro;
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
              var r = u.tag;
              if ((r === 3 || r === 4) && u.stateNode.containerInfo === n)
                return;
              u = u.return;
            }
          for (; f !== null; ) {
            if (u = Sl(f), u === null) return;
            if (r = u.tag, r === 5 || r === 6 || r === 26 || r === 27) {
              a = i = u;
              continue t;
            }
            f = f.parentNode;
          }
        }
        a = a.return;
      }
    au(function() {
      var v = i, S = Fn(l), E = [];
      t: {
        var y = Ko.get(t);
        if (y !== void 0) {
          var x = El, j = t;
          switch (t) {
            case "keypress":
              if (nn(l) === 0) break t;
            case "keydown":
            case "keyup":
              x = cm;
              break;
            case "focusin":
              j = "focus", x = T;
              break;
            case "focusout":
              j = "blur", x = T;
              break;
            case "beforeblur":
            case "afterblur":
              x = T;
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
              x = Al;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              x = iu;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              x = sm;
              break;
            case Xo:
            case Qo:
            case Vo:
              x = J;
              break;
            case Zo:
              x = mm;
              break;
            case "scroll":
            case "scrollend":
              x = xf;
              break;
            case "wheel":
              x = gm;
              break;
            case "copy":
            case "cut":
            case "paste":
              x = dt;
              break;
            case "gotpointercapture":
            case "lostpointercapture":
            case "pointercancel":
            case "pointerdown":
            case "pointermove":
            case "pointerout":
            case "pointerover":
            case "pointerup":
              x = zo;
              break;
            case "toggle":
            case "beforetoggle":
              x = vm;
          }
          var Z = (e & 4) !== 0, zt = !Z && (t === "scroll" || t === "scrollend"), h = Z ? y !== null ? y + "Capture" : null : y;
          Z = [];
          for (var d = v, p; d !== null; ) {
            var z = d;
            if (p = z.stateNode, z = z.tag, z !== 5 && z !== 26 && z !== 27 || p === null || h === null || (z = Ml(d, h), z != null && Z.push(
              Ci(d, z, p)
            )), zt) break;
            d = d.return;
          }
          0 < Z.length && (y = new x(
            y,
            j,
            null,
            l,
            S
          ), E.push({ event: y, listeners: Z }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (y = t === "mouseover" || t === "pointerover", x = t === "mouseout" || t === "pointerout", y && l !== kn && (j = l.relatedTarget || l.fromElement) && (Sl(j) || j[xl]))
            break t;
          if ((x || y) && (y = S.window === S ? S : (y = S.ownerDocument) ? y.defaultView || y.parentWindow : window, x ? (j = l.relatedTarget || l.toElement, x = v, j = j ? Sl(j) : null, j !== null && (zt = qt(j), Z = j.tag, j !== zt || Z !== 5 && Z !== 27 && Z !== 6) && (j = null)) : (x = null, j = v), x !== j)) {
            if (Z = Al, z = "onMouseLeave", h = "onMouseEnter", d = "mouse", (t === "pointerout" || t === "pointerover") && (Z = zo, z = "onPointerLeave", h = "onPointerEnter", d = "pointer"), zt = x == null ? y : Tl(x), p = j == null ? y : Tl(j), y = new Z(
              z,
              d + "leave",
              x,
              l,
              S
            ), y.target = zt, y.relatedTarget = p, z = null, Sl(S) === v && (Z = new Z(
              h,
              d + "enter",
              j,
              l,
              S
            ), Z.target = p, Z.relatedTarget = zt, z = Z), zt = z, x && j)
              e: {
                for (Z = ph, h = x, d = j, p = 0, z = h; z; z = Z(z))
                  p++;
                z = 0;
                for (var Q = d; Q; Q = Z(Q))
                  z++;
                for (; 0 < p - z; )
                  h = Z(h), p--;
                for (; 0 < z - p; )
                  d = Z(d), z--;
                for (; p--; ) {
                  if (h === d || d !== null && h === d.alternate) {
                    Z = h;
                    break e;
                  }
                  h = Z(h), d = Z(d);
                }
                Z = null;
              }
            else Z = null;
            x !== null && hd(
              E,
              y,
              x,
              Z,
              !1
            ), j !== null && zt !== null && hd(
              E,
              zt,
              j,
              Z,
              !0
            );
          }
        }
        t: {
          if (y = v ? Tl(v) : window, x = y.nodeName && y.nodeName.toLowerCase(), x === "select" || x === "input" && y.type === "file")
            var ht = Uo;
          else if (Oo(y))
            if (Bo)
              ht = _m;
            else {
              ht = Em;
              var q = Mm;
            }
          else
            x = y.nodeName, !x || x.toLowerCase() !== "input" || y.type !== "checkbox" && y.type !== "radio" ? v && R(v.elementType) && (ht = Uo) : ht = Am;
          if (ht && (ht = ht(t, v))) {
            Co(
              E,
              ht,
              l,
              S
            );
            break t;
          }
          q && q(t, y, v), t === "focusout" && v && y.type === "number" && v.memoizedProps.value != null && Jn(y, "number", y.value);
        }
        switch (q = v ? Tl(v) : window, t) {
          case "focusin":
            (Oo(q) || q.contentEditable === "true") && (on = q, Ef = v, ii = null);
            break;
          case "focusout":
            ii = Ef = on = null;
            break;
          case "mousedown":
            Af = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Af = !1, Go(E, l, S);
            break;
          case "selectionchange":
            if (Om) break;
          case "keydown":
          case "keyup":
            Go(E, l, S);
        }
        var tt;
        if (Sf)
          t: {
            switch (t) {
              case "compositionstart":
                var ut = "onCompositionStart";
                break t;
              case "compositionend":
                ut = "onCompositionEnd";
                break t;
              case "compositionupdate":
                ut = "onCompositionUpdate";
                break t;
            }
            ut = void 0;
          }
        else
          cn ? _o(t, l) && (ut = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (ut = "onCompositionStart");
        ut && (Mo && l.locale !== "ko" && (cn || ut !== "onCompositionStart" ? ut === "onCompositionEnd" && cn && (tt = $n()) : (Qe = S, Ba = "value" in Qe ? Qe.value : Qe.textContent, cn = !0)), q = Fu(v, ut), 0 < q.length && (ut = new Ht(
          ut,
          t,
          null,
          l,
          S
        ), E.push({ event: ut, listeners: q }), tt ? ut.data = tt : (tt = Do(l), tt !== null && (ut.data = tt)))), (tt = bm ? xm(t, l) : Sm(t, l)) && (ut = Fu(v, "onBeforeInput"), 0 < ut.length && (q = new Ht(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          S
        ), E.push({
          event: q,
          listeners: ut
        }), q.data = tt)), dh(
          E,
          t,
          v,
          l,
          S
        );
      }
      dd(E, e);
    });
  }
  function Ci(t, e, l) {
    return {
      instance: t,
      listener: e,
      currentTarget: l
    };
  }
  function Fu(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, i = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = Ml(t, l), n != null && a.unshift(
        Ci(t, n, i)
      ), n = Ml(t, e), n != null && a.push(
        Ci(t, n, i)
      )), t.tag === 3) return a;
      t = t.return;
    }
    return [];
  }
  function ph(t) {
    if (t === null) return null;
    do
      t = t.return;
    while (t && t.tag !== 5 && t.tag !== 27);
    return t || null;
  }
  function hd(t, e, l, a, n) {
    for (var i = e._reactName, u = []; l !== null && l !== a; ) {
      var f = l, r = f.alternate, v = f.stateNode;
      if (f = f.tag, r !== null && r === a) break;
      f !== 5 && f !== 26 && f !== 27 || v === null || (r = v, n ? (v = Ml(l, i), v != null && u.unshift(
        Ci(l, v, r)
      )) : n || (v = Ml(l, i), v != null && u.push(
        Ci(l, v, r)
      ))), l = l.return;
    }
    u.length !== 0 && t.push({ event: e, listeners: u });
  }
  var vh = /\r\n?/g, yh = /\u0000|\uFFFD/g;
  function gd(t) {
    return (typeof t == "string" ? t : "" + t).replace(vh, `
`).replace(yh, "");
  }
  function pd(t, e) {
    return e = gd(e), gd(t) === e;
  }
  function Tt(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || g(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && g(t, "" + a);
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
        N(t, a, i);
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
          typeof i == "function" && (l === "formAction" ? (e !== "input" && Tt(t, e, "name", n.name, n, null), Tt(
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
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = st.get(l) || l, ln(t, l, a));
    }
  }
  function $c(t, e, l, a, n, i) {
    switch (l) {
      case "style":
        N(t, a, i);
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
        typeof a == "string" ? g(t, a) : (typeof a == "number" || typeof a == "bigint") && g(t, "" + a);
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
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[se] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : ln(t, l, a);
          }
    }
  }
  function ue(t, e, l) {
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
                  throw Error(b(137, e));
                default:
                  Tt(t, e, i, u, l, null);
              }
          }
        n && Tt(t, e, "srcSet", l.srcSet, l, null), a && Tt(t, e, "src", l.src, l, null);
        return;
      case "input":
        nt("invalid", t);
        var f = i = u = n = null, r = null, v = null;
        for (a in l)
          if (l.hasOwnProperty(a)) {
            var S = l[a];
            if (S != null)
              switch (a) {
                case "name":
                  n = S;
                  break;
                case "type":
                  u = S;
                  break;
                case "checked":
                  r = S;
                  break;
                case "defaultChecked":
                  v = S;
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
                  Tt(t, e, a, S, l, null);
              }
          }
        Ua(
          t,
          i,
          f,
          r,
          v,
          u,
          n,
          !1
        );
        return;
      case "select":
        nt("invalid", t), a = u = i = null;
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
                Tt(t, e, n, f, l, null);
            }
        e = i, l = u, t.multiple = !!a, e != null ? Jl(t, !!a, e, !1) : l != null && Jl(t, !!a, l, !0);
        return;
      case "textarea":
        nt("invalid", t), i = n = a = null;
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
                if (f != null) throw Error(b(91));
                break;
              default:
                Tt(t, e, u, f, l, null);
            }
        o(t, a, n, i);
        return;
      case "option":
        for (r in l)
          l.hasOwnProperty(r) && (a = l[r], a != null) && (r === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : Tt(t, e, r, a, l, null));
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
        for (a = 0; a < Oi.length; a++)
          nt(Oi[a], t);
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
        if (R(e)) {
          for (S in l)
            l.hasOwnProperty(S) && (a = l[S], a !== void 0 && $c(
              t,
              e,
              S,
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
        var n = null, i = null, u = null, f = null, r = null, v = null, S = null;
        for (x in l) {
          var E = l[x];
          if (l.hasOwnProperty(x) && E != null)
            switch (x) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                r = E;
              default:
                a.hasOwnProperty(x) || Tt(t, e, x, null, a, E);
            }
        }
        for (var y in a) {
          var x = a[y];
          if (E = l[y], a.hasOwnProperty(y) && (x != null || E != null))
            switch (y) {
              case "type":
                i = x;
                break;
              case "name":
                n = x;
                break;
              case "checked":
                v = x;
                break;
              case "defaultChecked":
                S = x;
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
                x !== E && Tt(
                  t,
                  e,
                  y,
                  x,
                  a,
                  E
                );
            }
        }
        ye(
          t,
          u,
          f,
          r,
          v,
          S,
          i,
          n
        );
        return;
      case "select":
        x = u = f = y = null;
        for (i in l)
          if (r = l[i], l.hasOwnProperty(i) && r != null)
            switch (i) {
              case "value":
                break;
              case "multiple":
                x = r;
              default:
                a.hasOwnProperty(i) || Tt(
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
                y = i;
                break;
              case "defaultValue":
                f = i;
                break;
              case "multiple":
                u = i;
              default:
                i !== r && Tt(
                  t,
                  e,
                  n,
                  i,
                  a,
                  r
                );
            }
        e = f, l = u, a = x, y != null ? Jl(t, !!l, y, !1) : !!a != !!l && (e != null ? Jl(t, !!l, e, !0) : Jl(t, !!l, l ? [] : "", !1));
        return;
      case "textarea":
        x = y = null;
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
        for (u in a)
          if (n = a[u], i = l[u], a.hasOwnProperty(u) && (n != null || i != null))
            switch (u) {
              case "value":
                y = n;
                break;
              case "defaultValue":
                x = n;
                break;
              case "children":
                break;
              case "dangerouslySetInnerHTML":
                if (n != null) throw Error(b(91));
                break;
              default:
                n !== i && Tt(t, e, u, n, a, i);
            }
        c(t, y, x);
        return;
      case "option":
        for (var j in l)
          y = l[j], l.hasOwnProperty(j) && y != null && !a.hasOwnProperty(j) && (j === "selected" ? t.selected = !1 : Tt(
            t,
            e,
            j,
            null,
            a,
            y
          ));
        for (r in a)
          y = a[r], x = l[r], a.hasOwnProperty(r) && y !== x && (y != null || x != null) && (r === "selected" ? t.selected = y && typeof y != "function" && typeof y != "symbol" : Tt(
            t,
            e,
            r,
            y,
            a,
            x
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
        for (var Z in l)
          y = l[Z], l.hasOwnProperty(Z) && y != null && !a.hasOwnProperty(Z) && Tt(t, e, Z, null, a, y);
        for (v in a)
          if (y = a[v], x = l[v], a.hasOwnProperty(v) && y !== x && (y != null || x != null))
            switch (v) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (y != null)
                  throw Error(b(137, e));
                break;
              default:
                Tt(
                  t,
                  e,
                  v,
                  y,
                  a,
                  x
                );
            }
        return;
      default:
        if (R(e)) {
          for (var zt in l)
            y = l[zt], l.hasOwnProperty(zt) && y !== void 0 && !a.hasOwnProperty(zt) && $c(
              t,
              e,
              zt,
              void 0,
              a,
              y
            );
          for (S in a)
            y = a[S], x = l[S], !a.hasOwnProperty(S) || y === x || y === void 0 && x === void 0 || $c(
              t,
              e,
              S,
              y,
              a,
              x
            );
          return;
        }
    }
    for (var h in l)
      y = l[h], l.hasOwnProperty(h) && y != null && !a.hasOwnProperty(h) && Tt(t, e, h, null, a, y);
    for (E in a)
      y = a[E], x = l[E], !a.hasOwnProperty(E) || y === x || y == null && x == null || Tt(t, e, E, y, a, x);
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
  function xh() {
    if (typeof performance.getEntriesByType == "function") {
      for (var t = 0, e = 0, l = performance.getEntriesByType("resource"), a = 0; a < l.length; a++) {
        var n = l[a], i = n.transferSize, u = n.initiatorType, f = n.duration;
        if (i && f && vd(u)) {
          for (u = 0, f = n.responseEnd, a += 1; a < l.length; a++) {
            var r = l[a], v = r.startTime;
            if (v > f) break;
            var S = r.transferSize, E = r.initiatorType;
            S && vd(E) && (r = r.responseEnd, u += S * (r < f ? 1 : (f - v) / (r - v)));
          }
          if (--a, e += 8 * (i + u) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var Ic = null, Pc = null;
  function Wu(t) {
    return t.nodeType === 9 ? t : t.ownerDocument;
  }
  function yd(t) {
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
  function Sh() {
    var t = window.event;
    return t && t.type === "popstate" ? t === eo ? !1 : (eo = t, !0) : (eo = null, !1);
  }
  var xd = typeof setTimeout == "function" ? setTimeout : void 0, Th = typeof clearTimeout == "function" ? clearTimeout : void 0, Sd = typeof Promise == "function" ? Promise : void 0, zh = typeof queueMicrotask == "function" ? queueMicrotask : typeof Sd < "u" ? function(t) {
    return Sd.resolve(null).then(t).catch(Mh);
  } : xd;
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
            t.removeChild(n), wn(e);
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
            var u = i.nextSibling, f = i.nodeName;
            i[Aa] || f === "SCRIPT" || f === "STYLE" || f === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && Ui(t.ownerDocument.body);
      l = n;
    } while (l);
    wn(e);
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
  var io = null;
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
    switch (e = Wu(l), t) {
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
  function Ui(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    Qn(t);
  }
  var $e = /* @__PURE__ */ new Map(), Dd = /* @__PURE__ */ new Set();
  function $u(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var Ll = D.d;
  D.d = {
    f: Dh,
    r: Oh,
    D: Ch,
    C: Uh,
    L: Bh,
    m: Nh,
    X: Hh,
    S: Rh,
    M: wh
  };
  function Dh() {
    var t = Ll.f(), e = Xu();
    return t || e;
  }
  function Oh(t) {
    var e = fl(t);
    e !== null && e.tag === 5 && e.type === "form" ? Zr(e) : Ll.r(t);
  }
  var Nn = typeof document > "u" ? null : document;
  function Od(t, e, l) {
    var a = Nn;
    if (a && typeof e == "string" && e) {
      var n = Te(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Dd.has(n) || (Dd.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), ue(e, "link", t), Yt(e), a.head.appendChild(e)));
    }
  }
  function Ch(t) {
    Ll.D(t), Od("dns-prefetch", t, null);
  }
  function Uh(t, e) {
    Ll.C(t, e), Od("preconnect", t, e);
  }
  function Bh(t, e, l) {
    Ll.L(t, e, l);
    var a = Nn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + Te(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + Te(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + Te(
        l.imageSizes
      ) + '"]')) : n += '[href="' + Te(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = Rn(t);
          break;
        case "script":
          i = Hn(t);
      }
      $e.has(i) || (t = X(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), $e.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Bi(i)) || e === "script" && a.querySelector(Ni(i)) || (e = a.createElement("link"), ue(e, "link", t), Yt(e), a.head.appendChild(e)));
    }
  }
  function Nh(t, e) {
    Ll.m(t, e);
    var l = Nn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + Te(a) + '"][href="' + Te(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = Hn(t);
      }
      if (!$e.has(i) && (t = X({ rel: "modulepreload", href: t }, e), $e.set(i, t), l.querySelector(n) === null)) {
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
        a = l.createElement("link"), ue(a, "link", t), Yt(a), l.head.appendChild(a);
      }
    }
  }
  function Rh(t, e, l) {
    Ll.S(t, e, l);
    var a = Nn;
    if (a && t) {
      var n = Vl(a).hoistableStyles, i = Rn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var f = { loading: 0, preload: null };
        if (u = a.querySelector(
          Bi(i)
        ))
          f.loading = 5;
        else {
          t = X(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = $e.get(i)) && uo(t, l);
          var r = u = a.createElement("link");
          Yt(r), ue(r, "link", t), r._p = new Promise(function(v, S) {
            r.onload = v, r.onerror = S;
          }), r.addEventListener("load", function() {
            f.loading |= 1;
          }), r.addEventListener("error", function() {
            f.loading |= 2;
          }), f.loading |= 4, Iu(u, e, a);
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
  function Hh(t, e) {
    Ll.X(t, e);
    var l = Nn;
    if (l && t) {
      var a = Vl(l).hoistableScripts, n = Hn(t), i = a.get(n);
      i || (i = l.querySelector(Ni(n)), i || (t = X({ src: t, async: !0 }, e), (e = $e.get(n)) && fo(t, e), i = l.createElement("script"), Yt(i), ue(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function wh(t, e) {
    Ll.M(t, e);
    var l = Nn;
    if (l && t) {
      var a = Vl(l).hoistableScripts, n = Hn(t), i = a.get(n);
      i || (i = l.querySelector(Ni(n)), i || (t = X({ src: t, async: !0, type: "module" }, e), (e = $e.get(n)) && fo(t, e), i = l.createElement("script"), Yt(i), ue(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Cd(t, e, l, a) {
    var n = (n = $.current) ? $u(n) : null;
    if (!n) throw Error(b(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = Rn(l.href), l = Vl(
          n
        ).hoistableStyles, a = l.get(e), a || (a = {
          type: "style",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      case "link":
        if (l.rel === "stylesheet" && typeof l.href == "string" && typeof l.precedence == "string") {
          t = Rn(l.href);
          var i = Vl(
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
          }, $e.set(t, l), i || jh(
            n,
            t,
            l,
            u.state
          ))), e && a === null)
            throw Error(b(528, ""));
          return u;
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
  function Rn(t) {
    return 'href="' + Te(t) + '"';
  }
  function Bi(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Ud(t) {
    return X({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function jh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), ue(e, "link", l), Yt(e), t.head.appendChild(e));
  }
  function Hn(t) {
    return '[src="' + Te(t) + '"]';
  }
  function Ni(t) {
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
          var n = X({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), Yt(a), ue(a, "style", n), Iu(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = Rn(l.href);
          var i = t.querySelector(
            Bi(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, Yt(i), i;
          a = Ud(l), (n = $e.get(n)) && uo(a, n), i = (t.ownerDocument || t).createElement("link"), Yt(i);
          var u = i;
          return u._p = new Promise(function(f, r) {
            u.onload = f, u.onerror = r;
          }), ue(i, "link", a), e.state.loading |= 4, Iu(i, l.precedence, t), e.instance = i;
        case "script":
          return i = Hn(l.src), (n = t.querySelector(
            Ni(i)
          )) ? (e.instance = n, Yt(n), n) : (a = l, (n = $e.get(i)) && (a = X({}, l), fo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Yt(n), ue(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(b(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, Iu(a, l.precedence, t));
    return e.instance;
  }
  function Iu(t, e, l) {
    for (var a = l.querySelectorAll(
      'link[rel="stylesheet"][data-precedence],style[data-precedence]'
    ), n = a.length ? a[a.length - 1] : null, i = n, u = 0; u < a.length; u++) {
      var f = a[u];
      if (f.dataset.precedence === e) i = f;
      else if (i !== n) break;
    }
    i ? i.parentNode.insertBefore(t, i.nextSibling) : (e = l.nodeType === 9 ? l.head : l, e.insertBefore(t, e.firstChild));
  }
  function uo(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.title == null && (t.title = e.title);
  }
  function fo(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.integrity == null && (t.integrity = e.integrity);
  }
  var Pu = null;
  function Nd(t, e, l) {
    if (Pu === null) {
      var a = /* @__PURE__ */ new Map(), n = Pu = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = Pu, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var i = l[n];
      if (!(i[Aa] || i[Qt] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
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
  function qh(t, e, l) {
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
        var n = Rn(a.href), i = e.querySelector(
          Bi(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = tf.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, Yt(i);
          return;
        }
        i = e.ownerDocument || e, a = Ud(a), (n = $e.get(n)) && uo(a, n), i = i.createElement("link"), Yt(i);
        var u = i;
        u._p = new Promise(function(f, r) {
          u.onload = f, u.onerror = r;
        }), ue(i, "link", a), l.instance = i;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = tf.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var co = 0;
  function Gh(t, e) {
    return t.stylesheets && t.count === 0 && lf(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && lf(t, t.stylesheets), t.unsuspend) {
          var i = t.unsuspend;
          t.unsuspend = null, i();
        }
      }, 6e4 + e);
      0 < t.imgBytes && co === 0 && (co = 62500 * xh());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && lf(t, t.stylesheets), t.unsuspend)) {
            var i = t.unsuspend;
            t.unsuspend = null, i();
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
        ), i = 0; i < n.length; i++) {
          var u = n[i];
          (u.nodeName === "LINK" || u.getAttribute("media") !== "not all") && (l.set(u.dataset.precedence, u), a = u);
        }
        a && l.set(null, a);
      }
      n = e.instance, u = n.getAttribute("data-precedence"), i = l.get(u) || a, i === a && l.set(null, n), l.set(u, n), this.count++, a = tf.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), i ? i.parentNode.insertBefore(n, i.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Ri = {
    $$typeof: Nt,
    Provider: null,
    Consumer: null,
    _currentValue: Y,
    _currentValue2: Y,
    _threadCount: 0
  };
  function Xh(t, e, l, a, n, i, u, f, r) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Ie(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Ie(0), this.hiddenUpdates = Ie(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = r, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function wd(t, e, l, a, n, i, u, f, r, v, S, E) {
    return t = new Xh(
      t,
      e,
      l,
      u,
      r,
      v,
      S,
      E,
      f
    ), e = 1, i === !0 && (e |= 24), i = Ne(3, null, null, e), t.current = i, i.stateNode = t, e = Lf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Zf(i), t;
  }
  function jd(t) {
    return t ? (t = dn, t) : dn;
  }
  function qd(t, e, l, a, n, i) {
    n = jd(n), a.context === null ? a.context = n : a.pendingContext = n, a = aa(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = na(t, a, e), l !== null && (_e(l, t, e), di(l, t, e));
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
      var e = qa(t, 67108864);
      e !== null && _e(e, t, 67108864), oo(t, 67108864);
    }
  }
  function Ld(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = qe();
      e = re(e);
      var l = qa(t, e);
      l !== null && _e(l, t, e), oo(t, e);
    }
  }
  var af = !0;
  function Qh(t, e, l, a) {
    var n = m.T;
    m.T = null;
    var i = D.p;
    try {
      D.p = 2, ro(t, e, l, a);
    } finally {
      D.p = i, m.T = n;
    }
  }
  function Vh(t, e, l, a) {
    var n = m.T;
    m.T = null;
    var i = D.p;
    try {
      D.p = 8, ro(t, e, l, a);
    } finally {
      D.p = i, m.T = n;
    }
  }
  function ro(t, e, l, a) {
    if (af) {
      var n = so(a);
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
          var i = fl(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = bl(i.pendingLanes);
                  if (u !== 0) {
                    var f = i;
                    for (f.pendingLanes |= 2, f.entangledLanes |= 2; u; ) {
                      var r = 1 << 31 - pe(u);
                      f.entanglements[1] |= r, u &= ~r;
                    }
                    hl(i), (pt & 6) === 0 && (Gu = le() + 500, Di(0));
                  }
                }
                break;
              case 31:
              case 13:
                f = qa(i, 2), f !== null && _e(f, i, 2), Xu(), oo(i, 2);
            }
          if (i = so(a), i === null && Wc(
            t,
            e,
            a,
            nf,
            l
          ), i === n) break;
          n = i;
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
  function so(t) {
    return t = Fn(t), mo(t);
  }
  var nf = null;
  function mo(t) {
    if (nf = null, t = Sl(t), t !== null) {
      var e = qt(t);
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
        switch (Xi()) {
          case Qi:
            return 2;
          case $a:
            return 8;
          case Sa:
          case mf:
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
  var ho = !1, ga = null, pa = null, va = null, Hi = /* @__PURE__ */ new Map(), wi = /* @__PURE__ */ new Map(), ya = [], Zh = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Qd(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        ga = null;
        break;
      case "dragenter":
      case "dragleave":
        pa = null;
        break;
      case "mouseover":
      case "mouseout":
        va = null;
        break;
      case "pointerover":
      case "pointerout":
        Hi.delete(e.pointerId);
        break;
      case "gotpointercapture":
      case "lostpointercapture":
        wi.delete(e.pointerId);
    }
  }
  function ji(t, e, l, a, n, i) {
    return t === null || t.nativeEvent !== i ? (t = {
      blockedOn: e,
      domEventName: l,
      eventSystemFlags: a,
      nativeEvent: i,
      targetContainers: [n]
    }, e !== null && (e = fl(e), e !== null && Gd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function Kh(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return ga = ji(
          ga,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return pa = ji(
          pa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return va = ji(
          va,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "pointerover":
        var i = n.pointerId;
        return Hi.set(
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
      case "gotpointercapture":
        return i = n.pointerId, wi.set(
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
    }
    return !1;
  }
  function Vd(t) {
    var e = Sl(t.target);
    if (e !== null) {
      var l = qt(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = kt(l), e !== null) {
            t.blockedOn = e, Wi(t.priority, function() {
              Ld(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = Pt(l), e !== null) {
            t.blockedOn = e, Wi(t.priority, function() {
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
      var l = so(t.nativeEvent);
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
    ho = !1, ga !== null && uf(ga) && (ga = null), pa !== null && uf(pa) && (pa = null), va !== null && uf(va) && (va = null), Hi.forEach(Zd), wi.forEach(Zd);
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
          var i = fl(l);
          i !== null && (t.splice(e, 3), e -= 3, sc(
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
  function wn(t) {
    function e(r) {
      return ff(r, t);
    }
    ga !== null && ff(ga, t), pa !== null && ff(pa, t), va !== null && ff(va, t), Hi.forEach(e), wi.forEach(e);
    for (var l = 0; l < ya.length; l++) {
      var a = ya[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < ya.length && (l = ya[0], l.blockedOn === null); )
      Vd(l), l.blockedOn === null && ya.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[se] || null;
        if (typeof i == "function")
          u || Kd(l);
        else if (u) {
          var f = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[se] || null)
              f = u.formAction;
            else if (mo(n) !== null) continue;
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
  function go(t) {
    this._internalRoot = t;
  }
  of.prototype.render = go.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(b(409));
    var l = e.current, a = qe();
    qd(l, a, t, e, null, null);
  }, of.prototype.unmount = go.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      qd(t.current, 2, null, t, null, null), Xu(), e[xl] = null;
    }
  };
  function of(t) {
    this._internalRoot = t;
  }
  of.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = tn();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < ya.length && e !== 0 && e < ya[l].priority; l++) ;
      ya.splice(l, 0, t), l === 0 && Vd(t);
    }
  };
  var kd = K.version;
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
    var rf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!rf.isDisabled && rf.supportsFiber)
      try {
        Ta = rf.inject(
          kh
        ), ge = rf;
      } catch {
      }
  }
  return Yi.createRoot = function(t, e) {
    if (!Bt(t)) throw Error(b(299));
    var l = !1, a = "", n = es, i = ls, u = as;
    return e != null && (e.unstable_strictMode === !0 && (l = !0), e.identifierPrefix !== void 0 && (a = e.identifierPrefix), e.onUncaughtError !== void 0 && (n = e.onUncaughtError), e.onCaughtError !== void 0 && (i = e.onCaughtError), e.onRecoverableError !== void 0 && (u = e.onRecoverableError)), e = wd(
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
    ), t[xl] = e.current, Fc(t), new go(e);
  }, Yi.hydrateRoot = function(t, e, l) {
    if (!Bt(t)) throw Error(b(299));
    var a = !1, n = "", i = es, u = ls, f = as, r = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (i = l.onUncaughtError), l.onCaughtError !== void 0 && (u = l.onCaughtError), l.onRecoverableError !== void 0 && (f = l.onRecoverableError), l.formState !== void 0 && (r = l.formState)), e = wd(
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
      f,
      Jd
    ), e.context = jd(null), l = e.current, a = qe(), a = re(a), n = aa(a), n.callback = null, na(l, n, a), l = a, e.current.lanes = l, Ql(e, l), hl(e), t[xl] = e.current, Fc(t), new of(e);
  }, Yi.version = "19.2.3", Yi;
}
var nm;
function ng() {
  if (nm) return vo.exports;
  nm = 1;
  function A() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(A);
      } catch (K) {
        console.error(K);
      }
  }
  return A(), vo.exports = ag(), vo.exports;
}
var ig = ng(), im = To();
function ug(A) {
  const K = (c) => {
    const o = document.getElementById(c);
    if (!o)
      throw new Error(`Missing cmux diff viewer element: ${c}`);
    return o;
  }, rt = A.assets ?? {}, b = (c, o) => {
    if (typeof c != "string" || c.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${o}`);
    return new URL(c, window.location.href).href;
  }, Bt = b(rt.diffsModuleURL, "diffsModuleURL"), qt = b(rt.treesModuleURL, "treesModuleURL"), kt = b(rt.workerPoolModuleURL, "workerPoolModuleURL"), Pt = b(rt.workerModuleURL, "workerModuleURL"), U = A.payload ?? {}, _ = U.labels ?? {}, lt = K("viewer"), X = K("status"), Et = K("toolbar"), Xt = K("source-select"), fe = K("repo-select"), te = K("base-select"), Ye = K("source-detail"), vt = K("jump-select"), Ge = K("external-link"), Nt = K("files-toggle"), Ft = K("layout-toggle"), ce = K("options-button"), Rt = K("options-menu"), et = K("files-sidebar"), Ct = K("file-list"), De = K("files-count"), Se = K("file-search-toggle"), oe = K("file-collapse-toggle"), ee = K("stats-files"), al = K("stats-added"), Le = K("stats-deleted"), G = (c) => _[c] ?? c, m = {
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
  let D, Y, V;
  const k = [], s = [], M = /* @__PURE__ */ new Map();
  let B = /* @__PURE__ */ new Set(), H = null, F = null, $ = /* @__PURE__ */ new Map(), ct = { value: null }, $t = "", yt = "", gl = !1, Xe = /* @__PURE__ */ new Map(), nl = /* @__PURE__ */ new Map();
  document.title = U.title, ge(U.appearance), pe(), se(U.sourceOptions ?? []), en(fe, U.repoOptions ?? [], U.repoRoot ?? "", G("repoPath")), en(te, U.baseOptions ?? [], U.branchBaseRef ?? "", G("branchBase"));
  const jn = globalThis.queueMicrotask ?? ((c) => setTimeout(c, 0));
  U.pendingReplacement === !0 ? (Oe(U.statusMessage ?? G("loadingDiff"), { loading: !0, pending: !0 }), Gi()) : typeof U.statusMessage == "string" && U.statusMessage.length > 0 ? Oe(U.statusMessage, { error: U.statusIsError === !0, loading: !1 }) : jn(() => {
    pl().catch((c) => {
      console.error("cmux diff viewer render failed", c), Oe(G("renderFailed"), { error: !0, loading: !1 });
    });
  });
  async function pl() {
    Oe(G("loadingRenderer"), { loading: !0 });
    const [
      {
        CodeView: c,
        getFiletypeFromFileName: o,
        parsePatchFiles: g,
        preloadHighlighter: O,
        processFile: w,
        registerCustomTheme: N
      },
      R
    ] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(Bt),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(qt).catch((At) => (console.warn("cmux diff file tree import failed", At), null))
    ]);
    if (Ua(N, U.appearance.themes.light), Ua(N, U.appearance.themes.dark), Oe(G("parsingDiff"), { loading: !0 }), xa("loading"), Y = await Yn(), Zn(k), re(), window.__cmuxDiffViewer = { codeView: D, items: k, state: m, workerPool: Y }, Gn(Y), Y?.initialize?.()?.then?.(() => Ln(Y?.getStats?.()))?.catch?.((At) => console.warn("cmux diff worker pool initialization failed", At)), window.addEventListener("pagehide", () => Y?.terminate?.(), { once: !0 }), await Qi({
      CodeView: c,
      parsePatchFiles: g,
      processFile: w,
      treesModule: R
    }), k.length === 0)
      throw new Error(G("noFileDiffs"));
    Y || Jn(U.appearance, s.length > 0 ? s : k, o, O).catch((At) => console.warn("cmux diff highlighter preload failed", At));
  }
  function Oe(c, o = {}) {
    X.isConnected || lt.replaceChildren(X), document.body.dataset.loading = o.loading === !0 || o.pending === !0 ? "true" : "false", document.body.dataset.statusOnly = "false", X.dataset.error = o.error === !0 ? "true" : "false", X.dataset.pending = o.pending === !0 ? "true" : "false", X.textContent = c;
  }
  function qn(c) {
    document.open(), document.write(c), document.close();
  }
  async function df(c) {
    if (!c.ok)
      return Oe(G("renderFailed"), { error: !0, loading: !1 }), !1;
    const o = await c.text();
    return o.includes('data-cmux-diff-pending="true"') ? !1 : (qn(o), !0);
  }
  async function Gi() {
    try {
      const c = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
      await df(c);
    } catch (c) {
      document.documentElement.dataset.cmuxDiffWait = "failed", Oe(G("renderFailed"), { error: !0, loading: !1 }), console.warn("cmux diff viewer deferred load failed", c);
    }
  }
  async function Yn() {
    if (typeof Worker > "u")
      return null;
    try {
      const c = await import(kt);
      Ua(c.registerCustomTheme, U.appearance.themes.light), Ua(c.registerCustomTheme, U.appearance.themes.dark);
      const o = new URL(Pt, window.location.href).href;
      return c.createDiffWorkerPool({
        workerURL: o,
        highlighterOptions: Li()
      }) ?? null;
    } catch (c) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", c), null;
    }
  }
  function Gn(c) {
    if (!c) {
      xa("fallback");
      return;
    }
    xa("enabled"), Ln(c.getStats?.());
    const o = c.subscribeToStatChanges?.((g) => {
      Ln(g);
    });
    typeof o == "function" && window.addEventListener("pagehide", o, { once: !0 });
  }
  function xa(c) {
    document.body.dataset.workerPool = c;
  }
  function Ln(c) {
    !c || typeof c != "object" || (typeof c.managerState == "string" && (document.body.dataset.workerPoolState = c.managerState), Number.isFinite(c.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(c.totalWorkers)), typeof c.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(c.workersFailed)));
  }
  function Li() {
    return {
      theme: U.appearance.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: m.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const le = /^From\s+([a-f0-9]+)\s/im;
  function Xi(c, o) {
    const g = c?.match(le);
    return g?.[1] ? new TextDecoder().decode(new TextEncoder().encode(g[1].slice(0, 5))) : `Commit ${o + 1}`;
  }
  async function Qi({ CodeView: c, parsePatchFiles: o, processFile: g, treesModule: O }) {
    const w = mf(), N = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, R = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let st = performance.now(), At = performance.now(), ot = !0;
    const de = {
      initialBatchSize: cl(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function kn(T, C) {
      const J = Fn(w, T, C);
      return J?.renamedItem && au(J.renamedItem), J?.item;
    }
    function Fn(T, C, J) {
      if (!C)
        return null;
      const I = Da(C), dt = J == null ? I : `${J}/${I}`, mt = I.length === 0 ? void 0 : T.pathStateByTreePath.get(dt), Ht = mt == null ? void 0 : kl(T, dt, mt), be = Ca(C), Ue = {
        id: T.itemIdToFile.has(dt) ? zl(T, `${dt}?2`) : dt,
        type: "diff",
        fileDiff: C,
        version: 0
      }, uu = T.items.length;
      T.fileIndex += 1, T.items.push(Ue), T.pendingItems.push(Ue), T.pendingItemById.set(Ue.id, Ue), T.itemIdToFile.set(Ue.id, { fileOrder: uu, path: I }), T.itemIdByTreePath.set(dt, Ue.id), T.treePathByItemId.set(Ue.id, dt), T.diffStats.addedLines += be.added, T.diffStats.deletedLines += be.deleted, T.diffStats.fileCount += 1, T.diffStats.totalLinesOfCode += C.unifiedLineCount ?? C.splitLineCount ?? 0;
      const ti = T.statsByPath.get(dt);
      return T.statsByPath.set(dt, be), mt != null && !Te(ti, be) && (T.pendingStatsChanged = !0), I.length > 0 && (mt == null && T.paths.push(dt), T.pathToItemId.set(dt, Ue.id), lu(T, dt, C.type, mt?.sawDeleted === !0), T.pathStateByTreePath.set(dt, {
        currentItem: Ue,
        currentItemId: Ue.id,
        currentType: C.type,
        fileOrder: uu,
        sawDeleted: mt?.sawDeleted === !0 || C.type === "deleted"
      })), { item: Ue, renamedItem: Ht };
    }
    function kl(T, C, J) {
      const I = J.currentItemId, dt = J.currentType === "deleted" ? "?deleted" : "?previous", mt = zl(T, `${C}${dt}`);
      if (J.currentItem.id = mt, J.currentItemId = mt, T.itemIdToFile.has(I)) {
        const Ht = T.itemIdToFile.get(I);
        T.itemIdToFile.delete(I), T.itemIdToFile.set(mt, Ht);
      }
      if (T.treePathByItemId.has(I) && (T.treePathByItemId.delete(I), T.treePathByItemId.set(mt, C)), T.pendingItemById.has(I)) {
        const Ht = T.pendingItemById.get(I);
        T.pendingItemById.delete(I), T.pendingItemById.set(mt, Ht);
        return;
      }
      return { oldId: I, newId: mt };
    }
    function zl(T, C) {
      if (!T.itemIdToFile.has(C))
        return C;
      let J = T.nextCollisionSuffixByBase.get(C) ?? 2, I = `${C}-${J}`;
      for (; T.itemIdToFile.has(I); )
        J += 1, I = `${C}-${J}`;
      return T.nextCollisionSuffixByBase.set(C, J + 1), I;
    }
    function lu(T, C, J, I) {
      if (I && J !== "deleted") {
        T.gitStatusByPath.delete(C) && an(T, C);
        return;
      }
      const dt = Oa(J);
      if (dt === "modified") {
        T.gitStatusByPath.delete(C) && an(T, C);
        return;
      }
      if (T.gitStatusByPath.get(C)?.status === dt)
        return;
      const Ht = { path: C, status: dt };
      T.gitStatusByPath.set(C, Ht), T.pendingGitStatusRemovePaths.delete(C), T.pendingGitStatusSetByPath.set(C, Ht);
    }
    function an(T, C) {
      T.pendingGitStatusSetByPath.delete(C), T.pendingGitStatusRemovePaths.add(C);
    }
    function au(T) {
      if (B.delete(T.oldId) && B.add(T.newId), M.has(T.oldId)) {
        const C = M.get(T.oldId);
        M.delete(T.oldId), M.set(T.newId, C);
      }
      ln(T.oldId, T.newId), D?.updateItemId?.(T.oldId, T.newId);
    }
    async function Ml(T, C) {
      kn(T, C) && await Ce(!1);
    }
    async function Ce(T) {
      if (w.pendingItems.length === 0)
        return;
      const C = performance.now();
      if (!T && ot && C - st >= 8 && w.pendingItems.length < de.initialBatchSize && C - At < de.initialMaxWait) {
        await Zi(), st = performance.now();
        return;
      }
      const J = ot ? de.initialBatchSize : de.incrementalBatchSize, I = ot ? de.initialMaxWait : de.incrementalMaxWait;
      if (T || w.pendingItems.length >= J || C - At >= I) {
        Wn(), await Zi(), st = performance.now();
        return;
      }
    }
    function Wn() {
      if (w.pendingItems.length === 0)
        return;
      const T = w.pendingItems.splice(0, w.pendingItems.length);
      w.pendingItemById.clear();
      const C = T, J = s.length > 0;
      k.push(...T);
      for (const I of T)
        M.set(I.id, I);
      if (C.length > 0) {
        s.push(...C);
        for (const I of C)
          B.add(I.id);
        D ? D.addItems(C) : (D = new c(Ji(), Y ?? void 0), D.setup(lt), D.setItems(s), D.render(!0), window.__cmuxDiffViewer.codeView = D);
      }
      bf(T), Qe(O, !1, T.length), R.flushCount += 1, R.maxBatchSize = Math.max(R.maxBatchSize, T.length), R.fileCount = k.length, R.renderableFileCount = s.length, $a(R), At = performance.now(), ot && (ot = !1, document.body.dataset.loading = "false", X.remove()), J || ve(s[0]?.id ?? k[0]?.id ?? ""), window.__cmuxDiffViewer.items = k, window.__cmuxDiffViewer.codeViewItems = s, window.__cmuxDiffViewer.streamMetrics = R;
    }
    function Fl() {
      D && (D.syncContainerHeight?.(), D.render(!0));
    }
    function Qe(T, C, J = 1) {
      if (N.treesModule = T, N.dirtyCount += J, C || N.lastRefreshAt === 0) {
        Ba(N.treesModule);
        return;
      }
      const I = performance.now() - N.lastRefreshAt;
      if (N.dirtyCount >= 1e3 || I >= 1e3) {
        Ba(N.treesModule);
        return;
      }
      if (N.timeout !== 0)
        return;
      const dt = Math.max(0, 1e3 - I);
      N.timeout = window.setTimeout(() => {
        N.timeout = 0, Ba(N.treesModule);
      }, dt);
    }
    function Ba(T) {
      N.timeout !== 0 && (window.clearTimeout(N.timeout), N.timeout = 0), N.dirtyCount = 0, N.lastRefreshAt = performance.now(), R.treeRefreshCount += 1, F = Vi(w), yf(F, T), re(), $a(R);
    }
    const ol = await fetch(U.patchURL, { cache: "no-store" });
    if (!ol.ok)
      throw new Error(`${G("loadingDiff")} (${ol.status})`);
    if (!ol.body?.getReader) {
      const T = await ol.text();
      await Sa(T, o, Ml), await Ce(!0), Fl(), Qe(O, !0), R.completedAt = performance.now();
      return;
    }
    const $n = new TextDecoder(), nn = ol.body.getReader(), Na = "diff --git ", In = `
` + Na, me = In.length - 1, rl = /\S/;
    function El(T, C) {
      const J = Math.max(C, 0);
      if (J === 0 && T.startsWith(Na))
        return 0;
      const I = T.indexOf(In, J);
      return I === -1 ? void 0 : I + 1;
    }
    function Wl(T, C) {
      return Math.max(C, T.length - me);
    }
    function xf(T, C, J) {
      const I = Math.max(C, 0), dt = Math.min(J, T.length);
      if (I >= dt)
        return;
      let mt = T.lastIndexOf(`
From `, dt - 1);
      for (; mt !== -1; ) {
        const Ht = mt + 1;
        if (Ht < I)
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
      const C = El(T, 0);
      if (C == null || C <= 0)
        return;
      const J = T.slice(0, C);
      return le.test(J) ? J : void 0;
    }
    async function un(T) {
      if (T.trim() === "")
        return;
      const C = Pn(T);
      C != null && (nu = Xi(C, iu), iu += 1);
      const J = `cmux-diff-file-${w.fileIndex}`;
      await Ml(g(T, {
        cacheKey: J,
        isGitDiff: !0
      }), nu);
    }
    function Ra() {
      let T, C = "", J = 0, I = !1;
      function dt() {
        if (T == null) {
          if (T = El(C, J), T == null)
            return J = Wl(C, 0), null;
          I = !0, J = T + 1;
        }
        for (; ; ) {
          const mt = T;
          if (mt == null)
            return null;
          const Ht = El(C, J);
          if (Ht == null)
            return J = Wl(C, mt + 1), null;
          const be = xf(C, mt + 1, Ht) ?? Ht, Ha = C.slice(0, be);
          if (C = C.slice(be), T = El(C, 0), J = T == null ? 0 : T + 1, rl.test(Ha))
            return Ha;
        }
      }
      return {
        push(mt) {
          mt.length > 0 && (C += mt);
        },
        takeAvailableFile: dt,
        finish() {
          const mt = dt();
          if (mt != null)
            return { fileText: mt };
          if (!rl.test(C))
            return C = "", {};
          if (!I) {
            const be = C;
            return C = "", { fallbackPatchContent: be };
          }
          const Ht = C;
          return C = "", { fileText: Ht };
        }
      };
    }
    async function $l(T) {
      let C;
      for (; (C = T.takeAvailableFile()) != null; )
        await un(C);
    }
    const Al = Ra();
    let nu, iu = 0;
    for (; ; ) {
      const { done: T, value: C } = await nn.read();
      if (T) {
        const J = $n.decode();
        J.length > 0 && (Al.push(J), await $l(Al));
        break;
      }
      Al.push($n.decode(C, { stream: !0 })), await $l(Al);
    }
    const fn = Al.finish();
    fn.fileText != null ? (await un(fn.fileText), await $l(Al)) : fn.fallbackPatchContent != null && await Sa(fn.fallbackPatchContent, o, Ml), await Ce(!0), Fl(), Qe(O, !0), R.completedAt = performance.now(), $a(R);
  }
  function $a(c) {
    document.body.dataset.streamFileCount = String(c.fileCount ?? k.length), document.body.dataset.streamRenderableFileCount = String(c.renderableFileCount ?? s.length), document.body.dataset.streamFlushCount = String(c.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(c.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(c.treeRefreshCount ?? 0), Number.isFinite(c.completedAt) && c.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(c.completedAt - c.startedAt)));
  }
  async function Sa(c, o, g) {
    const O = o(c, "cmux-diff"), w = O.length > 1;
    for (const [N, R] of O.entries()) {
      const st = w ? Xi(R.patchMetadata, N) : void 0;
      for (const At of R.files ?? [])
        await g(At, st);
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
  function Vi(c) {
    const o = c.lastTreeSource, g = hf(c), O = {
      diffStats: { ...c.diffStats },
      gitStatus: Array.from(c.gitStatusByPath.values()),
      gitStatusPatch: g,
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
  function Zi() {
    return new Promise((c) => {
      let o = !1, g = 0;
      const O = () => {
        o || (o = !0, g !== 0 && window.clearTimeout(g), c());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        g = window.setTimeout(O, 50), window.requestAnimationFrame(O);
      else if (typeof MessageChannel < "u") {
        const w = new MessageChannel();
        w.port1.onmessage = O, w.port2.postMessage(void 0);
      } else
        queueMicrotask(O);
    });
  }
  async function Ta() {
    return ct.value == null && (ct.value = fetch(U.patchURL, { cache: "no-store" }).then(async (c) => {
      if (!c.ok)
        throw new Error(`${G("loadingDiff")} (${c.status})`);
      return c.text();
    })), ct.value;
  }
  function ge(c) {
    const o = document.documentElement.style;
    o.setProperty("--cmux-diff-bg-light", c.themes.light.background), o.setProperty("--cmux-diff-bg-dark", c.themes.dark.background), o.setProperty("--cmux-diff-fg-light", c.themes.light.foreground), o.setProperty("--cmux-diff-fg-dark", c.themes.dark.foreground), o.setProperty("--cmux-diff-selection-bg-light", c.themes.light.selectionBackground), o.setProperty("--cmux-diff-selection-bg-dark", c.themes.dark.selectionBackground), o.setProperty("--cmux-diff-code-font-family", il(c.fontFamily)), o.setProperty("--cmux-diff-font-size", `${c.fontSize}px`), o.setProperty("--cmux-diff-line-height", `${c.lineHeight}px`);
  }
  function il(c) {
    const o = typeof c == "string" && c.trim() !== "" ? c.trim() : "Menlo";
    return `${JSON.stringify(o)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
  }
  function pe() {
    Nt.innerHTML = ye("files"), Se.innerHTML = ye("search"), oe.innerHTML = ye("sidebarCollapse"), Ft.innerHTML = ye(m.layout), ce.innerHTML = ye("dots"), typeof U.externalURL == "string" && U.externalURL.length > 0 && (Ge.href = U.externalURL, Ge.innerHTML = ye("external"), Ge.hidden = !1), Nt.addEventListener("click", () => Ma(!m.filesVisible)), oe.addEventListener("click", () => Ma(!1)), Se.addEventListener("click", () => Xn(!m.fileSearchOpen)), Ft.addEventListener("click", () => pf(m.layout === "split" ? "unified" : "split")), ce.addEventListener("click", () => Ea(Rt.hidden)), document.addEventListener("click", (c) => {
      Rt.hidden || c.target instanceof Node && Et.contains(c.target) || Ea(!1);
    }), document.addEventListener("keydown", (c) => {
      c.key === "Escape" && Ea(!1);
    }), gf(), re();
  }
  function gf() {
    const c = U.shortcuts ?? {}, o = za(c.diffViewerScrollDown), g = za(c.diffViewerScrollUp), O = za(c.diffViewerScrollToBottom), w = za(c.diffViewerScrollToTop), N = za(c.diffViewerOpenFileSearch);
    let R = null, st = 0;
    document.addEventListener("keydown", (ot) => {
      if (!(ot.defaultPrevented || Pa(ot.target))) {
        if (R && !yl(R.shortcut.second, ot) && At(), R && yl(R.shortcut.second, ot)) {
          ot.preventDefault(), R.action(), At();
          return;
        }
        if (vl(o, ot)) {
          ot.preventDefault(), Xl(1);
          return;
        }
        if (vl(g, ot)) {
          ot.preventDefault(), Xl(-1);
          return;
        }
        if (vl(O, ot)) {
          ot.preventDefault(), lt.scrollTo({ top: lt.scrollHeight, behavior: "auto" });
          return;
        }
        if (vl(N, ot) && V) {
          ot.preventDefault(), Ma(!0), Xn(!0);
          return;
        }
        Ia(w, ot) && (ot.preventDefault(), R = {
          shortcut: w,
          action: () => lt.scrollTo({ top: 0, behavior: "auto" })
        }, st = setTimeout(At, 700));
      }
    });
    function At() {
      R = null, st !== 0 && (clearTimeout(st), st = 0);
    }
  }
  function za(c) {
    return !c || c.unbound === !0 || !c.first ? null : {
      first: Ki(c.first),
      second: c.second ? Ki(c.second) : null
    };
  }
  function Ki(c) {
    return {
      key: String(c?.key ?? "").toLowerCase(),
      command: c?.command === !0,
      shift: c?.shift === !0,
      option: c?.option === !0,
      control: c?.control === !0
    };
  }
  function vl(c, o) {
    return c && !c.second && yl(c.first, o);
  }
  function Ia(c, o) {
    return c && c.second && yl(c.first, o);
  }
  function yl(c, o) {
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
  function Ji() {
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
      unsafeCSS: ki(),
      theme: U.appearance.theme,
      themeType: "system"
    };
  }
  function ki() {
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
    const c = Ji();
    if (!D) {
      Ql();
      return;
    }
    D.setOptions(c), Ql(), D.render(!0);
  }
  function Ql() {
    Y?.setRenderOptions && Y.setRenderOptions(Li()).then(() => D?.render(!0)).catch((c) => console.warn("cmux diff worker render options update failed", c));
  }
  function pf(c) {
    m.layout = c === "unified" ? "unified" : "split", re(), Ie();
  }
  function Ma(c) {
    m.filesVisible = c, document.body.dataset.filesHidden = c ? "false" : "true", et.setAttribute("aria-hidden", String(!c)), c ? et.removeAttribute("inert") : et.setAttribute("inert", ""), re();
  }
  function Xn(c) {
    m.fileSearchOpen = !!c, V && (m.fileSearchOpen ? V.openSearch("") : V.closeSearch()), re();
  }
  function Fi(c) {
    m.collapsed = c;
    const o = s.map((w) => ({
      ...w,
      collapsed: c,
      version: (w.version ?? 0) + 1
    })), g = new Map(o.map((w) => [w.id, w])), O = k.map((w) => g.get(w.id) ?? {
      ...w,
      collapsed: c,
      version: (w.version ?? 0) + 1
    });
    s.splice(0, s.length, ...o), k.splice(0, k.length, ...O), D && (D.setItems(s), D.render(!0)), re();
  }
  function re() {
    Nt.setAttribute("aria-pressed", String(m.filesVisible)), Nt.title = m.filesVisible ? G("hideFiles") : G("showFiles"), Nt.setAttribute("aria-label", Nt.title), oe.title = G("hideFiles"), oe.setAttribute("aria-label", oe.title), Ft.innerHTML = ye(m.layout), Ft.title = m.layout === "split" ? G("switchToUnifiedDiff") : G("switchToSplitDiff"), Ft.setAttribute("aria-label", Ft.title), ce.setAttribute("aria-expanded", String(!Rt.hidden)), document.documentElement.dataset.layout = m.layout, document.documentElement.dataset.wordWrap = String(m.wordWrap), document.documentElement.dataset.diffIndicators = m.diffIndicators, Se.disabled = !V, Se.setAttribute("aria-pressed", String(m.fileSearchOpen)), Se.title = m.fileSearchOpen ? G("hideFileSearch") : G("showFileSearch"), Se.setAttribute("aria-label", Se.title);
  }
  function Ea(c) {
    c && tn(), Rt.hidden = !c, re();
  }
  function tn() {
    Rt.textContent = "";
    const c = [
      { label: G("refresh"), icon: "refresh", action: () => window.location.reload() },
      { label: m.wordWrap ? G("disableWordWrap") : G("enableWordWrap"), icon: "wrap", checked: m.wordWrap, action: () => {
        m.wordWrap = !m.wordWrap, Ie();
      } },
      { label: m.collapsed ? G("expandAllDiffs") : G("collapseAllDiffs"), icon: "collapse", checked: m.collapsed, action: () => Fi(!m.collapsed) },
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
      { label: G("copyGitApplyCommand"), icon: "clipboard", action: ul }
    ];
    for (const o of c) {
      if (o === "separator") {
        const O = document.createElement("div");
        O.className = "menu-separator", Rt.append(O);
        continue;
      }
      if (o.kind === "segment") {
        const O = document.createElement("div");
        O.className = "menu-item menu-segment", O.setAttribute("role", "presentation"), O.innerHTML = `${ye(o.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`, O.querySelector(".menu-label").textContent = o.label;
        const w = O.querySelector(".menu-segment-controls");
        for (const N of o.options) {
          const R = document.createElement("button");
          R.type = "button", R.className = "segment-button", R.title = N.label, R.setAttribute("aria-label", N.label), R.setAttribute("aria-pressed", String(m.diffIndicators === N.value)), R.innerHTML = ye(N.icon), R.addEventListener("click", () => {
            m.diffIndicators = N.value, Ie(), tn(), re();
          }), w.append(R);
        }
        Rt.append(O);
        continue;
      }
      const g = document.createElement("button");
      g.type = "button", g.className = "menu-item", g.setAttribute("role", o.checked == null ? "menuitem" : "menuitemcheckbox"), o.checked != null && g.setAttribute("aria-checked", String(!!o.checked)), g.disabled = !!o.disabled, g.innerHTML = `${ye(o.icon)}<span class="menu-label"></span><span class="menu-check">${o.checked ? ye("check") : ""}</span>`, g.querySelector(".menu-label").textContent = o.label, g.addEventListener("click", () => {
        g.disabled || (o.action?.(), tn(), re());
      }), Rt.append(g);
    }
  }
  function Wi(c) {
    const o = new Set(c.split(/\r?\n/));
    let g = "CMUX_DIFF_PATCH", O = 0;
    for (; o.has(g); )
      O += 1, g = `CMUX_DIFF_PATCH_${O}`;
    return g;
  }
  async function ul() {
    const o = await Ta(), g = o.endsWith(`
`) ? o : `${o}
`, O = Wi(g), w = `git apply <<'${O}'
${g}${O}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(w);
      } catch {
        Qt(w);
      }
    else
      Qt(w);
    ce.title = G("copiedGitApplyCommand"), ce.setAttribute("aria-label", G("copiedGitApplyCommand"));
  }
  function Qt(c) {
    const o = document.createElement("textarea");
    o.value = c, o.setAttribute("readonly", ""), o.style.position = "fixed", o.style.left = "-9999px", document.body.append(o), o.select(), document.execCommand("copy"), o.remove();
  }
  function se(c) {
    if (Ye.textContent = xl(), !Array.isArray(c) || c.length < 2)
      return;
    Xt.textContent = "";
    const o = c.find((g) => g.selected) ?? c.find((g) => !g.disabled);
    for (const g of c) {
      const O = document.createElement("option");
      O.value = g.value, O.textContent = g.label, O.disabled = g.disabled || !g.url, O.selected = g.value === o?.value, g.message && (O.title = g.message), Xt.append(O);
    }
    Ye.textContent = o?.sourceLabel ?? xl(), Xt.hidden = !1, Xt.addEventListener("change", () => {
      const g = c.find((O) => O.value === Xt.value);
      if (!g?.url) {
        Xt.value = o?.value ?? "";
        return;
      }
      Oe(G("loadingDiff"), { pending: !0 }), window.location.href = g.url;
    });
  }
  function xl() {
    return [U.sourceLabel, U.repoRoot, U.branchBaseRef].filter((o) => typeof o == "string" && o.trim() !== "").join(" | ");
  }
  function en(c, o, g, O) {
    if (!c || !Array.isArray(o) || o.length < 2)
      return;
    c.textContent = "";
    const w = o.find((N) => N.selected) ?? o.find((N) => !N.disabled);
    for (const N of o) {
      const R = document.createElement("option");
      R.value = N.value, R.textContent = N.label, R.disabled = N.disabled || !N.url, R.selected = N.value === w?.value, N.message && (R.title = N.message), c.append(R);
    }
    c.hidden = !1, c.title = O, c.addEventListener("change", () => {
      const N = o.find((R) => R.value === c.value);
      if (!N?.url) {
        c.value = w?.value ?? g ?? "";
        return;
      }
      Oe(G("loadingDiff"), { pending: !0 }), window.location.href = N.url;
    });
  }
  function vf(c, o) {
    const g = Sl(c), O = Qn(o);
    if (_a(c, []), V && (V.cleanUp?.(), V = null), H = null, m.fileSearchOpen = !1, Ct.textContent = "", De.textContent = `${g}`, Ii(c), O)
      try {
        $i(c, o), re();
        return;
      } catch (N) {
        console.warn("cmux diff file tree setup failed", N);
      }
    const w = fl(c);
    _a(c, w), Vn(w), re();
  }
  function yf(c, o) {
    const g = Sl(c);
    if (_a(c, []), De.textContent = `${g}`, Ii(c), V && Ct.dataset.treeMode === "pierre" && o?.preparePresortedFileTreeInput) {
      Aa(c, o);
      return;
    }
    if (V || Ct.childElementCount === 0) {
      vf(c, o);
      return;
    }
    const O = fl(c);
    _a(c, O), Ct.textContent = "", Vn(O);
  }
  function $i(c, o) {
    const { FileTree: g, preparePresortedFileTreeInput: O } = o, w = Tl(c);
    H = c;
    const N = w[0];
    Yt(c), Ct.dataset.treeMode = "pierre", V = new g({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: N ? [N] : [],
      initialVisibleRowCount: cl(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: O(w),
      presorted: !0,
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: c.gitStatus,
      renderRowDecoration(R) {
        if (R.item.kind !== "file")
          return null;
        const st = $.get(R.item.path);
        return st == null || st.added === 0 && st.deleted === 0 ? null : {
          text: `+${st.added} -${st.deleted}`,
          title: `${st.added} ${G("additions")}, ${st.deleted} ${G("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Zl(),
      onSelectionChange(R) {
        if (gl)
          return;
        const st = R[R.length - 1], At = Xe.get(st);
        At && Kl(At);
      }
    }), V.render({ containerWrapper: Ct });
  }
  function Aa(c, o) {
    const g = H, O = Tl(c);
    H = c, Yt(c);
    let w = !1;
    if (g && (c.previousSource === g || Vl(g, c)) && c.pathCount >= g.pathCount) {
      const N = c.paths.slice(g.pathCount, c.pathCount);
      if (N.length > 0)
        try {
          V.batch(N.map((R) => ({ type: "add", path: R })));
        } catch (R) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", R), V.resetPaths(O, {
            preparedInput: o.preparePresortedFileTreeInput(O)
          }), w = !0;
        }
    } else
      V.resetPaths(O, {
        preparedInput: o.preparePresortedFileTreeInput(O)
      }), w = !0;
    c.gitStatusPatch ? typeof V.applyGitStatusPatch == "function" ? V.applyGitStatusPatch(c.gitStatusPatch) : V.setGitStatus(c.gitStatus) : (w || c.statsChanged === !0) && V.setGitStatus(c.gitStatus);
  }
  function Qn(c) {
    return !!(c?.FileTree && c?.preparePresortedFileTreeInput);
  }
  function Sl(c) {
    return c?.pathCount ?? c?.entries?.length ?? 0;
  }
  function fl(c) {
    const o = c?.pathCount ?? c?.entries?.length ?? 0, g = c?.entries ?? [];
    if (g.length > 0)
      return g.length === o ? g : g.slice(0, o);
    const O = Tl(c), w = c?.pathToItemId, N = c?.statsByPath;
    return O.map((R) => {
      const st = w instanceof Map ? w.get(R) : void 0, At = st ? M.get(st) : void 0, ot = At?.fileDiff ?? {};
      return {
        item: At ?? { id: st ?? R, fileDiff: ot },
        path: R,
        status: eu(ot),
        stats: N instanceof Map ? N.get(R) ?? Ca(ot) : Ca(ot)
      };
    });
  }
  function Tl(c) {
    const o = c?.pathCount ?? c?.paths?.length ?? 0, g = c?.paths ?? [];
    return g.length === o ? g : g.slice(0, o);
  }
  function Vl(c, o) {
    const g = c?.paths, O = o?.paths, w = c?.pathCount ?? g?.length ?? 0, N = o?.pathCount ?? O?.length ?? 0;
    if (!Array.isArray(g) || !Array.isArray(O) || w > N)
      return !1;
    for (let R = 0; R < w; R += 1)
      if (g[R] !== O[R])
        return !1;
    return !0;
  }
  function Yt(c) {
    if (c?.statsByPath instanceof Map) {
      $ = c.statsByPath;
      return;
    }
    $ = /* @__PURE__ */ new Map();
    const o = fl(c);
    for (const g of o)
      $.set(g.path, g.stats);
  }
  function _a(c, o) {
    if (c?.pathToItemId instanceof Map && c?.treePathByItemId instanceof Map)
      Xe = c.pathToItemId, nl = c.treePathByItemId;
    else if (c?.pathToItemId instanceof Map) {
      Xe = c.pathToItemId, nl = /* @__PURE__ */ new Map();
      for (const [g, O] of Xe)
        nl.set(O, g);
    } else {
      Xe = /* @__PURE__ */ new Map(), nl = /* @__PURE__ */ new Map();
      for (const g of o) {
        const O = g.item?.id;
        O && (Xe.set(g.path, O), nl.set(O, g.path));
      }
    }
    yt && !Xe.has(yt) && (yt = "");
  }
  function Vn(c) {
    delete Ct.dataset.treeMode;
    for (const o of c) {
      const g = o.item, O = g.fileDiff ?? {}, w = o.stats ?? Ca(O), N = document.createElement("button");
      N.type = "button", N.className = "file-entry", N.dataset.itemId = g.id, N.title = Da(O), N.innerHTML = `
      <span class="file-status">${Kn(O)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${w.added}</span>
        <span class="stat-del">-${w.deleted}</span>
      </span>
    `, N.querySelector(".file-name").textContent = Da(O), N.addEventListener("click", () => Kl(g.id)), Ct.append(N);
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
  function Ii(c) {
    const o = c?.diffStats;
    if (o && Number.isFinite(o.addedLines) && Number.isFinite(o.deletedLines) && Number.isFinite(o.fileCount)) {
      ee.textContent = `${o.fileCount}`, al.textContent = `+${o.addedLines}`, Le.textContent = `-${o.deletedLines}`;
      return;
    }
    Pi(c?.entries ?? []);
  }
  function Pi(c) {
    const o = c.reduce((g, O) => {
      const w = O.stats ?? Ca(O.item?.fileDiff ?? {});
      return g.added += w.added, g.deleted += w.deleted, g;
    }, { added: 0, deleted: 0 });
    ee.textContent = `${c.length}`, al.textContent = `+${o.added}`, Le.textContent = `-${o.deleted}`;
  }
  function Zn(c) {
    vt.textContent = "";
    const o = document.createElement("option");
    o.value = "", o.textContent = G("jumpToFile"), vt.append(o), vt.dataset.initialized = "true";
    for (const g of c) {
      const O = document.createElement("option");
      O.value = g.id, O.textContent = Da(g.fileDiff ?? {}), vt.append(O);
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
    for (const g of c) {
      const O = document.createElement("option");
      O.value = g.id, O.textContent = Da(g.fileDiff ?? {}), o.append(O);
    }
    vt.append(o), vt.hidden = !1;
  }
  function ln(c, o) {
    if (vt.dataset.initialized === "true") {
      for (const g of vt.options)
        if (g.value === c) {
          g.value = o;
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
    const o = k.findIndex((g) => g.id === c);
    if (o === -1)
      return s[0]?.id ?? "";
    for (let g = o + 1; g < k.length; g += 1)
      if (B.has(k[g].id))
        return k[g].id;
    for (let g = o - 1; g >= 0; g -= 1)
      if (B.has(k[g].id))
        return k[g].id;
    return "";
  }
  function ve(c) {
    if (!(!c || $t === c)) {
      $t = c, tu(c);
      for (const o of Ct.querySelectorAll(".file-entry"))
        o.setAttribute("aria-current", o.dataset.itemId === c ? "true" : "false");
      vt.value !== c && (vt.value = c);
    }
  }
  function tu(c) {
    if (!V)
      return;
    const o = nl.get(c);
    if (!(!o || o === yt)) {
      gl = !0;
      try {
        yt && V.getItem(yt)?.deselect(), V.getItem(o)?.select(), V.scrollToPath(o, { focus: !1, offset: "nearest" }), yt = o;
      } finally {
        jn(() => {
          gl = !1;
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
  function eu(c) {
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
  function Ca(c) {
    const o = { added: 0, deleted: 0 };
    for (const g of c.hunks ?? [])
      o.added += g.additionLines ?? 0, o.deleted += g.deletionLines ?? 0;
    return o;
  }
  function Te(c, o) {
    return c?.added === o.added && c?.deleted === o.deleted;
  }
  function ye(c) {
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
  function Ua(c, o) {
    c(o.name, () => Promise.resolve(Jl(o)));
  }
  function Jn(c, o, g, O) {
    const w = Array.from(new Set([
      c.theme?.light,
      c.theme?.dark
    ].filter(Boolean))), N = Array.from(new Set(o.flatMap((R) => {
      const st = R.fileDiff ?? {}, At = st.name ?? st.newName ?? st.oldName ?? st.prevName ?? "", ot = st.lang ?? g(At) ?? "text";
      return ot ? [ot] : [];
    })));
    return O({
      themes: w,
      langs: N.length > 0 ? N : ["text"]
    });
  }
  function Jl(c) {
    const o = c.palette ?? {}, g = c.foreground, O = c.background;
    return {
      name: c.name,
      displayName: c.ghosttyName,
      type: c.type,
      colors: {
        "editor.background": O,
        "editor.foreground": g,
        "terminal.background": O,
        "terminal.foreground": g,
        "terminal.ansiBlack": o[0] ?? g,
        "terminal.ansiRed": o[1] ?? g,
        "terminal.ansiGreen": o[2] ?? g,
        "terminal.ansiYellow": o[3] ?? g,
        "terminal.ansiBlue": o[4] ?? g,
        "terminal.ansiMagenta": o[5] ?? g,
        "terminal.ansiCyan": o[6] ?? g,
        "terminal.ansiWhite": o[7] ?? g,
        "terminal.ansiBrightBlack": o[8] ?? g,
        "terminal.ansiBrightRed": o[9] ?? o[1] ?? g,
        "terminal.ansiBrightGreen": o[10] ?? o[2] ?? g,
        "terminal.ansiBrightYellow": o[11] ?? o[3] ?? g,
        "terminal.ansiBrightBlue": o[12] ?? o[4] ?? g,
        "terminal.ansiBrightMagenta": o[13] ?? o[5] ?? g,
        "terminal.ansiBrightCyan": o[14] ?? o[6] ?? g,
        "terminal.ansiBrightWhite": o[15] ?? g,
        "gitDecoration.addedResourceForeground": o[10] ?? o[2] ?? "#32d74b",
        "gitDecoration.deletedResourceForeground": o[9] ?? o[1] ?? "#ff453a",
        "gitDecoration.modifiedResourceForeground": o[12] ?? o[4] ?? "#0a84ff",
        "editor.selectionBackground": c.selectionBackground,
        "editor.selectionForeground": c.selectionForeground
      },
      tokenColors: [
        { settings: { foreground: g, background: O } },
        { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: o[8] ?? g, fontStyle: "italic" } },
        { scope: ["string", "constant.other.symbol"], settings: { foreground: o[2] ?? g } },
        { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: o[3] ?? g } },
        { scope: ["keyword", "storage", "storage.type"], settings: { foreground: o[5] ?? g } },
        { scope: ["entity.name.function", "support.function"], settings: { foreground: o[4] ?? g } },
        { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: o[6] ?? g } },
        { scope: ["variable", "meta.definition.variable"], settings: { foreground: g } },
        { scope: ["invalid", "message.error"], settings: { foreground: o[9] ?? o[1] ?? g } }
      ]
    };
  }
}
function Ot(A, K) {
  return A.payload?.labels?.[K] ?? K;
}
const fg = ["82%", "64%", "76%", "58%", "70%", "46%"], cg = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
function og() {
  return /* @__PURE__ */ L.jsx("div", { className: "diff-loading-placeholder p-2", "aria-hidden": "true", children: fg.map((A, K) => /* @__PURE__ */ L.jsxs("div", { className: "grid h-[30px] grid-cols-[17px_minmax(0,1fr)_44px] items-center gap-2 rounded-md px-[7px]", children: [
    /* @__PURE__ */ L.jsx("span", { className: "size-[17px] rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ L.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: A } }),
    /* @__PURE__ */ L.jsx("span", { className: "h-3 justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: { width: K % 2 === 0 ? "34px" : "24px" } })
  ] }, `${A}-${K}`)) });
}
function rg() {
  return /* @__PURE__ */ L.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    /* @__PURE__ */ L.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
      /* @__PURE__ */ L.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ L.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ L.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
    ] }),
    /* @__PURE__ */ L.jsx("div", { className: "space-y-[13px] px-3 py-1", children: cg.map((A, K) => /* @__PURE__ */ L.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
      /* @__PURE__ */ L.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
      /* @__PURE__ */ L.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: A } })
    ] }, `${A}-${K}`)) })
  ] });
}
function sg({ config: A }) {
  return /* @__PURE__ */ L.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    /* @__PURE__ */ L.jsx("select", { id: "source-select", "aria-label": Ot(A, "diffTarget"), hidden: !0 }),
    /* @__PURE__ */ L.jsx("select", { id: "repo-select", "aria-label": Ot(A, "repoPath"), hidden: !0 }),
    /* @__PURE__ */ L.jsx("select", { id: "base-select", "aria-label": Ot(A, "branchBase"), hidden: !0 }),
    /* @__PURE__ */ L.jsx("span", { id: "source-detail" })
  ] });
}
function dg({ config: A }) {
  return /* @__PURE__ */ L.jsxs("header", { id: "toolbar", children: [
    /* @__PURE__ */ L.jsx(sg, { config: A }),
    /* @__PURE__ */ L.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ L.jsx("select", { id: "jump-select", "aria-label": Ot(A, "jumpToFile"), hidden: !0 }) }),
    /* @__PURE__ */ L.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
      /* @__PURE__ */ L.jsx(
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
      /* @__PURE__ */ L.jsx(
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
      /* @__PURE__ */ L.jsx(
        "button",
        {
          id: "layout-toggle",
          className: "toolbar-icon",
          type: "button",
          title: Ot(A, "switchToUnifiedDiff"),
          "aria-label": Ot(A, "switchToUnifiedDiff")
        }
      ),
      /* @__PURE__ */ L.jsx(
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
    /* @__PURE__ */ L.jsx("div", { id: "options-menu", role: "menu", "aria-label": Ot(A, "options"), hidden: !0 })
  ] });
}
function mg({ config: A }) {
  return /* @__PURE__ */ L.jsxs("aside", { id: "files-sidebar", "aria-label": Ot(A, "changedFiles"), children: [
    /* @__PURE__ */ L.jsxs("div", { id: "files-header", children: [
      /* @__PURE__ */ L.jsxs("span", { id: "files-title", children: [
        /* @__PURE__ */ L.jsx("span", { children: Ot(A, "files") }),
        /* @__PURE__ */ L.jsx("span", { id: "files-count" })
      ] }),
      /* @__PURE__ */ L.jsxs("span", { id: "files-header-actions", children: [
        /* @__PURE__ */ L.jsx(
          "button",
          {
            id: "file-search-toggle",
            type: "button",
            title: Ot(A, "showFileSearch"),
            "aria-label": Ot(A, "showFileSearch"),
            "aria-pressed": "false"
          }
        ),
        /* @__PURE__ */ L.jsx(
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
    /* @__PURE__ */ L.jsx("div", { id: "file-list", children: /* @__PURE__ */ L.jsx(og, {}) }),
    /* @__PURE__ */ L.jsxs("div", { id: "files-footer", "aria-label": Ot(A, "diffStats"), children: [
      /* @__PURE__ */ L.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ L.jsx("span", { children: Ot(A, "files") }),
        /* @__PURE__ */ L.jsx("strong", { id: "stats-files", children: "0" })
      ] }),
      /* @__PURE__ */ L.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ L.jsx("span", { children: Ot(A, "additions") }),
        /* @__PURE__ */ L.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" })
      ] }),
      /* @__PURE__ */ L.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ L.jsx("span", { children: Ot(A, "deletions") }),
        /* @__PURE__ */ L.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" })
      ] })
    ] })
  ] });
}
function hg({ config: A }) {
  const K = im.useRef(!1), rt = im.useCallback((b) => {
    !b || K.current || (K.current = !0, queueMicrotask(() => ug(A)));
  }, [A]);
  return /* @__PURE__ */ L.jsxs("div", { id: "app", ref: rt, children: [
    /* @__PURE__ */ L.jsx(dg, { config: A }),
    /* @__PURE__ */ L.jsxs("section", { id: "content", children: [
      /* @__PURE__ */ L.jsx(mg, { config: A }),
      /* @__PURE__ */ L.jsxs("main", { id: "viewer", "aria-label": Ot(A, "diffViewer"), children: [
        /* @__PURE__ */ L.jsx("div", { id: "status", children: A.payload?.statusMessage ?? Ot(A, "loadingDiff") }),
        /* @__PURE__ */ L.jsx(rg, {})
      ] })
    ] })
  ] });
}
const gg = '@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-space-y-reverse:0;--tw-border-style:solid}}}@layer theme{:root,:host{--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--spacing:.25rem;--radius-md:.375rem;--default-font-family:var(--font-sans);--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab,red,red)){::placeholder{color:color-mix(in oklab,currentcolor 50%,transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}}@layer components;@layer utilities{.\\@container{container-type:inline-size}.collapse{visibility:collapse}.visible{visibility:visible}.fixed{position:fixed}.static{position:static}.mx-3\\.5{margin-inline:calc(var(--spacing) * 3.5)}.mt-3\\.5{margin-top:calc(var(--spacing) * 3.5)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.flex{display:flex}.grid{display:grid}.hidden{display:none}.size-\\[17px\\]{width:17px;height:17px}.h-3{height:calc(var(--spacing) * 3)}.h-9{height:calc(var(--spacing) * 9)}.h-\\[30px\\]{height:30px}.h-px{height:1px}.w-2\\/5{width:40%}.min-w-0{min-width:calc(var(--spacing) * 0)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.grid-cols-\\[17px_minmax\\(0\\,1fr\\)_44px\\]{grid-template-columns:17px minmax(0,1fr) 44px}.grid-cols-\\[42px_minmax\\(0\\,1fr\\)\\]{grid-template-columns:42px minmax(0,1fr)}.grid-cols-\\[72px_minmax\\(0\\,1fr\\)_96px\\]{grid-template-columns:72px minmax(0,1fr) 96px}.items-center{align-items:center}.justify-center{justify-content:center}.gap-1\\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}:where(.space-y-\\[13px\\]>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(13px * var(--tw-space-y-reverse));margin-block-end:calc(13px * calc(1 - var(--tw-space-y-reverse)))}.justify-self-end{justify-self:flex-end}.rounded{border-radius:.25rem}.rounded-\\[5px\\]{border-radius:5px}.rounded-md{border-radius:var(--radius-md)}.border{border-style:var(--tw-border-style);border-width:1px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:color-mix(in lab,var(--cmux-diff-fg) 18%,transparent)}}.border-\\[var\\(--cmux-diff-border\\)\\]{border-color:var(--cmux-diff-border)}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.bg-\\[var\\(--cmux-diff-muted-bg\\)\\]{background-color:var(--cmux-diff-muted-bg)}.p-2{padding:calc(var(--spacing) * 2)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-\\[7px\\]{padding-inline:7px}.py-1{padding-block:calc(var(--spacing) * 1)}.pt-3{padding-top:calc(var(--spacing) * 3)}.italic{font-style:italic}.opacity-70{opacity:.7}}:root{color-scheme:light dark;--cmux-diff-bg-light:#fff;--cmux-diff-bg-dark:#000;--cmux-diff-fg-light:#000;--cmux-diff-fg-dark:#fff;--cmux-diff-selection-bg-light:#abd8ff;--cmux-diff-selection-bg-dark:#3f638b;--cmux-diff-ui-font-family:system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size:12px;--cmux-diff-ui-line-height:16px;--cmux-diff-code-font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size:10px;--cmux-diff-line-height:20px;--cmux-diff-bg:var(--cmux-diff-bg-light);--cmux-diff-fg:var(--cmux-diff-fg-light);--cmux-diff-border:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-border:color-mix(in lab, var(--cmux-diff-fg) 12%, transparent)}}:root{--cmux-diff-sidebar-bg:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-sidebar-bg:color-mix(in lab, var(--cmux-diff-bg) 98%, var(--cmux-diff-fg))}}:root{--cmux-diff-muted-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-muted-bg:color-mix(in lab, var(--cmux-diff-fg) 8%, transparent)}}:root{--cmux-diff-hover-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-hover-bg:color-mix(in lab, var(--cmux-diff-fg) 10%, transparent)}}:root{--cmux-diff-accent:light-dark(#0a84ff,#7ab7ff);background:var(--cmux-diff-bg);color:var(--cmux-diff-fg)}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg:var(--cmux-diff-bg-dark);--cmux-diff-fg:var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{height:100%;overflow:hidden}body{background:var(--cmux-diff-bg);height:100vh;min-height:0;color:var(--cmux-diff-fg);font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height);flex-direction:column;margin:0;display:flex;overflow:hidden}#app{overscroll-behavior:contain;contain:strict;background:inherit;height:100vh;min-height:0;color:inherit;grid-template-rows:auto minmax(0,1fr);display:grid;overflow:hidden}#toolbar{border-bottom:1px solid var(--cmux-diff-fg);flex:none;align-items:center;gap:7px;min-height:32px;padding:3px 8px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#toolbar{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}#toolbar{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#toolbar{background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg))}}#toolbar{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#toolbar{color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg))}}#toolbar{z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{align-items:center;gap:6px;min-width:0;display:flex}.toolbar-left{flex:0 36%}.toolbar-middle{flex:auto;justify-content:center}.toolbar-actions{flex:none}#source-select,#repo-select,#base-select,#jump-select{appearance:none;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,var(--cmux-diff-fg);border:1px solid #0000;border-radius:6px;min-width:118px;max-width:min(30vw,320px);height:24px;padding:0 24px 0 9px}@supports (color:color-mix(in lab,red,red)){#source-select,#repo-select,#base-select,#jump-select{background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent)}}#source-select,#repo-select,#base-select,#jump-select{color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent)}}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent)}}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline-offset:1px}#source-detail{text-overflow:ellipsis;white-space:nowrap;min-width:0;color:var(--cmux-diff-fg);overflow:hidden}@supports (color:color-mix(in lab,red,red)){#source-detail{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}.toolbar-icon{width:28px;height:26px;color:var(--cmux-diff-fg);background:0 0;border:1px solid #0000;border-radius:6px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.toolbar-icon{color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg))}}.toolbar-icon{cursor:pointer;padding:0}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true],.toolbar-icon[aria-pressed=true]{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:16px;height:16px;display:block}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{border:1px solid var(--cmux-diff-fg);min-width:246px;padding:8px;position:absolute;top:calc(100% + 7px);right:10px}@supports (color:color-mix(in lab,red,red)){#options-menu{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent)}}#options-menu{background:var(--cmux-diff-bg);border-radius:8px}@supports (color:color-mix(in lab,red,red)){#options-menu{background:color-mix(in lab,var(--cmux-diff-bg) 94%,var(--cmux-diff-fg))}}#options-menu{z-index:100;box-shadow:0 16px 34px lab(0% none none/.28)}#options-menu[hidden]{display:none}.menu-separator{background:var(--cmux-diff-fg);height:1px;margin:7px 6px}@supports (color:color-mix(in lab,red,red)){.menu-separator{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.menu-item{width:100%;min-height:31px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:6px;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;display:grid}@supports (color:color-mix(in lab,red,red)){.menu-item{color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg))}}.menu-item{font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.menu-item:hover:not(:disabled){color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:0 0}.menu-segment-controls{background:var(--cmux-diff-bg);border-radius:7px;justify-self:end;align-items:center;gap:2px;padding:2px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.menu-segment-controls{background:color-mix(in lab,var(--cmux-diff-bg) 82%,var(--cmux-diff-fg))}}.segment-button{width:27px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.segment-button{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.segment-button{padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.segment-button:hover,.segment-button[aria-pressed=true],.menu-item:disabled{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}}.menu-label{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.menu-check{justify-self:end}#content{--cmux-diff-files-width:clamp(190px, 22vw, 252px);grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);overscroll-behavior:contain;contain:strict;background:inherit;flex:auto;grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";min-width:0;min-height:0;display:grid;position:relative;overflow:hidden}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}#files-sidebar{border-left:1px solid var(--cmux-diff-border);background:var(--cmux-diff-bg);flex-direction:column;grid-area:files;width:100%;min-width:0;height:100%;min-height:0;display:flex;position:relative;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#files-sidebar{background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg))}}#files-sidebar{contain:strict;opacity:1;transition:opacity .1s,visibility linear}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s,visibility 0s linear .1s}#files-header{z-index:1;border-bottom:1px solid var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:8px;min-height:30px;padding:0 7px 0 10px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#files-header{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-header{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#files-header{background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg))}}#files-header{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#files-header{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}#files-title{align-items:center;gap:6px;min-width:0;display:inline-flex}#files-header-actions{flex:none;align-items:center;gap:2px;display:inline-flex}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;flex:none;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){#file-search-toggle,#file-collapse-toggle{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}#file-search-toggle,#file-collapse-toggle{padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:15px;height:15px}#file-list{--trees-bg-override:var(--cmux-diff-sidebar-bg);--trees-fg-override:var(--cmux-diff-fg);flex:auto;min-height:0;padding:6px 4px 6px 6px;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-override:color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg))}}#file-list{--trees-fg-muted-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-muted-override:color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg))}}#file-list{--trees-bg-muted-override:var(--cmux-diff-hover-bg);--trees-selected-bg-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-selected-bg-override:color-mix(in lab, var(--cmux-diff-fg) 11%, transparent)}}#file-list{--trees-selected-fg-override:var(--cmux-diff-fg);--trees-selected-focused-border-color-override:transparent;--trees-border-color-override:var(--cmux-diff-border);--trees-focus-ring-color-override:var(--cmux-diff-accent)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-focus-ring-color-override:color-mix(in lab, var(--cmux-diff-accent) 72%, transparent)}}#file-list{--trees-font-family-override:var(--cmux-diff-ui-font-family);--trees-font-size-override:var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override:500;--trees-density-override:.78;--trees-border-radius-override:5px;--trees-item-padding-x-override:7px;--trees-item-margin-x-override:0;--trees-padding-inline-override:0;--trees-search-bg-override:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-search-bg-override:color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))}}#file-list{--trees-status-added-override:light-dark(#257a3e,#8fd88f);--trees-status-modified-override:var(--cmux-diff-accent);--trees-status-renamed-override:light-dark(#a26300,#ffd166);--trees-status-deleted-override:light-dark(#b42318,#ff8a80)}body[data-loading=false] .diff-loading-placeholder{display:none}#file-list file-tree-container{width:100%;height:100%}#files-footer{border-top:1px solid var(--cmux-diff-fg);flex:none;padding:7px 10px 8px}@supports (color:color-mix(in lab,red,red)){#files-footer{border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-footer{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#files-footer{background:color-mix(in lab,var(--cmux-diff-bg) 97%,var(--cmux-diff-fg))}}.stats-row{min-height:19px;color:var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:10px;display:flex}@supports (color:color-mix(in lab,red,red)){.stats-row{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}.stats-row strong{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg))}}.stats-row strong{font-weight:600}.file-entry{width:100%;min-height:30px;color:inherit;font:inherit;text-align:left;background:0 0;border:0;border-radius:6px;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;padding:3px 7px;display:grid}.file-entry:hover,.file-entry[aria-current=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.file-status{width:17px;height:17px;color:var(--cmux-diff-fg);border:1px solid;border-radius:5px;justify-content:center;align-items:center;font-size:9px;line-height:1;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-status{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.file-name{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.file-stats{color:var(--cmux-diff-fg);gap:5px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-stats{color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));overscroll-behavior:contain;overflow-anchor:none;contain:strict;will-change:scroll-position;border-bottom:1px solid var(--cmux-diff-border);background:inherit;grid-area:viewer;width:100%;min-width:0;height:100%;min-height:0;position:relative;overflow:clip auto}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border);display:block;overflow:clip}#status{z-index:2;border-bottom:1px solid var(--cmux-diff-fg);align-items:center;gap:10px;min-height:40px;padding:10px 14px;display:flex;position:sticky;top:0}@supports (color:color-mix(in lab,red,red)){#status{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#status{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#status{background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg))}}#status{font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status{color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{content:"";border:2px solid var(--cmux-diff-fg);flex:none;width:14px;height:14px}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent)}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-radius:50%;animation:.8s linear infinite cmuxDiffPendingSpin}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before,body[data-loading=true] #status:before{animation:none}}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}';
function pg() {
  const A = document.getElementById("cmux-diff-viewer-config");
  if (!A?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(A.textContent);
}
function vg() {
  const A = document.createElement("style");
  A.dataset.cmuxDiffViewerStyle = "true", A.textContent = gg, document.head.append(A);
}
const sf = pg();
vg();
document.title = sf.payload?.title ?? document.title;
document.body.dataset.filesHidden = "false";
document.body.dataset.loading = sf.payload?.pendingReplacement || !sf.payload?.statusMessage ? "true" : "false";
document.body.dataset.statusOnly = "false";
const um = document.getElementById("root");
if (!um)
  throw new Error("Missing cmux diff viewer root");
ig.createRoot(um).render(/* @__PURE__ */ L.jsx(hg, { config: sf }));
