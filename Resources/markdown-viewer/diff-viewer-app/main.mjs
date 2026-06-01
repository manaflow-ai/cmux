var po = { exports: {} }, ji = {};
var Fd;
function Wh() {
  if (Fd) return ji;
  Fd = 1;
  var T = /* @__PURE__ */ Symbol.for("react.transitional.element"), L = /* @__PURE__ */ Symbol.for("react.fragment");
  function lt(v, yt, Ut) {
    var Bt = null;
    if (Ut !== void 0 && (Bt = "" + Ut), yt.key !== void 0 && (Bt = "" + yt.key), "key" in yt) {
      Ut = {};
      for (var te in yt)
        te !== "key" && (Ut[te] = yt[te]);
    } else Ut = yt;
    return yt = Ut.ref, {
      $$typeof: T,
      type: v,
      key: Bt,
      ref: yt !== void 0 ? yt : null,
      props: Ut
    };
  }
  return ji.Fragment = L, ji.jsx = lt, ji.jsxs = lt, ji;
}
var Wd;
function $h() {
  return Wd || (Wd = 1, po.exports = Wh()), po.exports;
}
var X = $h(), vo = { exports: {} }, qi = {}, yo = { exports: {} }, bo = {};
var $d;
function Ih() {
  return $d || ($d = 1, (function(T) {
    function L(m, D) {
      var Y = m.length;
      m.push(D);
      t: for (; 0 < Y; ) {
        var Z = Y - 1 >>> 1, k = m[Z];
        if (0 < yt(k, D))
          m[Z] = D, m[Y] = k, Y = Z;
        else break t;
      }
    }
    function lt(m) {
      return m.length === 0 ? null : m[0];
    }
    function v(m) {
      if (m.length === 0) return null;
      var D = m[0], Y = m.pop();
      if (Y !== D) {
        m[0] = Y;
        t: for (var Z = 0, k = m.length, s = k >>> 1; Z < s; ) {
          var M = 2 * (Z + 1) - 1, B = m[M], R = M + 1, F = m[R];
          if (0 > yt(B, Y))
            R < k && 0 > yt(F, B) ? (m[Z] = F, m[R] = Y, Z = R) : (m[Z] = B, m[M] = Y, Z = M);
          else if (R < k && 0 > yt(F, Y))
            m[Z] = F, m[R] = Y, Z = R;
          else break t;
        }
      }
      return D;
    }
    function yt(m, D) {
      var Y = m.sortIndex - D.sortIndex;
      return Y !== 0 ? Y : m.id - D.id;
    }
    if (T.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var Ut = performance;
      T.unstable_now = function() {
        return Ut.now();
      };
    } else {
      var Bt = Date, te = Bt.now();
      T.unstable_now = function() {
        return Bt.now() - te;
      };
    }
    var U = [], _ = [], nt = 1, Q = null, _t = 3, Vt = !1, oe = !1, ee = !1, we = !1, bt = typeof setTimeout == "function" ? setTimeout : null, je = typeof clearTimeout == "function" ? clearTimeout : null, wt = typeof setImmediate < "u" ? setImmediate : null;
    function Wt(m) {
      for (var D = lt(_); D !== null; ) {
        if (D.callback === null) v(_);
        else if (D.startTime <= m)
          v(_), D.sortIndex = D.expirationTime, L(U, D);
        else break;
        D = lt(_);
      }
    }
    function re(m) {
      if (ee = !1, Wt(m), !oe)
        if (lt(U) !== null)
          oe = !0, jt || (jt = !0, le());
        else {
          var D = lt(_);
          D !== null && q(re, D.startTime - m);
        }
    }
    var jt = !1, at = -1, Nt = 5, Ae = -1;
    function be() {
      return we ? !0 : !(T.unstable_now() - Ae < Nt);
    }
    function se() {
      if (we = !1, jt) {
        var m = T.unstable_now();
        Ae = m;
        var D = !0;
        try {
          t: {
            oe = !1, ee && (ee = !1, je(at), at = -1), Vt = !0;
            var Y = _t;
            try {
              e: {
                for (Wt(m), Q = lt(U); Q !== null && !(Q.expirationTime > m && be()); ) {
                  var Z = Q.callback;
                  if (typeof Z == "function") {
                    Q.callback = null, _t = Q.priorityLevel;
                    var k = Z(
                      Q.expirationTime <= m
                    );
                    if (m = T.unstable_now(), typeof k == "function") {
                      Q.callback = k, Wt(m), D = !0;
                      break e;
                    }
                    Q === lt(U) && v(U), Wt(m);
                  } else v(U);
                  Q = lt(U);
                }
                if (Q !== null) D = !0;
                else {
                  var s = lt(_);
                  s !== null && q(
                    re,
                    s.startTime - m
                  ), D = !1;
                }
              }
              break t;
            } finally {
              Q = null, _t = Y, Vt = !1;
            }
            D = void 0;
          }
        } finally {
          D ? le() : jt = !1;
        }
      }
    }
    var le;
    if (typeof wt == "function")
      le = function() {
        wt(se);
      };
    else if (typeof MessageChannel < "u") {
      var il = new MessageChannel(), qe = il.port2;
      il.port1.onmessage = se, le = function() {
        qe.postMessage(null);
      };
    } else
      le = function() {
        bt(se, 0);
      };
    function q(m, D) {
      at = bt(function() {
        m(T.unstable_now());
      }, D);
    }
    T.unstable_IdlePriority = 5, T.unstable_ImmediatePriority = 1, T.unstable_LowPriority = 4, T.unstable_NormalPriority = 3, T.unstable_Profiling = null, T.unstable_UserBlockingPriority = 2, T.unstable_cancelCallback = function(m) {
      m.callback = null;
    }, T.unstable_forceFrameRate = function(m) {
      0 > m || 125 < m ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : Nt = 0 < m ? Math.floor(1e3 / m) : 5;
    }, T.unstable_getCurrentPriorityLevel = function() {
      return _t;
    }, T.unstable_next = function(m) {
      switch (_t) {
        case 1:
        case 2:
        case 3:
          var D = 3;
          break;
        default:
          D = _t;
      }
      var Y = _t;
      _t = D;
      try {
        return m();
      } finally {
        _t = Y;
      }
    }, T.unstable_requestPaint = function() {
      we = !0;
    }, T.unstable_runWithPriority = function(m, D) {
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
      var Y = _t;
      _t = m;
      try {
        return D();
      } finally {
        _t = Y;
      }
    }, T.unstable_scheduleCallback = function(m, D, Y) {
      var Z = T.unstable_now();
      switch (typeof Y == "object" && Y !== null ? (Y = Y.delay, Y = typeof Y == "number" && 0 < Y ? Z + Y : Z) : Y = Z, m) {
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
        id: nt++,
        callback: D,
        priorityLevel: m,
        startTime: Y,
        expirationTime: k,
        sortIndex: -1
      }, Y > Z ? (m.sortIndex = Y, L(_, m), lt(U) === null && m === lt(_) && (ee ? (je(at), at = -1) : ee = !0, q(re, Y - Z))) : (m.sortIndex = k, L(U, m), oe || Vt || (oe = !0, jt || (jt = !0, le()))), m;
    }, T.unstable_shouldYield = be, T.unstable_wrapCallback = function(m) {
      var D = _t;
      return function() {
        var Y = _t;
        _t = D;
        try {
          return m.apply(this, arguments);
        } finally {
          _t = Y;
        }
      };
    };
  })(bo)), bo;
}
var Id;
function Ph() {
  return Id || (Id = 1, yo.exports = Ih()), yo.exports;
}
var xo = { exports: {} }, $ = {};
var Pd;
function tg() {
  if (Pd) return $;
  Pd = 1;
  var T = /* @__PURE__ */ Symbol.for("react.transitional.element"), L = /* @__PURE__ */ Symbol.for("react.portal"), lt = /* @__PURE__ */ Symbol.for("react.fragment"), v = /* @__PURE__ */ Symbol.for("react.strict_mode"), yt = /* @__PURE__ */ Symbol.for("react.profiler"), Ut = /* @__PURE__ */ Symbol.for("react.consumer"), Bt = /* @__PURE__ */ Symbol.for("react.context"), te = /* @__PURE__ */ Symbol.for("react.forward_ref"), U = /* @__PURE__ */ Symbol.for("react.suspense"), _ = /* @__PURE__ */ Symbol.for("react.memo"), nt = /* @__PURE__ */ Symbol.for("react.lazy"), Q = /* @__PURE__ */ Symbol.for("react.activity"), _t = Symbol.iterator;
  function Vt(s) {
    return s === null || typeof s != "object" ? null : (s = _t && s[_t] || s["@@iterator"], typeof s == "function" ? s : null);
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
  }, ee = Object.assign, we = {};
  function bt(s, M, B) {
    this.props = s, this.context = M, this.refs = we, this.updater = B || oe;
  }
  bt.prototype.isReactComponent = {}, bt.prototype.setState = function(s, M) {
    if (typeof s != "object" && typeof s != "function" && s != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, s, M, "setState");
  }, bt.prototype.forceUpdate = function(s) {
    this.updater.enqueueForceUpdate(this, s, "forceUpdate");
  };
  function je() {
  }
  je.prototype = bt.prototype;
  function wt(s, M, B) {
    this.props = s, this.context = M, this.refs = we, this.updater = B || oe;
  }
  var Wt = wt.prototype = new je();
  Wt.constructor = wt, ee(Wt, bt.prototype), Wt.isPureReactComponent = !0;
  var re = Array.isArray;
  function jt() {
  }
  var at = { H: null, A: null, T: null, S: null }, Nt = Object.prototype.hasOwnProperty;
  function Ae(s, M, B) {
    var R = B.ref;
    return {
      $$typeof: T,
      type: s,
      key: M,
      ref: R !== void 0 ? R : null,
      props: B
    };
  }
  function be(s, M) {
    return Ae(s.type, M, s.props);
  }
  function se(s) {
    return typeof s == "object" && s !== null && s.$$typeof === T;
  }
  function le(s) {
    var M = { "=": "=0", ":": "=2" };
    return "$" + s.replace(/[=:]/g, function(B) {
      return M[B];
    });
  }
  var il = /\/+/g;
  function qe(s, M) {
    return typeof s == "object" && s !== null && s.key != null ? le("" + s.key) : M.toString(36);
  }
  function q(s) {
    switch (s.status) {
      case "fulfilled":
        return s.value;
      case "rejected":
        throw s.reason;
      default:
        switch (typeof s.status == "string" ? s.then(jt, jt) : (s.status = "pending", s.then(
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
  function m(s, M, B, R, F) {
    var I = typeof s;
    (I === "undefined" || I === "boolean") && (s = null);
    var rt = !1;
    if (s === null) rt = !0;
    else
      switch (I) {
        case "bigint":
        case "string":
        case "number":
          rt = !0;
          break;
        case "object":
          switch (s.$$typeof) {
            case T:
            case L:
              rt = !0;
              break;
            case nt:
              return rt = s._init, m(
                rt(s._payload),
                M,
                B,
                R,
                F
              );
          }
      }
    if (rt)
      return F = F(s), rt = R === "" ? "." + qe(s, 0) : R, re(F) ? (B = "", rt != null && (B = rt.replace(il, "$&/") + "/"), m(F, M, B, "", function(gl) {
        return gl;
      })) : F != null && (se(F) && (F = be(
        F,
        B + (F.key == null || s && s.key === F.key ? "" : ("" + F.key).replace(
          il,
          "$&/"
        ) + "/") + rt
      )), M.push(F)), 1;
    rt = 0;
    var It = R === "" ? "." : R + ":";
    if (re(s))
      for (var xt = 0; xt < s.length; xt++)
        R = s[xt], I = It + qe(R, xt), rt += m(
          R,
          M,
          B,
          I,
          F
        );
    else if (xt = Vt(s), typeof xt == "function")
      for (s = xt.call(s), xt = 0; !(R = s.next()).done; )
        R = R.value, I = It + qe(R, xt++), rt += m(
          R,
          M,
          B,
          I,
          F
        );
    else if (I === "object") {
      if (typeof s.then == "function")
        return m(
          q(s),
          M,
          B,
          R,
          F
        );
      throw M = String(s), Error(
        "Objects are not valid as a React child (found: " + (M === "[object Object]" ? "object with keys {" + Object.keys(s).join(", ") + "}" : M) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return rt;
  }
  function D(s, M, B) {
    if (s == null) return s;
    var R = [], F = 0;
    return m(s, R, "", "", function(I) {
      return M.call(B, I, F++);
    }), R;
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
  var Z = typeof reportError == "function" ? reportError : function(s) {
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
      if (!se(s))
        throw Error(
          "React.Children.only expected to receive a single React element child."
        );
      return s;
    }
  };
  return $.Activity = Q, $.Children = k, $.Component = bt, $.Fragment = lt, $.Profiler = yt, $.PureComponent = wt, $.StrictMode = v, $.Suspense = U, $.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = at, $.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(s) {
      return at.H.useMemoCache(s);
    }
  }, $.cache = function(s) {
    return function() {
      return s.apply(null, arguments);
    };
  }, $.cacheSignal = function() {
    return null;
  }, $.cloneElement = function(s, M, B) {
    if (s == null)
      throw Error(
        "The argument must be a React element, but you passed " + s + "."
      );
    var R = ee({}, s.props), F = s.key;
    if (M != null)
      for (I in M.key !== void 0 && (F = "" + M.key), M)
        !Nt.call(M, I) || I === "key" || I === "__self" || I === "__source" || I === "ref" && M.ref === void 0 || (R[I] = M[I]);
    var I = arguments.length - 2;
    if (I === 1) R.children = B;
    else if (1 < I) {
      for (var rt = Array(I), It = 0; It < I; It++)
        rt[It] = arguments[It + 2];
      R.children = rt;
    }
    return Ae(s.type, F, R);
  }, $.createContext = function(s) {
    return s = {
      $$typeof: Bt,
      _currentValue: s,
      _currentValue2: s,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, s.Provider = s, s.Consumer = {
      $$typeof: Ut,
      _context: s
    }, s;
  }, $.createElement = function(s, M, B) {
    var R, F = {}, I = null;
    if (M != null)
      for (R in M.key !== void 0 && (I = "" + M.key), M)
        Nt.call(M, R) && R !== "key" && R !== "__self" && R !== "__source" && (F[R] = M[R]);
    var rt = arguments.length - 2;
    if (rt === 1) F.children = B;
    else if (1 < rt) {
      for (var It = Array(rt), xt = 0; xt < rt; xt++)
        It[xt] = arguments[xt + 2];
      F.children = It;
    }
    if (s && s.defaultProps)
      for (R in rt = s.defaultProps, rt)
        F[R] === void 0 && (F[R] = rt[R]);
    return Ae(s, I, F);
  }, $.createRef = function() {
    return { current: null };
  }, $.forwardRef = function(s) {
    return { $$typeof: te, render: s };
  }, $.isValidElement = se, $.lazy = function(s) {
    return {
      $$typeof: nt,
      _payload: { _status: -1, _result: s },
      _init: Y
    };
  }, $.memo = function(s, M) {
    return {
      $$typeof: _,
      type: s,
      compare: M === void 0 ? null : M
    };
  }, $.startTransition = function(s) {
    var M = at.T, B = {};
    at.T = B;
    try {
      var R = s(), F = at.S;
      F !== null && F(B, R), typeof R == "object" && R !== null && typeof R.then == "function" && R.then(jt, Z);
    } catch (I) {
      Z(I);
    } finally {
      M !== null && B.types !== null && (M.types = B.types), at.T = M;
    }
  }, $.unstable_useCacheRefresh = function() {
    return at.H.useCacheRefresh();
  }, $.use = function(s) {
    return at.H.use(s);
  }, $.useActionState = function(s, M, B) {
    return at.H.useActionState(s, M, B);
  }, $.useCallback = function(s, M) {
    return at.H.useCallback(s, M);
  }, $.useContext = function(s) {
    return at.H.useContext(s);
  }, $.useDebugValue = function() {
  }, $.useDeferredValue = function(s, M) {
    return at.H.useDeferredValue(s, M);
  }, $.useEffect = function(s, M) {
    return at.H.useEffect(s, M);
  }, $.useEffectEvent = function(s) {
    return at.H.useEffectEvent(s);
  }, $.useId = function() {
    return at.H.useId();
  }, $.useImperativeHandle = function(s, M, B) {
    return at.H.useImperativeHandle(s, M, B);
  }, $.useInsertionEffect = function(s, M) {
    return at.H.useInsertionEffect(s, M);
  }, $.useLayoutEffect = function(s, M) {
    return at.H.useLayoutEffect(s, M);
  }, $.useMemo = function(s, M) {
    return at.H.useMemo(s, M);
  }, $.useOptimistic = function(s, M) {
    return at.H.useOptimistic(s, M);
  }, $.useReducer = function(s, M, B) {
    return at.H.useReducer(s, M, B);
  }, $.useRef = function(s) {
    return at.H.useRef(s);
  }, $.useState = function(s) {
    return at.H.useState(s);
  }, $.useSyncExternalStore = function(s, M, B) {
    return at.H.useSyncExternalStore(
      s,
      M,
      B
    );
  }, $.useTransition = function() {
    return at.H.useTransition();
  }, $.version = "19.2.3", $;
}
var tm;
function To() {
  return tm || (tm = 1, xo.exports = tg()), xo.exports;
}
var So = { exports: {} }, ge = {};
var em;
function eg() {
  if (em) return ge;
  em = 1;
  var T = To();
  function L(U) {
    var _ = "https://react.dev/errors/" + U;
    if (1 < arguments.length) {
      _ += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var nt = 2; nt < arguments.length; nt++)
        _ += "&args[]=" + encodeURIComponent(arguments[nt]);
    }
    return "Minified React error #" + U + "; visit " + _ + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function lt() {
  }
  var v = {
    d: {
      f: lt,
      r: function() {
        throw Error(L(522));
      },
      D: lt,
      C: lt,
      L: lt,
      m: lt,
      X: lt,
      S: lt,
      M: lt
    },
    p: 0,
    findDOMNode: null
  }, yt = /* @__PURE__ */ Symbol.for("react.portal");
  function Ut(U, _, nt) {
    var Q = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: yt,
      key: Q == null ? null : "" + Q,
      children: U,
      containerInfo: _,
      implementation: nt
    };
  }
  var Bt = T.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function te(U, _) {
    if (U === "font") return "";
    if (typeof _ == "string")
      return _ === "use-credentials" ? _ : "";
  }
  return ge.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = v, ge.createPortal = function(U, _) {
    var nt = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!_ || _.nodeType !== 1 && _.nodeType !== 9 && _.nodeType !== 11)
      throw Error(L(299));
    return Ut(U, _, null, nt);
  }, ge.flushSync = function(U) {
    var _ = Bt.T, nt = v.p;
    try {
      if (Bt.T = null, v.p = 2, U) return U();
    } finally {
      Bt.T = _, v.p = nt, v.d.f();
    }
  }, ge.preconnect = function(U, _) {
    typeof U == "string" && (_ ? (_ = _.crossOrigin, _ = typeof _ == "string" ? _ === "use-credentials" ? _ : "" : void 0) : _ = null, v.d.C(U, _));
  }, ge.prefetchDNS = function(U) {
    typeof U == "string" && v.d.D(U);
  }, ge.preinit = function(U, _) {
    if (typeof U == "string" && _ && typeof _.as == "string") {
      var nt = _.as, Q = te(nt, _.crossOrigin), _t = typeof _.integrity == "string" ? _.integrity : void 0, Vt = typeof _.fetchPriority == "string" ? _.fetchPriority : void 0;
      nt === "style" ? v.d.S(
        U,
        typeof _.precedence == "string" ? _.precedence : void 0,
        {
          crossOrigin: Q,
          integrity: _t,
          fetchPriority: Vt
        }
      ) : nt === "script" && v.d.X(U, {
        crossOrigin: Q,
        integrity: _t,
        fetchPriority: Vt,
        nonce: typeof _.nonce == "string" ? _.nonce : void 0
      });
    }
  }, ge.preinitModule = function(U, _) {
    if (typeof U == "string")
      if (typeof _ == "object" && _ !== null) {
        if (_.as == null || _.as === "script") {
          var nt = te(
            _.as,
            _.crossOrigin
          );
          v.d.M(U, {
            crossOrigin: nt,
            integrity: typeof _.integrity == "string" ? _.integrity : void 0,
            nonce: typeof _.nonce == "string" ? _.nonce : void 0
          });
        }
      } else _ == null && v.d.M(U);
  }, ge.preload = function(U, _) {
    if (typeof U == "string" && typeof _ == "object" && _ !== null && typeof _.as == "string") {
      var nt = _.as, Q = te(nt, _.crossOrigin);
      v.d.L(U, nt, {
        crossOrigin: Q,
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
  }, ge.preloadModule = function(U, _) {
    if (typeof U == "string")
      if (_) {
        var nt = te(_.as, _.crossOrigin);
        v.d.m(U, {
          as: typeof _.as == "string" && _.as !== "script" ? _.as : void 0,
          crossOrigin: nt,
          integrity: typeof _.integrity == "string" ? _.integrity : void 0
        });
      } else v.d.m(U);
  }, ge.requestFormReset = function(U) {
    v.d.r(U);
  }, ge.unstable_batchedUpdates = function(U, _) {
    return U(_);
  }, ge.useFormState = function(U, _, nt) {
    return Bt.H.useFormState(U, _, nt);
  }, ge.useFormStatus = function() {
    return Bt.H.useHostTransitionStatus();
  }, ge.version = "19.2.3", ge;
}
var lm;
function lg() {
  if (lm) return So.exports;
  lm = 1;
  function T() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(T);
      } catch (L) {
        console.error(L);
      }
  }
  return T(), So.exports = eg(), So.exports;
}
var am;
function ag() {
  if (am) return qi;
  am = 1;
  var T = Ph(), L = To(), lt = lg();
  function v(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function yt(t) {
    return !(!t || t.nodeType !== 1 && t.nodeType !== 9 && t.nodeType !== 11);
  }
  function Ut(t) {
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
  function Bt(t) {
    if (t.tag === 13) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function te(t) {
    if (t.tag === 31) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function U(t) {
    if (Ut(t) !== t)
      throw Error(v(188));
  }
  function _(t) {
    var e = t.alternate;
    if (!e) {
      if (e = Ut(t), e === null) throw Error(v(188));
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
        throw Error(v(188));
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
          if (!u) throw Error(v(189));
        }
      }
      if (l.alternate !== a) throw Error(v(190));
    }
    if (l.tag !== 3) throw Error(v(188));
    return l.stateNode.current === l ? t : e;
  }
  function nt(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t;
    for (t = t.child; t !== null; ) {
      if (e = nt(t), e !== null) return e;
      t = t.sibling;
    }
    return null;
  }
  var Q = Object.assign, _t = /* @__PURE__ */ Symbol.for("react.element"), Vt = /* @__PURE__ */ Symbol.for("react.transitional.element"), oe = /* @__PURE__ */ Symbol.for("react.portal"), ee = /* @__PURE__ */ Symbol.for("react.fragment"), we = /* @__PURE__ */ Symbol.for("react.strict_mode"), bt = /* @__PURE__ */ Symbol.for("react.profiler"), je = /* @__PURE__ */ Symbol.for("react.consumer"), wt = /* @__PURE__ */ Symbol.for("react.context"), Wt = /* @__PURE__ */ Symbol.for("react.forward_ref"), re = /* @__PURE__ */ Symbol.for("react.suspense"), jt = /* @__PURE__ */ Symbol.for("react.suspense_list"), at = /* @__PURE__ */ Symbol.for("react.memo"), Nt = /* @__PURE__ */ Symbol.for("react.lazy"), Ae = /* @__PURE__ */ Symbol.for("react.activity"), be = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), se = Symbol.iterator;
  function le(t) {
    return t === null || typeof t != "object" ? null : (t = se && t[se] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var il = /* @__PURE__ */ Symbol.for("react.client.reference");
  function qe(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === il ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case ee:
        return "Fragment";
      case bt:
        return "Profiler";
      case we:
        return "StrictMode";
      case re:
        return "Suspense";
      case jt:
        return "SuspenseList";
      case Ae:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case oe:
          return "Portal";
        case wt:
          return t.displayName || "Context";
        case je:
          return (t._context.displayName || "Context") + ".Consumer";
        case Wt:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case at:
          return e = t.displayName || null, e !== null ? e : qe(t.type) || "Memo";
        case Nt:
          e = t._payload, t = t._init;
          try {
            return qe(t(e));
          } catch {
          }
      }
    return null;
  }
  var q = Array.isArray, m = L.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, D = lt.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, Y = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, Z = [], k = -1;
  function s(t) {
    return { current: t };
  }
  function M(t) {
    0 > k || (t.current = Z[k], Z[k] = null, k--);
  }
  function B(t, e) {
    k++, Z[k] = t.current, t.current = e;
  }
  var R = s(null), F = s(null), I = s(null), rt = s(null);
  function It(t, e) {
    switch (B(I, e), B(F, t), B(R, null), e.nodeType) {
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
    M(R), B(R, t);
  }
  function xt() {
    M(R), M(F), M(I);
  }
  function gl(t) {
    t.memoizedState !== null && B(rt, t);
    var e = R.current, l = bd(e, t.type);
    e !== l && (B(F, t), B(R, l));
  }
  function Ye(t) {
    F.current === t && (M(R), M(F)), rt.current === t && (M(rt), Ni._currentValue = Y);
  }
  var ul, Hn;
  function pl(t) {
    if (ul === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        ul = e && e[1] || "", Hn = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + ul + t + Hn;
  }
  var _e = !1;
  function wn(t, e) {
    if (!t || _e) return "";
    _e = !0;
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
                } catch (x) {
                  var y = x;
                }
                Reflect.construct(t, [], A);
              } else {
                try {
                  A.call();
                } catch (x) {
                  y = x;
                }
                t.call(A.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (x) {
                y = x;
              }
              (A = t()) && typeof A.catch == "function" && A.catch(function() {
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
        var o = u.split(`
`), p = f.split(`
`);
        for (n = a = 0; a < o.length && !o[a].includes("DetermineComponentFrameRoot"); )
          a++;
        for (; n < p.length && !p[n].includes(
          "DetermineComponentFrameRoot"
        ); )
          n++;
        if (a === o.length || n === p.length)
          for (a = o.length - 1, n = p.length - 1; 1 <= a && 0 <= n && o[a] !== p[n]; )
            n--;
        for (; 1 <= a && 0 <= n; a--, n--)
          if (o[a] !== p[n]) {
            if (a !== 1 || n !== 1)
              do
                if (a--, n--, 0 > n || o[a] !== p[n]) {
                  var S = `
` + o[a].replace(" at new ", " at ");
                  return t.displayName && S.includes("<anonymous>") && (S = S.replace("<anonymous>", t.displayName)), S;
                }
              while (1 <= a && 0 <= n);
            break;
          }
      }
    } finally {
      _e = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? pl(l) : "";
  }
  function ff(t, e) {
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
        return wn(t.type, !1);
      case 11:
        return wn(t.type.render, !1);
      case 1:
        return wn(t.type, !0);
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
        e += ff(t, l), l = t, t = t.return;
      while (t);
      return e;
    } catch (a) {
      return `
Error generating stack: ` + a.message + `
` + a.stack;
    }
  }
  var jn = Object.prototype.hasOwnProperty, qn = T.unstable_scheduleCallback, Sa = T.unstable_cancelCallback, Yn = T.unstable_shouldYield, Gi = T.unstable_requestPaint, ae = T.unstable_now, Li = T.unstable_getCurrentPriorityLevel, Xi = T.unstable_ImmediatePriority, Fa = T.unstable_UserBlockingPriority, Ta = T.unstable_NormalPriority, cf = T.unstable_LowPriority, Qi = T.unstable_IdlePriority, of = T.log, Vi = T.unstable_setDisableYieldValue, za = null, pe = null;
  function fl(t) {
    if (typeof of == "function" && Vi(t), pe && typeof pe.setStrictMode == "function")
      try {
        pe.setStrictMode(za, t);
      } catch {
      }
  }
  var ve = Math.clz32 ? Math.clz32 : Zi, rf = Math.log, Ma = Math.LN2;
  function Zi(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (rf(t) / Ma | 0) | 0;
  }
  var vl = 256, Wa = 262144, yl = 4194304;
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
  function $a(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, i = t.suspendedLanes, u = t.pingedLanes;
    t = t.warmLanes;
    var f = a & 134217727;
    return f !== 0 ? (a = f & ~i, a !== 0 ? n = bl(a) : (u &= f, u !== 0 ? n = bl(u) : l || (l = f & ~t, l !== 0 && (n = bl(l))))) : (f = a & ~i, f !== 0 ? n = bl(f) : u !== 0 ? n = bl(u) : l || (l = a & ~t, l !== 0 && (n = bl(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function Kl(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function Ki(t, e) {
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
  function Ji() {
    var t = yl;
    return yl <<= 1, (yl & 62914560) === 0 && (yl = 4194304), t;
  }
  function $e(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function Jl(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function sf(t, e, l, a, n, i) {
    var u = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var f = t.entanglements, o = t.expirationTimes, p = t.hiddenUpdates;
    for (l = u & ~l; 0 < l; ) {
      var S = 31 - ve(l), A = 1 << S;
      f[S] = 0, o[S] = -1;
      var y = p[S];
      if (y !== null)
        for (p[S] = null, S = 0; S < y.length; S++) {
          var x = y[S];
          x !== null && (x.lane &= -536870913);
        }
      l &= ~A;
    }
    a !== 0 && Ea(t, a, 0), i !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= i & ~(u & ~e));
  }
  function Ea(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - ve(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function Gn(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - ve(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function ki(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : de(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function de(t) {
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
  function Aa(t) {
    return t &= -t, 2 < t ? 8 < t ? (t & 134217727) !== 0 ? 32 : 268435456 : 8 : 2;
  }
  function Ia() {
    var t = D.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Xd(t.type));
  }
  function Fi(t, e) {
    var l = D.p;
    try {
      return D.p = t, e();
    } finally {
      D.p = l;
    }
  }
  var cl = Math.random().toString(36).slice(2), Zt = "__reactFiber$" + cl, me = "__reactProps$" + cl, xl = "__reactContainer$" + cl, Pa = "__reactEvents$" + cl, df = "__reactListeners$" + cl, mf = "__reactHandles$" + cl, Wi = "__reactResources$" + cl, _a = "__reactMarker$" + cl;
  function Ln(t) {
    delete t[Zt], delete t[me], delete t[Pa], delete t[df], delete t[mf];
  }
  function Sl(t) {
    var e = t[Zt];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[xl] || l[Zt]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Ad(t); t !== null; ) {
            if (l = t[Zt]) return l;
            t = Ad(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function ol(t) {
    if (t = t[Zt] || t[xl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function Tl(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(v(33));
  }
  function zl(t) {
    var e = t[Wi];
    return e || (e = t[Wi] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function qt(t) {
    t[_a] = !0;
  }
  var Xn = /* @__PURE__ */ new Set(), Qn = {};
  function Ml(t, e) {
    El(t, e), El(t + "Capture", e);
  }
  function El(t, e) {
    for (Qn[t] = e, t = 0; t < e.length; t++)
      Xn.add(e[t]);
  }
  var hf = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), Vn = {}, $i = {};
  function gf(t) {
    return jn.call($i, t) ? !0 : jn.call(Vn, t) ? !1 : hf.test(t) ? $i[t] = !0 : (Vn[t] = !0, !1);
  }
  function kl(t, e, l) {
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
  function tn(t, e, l) {
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
  function Ge(t, e, l, a) {
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
  function Fl(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function pf(t, e, l) {
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
  function Zn(t) {
    if (!t._valueTracker) {
      var e = Fl(t) ? "checked" : "value";
      t._valueTracker = pf(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function Kn(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = Fl(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function rl(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var vf = /[\n"\\]/g;
  function Rt(t) {
    return t.replace(
      vf,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function Wl(t, e, l, a, n, i, u, f) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + xe(e)) : t.value !== "" + xe(e) && (t.value = "" + xe(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? Jn(t, u, xe(e)) : l != null ? Jn(t, u, xe(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), f != null && typeof f != "function" && typeof f != "symbol" && typeof f != "boolean" ? t.name = "" + xe(f) : t.removeAttribute("name");
  }
  function Ii(t, e, l, a, n, i, u, f) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        Zn(t);
        return;
      }
      l = l != null ? "" + xe(l) : "", e = e != null ? "" + xe(e) : l, f || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = f ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), Zn(t);
  }
  function Jn(t, e, l) {
    e === "number" && rl(t.ownerDocument) === t || t.defaultValue === "" + l || (t.defaultValue = "" + l);
  }
  function c(t, e, l, a) {
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
  function r(t, e, l) {
    if (e != null && (e = "" + xe(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + xe(l) : "";
  }
  function b(t, e, l, a) {
    if (e == null) {
      if (a != null) {
        if (l != null) throw Error(v(92));
        if (q(a)) {
          if (1 < a.length) throw Error(v(93));
          a = a[0];
        }
        l = a;
      }
      l == null && (l = ""), e = l;
    }
    l = xe(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), Zn(t);
  }
  function O(t, e) {
    if (e) {
      var l = t.firstChild;
      if (l && l === t.lastChild && l.nodeType === 3) {
        l.nodeValue = e;
        return;
      }
    }
    t.textContent = e;
  }
  var N = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function H(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || N.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function G(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(v(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && H(t, n, a);
    } else
      for (var i in e)
        e.hasOwnProperty(i) && H(t, i, e[i]);
  }
  function W(t) {
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
  ]), pt = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function Ie(t) {
    return pt.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function Pe() {
  }
  var kn = null;
  function Fn(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Al = null, $l = null;
  function Wn(t) {
    var e = ol(t);
    if (e && (t = e.stateNode)) {
      var l = t[me] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if (Wl(
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
              'input[name="' + Rt(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[me] || null;
                if (!n) throw Error(v(90));
                Wl(
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
              a = l[e], a.form === t.form && Kn(a);
          }
          break t;
        case "textarea":
          r(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && c(t, !!l.multiple, e, !1);
      }
    }
  }
  var $n = !1;
  function en(t, e, l) {
    if ($n) return t(e, l);
    $n = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if ($n = !1, (Al !== null || $l !== null) && (qu(), Al && (e = Al, t = $l, $l = Al = null, Wn(e), t)))
        for (e = 0; e < t.length; e++) Wn(t[e]);
    }
  }
  function _l(t, e) {
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
        v(231, e, typeof l)
      );
    return l;
  }
  var tl = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), ln = !1;
  if (tl)
    try {
      var Dl = {};
      Object.defineProperty(Dl, "passive", {
        get: function() {
          ln = !0;
        }
      }), window.addEventListener("test", Dl, Dl), window.removeEventListener("test", Dl, Dl);
    } catch {
      ln = !1;
    }
  var Le = null, Ol = null, Da = null;
  function Pi() {
    if (Da) return Da;
    var t, e = Ol, l = e.length, a, n = "value" in Le ? Le.value : Le.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return Da = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function Oa(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function Ca() {
    return !0;
  }
  function tu() {
    return !1;
  }
  function ne(t) {
    function e(l, a, n, i, u) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = i, this.target = u, this.currentTarget = null;
      for (var f in t)
        t.hasOwnProperty(f) && (l = t[f], this[f] = l ? l(i) : i[f]);
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? Ca : tu, this.isPropagationStopped = tu, this;
    }
    return Q(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = Ca);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = Ca);
      },
      persist: function() {
      },
      isPersistent: Ca
    }), e;
  }
  var Xe = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, Ua = ne(Xe), Ba = Q({}, Xe, { view: 0, detail: 0 }), yf = ne(Ba), an, In, Cl, el = Q({}, Ba, {
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
    getModifierState: xf,
    button: 0,
    buttons: 0,
    relatedTarget: function(t) {
      return t.relatedTarget === void 0 ? t.fromElement === t.srcElement ? t.toElement : t.fromElement : t.relatedTarget;
    },
    movementX: function(t) {
      return "movementX" in t ? t.movementX : (t !== Cl && (Cl && t.type === "mousemove" ? (an = t.screenX - Cl.screenX, In = t.screenY - Cl.screenY) : In = an = 0, Cl = t), an);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : In;
    }
  }), Pn = ne(el), eu = Q({}, el, { dataTransfer: 0 }), nn = ne(eu), E = Q({}, Ba, { relatedTarget: 0 }), C = ne(E), J = Q({}, Xe, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), P = ne(J), dt = Q({}, Xe, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), mt = ne(dt), Yt = Q({}, Xe, { data: 0 }), he = ne(Yt), Na = {
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
  }, De = {
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
  }, lu = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function bf(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = lu[t]) ? !!e[t] : !1;
  }
  function xf() {
    return bf;
  }
  var fm = Q({}, Ba, {
    key: function(t) {
      if (t.key) {
        var e = Na[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = Oa(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? De[t.keyCode] || "Unidentified" : "";
    },
    code: 0,
    location: 0,
    ctrlKey: 0,
    shiftKey: 0,
    altKey: 0,
    metaKey: 0,
    repeat: 0,
    locale: 0,
    getModifierState: xf,
    charCode: function(t) {
      return t.type === "keypress" ? Oa(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? Oa(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), cm = ne(fm), om = Q({}, el, {
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
  }), zo = ne(om), rm = Q({}, Ba, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: xf
  }), sm = ne(rm), dm = Q({}, Xe, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), mm = ne(dm), hm = Q({}, el, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), gm = ne(hm), pm = Q({}, Xe, {
    newState: 0,
    oldState: 0
  }), vm = ne(pm), ym = [9, 13, 27, 32], Sf = tl && "CompositionEvent" in window, ti = null;
  tl && "documentMode" in document && (ti = document.documentMode);
  var bm = tl && "TextEvent" in window && !ti, Mo = tl && (!Sf || ti && 8 < ti && 11 >= ti), Eo = " ", Ao = !1;
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
  var un = !1;
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
    if (un)
      return t === "compositionend" || !Sf && _o(t, e) ? (t = Pi(), Da = Ol = Le = null, un = !1, t) : null;
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
    Al ? $l ? $l.push(a) : $l = [a] : Al = a, e = Zu(e, "onChange"), 0 < e.length && (l = new Ua(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var ei = null, li = null;
  function zm(t) {
    dd(t, 0);
  }
  function au(t) {
    var e = Tl(t);
    if (Kn(e)) return t;
  }
  function Uo(t, e) {
    if (t === "change") return e;
  }
  var Bo = !1;
  if (tl) {
    var Tf;
    if (tl) {
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
    ei && (ei.detachEvent("onpropertychange", Ho), li = ei = null);
  }
  function Ho(t) {
    if (t.propertyName === "value" && au(li)) {
      var e = [];
      Co(
        e,
        li,
        t,
        Fn(t)
      ), en(zm, e);
    }
  }
  function Mm(t, e, l) {
    t === "focusin" ? (Ro(), ei = e, li = l, ei.attachEvent("onpropertychange", Ho)) : t === "focusout" && Ro();
  }
  function Em(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return au(li);
  }
  function Am(t, e) {
    if (t === "click") return au(e);
  }
  function _m(t, e) {
    if (t === "input" || t === "change")
      return au(e);
  }
  function Dm(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var Oe = typeof Object.is == "function" ? Object.is : Dm;
  function ai(t, e) {
    if (Oe(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!jn.call(e, n) || !Oe(t[n], e[n]))
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
    for (var e = rl(t.document); e instanceof t.HTMLIFrameElement; ) {
      try {
        var l = typeof e.contentWindow.location.href == "string";
      } catch {
        l = !1;
      }
      if (l) t = e.contentWindow;
      else break;
      e = rl(t.document);
    }
    return e;
  }
  function Mf(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var Om = tl && "documentMode" in document && 11 >= document.documentMode, fn = null, Ef = null, ni = null, Af = !1;
  function Go(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Af || fn == null || fn !== rl(a) || (a = fn, "selectionStart" in a && Mf(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), ni && ai(ni, a) || (ni = a, a = Zu(Ef, "onSelect"), 0 < a.length && (e = new Ua(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = fn)));
  }
  function Ra(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var cn = {
    animationend: Ra("Animation", "AnimationEnd"),
    animationiteration: Ra("Animation", "AnimationIteration"),
    animationstart: Ra("Animation", "AnimationStart"),
    transitionrun: Ra("Transition", "TransitionRun"),
    transitionstart: Ra("Transition", "TransitionStart"),
    transitioncancel: Ra("Transition", "TransitionCancel"),
    transitionend: Ra("Transition", "TransitionEnd")
  }, _f = {}, Lo = {};
  tl && (Lo = document.createElement("div").style, "AnimationEvent" in window || (delete cn.animationend.animation, delete cn.animationiteration.animation, delete cn.animationstart.animation), "TransitionEvent" in window || delete cn.transitionend.transition);
  function Ha(t) {
    if (_f[t]) return _f[t];
    if (!cn[t]) return t;
    var e = cn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Lo)
        return _f[t] = e[l];
    return t;
  }
  var Xo = Ha("animationend"), Qo = Ha("animationiteration"), Vo = Ha("animationstart"), Cm = Ha("transitionrun"), Um = Ha("transitionstart"), Bm = Ha("transitioncancel"), Zo = Ha("transitionend"), Ko = /* @__PURE__ */ new Map(), Df = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Df.push("scrollEnd");
  function ll(t, e) {
    Ko.set(t, e), Ml(e, [t]);
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
  }, Qe = [], on = 0, Of = 0;
  function iu() {
    for (var t = on, e = Of = on = 0; e < t; ) {
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
      i !== 0 && Jo(l, n, i);
    }
  }
  function uu(t, e, l, a) {
    Qe[on++] = t, Qe[on++] = e, Qe[on++] = l, Qe[on++] = a, Of |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Cf(t, e, l, a) {
    return uu(t, e, l, a), fu(t);
  }
  function wa(t, e) {
    return uu(t, null, null, e), fu(t);
  }
  function Jo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, i = t.return; i !== null; )
      i.childLanes |= l, a = i.alternate, a !== null && (a.childLanes |= l), i.tag === 22 && (t = i.stateNode, t === null || t._visibility & 1 || (n = !0)), t = i, i = i.return;
    return t.tag === 3 ? (i = t.stateNode, n && e !== null && (n = 31 - ve(l), t = i.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), i) : null;
  }
  function fu(t) {
    if (50 < Ai)
      throw Ai = 0, Yc = null, Error(v(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var rn = {};
  function Nm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function Ce(t, e, l, a) {
    return new Nm(t, e, l, a);
  }
  function Uf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function Ul(t, e) {
    var l = t.alternate;
    return l === null ? (l = Ce(
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
    if (a = t, typeof t == "function") Uf(t) && (u = 1);
    else if (typeof t == "string")
      u = qh(
        t,
        l,
        R.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case Ae:
          return t = Ce(31, l, e, n), t.elementType = Ae, t.lanes = i, t;
        case ee:
          return ja(l.children, n, i, e);
        case we:
          u = 8, n |= 24;
          break;
        case bt:
          return t = Ce(12, l, e, n | 2), t.elementType = bt, t.lanes = i, t;
        case re:
          return t = Ce(13, l, e, n), t.elementType = re, t.lanes = i, t;
        case jt:
          return t = Ce(19, l, e, n), t.elementType = jt, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case wt:
                u = 10;
                break t;
              case je:
                u = 9;
                break t;
              case Wt:
                u = 11;
                break t;
              case at:
                u = 14;
                break t;
              case Nt:
                u = 16, a = null;
                break t;
            }
          u = 29, l = Error(
            v(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = Ce(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function ja(t, e, l, a) {
    return t = Ce(7, t, a, e), t.lanes = l, t;
  }
  function Bf(t, e, l) {
    return t = Ce(6, t, null, e), t.lanes = l, t;
  }
  function Fo(t) {
    var e = Ce(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function Nf(t, e, l) {
    return e = Ce(
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
  function Ve(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = Wo.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Yi(e)
      }, Wo.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Yi(e)
    };
  }
  var sn = [], dn = 0, ou = null, ii = 0, Ze = [], Ke = 0, Il = null, sl = 1, dl = "";
  function Bl(t, e) {
    sn[dn++] = ii, sn[dn++] = ou, ou = t, ii = e;
  }
  function $o(t, e, l) {
    Ze[Ke++] = sl, Ze[Ke++] = dl, Ze[Ke++] = Il, Il = t;
    var a = sl;
    t = dl;
    var n = 32 - ve(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - ve(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, sl = 1 << 32 - ve(e) + n | l << n | a, dl = i + t;
    } else
      sl = 1 << i | l << n | a, dl = t;
  }
  function Rf(t) {
    t.return !== null && (Bl(t, 1), $o(t, 1, 0));
  }
  function Hf(t) {
    for (; t === ou; )
      ou = sn[--dn], sn[dn] = null, ii = sn[--dn], sn[dn] = null;
    for (; t === Il; )
      Il = Ze[--Ke], Ze[Ke] = null, dl = Ze[--Ke], Ze[Ke] = null, sl = Ze[--Ke], Ze[Ke] = null;
  }
  function Io(t, e) {
    Ze[Ke++] = sl, Ze[Ke++] = dl, Ze[Ke++] = Il, sl = e.id, dl = e.overflow, Il = t;
  }
  var ie = null, Dt = null, ot = !1, Pl = null, Je = !1, wf = Error(v(519));
  function ta(t) {
    var e = Error(
      v(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw ui(Ve(e, t)), wf;
  }
  function Po(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[Zt] = t, e[me] = a, l) {
      case "dialog":
        ut("cancel", e), ut("close", e);
        break;
      case "iframe":
      case "object":
      case "embed":
        ut("load", e);
        break;
      case "video":
      case "audio":
        for (l = 0; l < Di.length; l++)
          ut(Di[l], e);
        break;
      case "source":
        ut("error", e);
        break;
      case "img":
      case "image":
      case "link":
        ut("error", e), ut("load", e);
        break;
      case "details":
        ut("toggle", e);
        break;
      case "input":
        ut("invalid", e), Ii(
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
        ut("invalid", e);
        break;
      case "textarea":
        ut("invalid", e), b(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || pd(e.textContent, l) ? (a.popover != null && (ut("beforetoggle", e), ut("toggle", e)), a.onScroll != null && ut("scroll", e), a.onScrollEnd != null && ut("scrollend", e), a.onClick != null && (e.onclick = Pe), e = !0) : e = !1, e || ta(t, !0);
  }
  function tr(t) {
    for (ie = t.return; ie; )
      switch (ie.tag) {
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
          ie = ie.return;
      }
  }
  function mn(t) {
    if (t !== ie) return !1;
    if (!ot) return tr(t), ot = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || to(t.type, t.memoizedProps)), l = !l), l && Dt && ta(t), tr(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(v(317));
      Dt = Ed(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(v(317));
      Dt = Ed(t);
    } else
      e === 27 ? (e = Dt, ha(t.type) ? (t = io, io = null, Dt = t) : Dt = e) : Dt = ie ? Fe(t.stateNode.nextSibling) : null;
    return !0;
  }
  function qa() {
    Dt = ie = null, ot = !1;
  }
  function jf() {
    var t = Pl;
    return t !== null && (Me === null ? Me = t : Me.push.apply(
      Me,
      t
    ), Pl = null), t;
  }
  function ui(t) {
    Pl === null ? Pl = [t] : Pl.push(t);
  }
  var qf = s(null), Ya = null, Nl = null;
  function ea(t, e, l) {
    B(qf, e._currentValue), e._currentValue = l;
  }
  function Rl(t) {
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
          for (var o = 0; o < e.length; o++)
            if (f.context === e[o]) {
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
        if (u = n.return, u === null) throw Error(v(341));
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
  function hn(t, e, l, a) {
    t = null;
    for (var n = e, i = !1; n !== null; ) {
      if (!i) {
        if ((n.flags & 524288) !== 0) i = !0;
        else if ((n.flags & 262144) !== 0) break;
      }
      if (n.tag === 10) {
        var u = n.alternate;
        if (u === null) throw Error(v(387));
        if (u = u.memoizedProps, u !== null) {
          var f = n.type;
          Oe(n.pendingProps.value, u.value) || (t !== null ? t.push(f) : t = [f]);
        }
      } else if (n === rt.current) {
        if (u = n.alternate, u === null) throw Error(v(387));
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
      if (!Oe(
        t.context._currentValue,
        t.memoizedValue
      ))
        return !0;
      t = t.next;
    }
    return !1;
  }
  function Ga(t) {
    Ya = t, Nl = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function ue(t) {
    return er(Ya, t);
  }
  function su(t, e) {
    return Ya === null && Ga(t), er(t, e);
  }
  function er(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Nl === null) {
      if (t === null) throw Error(v(308));
      Nl = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else Nl = Nl.next = e;
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
  }, Hm = T.unstable_scheduleCallback, wm = T.unstable_NormalPriority, Kt = {
    $$typeof: wt,
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
  function fi(t) {
    t.refCount--, t.refCount === 0 && Hm(wm, function() {
      t.controller.abort();
    });
  }
  var ci = null, Xf = 0, gn = 0, pn = null;
  function jm(t, e) {
    if (ci === null) {
      var l = ci = [];
      Xf = 0, gn = Zc(), pn = {
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
    if (--Xf === 0 && ci !== null) {
      pn !== null && (pn.status = "fulfilled");
      var t = ci;
      ci = null, gn = 0, pn = null;
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
    Gs = ae(), typeof e == "object" && e !== null && typeof e.then == "function" && jm(t, e), ar !== null && ar(t, e);
  };
  var La = s(null);
  function Qf() {
    var t = La.current;
    return t !== null ? t : At.pooledCache;
  }
  function du(t, e) {
    e === null ? B(La, La.current) : B(La, e.pool);
  }
  function nr() {
    var t = Qf();
    return t === null ? null : { parent: Kt._currentValue, pool: t };
  }
  var vn = Error(v(460)), Vf = Error(v(474)), mu = Error(v(542)), hu = { then: function() {
  } };
  function ir(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function ur(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(Pe, Pe), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, cr(t), t;
      default:
        if (typeof e.status == "string") e.then(Pe, Pe);
        else {
          if (t = At, t !== null && 100 < t.shellSuspendCounter)
            throw Error(v(482));
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
        throw Qa = e, vn;
    }
  }
  function Xa(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (Qa = l, vn) : l;
    }
  }
  var Qa = null;
  function fr() {
    if (Qa === null) throw Error(v(459));
    var t = Qa;
    return Qa = null, t;
  }
  function cr(t) {
    if (t === vn || t === mu)
      throw Error(v(483));
  }
  var yn = null, oi = 0;
  function gu(t) {
    var e = oi;
    return oi += 1, yn === null && (yn = []), ur(yn, t, e);
  }
  function ri(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function pu(t, e) {
    throw e.$$typeof === _t ? Error(v(525)) : (t = Object.prototype.toString.call(e), Error(
      v(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function or(t) {
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
      return h = Ul(h, d), h.index = 0, h.sibling = null, h;
    }
    function i(h, d, g) {
      return h.index = g, t ? (g = h.alternate, g !== null ? (g = g.index, g < d ? (h.flags |= 67108866, d) : g) : (h.flags |= 67108866, d)) : (h.flags |= 1048576, d);
    }
    function u(h) {
      return t && h.alternate === null && (h.flags |= 67108866), h;
    }
    function f(h, d, g, z) {
      return d === null || d.tag !== 6 ? (d = Bf(g, h.mode, z), d.return = h, d) : (d = n(d, g), d.return = h, d);
    }
    function o(h, d, g, z) {
      var V = g.type;
      return V === ee ? S(
        h,
        d,
        g.props.children,
        z,
        g.key
      ) : d !== null && (d.elementType === V || typeof V == "object" && V !== null && V.$$typeof === Nt && Xa(V) === d.type) ? (d = n(d, g.props), ri(d, g), d.return = h, d) : (d = cu(
        g.type,
        g.key,
        g.props,
        null,
        h.mode,
        z
      ), ri(d, g), d.return = h, d);
    }
    function p(h, d, g, z) {
      return d === null || d.tag !== 4 || d.stateNode.containerInfo !== g.containerInfo || d.stateNode.implementation !== g.implementation ? (d = Nf(g, h.mode, z), d.return = h, d) : (d = n(d, g.children || []), d.return = h, d);
    }
    function S(h, d, g, z, V) {
      return d === null || d.tag !== 7 ? (d = ja(
        g,
        h.mode,
        z,
        V
      ), d.return = h, d) : (d = n(d, g), d.return = h, d);
    }
    function A(h, d, g) {
      if (typeof d == "string" && d !== "" || typeof d == "number" || typeof d == "bigint")
        return d = Bf(
          "" + d,
          h.mode,
          g
        ), d.return = h, d;
      if (typeof d == "object" && d !== null) {
        switch (d.$$typeof) {
          case Vt:
            return g = cu(
              d.type,
              d.key,
              d.props,
              null,
              h.mode,
              g
            ), ri(g, d), g.return = h, g;
          case oe:
            return d = Nf(
              d,
              h.mode,
              g
            ), d.return = h, d;
          case Nt:
            return d = Xa(d), A(h, d, g);
        }
        if (q(d) || le(d))
          return d = ja(
            d,
            h.mode,
            g,
            null
          ), d.return = h, d;
        if (typeof d.then == "function")
          return A(h, gu(d), g);
        if (d.$$typeof === wt)
          return A(
            h,
            su(h, d),
            g
          );
        pu(h, d);
      }
      return null;
    }
    function y(h, d, g, z) {
      var V = d !== null ? d.key : null;
      if (typeof g == "string" && g !== "" || typeof g == "number" || typeof g == "bigint")
        return V !== null ? null : f(h, d, "" + g, z);
      if (typeof g == "object" && g !== null) {
        switch (g.$$typeof) {
          case Vt:
            return g.key === V ? o(h, d, g, z) : null;
          case oe:
            return g.key === V ? p(h, d, g, z) : null;
          case Nt:
            return g = Xa(g), y(h, d, g, z);
        }
        if (q(g) || le(g))
          return V !== null ? null : S(h, d, g, z, null);
        if (typeof g.then == "function")
          return y(
            h,
            d,
            gu(g),
            z
          );
        if (g.$$typeof === wt)
          return y(
            h,
            d,
            su(h, g),
            z
          );
        pu(h, g);
      }
      return null;
    }
    function x(h, d, g, z, V) {
      if (typeof z == "string" && z !== "" || typeof z == "number" || typeof z == "bigint")
        return h = h.get(g) || null, f(d, h, "" + z, V);
      if (typeof z == "object" && z !== null) {
        switch (z.$$typeof) {
          case Vt:
            return h = h.get(
              z.key === null ? g : z.key
            ) || null, o(d, h, z, V);
          case oe:
            return h = h.get(
              z.key === null ? g : z.key
            ) || null, p(d, h, z, V);
          case Nt:
            return z = Xa(z), x(
              h,
              d,
              g,
              z,
              V
            );
        }
        if (q(z) || le(z))
          return h = h.get(g) || null, S(d, h, z, V, null);
        if (typeof z.then == "function")
          return x(
            h,
            d,
            g,
            gu(z),
            V
          );
        if (z.$$typeof === wt)
          return x(
            h,
            d,
            g,
            su(d, z),
            V
          );
        pu(d, z);
      }
      return null;
    }
    function w(h, d, g, z) {
      for (var V = null, ht = null, j = d, et = d = 0, ct = null; j !== null && et < g.length; et++) {
        j.index > et ? (ct = j, j = null) : ct = j.sibling;
        var gt = y(
          h,
          j,
          g[et],
          z
        );
        if (gt === null) {
          j === null && (j = ct);
          break;
        }
        t && j && gt.alternate === null && e(h, j), d = i(gt, d, et), ht === null ? V = gt : ht.sibling = gt, ht = gt, j = ct;
      }
      if (et === g.length)
        return l(h, j), ot && Bl(h, et), V;
      if (j === null) {
        for (; et < g.length; et++)
          j = A(h, g[et], z), j !== null && (d = i(
            j,
            d,
            et
          ), ht === null ? V = j : ht.sibling = j, ht = j);
        return ot && Bl(h, et), V;
      }
      for (j = a(j); et < g.length; et++)
        ct = x(
          j,
          h,
          et,
          g[et],
          z
        ), ct !== null && (t && ct.alternate !== null && j.delete(
          ct.key === null ? et : ct.key
        ), d = i(
          ct,
          d,
          et
        ), ht === null ? V = ct : ht.sibling = ct, ht = ct);
      return t && j.forEach(function(ba) {
        return e(h, ba);
      }), ot && Bl(h, et), V;
    }
    function K(h, d, g, z) {
      if (g == null) throw Error(v(151));
      for (var V = null, ht = null, j = d, et = d = 0, ct = null, gt = g.next(); j !== null && !gt.done; et++, gt = g.next()) {
        j.index > et ? (ct = j, j = null) : ct = j.sibling;
        var ba = y(h, j, gt.value, z);
        if (ba === null) {
          j === null && (j = ct);
          break;
        }
        t && j && ba.alternate === null && e(h, j), d = i(ba, d, et), ht === null ? V = ba : ht.sibling = ba, ht = ba, j = ct;
      }
      if (gt.done)
        return l(h, j), ot && Bl(h, et), V;
      if (j === null) {
        for (; !gt.done; et++, gt = g.next())
          gt = A(h, gt.value, z), gt !== null && (d = i(gt, d, et), ht === null ? V = gt : ht.sibling = gt, ht = gt);
        return ot && Bl(h, et), V;
      }
      for (j = a(j); !gt.done; et++, gt = g.next())
        gt = x(j, h, et, gt.value, z), gt !== null && (t && gt.alternate !== null && j.delete(gt.key === null ? et : gt.key), d = i(gt, d, et), ht === null ? V = gt : ht.sibling = gt, ht = gt);
      return t && j.forEach(function(Fh) {
        return e(h, Fh);
      }), ot && Bl(h, et), V;
    }
    function Et(h, d, g, z) {
      if (typeof g == "object" && g !== null && g.type === ee && g.key === null && (g = g.props.children), typeof g == "object" && g !== null) {
        switch (g.$$typeof) {
          case Vt:
            t: {
              for (var V = g.key; d !== null; ) {
                if (d.key === V) {
                  if (V = g.type, V === ee) {
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
                  } else if (d.elementType === V || typeof V == "object" && V !== null && V.$$typeof === Nt && Xa(V) === d.type) {
                    l(
                      h,
                      d.sibling
                    ), z = n(d, g.props), ri(z, g), z.return = h, h = z;
                    break t;
                  }
                  l(h, d);
                  break;
                } else e(h, d);
                d = d.sibling;
              }
              g.type === ee ? (z = ja(
                g.props.children,
                h.mode,
                z,
                g.key
              ), z.return = h, h = z) : (z = cu(
                g.type,
                g.key,
                g.props,
                null,
                h.mode,
                z
              ), ri(z, g), z.return = h, h = z);
            }
            return u(h);
          case oe:
            t: {
              for (V = g.key; d !== null; ) {
                if (d.key === V)
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
              z = Nf(g, h.mode, z), z.return = h, h = z;
            }
            return u(h);
          case Nt:
            return g = Xa(g), Et(
              h,
              d,
              g,
              z
            );
        }
        if (q(g))
          return w(
            h,
            d,
            g,
            z
          );
        if (le(g)) {
          if (V = le(g), typeof V != "function") throw Error(v(150));
          return g = V.call(g), K(
            h,
            d,
            g,
            z
          );
        }
        if (typeof g.then == "function")
          return Et(
            h,
            d,
            gu(g),
            z
          );
        if (g.$$typeof === wt)
          return Et(
            h,
            d,
            su(h, g),
            z
          );
        pu(h, g);
      }
      return typeof g == "string" && g !== "" || typeof g == "number" || typeof g == "bigint" ? (g = "" + g, d !== null && d.tag === 6 ? (l(h, d.sibling), z = n(d, g), z.return = h, h = z) : (l(h, d), z = Bf(g, h.mode, z), z.return = h, h = z), u(h)) : l(h, d);
    }
    return function(h, d, g, z) {
      try {
        oi = 0;
        var V = Et(
          h,
          d,
          g,
          z
        );
        return yn = null, V;
      } catch (j) {
        if (j === vn || j === mu) throw j;
        var ht = Ce(29, j, null, h.mode);
        return ht.lanes = z, ht.return = h, ht;
      }
    };
  }
  var Va = or(!0), rr = or(!1), la = !1;
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
    if (a = a.shared, (vt & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = fu(t), Jo(t, null, l), e;
    }
    return uu(t, a, e, l), fu(t);
  }
  function si(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Gn(t, l);
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
  function di() {
    if (kf) {
      var t = pn;
      if (t !== null) throw t;
    }
  }
  function mi(t, e, l, a) {
    kf = !1;
    var n = t.updateQueue;
    la = !1;
    var i = n.firstBaseUpdate, u = n.lastBaseUpdate, f = n.shared.pending;
    if (f !== null) {
      n.shared.pending = null;
      var o = f, p = o.next;
      o.next = null, u === null ? i = p : u.next = p, u = o;
      var S = t.alternate;
      S !== null && (S = S.updateQueue, f = S.lastBaseUpdate, f !== u && (f === null ? S.firstBaseUpdate = p : f.next = p, S.lastBaseUpdate = o));
    }
    if (i !== null) {
      var A = n.baseState;
      u = 0, S = p = o = null, f = i;
      do {
        var y = f.lane & -536870913, x = y !== f.lane;
        if (x ? (ft & y) === y : (a & y) === y) {
          y !== 0 && y === gn && (kf = !0), S !== null && (S = S.next = {
            lane: 0,
            tag: f.tag,
            payload: f.payload,
            callback: null,
            next: null
          });
          t: {
            var w = t, K = f;
            y = e;
            var Et = l;
            switch (K.tag) {
              case 1:
                if (w = K.payload, typeof w == "function") {
                  A = w.call(Et, A, y);
                  break t;
                }
                A = w;
                break t;
              case 3:
                w.flags = w.flags & -65537 | 128;
              case 0:
                if (w = K.payload, y = typeof w == "function" ? w.call(Et, A, y) : w, y == null) break t;
                A = Q({}, A, y);
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
          }, S === null ? (p = S = x, o = A) : S = S.next = x, u |= y;
        if (f = f.next, f === null) {
          if (f = n.shared.pending, f === null)
            break;
          x = f, f = x.next, x.next = null, n.lastBaseUpdate = x, n.shared.pending = null;
        }
      } while (!0);
      S === null && (o = A), n.baseState = o, n.firstBaseUpdate = p, n.lastBaseUpdate = S, i === null && (n.shared.lanes = 0), oa |= u, t.lanes = u, t.memoizedState = A;
    }
  }
  function sr(t, e) {
    if (typeof t != "function")
      throw Error(v(191, t));
    t.call(e);
  }
  function dr(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        sr(l[t], e);
  }
  var bn = s(null), vu = s(0);
  function mr(t, e) {
    t = Ql, B(vu, t), B(bn, e), Ql = t | e.baseLanes;
  }
  function Ff() {
    B(vu, Ql), B(bn, bn.current);
  }
  function Wf() {
    Ql = vu.current, M(bn), M(vu);
  }
  var Ue = s(null), ke = null;
  function ia(t) {
    var e = t.alternate;
    B(Xt, Xt.current & 1), B(Ue, t), ke === null && (e === null || bn.current !== null || e.memoizedState !== null) && (ke = t);
  }
  function $f(t) {
    B(Xt, Xt.current), B(Ue, t), ke === null && (ke = t);
  }
  function hr(t) {
    t.tag === 22 ? (B(Xt, Xt.current), B(Ue, t), ke === null && (ke = t)) : ua();
  }
  function ua() {
    B(Xt, Xt.current), B(Ue, Ue.current);
  }
  function Be(t) {
    M(Ue), ke === t && (ke = null), M(Xt);
  }
  var Xt = s(0);
  function yu(t) {
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
  var Hl = 0, tt = null, zt = null, Jt = null, bu = !1, xn = !1, Za = !1, xu = 0, hi = 0, Sn = null, Ym = 0;
  function Gt() {
    throw Error(v(321));
  }
  function If(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!Oe(t[l], e[l])) return !1;
    return !0;
  }
  function Pf(t, e, l, a, n, i) {
    return Hl = i, tt = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, m.H = t === null || t.memoizedState === null ? $r : hc, Za = !1, i = l(a, n), Za = !1, xn && (i = pr(
      e,
      l,
      a,
      n
    )), gr(t), i;
  }
  function gr(t) {
    m.H = vi;
    var e = zt !== null && zt.next !== null;
    if (Hl = 0, Jt = zt = tt = null, bu = !1, hi = 0, Sn = null, e) throw Error(v(300));
    t === null || kt || (t = t.dependencies, t !== null && ru(t) && (kt = !0));
  }
  function pr(t, e, l, a) {
    tt = t;
    var n = 0;
    do {
      if (xn && (Sn = null), hi = 0, xn = !1, 25 <= n) throw Error(v(301));
      if (n += 1, Jt = zt = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      m.H = Ir, i = e(l, a);
    } while (xn);
    return i;
  }
  function Gm() {
    var t = m.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? gi(e) : e, t = t.useState()[0], (zt !== null ? zt.memoizedState : null) !== t && (tt.flags |= 1024), e;
  }
  function tc() {
    var t = xu !== 0;
    return xu = 0, t;
  }
  function ec(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function lc(t) {
    if (bu) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      bu = !1;
    }
    Hl = 0, Jt = zt = tt = null, xn = !1, hi = xu = 0, Sn = null;
  }
  function ye() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return Jt === null ? tt.memoizedState = Jt = t : Jt = Jt.next = t, Jt;
  }
  function Qt() {
    if (zt === null) {
      var t = tt.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = zt.next;
    var e = Jt === null ? tt.memoizedState : Jt.next;
    if (e !== null)
      Jt = e, zt = t;
    else {
      if (t === null)
        throw tt.alternate === null ? Error(v(467)) : Error(v(310));
      zt = t, t = {
        memoizedState: zt.memoizedState,
        baseState: zt.baseState,
        baseQueue: zt.baseQueue,
        queue: zt.queue,
        next: null
      }, Jt === null ? tt.memoizedState = Jt = t : Jt = Jt.next = t;
    }
    return Jt;
  }
  function Su() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function gi(t) {
    var e = hi;
    return hi += 1, Sn === null && (Sn = []), t = ur(Sn, t, e), e = tt, (Jt === null ? e.memoizedState : Jt.next) === null && (e = e.alternate, m.H = e === null || e.memoizedState === null ? $r : hc), t;
  }
  function Tu(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return gi(t);
      if (t.$$typeof === wt) return ue(t);
    }
    throw Error(v(438, String(t)));
  }
  function ac(t) {
    var e = null, l = tt.updateQueue;
    if (l !== null && (e = l.memoCache), e == null) {
      var a = tt.alternate;
      a !== null && (a = a.updateQueue, a !== null && (a = a.memoCache, a != null && (e = {
        data: a.data.map(function(n) {
          return n.slice();
        }),
        index: 0
      })));
    }
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Su(), tt.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = be;
    return e.index++, l;
  }
  function wl(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function zu(t) {
    var e = Qt();
    return nc(e, zt, t);
  }
  function nc(t, e, l) {
    var a = t.queue;
    if (a === null) throw Error(v(311));
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
      var f = u = null, o = null, p = e, S = !1;
      do {
        var A = p.lane & -536870913;
        if (A !== p.lane ? (ft & A) === A : (Hl & A) === A) {
          var y = p.revertLane;
          if (y === 0)
            o !== null && (o = o.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: p.action,
              hasEagerState: p.hasEagerState,
              eagerState: p.eagerState,
              next: null
            }), A === gn && (S = !0);
          else if ((Hl & y) === y) {
            p = p.next, y === gn && (S = !0);
            continue;
          } else
            A = {
              lane: 0,
              revertLane: p.revertLane,
              gesture: null,
              action: p.action,
              hasEagerState: p.hasEagerState,
              eagerState: p.eagerState,
              next: null
            }, o === null ? (f = o = A, u = i) : o = o.next = A, tt.lanes |= y, oa |= y;
          A = p.action, Za && l(i, A), i = p.hasEagerState ? p.eagerState : l(i, A);
        } else
          y = {
            lane: A,
            revertLane: p.revertLane,
            gesture: p.gesture,
            action: p.action,
            hasEagerState: p.hasEagerState,
            eagerState: p.eagerState,
            next: null
          }, o === null ? (f = o = y, u = i) : o = o.next = y, tt.lanes |= A, oa |= A;
        p = p.next;
      } while (p !== null && p !== e);
      if (o === null ? u = i : o.next = f, !Oe(i, t.memoizedState) && (kt = !0, S && (l = pn, l !== null)))
        throw l;
      t.memoizedState = i, t.baseState = u, t.baseQueue = o, a.lastRenderedState = i;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function ic(t) {
    var e = Qt(), l = e.queue;
    if (l === null) throw Error(v(311));
    l.lastRenderedReducer = t;
    var a = l.dispatch, n = l.pending, i = e.memoizedState;
    if (n !== null) {
      l.pending = null;
      var u = n = n.next;
      do
        i = t(i, u.action), u = u.next;
      while (u !== n);
      Oe(i, e.memoizedState) || (kt = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function vr(t, e, l) {
    var a = tt, n = Qt(), i = ot;
    if (i) {
      if (l === void 0) throw Error(v(407));
      l = l();
    } else l = e();
    var u = !Oe(
      (zt || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, kt = !0), n = n.queue, cc(xr.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || Jt !== null && Jt.memoizedState.tag & 1) {
      if (a.flags |= 2048, Tn(
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
      ), At === null) throw Error(v(349));
      i || (Hl & 127) !== 0 || yr(a, e, l);
    }
    return l;
  }
  function yr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = tt.updateQueue, e === null ? (e = Su(), tt.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
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
      return !Oe(t, l);
    } catch {
      return !0;
    }
  }
  function Tr(t) {
    var e = wa(t, 2);
    e !== null && Ee(e, t, 2);
  }
  function uc(t) {
    var e = ye();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Za) {
        fl(!0);
        try {
          l();
        } finally {
          fl(!1);
        }
      }
    }
    return e.memoizedState = e.baseState = t, e.queue = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: wl,
      lastRenderedState: t
    }, e;
  }
  function zr(t, e, l, a) {
    return t.baseState = l, nc(
      t,
      zt,
      typeof a == "function" ? a : wl
    );
  }
  function Lm(t, e, l, a, n) {
    if (Au(t)) throw Error(v(485));
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
      } catch (p) {
        fc(t, e, p);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), m.T = i;
      }
    } else
      try {
        i = l(n, a), Er(t, e, i);
      } catch (p) {
        fc(t, e, p);
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
    if (ot) {
      var l = At.formState;
      if (l !== null) {
        t: {
          var a = tt;
          if (ot) {
            if (Dt) {
              e: {
                for (var n = Dt, i = Je; n.nodeType !== 8; ) {
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
                Dt = Fe(
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
    return l = ye(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Dr,
      lastRenderedState: e
    }, l.queue = a, l = kr.bind(
      null,
      tt,
      a
    ), a.dispatch = l, a = uc(!1), i = mc.bind(
      null,
      tt,
      !1,
      a.queue
    ), a = ye(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = Lm.bind(
      null,
      tt,
      n,
      i,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Cr(t) {
    var e = Qt();
    return Ur(e, zt, t);
  }
  function Ur(t, e, l) {
    if (e = nc(
      t,
      e,
      Dr
    )[0], t = zu(wl)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = gi(e);
      } catch (u) {
        throw u === vn ? mu : u;
      }
    else a = e;
    e = Qt();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (tt.flags |= 2048, Tn(
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
    var e = Qt(), l = zt;
    if (l !== null)
      return Ur(e, l, t);
    Qt(), e = e.memoizedState, l = Qt();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function Tn(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = tt.updateQueue, e === null && (e = Su(), tt.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Nr() {
    return Qt().memoizedState;
  }
  function Mu(t, e, l, a) {
    var n = ye();
    tt.flags |= t, n.memoizedState = Tn(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Eu(t, e, l, a) {
    var n = Qt();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    zt !== null && a !== null && If(a, zt.memoizedState.deps) ? n.memoizedState = Tn(e, i, l, a) : (tt.flags |= t, n.memoizedState = Tn(
      1 | e,
      i,
      l,
      a
    ));
  }
  function Rr(t, e) {
    Mu(8390656, 8, t, e);
  }
  function cc(t, e) {
    Eu(2048, 8, t, e);
  }
  function Qm(t) {
    tt.flags |= 4;
    var e = tt.updateQueue;
    if (e === null)
      e = Su(), tt.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function Hr(t) {
    var e = Qt().memoizedState;
    return Qm({ ref: e, nextImpl: t }), function() {
      if ((vt & 2) !== 0) throw Error(v(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function wr(t, e) {
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
  function Yr(t, e, l) {
    l = l != null ? l.concat([t]) : null, Eu(4, 4, qr.bind(null, e, t), l);
  }
  function oc() {
  }
  function Gr(t, e) {
    var l = Qt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && If(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Lr(t, e) {
    var l = Qt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && If(e, a[1]))
      return a[0];
    if (a = t(), Za) {
      fl(!0);
      try {
        t();
      } finally {
        fl(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function rc(t, e, l) {
    return l === void 0 || (Hl & 1073741824) !== 0 && (ft & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Xs(), tt.lanes |= t, oa |= t, l);
  }
  function Xr(t, e, l, a) {
    return Oe(l, e) ? l : bn.current !== null ? (t = rc(t, l, a), Oe(t, e) || (kt = !0), t) : (Hl & 42) === 0 || (Hl & 1073741824) !== 0 && (ft & 261930) === 0 ? (kt = !0, t.memoizedState = l) : (t = Xs(), tt.lanes |= t, oa |= t, e);
  }
  function Qr(t, e, l, a, n) {
    var i = D.p;
    D.p = i !== 0 && 8 > i ? i : 8;
    var u = m.T, f = {};
    m.T = f, mc(t, !1, e, l);
    try {
      var o = n(), p = m.S;
      if (p !== null && p(f, o), o !== null && typeof o == "object" && typeof o.then == "function") {
        var S = qm(
          o,
          a
        );
        pi(
          t,
          e,
          S,
          He(t)
        );
      } else
        pi(
          t,
          e,
          a,
          He(t)
        );
    } catch (A) {
      pi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: A },
        He()
      );
    } finally {
      D.p = i, u !== null && f.types !== null && (u.types = f.types), m.T = u;
    }
  }
  function Vm() {
  }
  function sc(t, e, l, a) {
    if (t.tag !== 5) throw Error(v(476));
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
        lastRenderedReducer: wl,
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
        lastRenderedReducer: wl,
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
      He()
    );
  }
  function dc() {
    return ue(Ni);
  }
  function Kr() {
    return Qt().memoizedState;
  }
  function Jr() {
    return Qt().memoizedState;
  }
  function Zm(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = He();
          t = aa(l);
          var a = na(e, t, l);
          a !== null && (Ee(a, e, l), si(a, e, l)), e = { cache: Lf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function Km(t, e, l) {
    var a = He();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Au(t) ? Fr(e, l) : (l = Cf(t, e, l, a), l !== null && (Ee(l, t, a), Wr(l, e, a)));
  }
  function kr(t, e, l) {
    var a = He();
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
          if (n.hasEagerState = !0, n.eagerState = f, Oe(f, u))
            return uu(t, e, n, 0), At === null && iu(), !1;
        } catch {
        }
      if (l = Cf(t, e, n, a), l !== null)
        return Ee(l, t, a), Wr(l, e, a), !0;
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
    }, Au(t)) {
      if (e) throw Error(v(479));
    } else
      e = Cf(
        t,
        l,
        a,
        2
      ), e !== null && Ee(e, t, 2);
  }
  function Au(t) {
    var e = t.alternate;
    return t === tt || e !== null && e === tt;
  }
  function Fr(t, e) {
    xn = bu = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function Wr(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Gn(t, l);
    }
  }
  var vi = {
    readContext: ue,
    use: Tu,
    useCallback: Gt,
    useContext: Gt,
    useEffect: Gt,
    useImperativeHandle: Gt,
    useLayoutEffect: Gt,
    useInsertionEffect: Gt,
    useMemo: Gt,
    useReducer: Gt,
    useRef: Gt,
    useState: Gt,
    useDebugValue: Gt,
    useDeferredValue: Gt,
    useTransition: Gt,
    useSyncExternalStore: Gt,
    useId: Gt,
    useHostTransitionStatus: Gt,
    useFormState: Gt,
    useActionState: Gt,
    useOptimistic: Gt,
    useMemoCache: Gt,
    useCacheRefresh: Gt
  };
  vi.useEffectEvent = Gt;
  var $r = {
    readContext: ue,
    use: Tu,
    useCallback: function(t, e) {
      return ye().memoizedState = [
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
      var l = ye();
      e = e === void 0 ? null : e;
      var a = t();
      if (Za) {
        fl(!0);
        try {
          t();
        } finally {
          fl(!1);
        }
      }
      return l.memoizedState = [a, e], a;
    },
    useReducer: function(t, e, l) {
      var a = ye();
      if (l !== void 0) {
        var n = l(e);
        if (Za) {
          fl(!0);
          try {
            l(e);
          } finally {
            fl(!1);
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
        tt,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = ye();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = uc(t);
      var e = t.queue, l = kr.bind(null, tt, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = ye();
      return rc(l, t, e);
    },
    useTransition: function() {
      var t = uc(!1);
      return t = Qr.bind(
        null,
        tt,
        t.queue,
        !0,
        !1
      ), ye().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = tt, n = ye();
      if (ot) {
        if (l === void 0)
          throw Error(v(407));
        l = l();
      } else {
        if (l = e(), At === null)
          throw Error(v(349));
        (ft & 127) !== 0 || yr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, Rr(xr.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, Tn(
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
      var t = ye(), e = At.identifierPrefix;
      if (ot) {
        var l = dl, a = sl;
        l = (a & ~(1 << 32 - ve(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = xu++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Ym++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: dc,
    useFormState: Or,
    useActionState: Or,
    useOptimistic: function(t) {
      var e = ye();
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
        tt,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: ac,
    useCacheRefresh: function() {
      return ye().memoizedState = Zm.bind(
        null,
        tt
      );
    },
    useEffectEvent: function(t) {
      var e = ye(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((vt & 2) !== 0)
          throw Error(v(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, hc = {
    readContext: ue,
    use: Tu,
    useCallback: Gr,
    useContext: ue,
    useEffect: cc,
    useImperativeHandle: Yr,
    useInsertionEffect: wr,
    useLayoutEffect: jr,
    useMemo: Lr,
    useReducer: zu,
    useRef: Nr,
    useState: function() {
      return zu(wl);
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Qt();
      return Xr(
        l,
        zt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = zu(wl)[0], e = Qt().memoizedState;
      return [
        typeof t == "boolean" ? t : gi(t),
        e
      ];
    },
    useSyncExternalStore: vr,
    useId: Kr,
    useHostTransitionStatus: dc,
    useFormState: Cr,
    useActionState: Cr,
    useOptimistic: function(t, e) {
      var l = Qt();
      return zr(l, zt, t, e);
    },
    useMemoCache: ac,
    useCacheRefresh: Jr
  };
  hc.useEffectEvent = Hr;
  var Ir = {
    readContext: ue,
    use: Tu,
    useCallback: Gr,
    useContext: ue,
    useEffect: cc,
    useImperativeHandle: Yr,
    useInsertionEffect: wr,
    useLayoutEffect: jr,
    useMemo: Lr,
    useReducer: ic,
    useRef: Nr,
    useState: function() {
      return ic(wl);
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Qt();
      return zt === null ? rc(l, t, e) : Xr(
        l,
        zt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = ic(wl)[0], e = Qt().memoizedState;
      return [
        typeof t == "boolean" ? t : gi(t),
        e
      ];
    },
    useSyncExternalStore: vr,
    useId: Kr,
    useHostTransitionStatus: dc,
    useFormState: Br,
    useActionState: Br,
    useOptimistic: function(t, e) {
      var l = Qt();
      return zt !== null ? zr(l, zt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ac,
    useCacheRefresh: Jr
  };
  Ir.useEffectEvent = Hr;
  function gc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : Q({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var pc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = He(), n = aa(a);
      n.payload = e, l != null && (n.callback = l), e = na(t, n, a), e !== null && (Ee(e, t, a), si(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = He(), n = aa(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = na(t, n, a), e !== null && (Ee(e, t, a), si(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = He(), a = aa(l);
      a.tag = 2, e != null && (a.callback = e), e = na(t, a, l), e !== null && (Ee(e, t, l), si(e, t, l));
    }
  };
  function Pr(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ai(l, a) || !ai(n, i) : !0;
  }
  function ts(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && pc.enqueueReplaceState(e, e.state, null);
  }
  function Ka(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = Q({}, l));
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
  function vc(t, e, l) {
    return l = aa(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      _u(t, e);
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
      if (e = l.alternate, e !== null && hn(
        e,
        l,
        n,
        !0
      ), l = Ue.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return ke === null ? Yu() : l.alternate === null && Lt === 0 && (Lt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === hu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Xc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === hu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Xc(t, a, n)), !1;
        }
        throw Error(v(435, l.tag));
      }
      return Xc(t, a, n), Yu(), !1;
    }
    if (ot)
      return e = Ue.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== wf && (t = Error(v(422), { cause: a }), ui(Ve(t, l)))) : (a !== wf && (e = Error(v(423), {
        cause: a
      }), ui(
        Ve(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ve(a, l), n = vc(
        t.stateNode,
        a,
        n
      ), Jf(t, n), Lt !== 4 && (Lt = 2)), !1;
    var i = Error(v(520), { cause: a });
    if (i = Ve(i, l), Ei === null ? Ei = [i] : Ei.push(i), Lt !== 4 && (Lt = 2), e === null) return !0;
    a = Ve(a, l), l = e;
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
  var yc = Error(v(461)), kt = !1;
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
    return Ga(e), a = Pf(
      t,
      e,
      l,
      u,
      i,
      n
    ), f = tc(), t !== null && !kt ? (ec(t, e, n), jl(t, e, n)) : (ot && f && Rf(e), e.flags |= 1, fe(t, e, a, n), e.child);
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
      )) : (t = cu(
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
      if (l = l.compare, l = l !== null ? l : ai, l(u, a) && t.ref === e.ref)
        return jl(t, e, n);
    }
    return e.flags |= 1, t = Ul(i, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function os(t, e, l, a, n) {
    if (t !== null) {
      var i = t.memoizedProps;
      if (ai(i, a) && t.ref === e.ref)
        if (kt = !1, e.pendingProps = a = i, Ac(t, n))
          (t.flags & 131072) !== 0 && (kt = !0);
        else
          return e.lanes = t.lanes, jl(t, e, n);
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
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && du(
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
      i !== null ? (du(e, i.cachePool), mr(e, i), ua(), e.memoizedState = null) : (t !== null && du(e, null), Ff(), ua());
    return fe(t, e, n, l), e.child;
  }
  function yi(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function ss(t, e, l, a, n) {
    var i = Qf();
    return i = i === null ? null : { parent: Kt._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && du(e, null), Ff(), hr(e), t !== null && hn(t, e, a, !0), e.childLanes = n, null;
  }
  function Du(t, e) {
    return e = Cu(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function ds(t, e, l) {
    return Va(e, t.child, null, l), t = Du(e, e.pendingProps), t.flags |= 2, Be(e), e.memoizedState = null, t;
  }
  function km(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (ot) {
        if (a.mode === "hidden")
          return t = Du(e, a), e.lanes = 536870912, yi(null, t);
        if ($f(e), (t = Dt) ? (t = Md(
          t,
          Je
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Il !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ie = e, Dt = null)) : t = null, t === null) throw ta(e);
        return e.lanes = 536870912, null;
      }
      return Du(e, a);
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
        else throw Error(v(558));
      else if (kt || hn(t, e, l, !1), n = (l & t.childLanes) !== 0, kt || n) {
        if (a = At, a !== null && (u = ki(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, wa(t, u), Ee(a, t, u), yc;
        Yu(), e = ds(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, Dt = Fe(u.nextSibling), ie = e, ot = !0, Pl = null, Je = !1, t !== null && Io(e, t), e = Du(e, a), e.flags |= 4096;
      return e;
    }
    return t = Ul(t.child, {
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
        throw Error(v(284));
      (t === null || t.ref !== l) && (e.flags |= 4194816);
    }
  }
  function bc(t, e, l, a, n) {
    return Ga(e), l = Pf(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = tc(), t !== null && !kt ? (ec(t, e, n), jl(t, e, n)) : (ot && a && Rf(e), e.flags |= 1, fe(t, e, l, n), e.child);
  }
  function ms(t, e, l, a, n, i) {
    return Ga(e), e.updateQueue = null, l = pr(
      e,
      a,
      l,
      n
    ), gr(t), a = tc(), t !== null && !kt ? (ec(t, e, i), jl(t, e, i)) : (ot && a && Rf(e), e.flags |= 1, fe(t, e, l, i), e.child);
  }
  function hs(t, e, l, a, n) {
    if (Ga(e), e.stateNode === null) {
      var i = rn, u = l.contextType;
      typeof u == "object" && u !== null && (i = ue(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = pc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Zf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? ue(u) : rn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (gc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && pc.enqueueReplaceState(i, i.state, null), mi(e, a, i, n), di(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var f = e.memoizedProps, o = Ka(l, f);
      i.props = o;
      var p = i.context, S = l.contextType;
      u = rn, typeof S == "object" && S !== null && (u = ue(S));
      var A = l.getDerivedStateFromProps;
      S = typeof A == "function" || typeof i.getSnapshotBeforeUpdate == "function", f = e.pendingProps !== f, S || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (f || p !== u) && ts(
        e,
        i,
        a,
        u
      ), la = !1;
      var y = e.memoizedState;
      i.state = y, mi(e, a, i, n), di(), p = e.memoizedState, f || y !== p || la ? (typeof A == "function" && (gc(
        e,
        l,
        A,
        a
      ), p = e.memoizedState), (o = la || Pr(
        e,
        l,
        o,
        a,
        y,
        p,
        u
      )) ? (S || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = p), i.props = a, i.state = p, i.context = u, a = o) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, Kf(t, e), u = e.memoizedProps, S = Ka(l, u), i.props = S, A = e.pendingProps, y = i.context, p = l.contextType, o = rn, typeof p == "object" && p !== null && (o = ue(p)), f = l.getDerivedStateFromProps, (p = typeof f == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== A || y !== o) && ts(
        e,
        i,
        a,
        o
      ), la = !1, y = e.memoizedState, i.state = y, mi(e, a, i, n), di();
      var x = e.memoizedState;
      u !== A || y !== x || la || t !== null && t.dependencies !== null && ru(t.dependencies) ? (typeof f == "function" && (gc(
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
        o
      ) || t !== null && t.dependencies !== null && ru(t.dependencies)) ? (p || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, x, o), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        x,
        o
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = x), i.props = a, i.state = x, i.context = o, a = S) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && y === t.memoizedState || (e.flags |= 1024), a = !1);
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
    )) : fe(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = jl(
      t,
      e,
      n
    ), t;
  }
  function gs(t, e, l, a) {
    return qa(), e.flags |= 256, fe(t, e, l, a), e.child;
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
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= Re), t;
  }
  function ps(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : (Xt.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (ot) {
        if (n ? ia(e) : ua(), (t = Dt) ? (t = Md(
          t,
          Je
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Il !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, ie = e, Dt = null)) : t = null, t === null) throw ta(e);
        return no(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var f = a.children;
      return a = a.fallback, n ? (ua(), n = e.mode, f = Cu(
        { mode: "hidden", children: f },
        n
      ), a = ja(
        a,
        n,
        l,
        null
      ), f.return = e, a.return = e, f.sibling = a, e.child = f, a = e.child, a.memoizedState = Sc(l), a.childLanes = Tc(
        t,
        u,
        l
      ), e.memoizedState = xc, yi(null, a)) : (ia(e), zc(e, f));
    }
    var o = t.memoizedState;
    if (o !== null && (f = o.dehydrated, f !== null)) {
      if (i)
        e.flags & 256 ? (ia(e), e.flags &= -257, e = Mc(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (ua(), e.child = t.child, e.flags |= 128, e = null) : (ua(), f = a.fallback, n = e.mode, a = Cu(
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
        ), a = e.child, a.memoizedState = Sc(l), a.childLanes = Tc(
          t,
          u,
          l
        ), e.memoizedState = xc, e = yi(null, a));
      else if (ia(e), no(f)) {
        if (u = f.nextSibling && f.nextSibling.dataset, u) var p = u.dgst;
        u = p, a = Error(v(419)), a.stack = "", a.digest = u, ui({ value: a, source: null, stack: null }), e = Mc(
          t,
          e,
          l
        );
      } else if (kt || hn(t, e, l, !1), u = (l & t.childLanes) !== 0, kt || u) {
        if (u = At, u !== null && (a = ki(u, l), a !== 0 && a !== o.retryLane))
          throw o.retryLane = a, wa(t, a), Ee(u, t, a), yc;
        ao(f) || Yu(), e = Mc(
          t,
          e,
          l
        );
      } else
        ao(f) ? (e.flags |= 192, e.child = t.child, e = null) : (t = o.treeContext, Dt = Fe(
          f.nextSibling
        ), ie = e, ot = !0, Pl = null, Je = !1, t !== null && Io(e, t), e = zc(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (ua(), f = a.fallback, n = e.mode, o = t.child, p = o.sibling, a = Ul(o, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = o.subtreeFlags & 65011712, p !== null ? f = Ul(
      p,
      f
    ) : (f = ja(
      f,
      n,
      l,
      null
    ), f.flags |= 2), f.return = e, a.return = e, a.sibling = f, e.child = a, yi(null, a), a = e.child, f = t.child.memoizedState, f === null ? f = Sc(l) : (n = f.cachePool, n !== null ? (o = Kt._currentValue, n = n.parent !== o ? { parent: o, pool: o } : n) : n = nr(), f = {
      baseLanes: f.baseLanes | l,
      cachePool: n
    }), a.memoizedState = f, a.childLanes = Tc(
      t,
      u,
      l
    ), e.memoizedState = xc, yi(t.child, a)) : (ia(e), l = t.child, t = l.sibling, l = Ul(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function zc(t, e) {
    return e = Cu(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Cu(t, e) {
    return t = Ce(22, t, null, e), t.lanes = 0, t;
  }
  function Mc(t, e, l) {
    return Va(e, t.child, null, l), t = zc(
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
    var u = Xt.current, f = (u & 2) !== 0;
    if (f ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, B(Xt, u), fe(t, e, a, l), a = ot ? ii : 0, !f && t !== null && (t.flags & 128) !== 0)
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
          t = l.alternate, t !== null && yu(t) === null && (n = l), l = l.sibling;
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
          if (t = n.alternate, t !== null && yu(t) === null) {
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
  function jl(t, e, l) {
    if (t !== null && (e.dependencies = t.dependencies), oa |= e.lanes, (l & e.childLanes) === 0)
      if (t !== null) {
        if (hn(
          t,
          e,
          l,
          !1
        ), (l & e.childLanes) === 0)
          return null;
      } else return null;
    if (t !== null && e.child !== t.child)
      throw Error(v(153));
    if (e.child !== null) {
      for (t = e.child, l = Ul(t, t.pendingProps), e.child = l, l.return = e; t.sibling !== null; )
        t = t.sibling, l = l.sibling = Ul(t, t.pendingProps), l.return = e;
      l.sibling = null;
    }
    return e.child;
  }
  function Ac(t, e) {
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && ru(t)));
  }
  function Fm(t, e, l) {
    switch (e.tag) {
      case 3:
        It(e, e.stateNode.containerInfo), ea(e, Kt, t.memoizedState.cache), qa();
        break;
      case 27:
      case 5:
        gl(e);
        break;
      case 4:
        It(e, e.stateNode.containerInfo);
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
          return a.dehydrated !== null ? (ia(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? ps(t, e, l) : (ia(e), t = jl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        ia(e);
        break;
      case 19:
        var n = (t.flags & 128) !== 0;
        if (a = (l & e.childLanes) !== 0, a || (hn(
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
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), B(Xt, Xt.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, rs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        ea(e, Kt, t.memoizedState.cache);
    }
    return jl(t, e, l);
  }
  function bs(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        kt = !0;
      else {
        if (!Ac(t, l) && (e.flags & 128) === 0)
          return kt = !1, Fm(
            t,
            e,
            l
          );
        kt = (t.flags & 131072) !== 0;
      }
    else
      kt = !1, ot && (e.flags & 1048576) !== 0 && $o(e, ii, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = Xa(e.elementType), e.type = t, typeof t == "function")
            Uf(t) ? (a = Ka(t, a), e.tag = 1, e = hs(
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
              if (n === Wt) {
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
            throw e = qe(t) || t, Error(v(306, e, ""));
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
          if (It(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(v(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, Kf(t, e), mi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, ea(e, Kt, a), a !== i.cache && Gf(
            e,
            [Kt],
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
              n = Ve(
                Error(v(424)),
                e
              ), ui(n), e = gs(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Dt = Fe(t.firstChild), ie = e, ot = !0, Pl = null, Je = !0, l = rr(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (qa(), a === n) {
              e = jl(
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
        )) ? e.memoizedState = l : ot || (l = e.type, t = e.pendingProps, a = Ku(
          I.current
        ).createElement(l), a[Zt] = e, a[me] = t, ce(a, l, t), qt(a), e.stateNode = a) : e.memoizedState = Cd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return gl(e), t === null && ot && (a = e.stateNode = _d(
          e.type,
          e.pendingProps,
          I.current
        ), ie = e, Je = !0, n = Dt, ha(e.type) ? (io = n, Dt = Fe(a.firstChild)) : Dt = n), fe(
          t,
          e,
          e.pendingProps.children,
          l
        ), Ou(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && ot && ((n = a = Dt) && (a = Eh(
          a,
          e.type,
          e.pendingProps,
          Je
        ), a !== null ? (e.stateNode = a, ie = e, Dt = Fe(a.firstChild), Je = !1, n = !0) : n = !1), n || ta(e)), gl(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, to(n, i) ? a = null : u !== null && to(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = Pf(
          t,
          e,
          Gm,
          null,
          null,
          l
        ), Ni._currentValue = n), Ou(t, e), fe(t, e, a, l), e.child;
      case 6:
        return t === null && ot && ((t = l = Dt) && (l = Ah(
          l,
          e.pendingProps,
          Je
        ), l !== null ? (e.stateNode = l, ie = e, Dt = null, t = !0) : t = !1), t || ta(e)), null;
      case 13:
        return ps(t, e, l);
      case 4:
        return It(
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
        return a = e.pendingProps, ea(e, e.type, a.value), fe(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, Ga(e), n = ue(n), a = a(n), e.flags |= 1, fe(t, e, a, l), e.child;
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
        return Ga(e), a = ue(Kt), t === null ? (n = Qf(), n === null && (n = At, i = Lf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Zf(e), ea(e, Kt, n)) : ((t.lanes & l) !== 0 && (Kf(t, e), mi(e, null, null, l), di()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), ea(e, Kt, a)) : (a = i.cache, ea(e, Kt, a), a !== n.cache && Gf(
          e,
          [Kt],
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
    throw Error(v(156, e.tag));
  }
  function ql(t) {
    t.flags |= 4;
  }
  function _c(t, e, l, a, n) {
    if ((e = (t.mode & 32) !== 0) && (e = !1), e) {
      if (t.flags |= 16777216, (n & 335544128) === n)
        if (t.stateNode.complete) t.flags |= 8192;
        else if (Ks()) t.flags |= 8192;
        else
          throw Qa = hu, Vf;
    } else t.flags &= -16777217;
  }
  function xs(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !Hd(e))
      if (Ks()) t.flags |= 8192;
      else
        throw Qa = hu, Vf;
  }
  function Uu(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? Ji() : 536870912, t.lanes |= e, An |= e);
  }
  function bi(t, e) {
    if (!ot)
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
  function Ot(t) {
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
        return Ot(e), null;
      case 1:
        return Ot(e), null;
      case 3:
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), Rl(Kt), xt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (mn(e) ? ql(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, jf())), Ot(e), null;
      case 26:
        var n = e.type, i = e.memoizedState;
        return t === null ? (ql(e), i !== null ? (Ot(e), xs(e, i)) : (Ot(e), _c(
          e,
          n,
          null,
          a,
          l
        ))) : i ? i !== t.memoizedState ? (ql(e), Ot(e), xs(e, i)) : (Ot(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && ql(e), Ot(e), _c(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if (Ye(e), l = I.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && ql(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(v(166));
            return Ot(e), null;
          }
          t = R.current, mn(e) ? Po(e) : (t = _d(n, a, l), e.stateNode = t, ql(e));
        }
        return Ot(e), null;
      case 5:
        if (Ye(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && ql(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(v(166));
            return Ot(e), null;
          }
          if (i = R.current, mn(e))
            Po(e);
          else {
            var u = Ku(
              I.current
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
            i[Zt] = e, i[me] = a;
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
            a && ql(e);
          }
        }
        return Ot(e), _c(
          e,
          e.type,
          t === null ? null : t.memoizedProps,
          e.pendingProps,
          l
        ), null;
      case 6:
        if (t && e.stateNode != null)
          t.memoizedProps !== a && ql(e);
        else {
          if (typeof a != "string" && e.stateNode === null)
            throw Error(v(166));
          if (t = I.current, mn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = ie, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[Zt] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || pd(t.nodeValue, l)), t || ta(e, !0);
          } else
            t = Ku(t).createTextNode(
              a
            ), t[Zt] = e, e.stateNode = t;
        }
        return Ot(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = mn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(v(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(v(557));
              t[Zt] = e;
            } else
              qa(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ot(e), t = !1;
          } else
            l = jf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (Be(e), e) : (Be(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(v(558));
        }
        return Ot(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = mn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(v(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(v(317));
              n[Zt] = e;
            } else
              qa(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ot(e), n = !1;
          } else
            n = jf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (Be(e), e) : (Be(e), null);
        }
        return Be(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Uu(e, e.updateQueue), Ot(e), null);
      case 4:
        return xt(), t === null && Fc(e.stateNode.containerInfo), Ot(e), null;
      case 10:
        return Rl(e.type), Ot(e), null;
      case 19:
        if (M(Xt), a = e.memoizedState, a === null) return Ot(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) bi(a, !1);
          else {
            if (Lt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = yu(t), i !== null) {
                  for (e.flags |= 128, bi(a, !1), t = i.updateQueue, e.updateQueue = t, Uu(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    ko(l, t), l = l.sibling;
                  return B(
                    Xt,
                    Xt.current & 1 | 2
                  ), ot && Bl(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && ae() > wu && (e.flags |= 128, n = !0, bi(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = yu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Uu(e, t), bi(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !ot)
                return Ot(e), null;
            } else
              2 * ae() - a.renderingStartTime > wu && l !== 536870912 && (e.flags |= 128, n = !0, bi(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = ae(), t.sibling = null, l = Xt.current, B(
          Xt,
          n ? l & 1 | 2 : l & 1
        ), ot && Bl(e, a.treeForkCount), t) : (Ot(e), null);
      case 22:
      case 23:
        return Be(e), Wf(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Ot(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Ot(e), l = e.updateQueue, l !== null && Uu(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && M(La), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), Rl(Kt), Ot(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(v(156, e.tag));
  }
  function $m(t, e) {
    switch (Hf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return Rl(Kt), xt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return Ye(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (Be(e), e.alternate === null)
            throw Error(v(340));
          qa();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (Be(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(v(340));
          qa();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return M(Xt), null;
      case 4:
        return xt(), null;
      case 10:
        return Rl(e.type), null;
      case 22:
      case 23:
        return Be(e), Wf(), t !== null && M(La), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return Rl(Kt), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function Ss(t, e) {
    switch (Hf(e), e.tag) {
      case 3:
        Rl(Kt), xt();
        break;
      case 26:
      case 27:
      case 5:
        Ye(e);
        break;
      case 4:
        xt();
        break;
      case 31:
        e.memoizedState !== null && Be(e);
        break;
      case 13:
        Be(e);
        break;
      case 19:
        M(Xt);
        break;
      case 10:
        Rl(e.type);
        break;
      case 22:
      case 23:
        Be(e), Wf(), t !== null && M(La);
        break;
      case 24:
        Rl(Kt);
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
      Tt(e, e.return, f);
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
              var o = l, p = f;
              try {
                p();
              } catch (S) {
                Tt(
                  n,
                  o,
                  S
                );
              }
            }
          }
          a = a.next;
        } while (a !== i);
      }
    } catch (S) {
      Tt(e, e.return, S);
    }
  }
  function Ts(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        dr(e, l);
      } catch (a) {
        Tt(t, t.return, a);
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
      Tt(t, e, a);
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
      Tt(t, e, n);
    }
  }
  function ml(t, e) {
    var l = t.ref, a = t.refCleanup;
    if (l !== null)
      if (typeof a == "function")
        try {
          a();
        } catch (n) {
          Tt(t, e, n);
        } finally {
          t.refCleanup = null, t = t.alternate, t != null && (t.refCleanup = null);
        }
      else if (typeof l == "function")
        try {
          l(null);
        } catch (n) {
          Tt(t, e, n);
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
      Tt(t, t.return, n);
    }
  }
  function Dc(t, e, l) {
    try {
      var a = t.stateNode;
      bh(a, t.type, l, e), a[me] = e;
    } catch (n) {
      Tt(t, t.return, n);
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
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = Pe));
    else if (a !== 4 && (a === 27 && ha(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Cc(t, e, l), t = t.sibling; t !== null; )
        Cc(t, e, l), t = t.sibling;
  }
  function Bu(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && ha(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (Bu(t, e, l), t = t.sibling; t !== null; )
        Bu(t, e, l), t = t.sibling;
  }
  function As(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      ce(e, a, l), e[Zt] = t, e[me] = l;
    } catch (i) {
      Tt(t, t.return, i);
    }
  }
  var Yl = !1, Ft = !1, Uc = !1, _s = typeof WeakSet == "function" ? WeakSet : Set, Pt = null;
  function Im(t, e) {
    if (t = t.containerInfo, Ic = Pu, t = Yo(t), Mf(t)) {
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
            var u = 0, f = -1, o = -1, p = 0, S = 0, A = t, y = null;
            e: for (; ; ) {
              for (var x; A !== l || n !== 0 && A.nodeType !== 3 || (f = u + n), A !== i || a !== 0 && A.nodeType !== 3 || (o = u + a), A.nodeType === 3 && (u += A.nodeValue.length), (x = A.firstChild) !== null; )
                y = A, A = x;
              for (; ; ) {
                if (A === t) break e;
                if (y === l && ++p === n && (f = u), y === i && ++S === a && (o = u), (x = A.nextSibling) !== null) break;
                A = y, y = A.parentNode;
              }
              A = x;
            }
            l = f === -1 || o === -1 ? null : { start: f, end: o };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (Pc = { focusedElem: t, selectionRange: l }, Pu = !1, Pt = e; Pt !== null; )
      if (e = Pt, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, Pt = t;
      else
        for (; Pt !== null; ) {
          switch (e = Pt, i = e.alternate, t = e.flags, e.tag) {
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
                  var w = Ka(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    w,
                    i
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch (K) {
                  Tt(
                    l,
                    l.return,
                    K
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
              if ((t & 1024) !== 0) throw Error(v(163));
          }
          if (t = e.sibling, t !== null) {
            t.return = e.return, Pt = t;
            break;
          }
          Pt = e.return;
        }
  }
  function Ds(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        Ll(t, l), a & 4 && xi(5, l);
        break;
      case 1:
        if (Ll(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              Tt(l, l.return, u);
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
              Tt(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && Ts(l), a & 512 && Si(l, l.return);
        break;
      case 3:
        if (Ll(t, l), a & 64 && (t = l.updateQueue, t !== null)) {
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
            Tt(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && As(l);
      case 26:
      case 5:
        Ll(t, l), e === null && a & 4 && Ms(l), a & 512 && Si(l, l.return);
        break;
      case 12:
        Ll(t, l);
        break;
      case 31:
        Ll(t, l), a & 4 && Us(t, l);
        break;
      case 13:
        Ll(t, l), a & 4 && Bs(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = fh.bind(
          null,
          l
        ), _h(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Yl, !a) {
          e = e !== null && e.memoizedState !== null || Ft, n = Yl;
          var i = Ft;
          Yl = a, (Ft = e) && !i ? Xl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : Ll(t, l), Yl = n, Ft = i;
        }
        break;
      case 30:
        break;
      default:
        Ll(t, l);
    }
  }
  function Os(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Os(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && Ln(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Ht = null, Se = !1;
  function Gl(t, e, l) {
    for (l = l.child; l !== null; )
      Cs(t, e, l), l = l.sibling;
  }
  function Cs(t, e, l) {
    if (pe && typeof pe.onCommitFiberUnmount == "function")
      try {
        pe.onCommitFiberUnmount(za, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        Ft || ml(l, e), Gl(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        Ft || ml(l, e);
        var a = Ht, n = Se;
        ha(l.type) && (Ht = l.stateNode, Se = !1), Gl(
          t,
          e,
          l
        ), Ci(l.stateNode), Ht = a, Se = n;
        break;
      case 5:
        Ft || ml(l, e);
      case 6:
        if (a = Ht, n = Se, Ht = null, Gl(
          t,
          e,
          l
        ), Ht = a, Se = n, Ht !== null)
          if (Se)
            try {
              (Ht.nodeType === 9 ? Ht.body : Ht.nodeName === "HTML" ? Ht.ownerDocument.body : Ht).removeChild(l.stateNode);
            } catch (i) {
              Tt(
                l,
                e,
                i
              );
            }
          else
            try {
              Ht.removeChild(l.stateNode);
            } catch (i) {
              Tt(
                l,
                e,
                i
              );
            }
        break;
      case 18:
        Ht !== null && (Se ? (t = Ht, Td(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), Rn(t)) : Td(Ht, l.stateNode));
        break;
      case 4:
        a = Ht, n = Se, Ht = l.stateNode.containerInfo, Se = !0, Gl(
          t,
          e,
          l
        ), Ht = a, Se = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        fa(2, l, e), Ft || fa(4, l, e), Gl(
          t,
          e,
          l
        );
        break;
      case 1:
        Ft || (ml(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && zs(
          l,
          e,
          a
        )), Gl(
          t,
          e,
          l
        );
        break;
      case 21:
        Gl(
          t,
          e,
          l
        );
        break;
      case 22:
        Ft = (a = Ft) || l.memoizedState !== null, Gl(
          t,
          e,
          l
        ), Ft = a;
        break;
      default:
        Gl(
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
        Rn(t);
      } catch (l) {
        Tt(e, e.return, l);
      }
    }
  }
  function Bs(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        Rn(t);
      } catch (l) {
        Tt(e, e.return, l);
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
        throw Error(v(435, t.tag));
    }
  }
  function Nu(t, e) {
    var l = Pm(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = ch.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function Te(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], i = t, u = e, f = u;
        t: for (; f !== null; ) {
          switch (f.tag) {
            case 27:
              if (ha(f.type)) {
                Ht = f.stateNode, Se = !1;
                break t;
              }
              break;
            case 5:
              Ht = f.stateNode, Se = !1;
              break t;
            case 3:
            case 4:
              Ht = f.stateNode.containerInfo, Se = !0;
              break t;
          }
          f = f.return;
        }
        if (Ht === null) throw Error(v(160));
        Cs(i, u, n), Ht = null, Se = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Ns(e, t), e = e.sibling;
  }
  var al = null;
  function Ns(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Te(e, t), ze(t), a & 4 && (fa(3, t, t.return), xi(3, t), fa(5, t, t.return));
        break;
      case 1:
        Te(e, t), ze(t), a & 512 && (Ft || l === null || ml(l, l.return)), a & 64 && Yl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = al;
        if (Te(e, t), ze(t), a & 512 && (Ft || l === null || ml(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[_a] || i[Zt] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), ce(i, a, l), i[Zt] = t, qt(i), a = i;
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
                      throw Error(v(468, a));
                  }
                  i[Zt] = t, qt(i), a = i;
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
        Te(e, t), ze(t), a & 512 && (Ft || l === null || ml(l, l.return)), l !== null && a & 4 && Dc(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (Te(e, t), ze(t), a & 512 && (Ft || l === null || ml(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            O(n, "");
          } catch (w) {
            Tt(t, t.return, w);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Dc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Uc = !0);
        break;
      case 6:
        if (Te(e, t), ze(t), a & 4) {
          if (t.stateNode === null)
            throw Error(v(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (w) {
            Tt(t, t.return, w);
          }
        }
        break;
      case 3:
        if (Fu = null, n = al, al = Ju(e.containerInfo), Te(e, t), al = n, ze(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            Rn(e.containerInfo);
          } catch (w) {
            Tt(t, t.return, w);
          }
        Uc && (Uc = !1, Rs(t));
        break;
      case 4:
        a = al, al = Ju(
          t.stateNode.containerInfo
        ), Te(e, t), ze(t), al = a;
        break;
      case 12:
        Te(e, t), ze(t);
        break;
      case 31:
        Te(e, t), ze(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 13:
        Te(e, t), ze(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Hu = ae()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var o = l !== null && l.memoizedState !== null, p = Yl, S = Ft;
        if (Yl = p || n, Ft = S || o, Te(e, t), Ft = S, Yl = p, ze(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || o || Yl || Ft || Ja(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                o = l = e;
                try {
                  if (i = o.stateNode, n)
                    u = i.style, typeof u.setProperty == "function" ? u.setProperty("display", "none", "important") : u.display = "none";
                  else {
                    f = o.stateNode;
                    var A = o.memoizedProps.style, y = A != null && A.hasOwnProperty("display") ? A.display : null;
                    f.style.display = y == null || typeof y == "boolean" ? "" : ("" + y).trim();
                  }
                } catch (w) {
                  Tt(o, o.return, w);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                o = e;
                try {
                  o.stateNode.nodeValue = n ? "" : o.memoizedProps;
                } catch (w) {
                  Tt(o, o.return, w);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                o = e;
                try {
                  var x = o.stateNode;
                  n ? zd(x, !0) : zd(o.stateNode, !1);
                } catch (w) {
                  Tt(o, o.return, w);
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
        Te(e, t), ze(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Nu(t, a)));
        break;
      case 30:
        break;
      case 21:
        break;
      default:
        Te(e, t), ze(t);
    }
  }
  function ze(t) {
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
        if (l == null) throw Error(v(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, i = Oc(t);
            Bu(t, i, n);
            break;
          case 5:
            var u = l.stateNode;
            l.flags & 32 && (O(u, ""), l.flags &= -33);
            var f = Oc(t);
            Bu(t, f, u);
            break;
          case 3:
          case 4:
            var o = l.stateNode.containerInfo, p = Oc(t);
            Cc(
              t,
              p,
              o
            );
            break;
          default:
            throw Error(v(161));
        }
      } catch (S) {
        Tt(t, t.return, S);
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
  function Ll(t, e) {
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
          fa(4, e, e.return), Ja(e);
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
  function Xl(t, e, l) {
    for (l = l && (e.subtreeFlags & 8772) !== 0, e = e.child; e !== null; ) {
      var a = e.alternate, n = t, i = e, u = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          Xl(
            n,
            i,
            l
          ), xi(4, i);
          break;
        case 1:
          if (Xl(
            n,
            i,
            l
          ), a = i, n = a.stateNode, typeof n.componentDidMount == "function")
            try {
              n.componentDidMount();
            } catch (p) {
              Tt(a, a.return, p);
            }
          if (a = i, n = a.updateQueue, n !== null) {
            var f = a.stateNode;
            try {
              var o = n.shared.hiddenCallbacks;
              if (o !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < o.length; n++)
                  sr(o[n], f);
            } catch (p) {
              Tt(a, a.return, p);
            }
          }
          l && u & 64 && Ts(i), Si(i, i.return);
          break;
        case 27:
          As(i);
        case 26:
        case 5:
          Xl(
            n,
            i,
            l
          ), l && a === null && u & 4 && Ms(i), Si(i, i.return);
          break;
        case 12:
          Xl(
            n,
            i,
            l
          );
          break;
        case 31:
          Xl(
            n,
            i,
            l
          ), l && u & 4 && Us(n, i);
          break;
        case 13:
          Xl(
            n,
            i,
            l
          ), l && u & 4 && Bs(n, i);
          break;
        case 22:
          i.memoizedState === null && Xl(
            n,
            i,
            l
          ), Si(i, i.return);
          break;
        case 30:
          break;
        default:
          Xl(
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
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && fi(l));
  }
  function Nc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && fi(t));
  }
  function nl(t, e, l, a) {
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
        nl(
          t,
          e,
          l,
          a
        ), n & 2048 && xi(9, e);
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
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && fi(t)));
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
            var i = e.memoizedProps, u = i.id, f = i.onPostCommit;
            typeof f == "function" && f(
              u,
              e.alternate === null ? "mount" : "update",
              t.passiveEffectDuration,
              -0
            );
          } catch (o) {
            Tt(e, e.return, o);
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
        ) : Ti(t, e) : i._visibility & 2 ? nl(
          t,
          e,
          l,
          a
        ) : (i._visibility |= 2, zn(
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
  function zn(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var i = t, u = e, f = l, o = a, p = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          zn(
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
          var S = u.stateNode;
          u.memoizedState !== null ? S._visibility & 2 ? zn(
            i,
            u,
            f,
            o,
            n
          ) : Ti(
            i,
            u
          ) : (S._visibility |= 2, zn(
            i,
            u,
            f,
            o,
            n
          )), n && p & 2048 && Bc(
            u.alternate,
            u
          );
          break;
        case 24:
          zn(
            i,
            u,
            f,
            o,
            n
          ), n && p & 2048 && Nc(u.alternate, u);
          break;
        default:
          zn(
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
            Ti(l, a), n & 2048 && Bc(
              a.alternate,
              a
            );
            break;
          case 24:
            Ti(l, a), n & 2048 && Nc(a.alternate, a);
            break;
          default:
            Ti(l, a);
        }
        e = e.sibling;
      }
  }
  var zi = 8192;
  function Mn(t, e, l) {
    if (t.subtreeFlags & zi)
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
        Mn(
          t,
          e,
          l
        ), t.flags & zi && t.memoizedState !== null && Yh(
          l,
          al,
          t.memoizedState,
          t.memoizedProps
        );
        break;
      case 5:
        Mn(
          t,
          e,
          l
        );
        break;
      case 3:
      case 4:
        var a = al;
        al = Ju(t.stateNode.containerInfo), Mn(
          t,
          e,
          l
        ), al = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = zi, zi = 16777216, Mn(
          t,
          e,
          l
        ), zi = a) : Mn(
          t,
          e,
          l
        ));
        break;
      default:
        Mn(
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
          Pt = a, Ys(
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
        Mi(t), t.flags & 2048 && fa(9, t, t.return);
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
          Pt = a, Ys(
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
          fa(8, e, e.return), Ru(e);
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
  function Ys(t, e) {
    for (; Pt !== null; ) {
      var l = Pt;
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
          fi(l.memoizedState.cache);
      }
      if (a = l.child, a !== null) a.return = l, Pt = a;
      else
        t: for (l = t; Pt !== null; ) {
          a = Pt;
          var n = a.sibling, i = a.return;
          if (Os(a), a === l) {
            Pt = null;
            break t;
          }
          if (n !== null) {
            n.return = i, Pt = n;
            break t;
          }
          Pt = i;
        }
    }
  }
  var th = {
    getCacheForType: function(t) {
      var e = ue(Kt), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return ue(Kt).controller.signal;
    }
  }, eh = typeof WeakMap == "function" ? WeakMap : Map, vt = 0, At = null, it = null, ft = 0, St = 0, Ne = null, ca = !1, En = !1, Rc = !1, Ql = 0, Lt = 0, oa = 0, ka = 0, Hc = 0, Re = 0, An = 0, Ei = null, Me = null, wc = !1, Hu = 0, Gs = 0, wu = 1 / 0, ju = null, ra = null, $t = 0, sa = null, _n = null, Vl = 0, jc = 0, qc = null, Ls = null, Ai = 0, Yc = null;
  function He() {
    return (vt & 2) !== 0 && ft !== 0 ? ft & -ft : m.T !== null ? Zc() : Ia();
  }
  function Xs() {
    if (Re === 0)
      if ((ft & 536870912) === 0 || ot) {
        var t = Wa;
        Wa <<= 1, (Wa & 3932160) === 0 && (Wa = 262144), Re = t;
      } else Re = 536870912;
    return t = Ue.current, t !== null && (t.flags |= 32), Re;
  }
  function Ee(t, e, l) {
    (t === At && (St === 2 || St === 9) || t.cancelPendingCommit !== null) && (Dn(t, 0), da(
      t,
      ft,
      Re,
      !1
    )), Jl(t, l), ((vt & 2) === 0 || t !== At) && (t === At && ((vt & 2) === 0 && (ka |= l), Lt === 4 && da(
      t,
      ft,
      Re,
      !1
    )), hl(t));
  }
  function Qs(t, e, l) {
    if ((vt & 6) !== 0) throw Error(v(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Kl(t, e), n = a ? nh(t, e) : Lc(t, e, !0), i = a;
    do {
      if (n === 0) {
        En && !a && da(t, e, 0, !1);
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
              n = Ei;
              var o = f.current.memoizedState.isDehydrated;
              if (o && (Dn(f, u).flags |= 256), u = Lc(
                f,
                u,
                !1
              ), u !== 2) {
                if (Rc && !o) {
                  f.errorRecoveryDisabledLanes |= i, ka |= i, n = 4;
                  break t;
                }
                i = Me, Me = n, i !== null && (Me === null ? Me = i : Me.push.apply(
                  Me,
                  i
                ));
              }
              n = u;
            }
            if (i = !1, n !== 2) continue;
          }
        }
        if (n === 1) {
          Dn(t, 0), da(t, e, 0, !0);
          break;
        }
        t: {
          switch (a = t, i = n, i) {
            case 0:
            case 1:
              throw Error(v(345));
            case 4:
              if ((e & 4194048) !== e) break;
            case 6:
              da(
                a,
                e,
                Re,
                !ca
              );
              break t;
            case 2:
              Me = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(v(329));
          }
          if ((e & 62914560) === e && (n = Hu + 300 - ae(), 10 < n)) {
            if (da(
              a,
              e,
              Re,
              !ca
            ), $a(a, 0, !0) !== 0) break t;
            Vl = e, a.timeoutHandle = xd(
              Vs.bind(
                null,
                a,
                l,
                Me,
                ju,
                wc,
                e,
                Re,
                ka,
                An,
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
            Me,
            ju,
            wc,
            e,
            Re,
            ka,
            An,
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
  function Vs(t, e, l, a, n, i, u, f, o, p, S, A, y, x) {
    if (t.timeoutHandle = -1, A = e.subtreeFlags, A & 8192 || (A & 16785408) === 16785408) {
      A = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: Pe
      }, ws(
        e,
        i,
        A
      );
      var w = (i & 62914560) === i ? Hu - ae() : (i & 4194048) === i ? Gs - ae() : 0;
      if (w = Gh(
        A,
        w
      ), w !== null) {
        Vl = i, t.cancelPendingCommit = w(
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
            S,
            A,
            null,
            y,
            x
          )
        ), da(t, i, u, !p);
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
  function lh(t) {
    for (var e = t; ; ) {
      var l = e.tag;
      if ((l === 0 || l === 11 || l === 15) && e.flags & 16384 && (l = e.updateQueue, l !== null && (l = l.stores, l !== null)))
        for (var a = 0; a < l.length; a++) {
          var n = l[a], i = n.getSnapshot;
          n = n.value;
          try {
            if (!Oe(i(), n)) return !1;
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
    e &= ~Hc, e &= ~ka, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var i = 31 - ve(n), u = 1 << i;
      a[i] = -1, n &= ~u;
    }
    l !== 0 && Ea(t, l, e);
  }
  function qu() {
    return (vt & 6) === 0 ? (_i(0), !1) : !0;
  }
  function Gc() {
    if (it !== null) {
      if (St === 0)
        var t = it.return;
      else
        t = it, Nl = Ya = null, lc(t), yn = null, oi = 0, t = it;
      for (; t !== null; )
        Ss(t.alternate, t), t = t.return;
      it = null;
    }
  }
  function Dn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Th(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), Vl = 0, Gc(), At = t, it = l = Ul(t.current, null), ft = e, St = 0, Ne = null, ca = !1, En = Kl(t, e), Rc = !1, An = Re = Hc = ka = oa = Lt = 0, Me = Ei = null, wc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - ve(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return Ql = e, iu(), l;
  }
  function Zs(t, e) {
    tt = null, m.H = vi, e === vn || e === mu ? (e = fr(), St = 3) : e === Vf ? (e = fr(), St = 4) : St = e === yc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, Ne = e, it === null && (Lt = 1, _u(
      t,
      Ve(e, t.current)
    ));
  }
  function Ks() {
    var t = Ue.current;
    return t === null ? !0 : (ft & 4194048) === ft ? ke === null : (ft & 62914560) === ft || (ft & 536870912) !== 0 ? t === ke : !1;
  }
  function Js() {
    var t = m.H;
    return m.H = vi, t === null ? vi : t;
  }
  function ks() {
    var t = m.A;
    return m.A = th, t;
  }
  function Yu() {
    Lt = 4, ca || (ft & 4194048) !== ft && Ue.current !== null || (En = !0), (oa & 134217727) === 0 && (ka & 134217727) === 0 || At === null || da(
      At,
      ft,
      Re,
      !1
    );
  }
  function Lc(t, e, l) {
    var a = vt;
    vt |= 2;
    var n = Js(), i = ks();
    (At !== t || ft !== e) && (ju = null, Dn(t, e)), e = !1;
    var u = Lt;
    t: do
      try {
        if (St !== 0 && it !== null) {
          var f = it, o = Ne;
          switch (St) {
            case 8:
              Gc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              Ue.current === null && (e = !0);
              var p = St;
              if (St = 0, Ne = null, On(t, f, o, p), l && En) {
                u = 0;
                break t;
              }
              break;
            default:
              p = St, St = 0, Ne = null, On(t, f, o, p);
          }
        }
        ah(), u = Lt;
        break;
      } catch (S) {
        Zs(t, S);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Nl = Ya = null, vt = a, m.H = n, m.A = i, it === null && (At = null, ft = 0, iu()), u;
  }
  function ah() {
    for (; it !== null; ) Fs(it);
  }
  function nh(t, e) {
    var l = vt;
    vt |= 2;
    var a = Js(), n = ks();
    At !== t || ft !== e ? (ju = null, wu = ae() + 500, Dn(t, e)) : En = Kl(
      t,
      e
    );
    t: do
      try {
        if (St !== 0 && it !== null) {
          e = it;
          var i = Ne;
          e: switch (St) {
            case 1:
              St = 0, Ne = null, On(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (ir(i)) {
                St = 0, Ne = null, Ws(e);
                break;
              }
              e = function() {
                St !== 2 && St !== 9 || At !== t || (St = 7), hl(t);
              }, i.then(e, e);
              break t;
            case 3:
              St = 7;
              break t;
            case 4:
              St = 5;
              break t;
            case 7:
              ir(i) ? (St = 0, Ne = null, Ws(e)) : (St = 0, Ne = null, On(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (it.tag) {
                case 26:
                  u = it.memoizedState;
                case 5:
                case 27:
                  var f = it;
                  if (u ? Hd(u) : f.stateNode.complete) {
                    St = 0, Ne = null;
                    var o = f.sibling;
                    if (o !== null) it = o;
                    else {
                      var p = f.return;
                      p !== null ? (it = p, Gu(p)) : it = null;
                    }
                    break e;
                  }
              }
              St = 0, Ne = null, On(t, e, i, 5);
              break;
            case 6:
              St = 0, Ne = null, On(t, e, i, 6);
              break;
            case 8:
              Gc(), Lt = 6;
              break t;
            default:
              throw Error(v(462));
          }
        }
        ih();
        break;
      } catch (S) {
        Zs(t, S);
      }
    while (!0);
    return Nl = Ya = null, m.H = a, m.A = n, vt = l, it !== null ? 0 : (At = null, ft = 0, iu(), Lt);
  }
  function ih() {
    for (; it !== null && !Yn(); )
      Fs(it);
  }
  function Fs(t) {
    var e = bs(t.alternate, t, Ql);
    t.memoizedProps = t.pendingProps, e === null ? Gu(t) : it = e;
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
          ft
        );
        break;
      case 11:
        e = ms(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          ft
        );
        break;
      case 5:
        lc(e);
      default:
        Ss(l, e), e = it = ko(e, Ql), e = bs(l, e, Ql);
    }
    t.memoizedProps = t.pendingProps, e === null ? Gu(t) : it = e;
  }
  function On(t, e, l, a) {
    Nl = Ya = null, lc(e), yn = null, oi = 0;
    var n = e.return;
    try {
      if (Jm(
        t,
        n,
        e,
        l,
        ft
      )) {
        Lt = 1, _u(
          t,
          Ve(l, t.current)
        ), it = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw it = n, i;
      Lt = 1, _u(
        t,
        Ve(l, t.current)
      ), it = null;
      return;
    }
    e.flags & 32768 ? (ot || a === 1 ? t = !0 : En || (ft & 536870912) !== 0 ? t = !1 : (ca = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = Ue.current, a !== null && a.tag === 13 && (a.flags |= 16384))), $s(e, t)) : Gu(e);
  }
  function Gu(t) {
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
        Ql
      );
      if (l !== null) {
        it = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        it = e;
        return;
      }
      it = e = t;
    } while (e !== null);
    Lt === 0 && (Lt = 5);
  }
  function $s(t, e) {
    do {
      var l = $m(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, it = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        it = t;
        return;
      }
      it = t = l;
    } while (t !== null);
    Lt = 6, it = null;
  }
  function Is(t, e, l, a, n, i, u, f, o) {
    t.cancelPendingCommit = null;
    do
      Lu();
    while ($t !== 0);
    if ((vt & 6) !== 0) throw Error(v(327));
    if (e !== null) {
      if (e === t.current) throw Error(v(177));
      if (i = e.lanes | e.childLanes, i |= Of, sf(
        t,
        l,
        i,
        u,
        f,
        o
      ), t === At && (it = At = null, ft = 0), _n = e, sa = t, Vl = l, jc = i, qc = n, Ls = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, oh(Ta, function() {
        return ad(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = m.T, m.T = null, n = D.p, D.p = 2, u = vt, vt |= 4;
        try {
          Im(t, e, l);
        } finally {
          vt = u, D.p = n, m.T = a;
        }
      }
      $t = 1, Ps(), td(), ed();
    }
  }
  function Ps() {
    if ($t === 1) {
      $t = 0;
      var t = sa, e = _n, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = m.T, m.T = null;
        var a = D.p;
        D.p = 2;
        var n = vt;
        vt |= 4;
        try {
          Ns(e, t);
          var i = Pc, u = Yo(t.containerInfo), f = i.focusedElem, o = i.selectionRange;
          if (u !== f && f && f.ownerDocument && qo(
            f.ownerDocument.documentElement,
            f
          )) {
            if (o !== null && Mf(f)) {
              var p = o.start, S = o.end;
              if (S === void 0 && (S = p), "selectionStart" in f)
                f.selectionStart = p, f.selectionEnd = Math.min(
                  S,
                  f.value.length
                );
              else {
                var A = f.ownerDocument || document, y = A && A.defaultView || window;
                if (y.getSelection) {
                  var x = y.getSelection(), w = f.textContent.length, K = Math.min(o.start, w), Et = o.end === void 0 ? K : Math.min(o.end, w);
                  !x.extend && K > Et && (u = Et, Et = K, K = u);
                  var h = jo(
                    f,
                    K
                  ), d = jo(
                    f,
                    Et
                  );
                  if (h && d && (x.rangeCount !== 1 || x.anchorNode !== h.node || x.anchorOffset !== h.offset || x.focusNode !== d.node || x.focusOffset !== d.offset)) {
                    var g = A.createRange();
                    g.setStart(h.node, h.offset), x.removeAllRanges(), K > Et ? (x.addRange(g), x.extend(d.node, d.offset)) : (g.setEnd(d.node, d.offset), x.addRange(g));
                  }
                }
              }
            }
            for (A = [], x = f; x = x.parentNode; )
              x.nodeType === 1 && A.push({
                element: x,
                left: x.scrollLeft,
                top: x.scrollTop
              });
            for (typeof f.focus == "function" && f.focus(), f = 0; f < A.length; f++) {
              var z = A[f];
              z.element.scrollLeft = z.left, z.element.scrollTop = z.top;
            }
          }
          Pu = !!Ic, Pc = Ic = null;
        } finally {
          vt = n, D.p = a, m.T = l;
        }
      }
      t.current = e, $t = 2;
    }
  }
  function td() {
    if ($t === 2) {
      $t = 0;
      var t = sa, e = _n, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = m.T, m.T = null;
        var a = D.p;
        D.p = 2;
        var n = vt;
        vt |= 4;
        try {
          Ds(t, e.alternate, e);
        } finally {
          vt = n, D.p = a, m.T = l;
        }
      }
      $t = 3;
    }
  }
  function ed() {
    if ($t === 4 || $t === 3) {
      $t = 0, Gi();
      var t = sa, e = _n, l = Vl, a = Ls;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? $t = 5 : ($t = 0, _n = sa = null, ld(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (ra = null), Aa(l), e = e.stateNode, pe && typeof pe.onCommitFiberRoot == "function")
        try {
          pe.onCommitFiberRoot(
            za,
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
      (Vl & 3) !== 0 && Lu(), hl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Yc ? Ai++ : (Ai = 0, Yc = t) : Ai = 0, _i(0);
    }
  }
  function ld(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, fi(e)));
  }
  function Lu() {
    return Ps(), td(), ed(), ad();
  }
  function ad() {
    if ($t !== 5) return !1;
    var t = sa, e = jc;
    jc = 0;
    var l = Aa(Vl), a = m.T, n = D.p;
    try {
      D.p = 32 > l ? 32 : l, m.T = null, l = qc, qc = null;
      var i = sa, u = Vl;
      if ($t = 0, _n = sa = null, Vl = 0, (vt & 6) !== 0) throw Error(v(331));
      var f = vt;
      if (vt |= 4, qs(i.current), Hs(
        i,
        i.current,
        u,
        l
      ), vt = f, _i(0, !1), pe && typeof pe.onPostCommitFiberRoot == "function")
        try {
          pe.onPostCommitFiberRoot(za, i);
        } catch {
        }
      return !0;
    } finally {
      D.p = n, m.T = a, ld(t, e);
    }
  }
  function nd(t, e, l) {
    e = Ve(l, e), e = vc(t.stateNode, e, 2), t = na(t, e, 2), t !== null && (Jl(t, 2), hl(t));
  }
  function Tt(t, e, l) {
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
            t = Ve(l, t), l = is(2), a = na(e, l, 2), a !== null && (us(
              l,
              a,
              e,
              t
            ), Jl(a, 2), hl(a));
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
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, At === t && (ft & l) === l && (Lt === 4 || Lt === 3 && (ft & 62914560) === ft && 300 > ae() - Hu ? (vt & 2) === 0 && Dn(t, 0) : Hc |= l, An === ft && (An = 0)), hl(t);
  }
  function id(t, e) {
    e === 0 && (e = Ji()), t = wa(t, e), t !== null && (Jl(t, e), hl(t));
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
        throw Error(v(314));
    }
    a !== null && a.delete(e), id(t, l);
  }
  function oh(t, e) {
    return qn(t, e);
  }
  var Xu = null, Cn = null, Qc = !1, Qu = !1, Vc = !1, ma = 0;
  function hl(t) {
    t !== Cn && t.next === null && (Cn === null ? Xu = Cn = t : Cn = Cn.next = t), Qu = !0, Qc || (Qc = !0, sh());
  }
  function _i(t, e) {
    if (!Vc && Qu) {
      Vc = !0;
      do
        for (var l = !1, a = Xu; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var i = 0;
            else {
              var u = a.suspendedLanes, f = a.pingedLanes;
              i = (1 << 31 - ve(42 | t) + 1) - 1, i &= n & ~(u & ~f), i = i & 201326741 ? i & 201326741 | 1 : i ? i | 2 : 0;
            }
            i !== 0 && (l = !0, od(a, i));
          } else
            i = ft, i = $a(
              a,
              a === At ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || Kl(a, i) || (l = !0, od(a, i));
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
    Qu = Qc = !1;
    var t = 0;
    ma !== 0 && Sh() && (t = ma);
    for (var e = ae(), l = null, a = Xu; a !== null; ) {
      var n = a.next, i = fd(a, e);
      i === 0 ? (a.next = null, l === null ? Xu = n : l.next = n, n === null && (Cn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (Qu = !0)), a = n;
    }
    $t !== 0 && $t !== 5 || _i(t), ma !== 0 && (ma = 0);
  }
  function fd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - ve(i), f = 1 << u, o = n[u];
      o === -1 ? ((f & l) === 0 || (f & a) !== 0) && (n[u] = Ki(f, e)) : o <= e && (t.expiredLanes |= f), i &= ~f;
    }
    if (e = At, l = ft, l = $a(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (St === 2 || St === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && Sa(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Kl(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && Sa(a), Aa(l)) {
        case 2:
        case 8:
          l = Fa;
          break;
        case 32:
          l = Ta;
          break;
        case 268435456:
          l = Qi;
          break;
        default:
          l = Ta;
      }
      return a = cd.bind(null, t), l = qn(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && Sa(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function cd(t, e) {
    if ($t !== 0 && $t !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Lu() && t.callbackNode !== l)
      return null;
    var a = ft;
    return a = $a(
      t,
      t === At ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Qs(t, a, e), fd(t, ae()), t.callbackNode != null && t.callbackNode === l ? cd.bind(null, t) : null);
  }
  function od(t, e) {
    if (Lu()) return null;
    Qs(t, e, !0);
  }
  function sh() {
    zh(function() {
      (vt & 6) !== 0 ? qn(
        Xi,
        rh
      ) : ud();
    });
  }
  function Zc() {
    if (ma === 0) {
      var t = gn;
      t === 0 && (t = vl, vl <<= 1, (vl & 261888) === 0 && (vl = 256)), ma = t;
    }
    return ma;
  }
  function rd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : Ie("" + t);
  }
  function sd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function dh(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = rd(
        (n[me] || null).action
      ), u = a.submitter;
      u && (e = (e = u[me] || null) ? rd(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
      var f = new Ua(
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
                  var o = u ? sd(n, u) : new FormData(n);
                  sc(
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
                typeof i == "function" && (f.preventDefault(), o = u ? sd(n, u) : new FormData(n), sc(
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
  for (var Kc = 0; Kc < Df.length; Kc++) {
    var Jc = Df[Kc], mh = Jc.toLowerCase(), hh = Jc[0].toUpperCase() + Jc.slice(1);
    ll(
      mh,
      "on" + hh
    );
  }
  ll(Xo, "onAnimationEnd"), ll(Qo, "onAnimationIteration"), ll(Vo, "onAnimationStart"), ll("dblclick", "onDoubleClick"), ll("focusin", "onFocus"), ll("focusout", "onBlur"), ll(Cm, "onTransitionRun"), ll(Um, "onTransitionStart"), ll(Bm, "onTransitionCancel"), ll(Zo, "onTransitionEnd"), El("onMouseEnter", ["mouseout", "mouseover"]), El("onMouseLeave", ["mouseout", "mouseover"]), El("onPointerEnter", ["pointerout", "pointerover"]), El("onPointerLeave", ["pointerout", "pointerover"]), Ml(
    "onChange",
    "change click focusin focusout input keydown keyup selectionchange".split(" ")
  ), Ml(
    "onSelect",
    "focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(
      " "
    )
  ), Ml("onBeforeInput", [
    "compositionend",
    "keypress",
    "textInput",
    "paste"
  ]), Ml(
    "onCompositionEnd",
    "compositionend focusout keydown keypress keyup mousedown".split(" ")
  ), Ml(
    "onCompositionStart",
    "compositionstart focusout keydown keypress keyup mousedown".split(" ")
  ), Ml(
    "onCompositionUpdate",
    "compositionupdate focusout keydown keypress keyup mousedown".split(" ")
  );
  var Di = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), gh = new Set(
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
            var f = a[u], o = f.instance, p = f.currentTarget;
            if (f = f.listener, o !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = p;
            try {
              i(n);
            } catch (S) {
              nu(S);
            }
            n.currentTarget = null, i = o;
          }
        else
          for (u = 0; u < a.length; u++) {
            if (f = a[u], o = f.instance, p = f.currentTarget, f = f.listener, o !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = p;
            try {
              i(n);
            } catch (S) {
              nu(S);
            }
            n.currentTarget = null, i = o;
          }
      }
    }
  }
  function ut(t, e) {
    var l = e[Pa];
    l === void 0 && (l = e[Pa] = /* @__PURE__ */ new Set());
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
  var Vu = "_reactListening" + Math.random().toString(36).slice(2);
  function Fc(t) {
    if (!t[Vu]) {
      t[Vu] = !0, Xn.forEach(function(l) {
        l !== "selectionchange" && (gh.has(l) || kc(l, !1, t), kc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[Vu] || (e[Vu] = !0, kc("selectionchange", !1, e));
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
    ), n = void 0, !ln || e !== "touchstart" && e !== "touchmove" && e !== "wheel" || (n = !0), a ? n !== void 0 ? t.addEventListener(e, l, {
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
              var o = u.tag;
              if ((o === 3 || o === 4) && u.stateNode.containerInfo === n)
                return;
              u = u.return;
            }
          for (; f !== null; ) {
            if (u = Sl(f), u === null) return;
            if (o = u.tag, o === 5 || o === 6 || o === 26 || o === 27) {
              a = i = u;
              continue t;
            }
            f = f.parentNode;
          }
        }
        a = a.return;
      }
    en(function() {
      var p = i, S = Fn(l), A = [];
      t: {
        var y = Ko.get(t);
        if (y !== void 0) {
          var x = Ua, w = t;
          switch (t) {
            case "keypress":
              if (Oa(l) === 0) break t;
            case "keydown":
            case "keyup":
              x = cm;
              break;
            case "focusin":
              w = "focus", x = C;
              break;
            case "focusout":
              w = "blur", x = C;
              break;
            case "beforeblur":
            case "afterblur":
              x = C;
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
              x = Pn;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              x = nn;
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
              x = P;
              break;
            case Zo:
              x = mm;
              break;
            case "scroll":
            case "scrollend":
              x = yf;
              break;
            case "wheel":
              x = gm;
              break;
            case "copy":
            case "cut":
            case "paste":
              x = mt;
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
          var K = (e & 4) !== 0, Et = !K && (t === "scroll" || t === "scrollend"), h = K ? y !== null ? y + "Capture" : null : y;
          K = [];
          for (var d = p, g; d !== null; ) {
            var z = d;
            if (g = z.stateNode, z = z.tag, z !== 5 && z !== 26 && z !== 27 || g === null || h === null || (z = _l(d, h), z != null && K.push(
              Oi(d, z, g)
            )), Et) break;
            d = d.return;
          }
          0 < K.length && (y = new x(
            y,
            w,
            null,
            l,
            S
          ), A.push({ event: y, listeners: K }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (y = t === "mouseover" || t === "pointerover", x = t === "mouseout" || t === "pointerout", y && l !== kn && (w = l.relatedTarget || l.fromElement) && (Sl(w) || w[xl]))
            break t;
          if ((x || y) && (y = S.window === S ? S : (y = S.ownerDocument) ? y.defaultView || y.parentWindow : window, x ? (w = l.relatedTarget || l.toElement, x = p, w = w ? Sl(w) : null, w !== null && (Et = Ut(w), K = w.tag, w !== Et || K !== 5 && K !== 27 && K !== 6) && (w = null)) : (x = null, w = p), x !== w)) {
            if (K = Pn, z = "onMouseLeave", h = "onMouseEnter", d = "mouse", (t === "pointerout" || t === "pointerover") && (K = zo, z = "onPointerLeave", h = "onPointerEnter", d = "pointer"), Et = x == null ? y : Tl(x), g = w == null ? y : Tl(w), y = new K(
              z,
              d + "leave",
              x,
              l,
              S
            ), y.target = Et, y.relatedTarget = g, z = null, Sl(S) === p && (K = new K(
              h,
              d + "enter",
              w,
              l,
              S
            ), K.target = g, K.relatedTarget = Et, z = K), Et = z, x && w)
              e: {
                for (K = ph, h = x, d = w, g = 0, z = h; z; z = K(z))
                  g++;
                z = 0;
                for (var V = d; V; V = K(V))
                  z++;
                for (; 0 < g - z; )
                  h = K(h), g--;
                for (; 0 < z - g; )
                  d = K(d), z--;
                for (; g--; ) {
                  if (h === d || d !== null && h === d.alternate) {
                    K = h;
                    break e;
                  }
                  h = K(h), d = K(d);
                }
                K = null;
              }
            else K = null;
            x !== null && hd(
              A,
              y,
              x,
              K,
              !1
            ), w !== null && Et !== null && hd(
              A,
              Et,
              w,
              K,
              !0
            );
          }
        }
        t: {
          if (y = p ? Tl(p) : window, x = y.nodeName && y.nodeName.toLowerCase(), x === "select" || x === "input" && y.type === "file")
            var ht = Uo;
          else if (Oo(y))
            if (Bo)
              ht = _m;
            else {
              ht = Em;
              var j = Mm;
            }
          else
            x = y.nodeName, !x || x.toLowerCase() !== "input" || y.type !== "checkbox" && y.type !== "radio" ? p && W(p.elementType) && (ht = Uo) : ht = Am;
          if (ht && (ht = ht(t, p))) {
            Co(
              A,
              ht,
              l,
              S
            );
            break t;
          }
          j && j(t, y, p), t === "focusout" && p && y.type === "number" && p.memoizedProps.value != null && Jn(y, "number", y.value);
        }
        switch (j = p ? Tl(p) : window, t) {
          case "focusin":
            (Oo(j) || j.contentEditable === "true") && (fn = j, Ef = p, ni = null);
            break;
          case "focusout":
            ni = Ef = fn = null;
            break;
          case "mousedown":
            Af = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Af = !1, Go(A, l, S);
            break;
          case "selectionchange":
            if (Om) break;
          case "keydown":
          case "keyup":
            Go(A, l, S);
        }
        var et;
        if (Sf)
          t: {
            switch (t) {
              case "compositionstart":
                var ct = "onCompositionStart";
                break t;
              case "compositionend":
                ct = "onCompositionEnd";
                break t;
              case "compositionupdate":
                ct = "onCompositionUpdate";
                break t;
            }
            ct = void 0;
          }
        else
          un ? _o(t, l) && (ct = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (ct = "onCompositionStart");
        ct && (Mo && l.locale !== "ko" && (un || ct !== "onCompositionStart" ? ct === "onCompositionEnd" && un && (et = Pi()) : (Le = S, Ol = "value" in Le ? Le.value : Le.textContent, un = !0)), j = Zu(p, ct), 0 < j.length && (ct = new he(
          ct,
          t,
          null,
          l,
          S
        ), A.push({ event: ct, listeners: j }), et ? ct.data = et : (et = Do(l), et !== null && (ct.data = et)))), (et = bm ? xm(t, l) : Sm(t, l)) && (ct = Zu(p, "onBeforeInput"), 0 < ct.length && (j = new he(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          S
        ), A.push({
          event: j,
          listeners: ct
        }), j.data = et)), dh(
          A,
          t,
          p,
          l,
          S
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
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = _l(t, l), n != null && a.unshift(
        Oi(t, n, i)
      ), n = _l(t, e), n != null && a.push(
        Oi(t, n, i)
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
      var f = l, o = f.alternate, p = f.stateNode;
      if (f = f.tag, o !== null && o === a) break;
      f !== 5 && f !== 26 && f !== 27 || p === null || (o = p, n ? (p = _l(l, i), p != null && u.unshift(
        Oi(l, p, o)
      )) : n || (p = _l(l, i), p != null && u.push(
        Oi(l, p, o)
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
  function Mt(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || O(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && O(t, "" + a);
        break;
      case "className":
        tn(t, "class", a);
        break;
      case "tabIndex":
        tn(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        tn(t, l, a);
        break;
      case "style":
        G(t, a, i);
        break;
      case "data":
        if (e !== "object") {
          tn(t, "data", a);
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
        a = Ie("" + a), t.setAttribute(l, a);
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
          typeof i == "function" && (l === "formAction" ? (e !== "input" && Mt(t, e, "name", n.name, n, null), Mt(
            t,
            e,
            "formEncType",
            n.formEncType,
            n,
            null
          ), Mt(
            t,
            e,
            "formMethod",
            n.formMethod,
            n,
            null
          ), Mt(
            t,
            e,
            "formTarget",
            n.formTarget,
            n,
            null
          )) : (Mt(t, e, "encType", n.encType, n, null), Mt(t, e, "method", n.method, n, null), Mt(t, e, "target", n.target, n, null)));
        if (a == null || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = Ie("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = Pe);
        break;
      case "onScroll":
        a != null && ut("scroll", t);
        break;
      case "onScrollEnd":
        a != null && ut("scrollend", t);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(v(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(v(60));
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
        l = Ie("" + a), t.setAttributeNS(
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
        ut("beforetoggle", t), ut("toggle", t), kl(t, "popover", a);
        break;
      case "xlinkActuate":
        Ge(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:actuate",
          a
        );
        break;
      case "xlinkArcrole":
        Ge(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:arcrole",
          a
        );
        break;
      case "xlinkRole":
        Ge(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:role",
          a
        );
        break;
      case "xlinkShow":
        Ge(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:show",
          a
        );
        break;
      case "xlinkTitle":
        Ge(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:title",
          a
        );
        break;
      case "xlinkType":
        Ge(
          t,
          "http://www.w3.org/1999/xlink",
          "xlink:type",
          a
        );
        break;
      case "xmlBase":
        Ge(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:base",
          a
        );
        break;
      case "xmlLang":
        Ge(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:lang",
          a
        );
        break;
      case "xmlSpace":
        Ge(
          t,
          "http://www.w3.org/XML/1998/namespace",
          "xml:space",
          a
        );
        break;
      case "is":
        kl(t, "is", a);
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = st.get(l) || l, kl(t, l, a));
    }
  }
  function $c(t, e, l, a, n, i) {
    switch (l) {
      case "style":
        G(t, a, i);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(v(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(v(60));
            t.innerHTML = l;
          }
        }
        break;
      case "children":
        typeof a == "string" ? O(t, a) : (typeof a == "number" || typeof a == "bigint") && O(t, "" + a);
        break;
      case "onScroll":
        a != null && ut("scroll", t);
        break;
      case "onScrollEnd":
        a != null && ut("scrollend", t);
        break;
      case "onClick":
        a != null && (t.onclick = Pe);
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
        if (!Qn.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[me] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : kl(t, l, a);
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
        ut("error", t), ut("load", t);
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
                  throw Error(v(137, e));
                default:
                  Mt(t, e, i, u, l, null);
              }
          }
        n && Mt(t, e, "srcSet", l.srcSet, l, null), a && Mt(t, e, "src", l.src, l, null);
        return;
      case "input":
        ut("invalid", t);
        var f = i = u = n = null, o = null, p = null;
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
                  o = S;
                  break;
                case "defaultChecked":
                  p = S;
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
                    throw Error(v(137, e));
                  break;
                default:
                  Mt(t, e, a, S, l, null);
              }
          }
        Ii(
          t,
          i,
          f,
          o,
          p,
          u,
          n,
          !1
        );
        return;
      case "select":
        ut("invalid", t), a = u = i = null;
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
                Mt(t, e, n, f, l, null);
            }
        e = i, l = u, t.multiple = !!a, e != null ? c(t, !!a, e, !1) : l != null && c(t, !!a, l, !0);
        return;
      case "textarea":
        ut("invalid", t), i = n = a = null;
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
                if (f != null) throw Error(v(91));
                break;
              default:
                Mt(t, e, u, f, l, null);
            }
        b(t, a, n, i);
        return;
      case "option":
        for (o in l)
          l.hasOwnProperty(o) && (a = l[o], a != null) && (o === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : Mt(t, e, o, a, l, null));
        return;
      case "dialog":
        ut("beforetoggle", t), ut("toggle", t), ut("cancel", t), ut("close", t);
        break;
      case "iframe":
      case "object":
        ut("load", t);
        break;
      case "video":
      case "audio":
        for (a = 0; a < Di.length; a++)
          ut(Di[a], t);
        break;
      case "image":
        ut("error", t), ut("load", t);
        break;
      case "details":
        ut("toggle", t);
        break;
      case "embed":
      case "source":
      case "link":
        ut("error", t), ut("load", t);
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
        for (p in l)
          if (l.hasOwnProperty(p) && (a = l[p], a != null))
            switch (p) {
              case "children":
              case "dangerouslySetInnerHTML":
                throw Error(v(137, e));
              default:
                Mt(t, e, p, a, l, null);
            }
        return;
      default:
        if (W(e)) {
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
      l.hasOwnProperty(f) && (a = l[f], a != null && Mt(t, e, f, a, l, null));
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
        var n = null, i = null, u = null, f = null, o = null, p = null, S = null;
        for (x in l) {
          var A = l[x];
          if (l.hasOwnProperty(x) && A != null)
            switch (x) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                o = A;
              default:
                a.hasOwnProperty(x) || Mt(t, e, x, null, a, A);
            }
        }
        for (var y in a) {
          var x = a[y];
          if (A = l[y], a.hasOwnProperty(y) && (x != null || A != null))
            switch (y) {
              case "type":
                i = x;
                break;
              case "name":
                n = x;
                break;
              case "checked":
                p = x;
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
                  throw Error(v(137, e));
                break;
              default:
                x !== A && Mt(
                  t,
                  e,
                  y,
                  x,
                  a,
                  A
                );
            }
        }
        Wl(
          t,
          u,
          f,
          o,
          p,
          S,
          i,
          n
        );
        return;
      case "select":
        x = u = f = y = null;
        for (i in l)
          if (o = l[i], l.hasOwnProperty(i) && o != null)
            switch (i) {
              case "value":
                break;
              case "multiple":
                x = o;
              default:
                a.hasOwnProperty(i) || Mt(
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
                y = i;
                break;
              case "defaultValue":
                f = i;
                break;
              case "multiple":
                u = i;
              default:
                i !== o && Mt(
                  t,
                  e,
                  n,
                  i,
                  a,
                  o
                );
            }
        e = f, l = u, a = x, y != null ? c(t, !!l, y, !1) : !!a != !!l && (e != null ? c(t, !!l, e, !0) : c(t, !!l, l ? [] : "", !1));
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
                Mt(t, e, f, null, a, n);
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
                if (n != null) throw Error(v(91));
                break;
              default:
                n !== i && Mt(t, e, u, n, a, i);
            }
        r(t, y, x);
        return;
      case "option":
        for (var w in l)
          y = l[w], l.hasOwnProperty(w) && y != null && !a.hasOwnProperty(w) && (w === "selected" ? t.selected = !1 : Mt(
            t,
            e,
            w,
            null,
            a,
            y
          ));
        for (o in a)
          y = a[o], x = l[o], a.hasOwnProperty(o) && y !== x && (y != null || x != null) && (o === "selected" ? t.selected = y && typeof y != "function" && typeof y != "symbol" : Mt(
            t,
            e,
            o,
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
        for (var K in l)
          y = l[K], l.hasOwnProperty(K) && y != null && !a.hasOwnProperty(K) && Mt(t, e, K, null, a, y);
        for (p in a)
          if (y = a[p], x = l[p], a.hasOwnProperty(p) && y !== x && (y != null || x != null))
            switch (p) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (y != null)
                  throw Error(v(137, e));
                break;
              default:
                Mt(
                  t,
                  e,
                  p,
                  y,
                  a,
                  x
                );
            }
        return;
      default:
        if (W(e)) {
          for (var Et in l)
            y = l[Et], l.hasOwnProperty(Et) && y !== void 0 && !a.hasOwnProperty(Et) && $c(
              t,
              e,
              Et,
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
      y = l[h], l.hasOwnProperty(h) && y != null && !a.hasOwnProperty(h) && Mt(t, e, h, null, a, y);
    for (A in a)
      y = a[A], x = l[A], !a.hasOwnProperty(A) || y === x || y == null && x == null || Mt(t, e, A, y, a, x);
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
            var o = l[a], p = o.startTime;
            if (p > f) break;
            var S = o.transferSize, A = o.initiatorType;
            S && vd(A) && (o = o.responseEnd, u += S * (o < f ? 1 : (f - p) / (o - p)));
          }
          if (--a, e += 8 * (i + u) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var Ic = null, Pc = null;
  function Ku(t) {
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
            t.removeChild(n), Rn(e);
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
            i[_a] || f === "SCRIPT" || f === "STYLE" || f === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && Ci(t.ownerDocument.body);
      l = n;
    } while (l);
    Rn(e);
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
          lo(l), Ln(l);
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
        if (!t[_a])
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
  function Ah(t, e, l) {
    if (e === "") return null;
    for (; t.nodeType !== 3; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !l || (t = Fe(t.nextSibling), t === null)) return null;
    return t;
  }
  function Md(t, e) {
    for (; t.nodeType !== 8; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !e || (t = Fe(t.nextSibling), t === null)) return null;
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
  var io = null;
  function Ed(t) {
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
        if (t = e.documentElement, !t) throw Error(v(452));
        return t;
      case "head":
        if (t = e.head, !t) throw Error(v(453));
        return t;
      case "body":
        if (t = e.body, !t) throw Error(v(454));
        return t;
      default:
        throw Error(v(451));
    }
  }
  function Ci(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    Ln(t);
  }
  var We = /* @__PURE__ */ new Map(), Dd = /* @__PURE__ */ new Set();
  function Ju(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var Zl = D.d;
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
    var t = Zl.f(), e = qu();
    return t || e;
  }
  function Oh(t) {
    var e = ol(t);
    e !== null && e.tag === 5 && e.type === "form" ? Zr(e) : Zl.r(t);
  }
  var Un = typeof document > "u" ? null : document;
  function Od(t, e, l) {
    var a = Un;
    if (a && typeof e == "string" && e) {
      var n = Rt(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Dd.has(n) || (Dd.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), ce(e, "link", t), qt(e), a.head.appendChild(e)));
    }
  }
  function Ch(t) {
    Zl.D(t), Od("dns-prefetch", t, null);
  }
  function Uh(t, e) {
    Zl.C(t, e), Od("preconnect", t, e);
  }
  function Bh(t, e, l) {
    Zl.L(t, e, l);
    var a = Un;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + Rt(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + Rt(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + Rt(
        l.imageSizes
      ) + '"]')) : n += '[href="' + Rt(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = Bn(t);
          break;
        case "script":
          i = Nn(t);
      }
      We.has(i) || (t = Q(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), We.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Ui(i)) || e === "script" && a.querySelector(Bi(i)) || (e = a.createElement("link"), ce(e, "link", t), qt(e), a.head.appendChild(e)));
    }
  }
  function Nh(t, e) {
    Zl.m(t, e);
    var l = Un;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + Rt(a) + '"][href="' + Rt(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = Nn(t);
      }
      if (!We.has(i) && (t = Q({ rel: "modulepreload", href: t }, e), We.set(i, t), l.querySelector(n) === null)) {
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
        a = l.createElement("link"), ce(a, "link", t), qt(a), l.head.appendChild(a);
      }
    }
  }
  function Rh(t, e, l) {
    Zl.S(t, e, l);
    var a = Un;
    if (a && t) {
      var n = zl(a).hoistableStyles, i = Bn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var f = { loading: 0, preload: null };
        if (u = a.querySelector(
          Ui(i)
        ))
          f.loading = 5;
        else {
          t = Q(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = We.get(i)) && uo(t, l);
          var o = u = a.createElement("link");
          qt(o), ce(o, "link", t), o._p = new Promise(function(p, S) {
            o.onload = p, o.onerror = S;
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
  function Hh(t, e) {
    Zl.X(t, e);
    var l = Un;
    if (l && t) {
      var a = zl(l).hoistableScripts, n = Nn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = Q({ src: t, async: !0 }, e), (e = We.get(n)) && fo(t, e), i = l.createElement("script"), qt(i), ce(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function wh(t, e) {
    Zl.M(t, e);
    var l = Un;
    if (l && t) {
      var a = zl(l).hoistableScripts, n = Nn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = Q({ src: t, async: !0, type: "module" }, e), (e = We.get(n)) && fo(t, e), i = l.createElement("script"), qt(i), ce(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Cd(t, e, l, a) {
    var n = (n = I.current) ? Ju(n) : null;
    if (!n) throw Error(v(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = Bn(l.href), l = zl(
          n
        ).hoistableStyles, a = l.get(e), a || (a = {
          type: "style",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      case "link":
        if (l.rel === "stylesheet" && typeof l.href == "string" && typeof l.precedence == "string") {
          t = Bn(l.href);
          var i = zl(
            n
          ).hoistableStyles, u = i.get(t);
          if (u || (n = n.ownerDocument || n, u = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, i.set(t, u), (i = n.querySelector(
            Ui(t)
          )) && !i._p && (u.instance = i, u.state.loading = 5), We.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, We.set(t, l), i || jh(
            n,
            t,
            l,
            u.state
          ))), e && a === null)
            throw Error(v(528, ""));
          return u;
        }
        if (e && a !== null)
          throw Error(v(529, ""));
        return null;
      case "script":
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = Nn(l), l = zl(
          n
        ).hoistableScripts, a = l.get(e), a || (a = {
          type: "script",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      default:
        throw Error(v(444, t));
    }
  }
  function Bn(t) {
    return 'href="' + Rt(t) + '"';
  }
  function Ui(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Ud(t) {
    return Q({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function jh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), ce(e, "link", l), qt(e), t.head.appendChild(e));
  }
  function Nn(t) {
    return '[src="' + Rt(t) + '"]';
  }
  function Bi(t) {
    return "script[async]" + t;
  }
  function Bd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + Rt(l.href) + '"]'
          );
          if (a)
            return e.instance = a, qt(a), a;
          var n = Q({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), qt(a), ce(a, "style", n), ku(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = Bn(l.href);
          var i = t.querySelector(
            Ui(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, qt(i), i;
          a = Ud(l), (n = We.get(n)) && uo(a, n), i = (t.ownerDocument || t).createElement("link"), qt(i);
          var u = i;
          return u._p = new Promise(function(f, o) {
            u.onload = f, u.onerror = o;
          }), ce(i, "link", a), e.state.loading |= 4, ku(i, l.precedence, t), e.instance = i;
        case "script":
          return i = Nn(l.src), (n = t.querySelector(
            Bi(i)
          )) ? (e.instance = n, qt(n), n) : (a = l, (n = We.get(i)) && (a = Q({}, l), fo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), qt(n), ce(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(v(443, e.type));
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
  function uo(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.title == null && (t.title = e.title);
  }
  function fo(t, e) {
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
      if (!(i[_a] || i[Zt] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
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
        var n = Bn(a.href), i = e.querySelector(
          Ui(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = Wu.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, qt(i);
          return;
        }
        i = e.ownerDocument || e, a = Ud(a), (n = We.get(n)) && uo(a, n), i = i.createElement("link"), qt(i);
        var u = i;
        u._p = new Promise(function(f, o) {
          u.onload = f, u.onerror = o;
        }), ce(i, "link", a), l.instance = i;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = Wu.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var co = 0;
  function Gh(t, e) {
    return t.stylesheets && t.count === 0 && Iu(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && Iu(t, t.stylesheets), t.unsuspend) {
          var i = t.unsuspend;
          t.unsuspend = null, i();
        }
      }, 6e4 + e);
      0 < t.imgBytes && co === 0 && (co = 62500 * xh());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && Iu(t, t.stylesheets), t.unsuspend)) {
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
    t.stylesheets = null, t.unsuspend !== null && (t.count++, $u = /* @__PURE__ */ new Map(), e.forEach(Lh, t), $u = null, Wu.call(t));
  }
  function Lh(t, e) {
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
    $$typeof: wt,
    Provider: null,
    Consumer: null,
    _currentValue: Y,
    _currentValue2: Y,
    _threadCount: 0
  };
  function Xh(t, e, l, a, n, i, u, f, o) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = $e(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = $e(0), this.hiddenUpdates = $e(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = o, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function wd(t, e, l, a, n, i, u, f, o, p, S, A) {
    return t = new Xh(
      t,
      e,
      l,
      u,
      o,
      p,
      S,
      A,
      f
    ), e = 1, i === !0 && (e |= 24), i = Ce(3, null, null, e), t.current = i, i.stateNode = t, e = Lf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Zf(i), t;
  }
  function jd(t) {
    return t ? (t = rn, t) : rn;
  }
  function qd(t, e, l, a, n, i) {
    n = jd(n), a.context === null ? a.context = n : a.pendingContext = n, a = aa(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = na(t, a, e), l !== null && (Ee(l, t, e), si(l, t, e));
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
      e !== null && Ee(e, t, 67108864), oo(t, 67108864);
    }
  }
  function Ld(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = He();
      e = de(e);
      var l = wa(t, e);
      l !== null && Ee(l, t, e), oo(t, e);
    }
  }
  var Pu = !0;
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
    if (Pu) {
      var n = so(a);
      if (n === null)
        Wc(
          t,
          e,
          a,
          tf,
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
          var i = ol(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = bl(i.pendingLanes);
                  if (u !== 0) {
                    var f = i;
                    for (f.pendingLanes |= 2, f.entangledLanes |= 2; u; ) {
                      var o = 1 << 31 - ve(u);
                      f.entanglements[1] |= o, u &= ~o;
                    }
                    hl(i), (vt & 6) === 0 && (wu = ae() + 500, _i(0));
                  }
                }
                break;
              case 31:
              case 13:
                f = wa(i, 2), f !== null && Ee(f, i, 2), qu(), oo(i, 2);
            }
          if (i = so(a), i === null && Wc(
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
  var tf = null;
  function mo(t) {
    if (tf = null, t = Sl(t), t !== null) {
      var e = Ut(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = Bt(e), t !== null) return t;
          t = null;
        } else if (l === 31) {
          if (t = te(e), t !== null) return t;
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
          case Fa:
            return 8;
          case Ta:
          case cf:
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
  var ho = !1, ga = null, pa = null, va = null, Ri = /* @__PURE__ */ new Map(), Hi = /* @__PURE__ */ new Map(), ya = [], Zh = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
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
        Ri.delete(e.pointerId);
        break;
      case "gotpointercapture":
      case "lostpointercapture":
        Hi.delete(e.pointerId);
    }
  }
  function wi(t, e, l, a, n, i) {
    return t === null || t.nativeEvent !== i ? (t = {
      blockedOn: e,
      domEventName: l,
      eventSystemFlags: a,
      nativeEvent: i,
      targetContainers: [n]
    }, e !== null && (e = ol(e), e !== null && Gd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function Kh(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return ga = wi(
          ga,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return pa = wi(
          pa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return va = wi(
          va,
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
          wi(
            Ri.get(i) || null,
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
          wi(
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
  function Vd(t) {
    var e = Sl(t.target);
    if (e !== null) {
      var l = Ut(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = Bt(l), e !== null) {
            t.blockedOn = e, Fi(t.priority, function() {
              Ld(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = te(l), e !== null) {
            t.blockedOn = e, Fi(t.priority, function() {
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
      var l = so(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        kn = a, l.target.dispatchEvent(a), kn = null;
      } else
        return e = ol(l), e !== null && Gd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function Zd(t, e, l) {
    ef(t) && l.delete(e);
  }
  function Jh() {
    ho = !1, ga !== null && ef(ga) && (ga = null), pa !== null && ef(pa) && (pa = null), va !== null && ef(va) && (va = null), Ri.forEach(Zd), Hi.forEach(Zd);
  }
  function lf(t, e) {
    t.blockedOn === e && (t.blockedOn = null, ho || (ho = !0, T.unstable_scheduleCallback(
      T.unstable_NormalPriority,
      Jh
    )));
  }
  var af = null;
  function Kd(t) {
    af !== t && (af = t, T.unstable_scheduleCallback(
      T.unstable_NormalPriority,
      function() {
        af === t && (af = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (mo(a || l) === null)
              continue;
            break;
          }
          var i = ol(l);
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
  function Rn(t) {
    function e(o) {
      return lf(o, t);
    }
    ga !== null && lf(ga, t), pa !== null && lf(pa, t), va !== null && lf(va, t), Ri.forEach(e), Hi.forEach(e);
    for (var l = 0; l < ya.length; l++) {
      var a = ya[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < ya.length && (l = ya[0], l.blockedOn === null); )
      Vd(l), l.blockedOn === null && ya.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[me] || null;
        if (typeof i == "function")
          u || Kd(l);
        else if (u) {
          var f = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[me] || null)
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
  nf.prototype.render = go.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(v(409));
    var l = e.current, a = He();
    qd(l, a, t, e, null, null);
  }, nf.prototype.unmount = go.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      qd(t.current, 2, null, t, null, null), qu(), e[xl] = null;
    }
  };
  function nf(t) {
    this._internalRoot = t;
  }
  nf.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = Ia();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < ya.length && e !== 0 && e < ya[l].priority; l++) ;
      ya.splice(l, 0, t), l === 0 && Vd(t);
    }
  };
  var kd = L.version;
  if (kd !== "19.2.3")
    throw Error(
      v(
        527,
        kd,
        "19.2.3"
      )
    );
  D.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(v(188)) : (t = Object.keys(t).join(","), Error(v(268, t)));
    return t = _(e), t = t !== null ? nt(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var kh = {
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
        za = uf.inject(
          kh
        ), pe = uf;
      } catch {
      }
  }
  return qi.createRoot = function(t, e) {
    if (!yt(t)) throw Error(v(299));
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
  }, qi.hydrateRoot = function(t, e, l) {
    if (!yt(t)) throw Error(v(299));
    var a = !1, n = "", i = es, u = ls, f = as, o = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (i = l.onUncaughtError), l.onCaughtError !== void 0 && (u = l.onCaughtError), l.onRecoverableError !== void 0 && (f = l.onRecoverableError), l.formState !== void 0 && (o = l.formState)), e = wd(
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
    ), e.context = jd(null), l = e.current, a = He(), a = de(a), n = aa(a), n.callback = null, na(l, n, a), l = a, e.current.lanes = l, Jl(e, l), hl(e), t[xl] = e.current, Fc(t), new nf(e);
  }, qi.version = "19.2.3", qi;
}
var nm;
function ng() {
  if (nm) return vo.exports;
  nm = 1;
  function T() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(T);
      } catch (L) {
        console.error(L);
      }
  }
  return T(), vo.exports = ag(), vo.exports;
}
var ig = ng(), im = To();
function ug(T, L, lt) {
  if (!T)
    return { kind: "reset" };
  const v = T.pathCount ?? T.paths?.length ?? 0, yt = L.pathCount ?? lt.length;
  return !(L.previousSource === T || fg(T, L)) || yt < v ? { kind: "reset" } : {
    addedPaths: lt.slice(v, yt),
    kind: "append"
  };
}
function fg(T, L) {
  const lt = T.paths, v = L.paths, yt = T.pathCount ?? lt?.length ?? 0, Ut = L.pathCount ?? v?.length ?? 0;
  if (!Array.isArray(lt) || !Array.isArray(v) || yt > Ut)
    return !1;
  for (let Bt = 0; Bt < yt; Bt += 1)
    if (lt[Bt] !== v[Bt])
      return !1;
  return !0;
}
function cg(T) {
  const L = (c) => {
    const r = document.getElementById(c);
    if (!r)
      throw new Error(`Missing cmux diff viewer element: ${c}`);
    return r;
  }, lt = T.assets ?? {}, v = (c, r) => {
    if (typeof c != "string" || c.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${r}`);
    return new URL(c, window.location.href).href;
  }, yt = v(lt.diffsModuleURL, "diffsModuleURL"), Ut = v(lt.treesModuleURL, "treesModuleURL"), Bt = v(lt.workerPoolModuleURL, "workerPoolModuleURL"), te = v(lt.workerModuleURL, "workerModuleURL"), U = T.payload ?? {}, _ = U.labels ?? {}, nt = L("viewer"), Q = L("status"), _t = L("toolbar"), Vt = L("source-select"), oe = L("repo-select"), ee = L("base-select"), we = L("source-detail"), bt = L("jump-select"), je = L("external-link"), wt = L("files-toggle"), Wt = L("layout-toggle"), re = L("options-button"), jt = L("options-menu"), at = L("files-sidebar"), Nt = L("file-list"), Ae = L("files-count"), be = L("file-search-toggle"), se = L("file-collapse-toggle"), le = L("stats-files"), il = L("stats-added"), qe = L("stats-deleted"), q = (c) => _[c] ?? c, m = {
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
  let D, Y, Z;
  const k = [], s = [], M = /* @__PURE__ */ new Map();
  let B = /* @__PURE__ */ new Set(), R = null, F = null, I = /* @__PURE__ */ new Map(), rt = { value: null }, It = "", xt = "", gl = !1, Ye = /* @__PURE__ */ new Map(), ul = /* @__PURE__ */ new Map();
  typeof U.title == "string" && U.title.trim() !== "" && (document.title = U.title), pe(U.appearance), ve(), me(U.sourceOptions ?? []), Pa(oe, U.repoOptions ?? [], U.repoRoot ?? "", q("repoPath")), Pa(ee, U.baseOptions ?? [], U.branchBaseRef ?? "", q("branchBase"));
  const Hn = globalThis.queueMicrotask ?? ((c) => setTimeout(c, 0));
  U.pendingReplacement === !0 ? (_e(U.statusMessage ?? q("loadingDiff"), { loading: !0, pending: !0 }), Yi()) : typeof U.statusMessage == "string" && U.statusMessage.length > 0 ? _e(U.statusMessage, { error: U.statusIsError === !0, loading: !1, statusOnly: !0 }) : Hn(() => {
    pl().catch((c) => {
      console.error("cmux diff viewer render failed", c), _e(q("renderFailed"), { error: !0, loading: !1, statusOnly: !0 });
    });
  });
  async function pl() {
    _e(q("loadingRenderer"), { loading: !0 });
    const [
      {
        CodeView: c,
        getFiletypeFromFileName: r,
        parsePatchFiles: b,
        preloadHighlighter: O,
        processFile: N,
        registerCustomTheme: H
      },
      G
    ] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(yt),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(Ut).catch((st) => (console.warn("cmux diff file tree import failed", st), null))
    ]);
    if (Wl(H, U.appearance.themes.light), Wl(H, U.appearance.themes.dark), _e(q("parsingDiff"), { loading: !0 }), Sa("loading"), Y = await jn(), Vn(k), de(), window.__cmuxDiffViewer = { codeView: D, items: k, state: m, workerPool: Y }, qn(Y), Y?.initialize?.()?.then?.(() => Yn(Y?.getStats?.()))?.catch?.((st) => console.warn("cmux diff worker pool initialization failed", st)), window.addEventListener("pagehide", () => Y?.terminate?.(), { once: !0 }), await Xi({
      CodeView: c,
      parsePatchFiles: b,
      processFile: N,
      treesModule: G
    }), k.length === 0)
      throw new Error(q("noFileDiffs"));
    Y || Ii(U.appearance, s.length > 0 ? s : k, r, O).catch((st) => console.warn("cmux diff highlighter preload failed", st));
  }
  function _e(c, r = {}) {
    Q.isConnected || nt.replaceChildren(Q), document.body.dataset.loading = r.loading === !0 || r.pending === !0 ? "true" : "false", document.body.dataset.statusOnly = r.statusOnly === !0 ? "true" : "false", Q.dataset.error = r.error === !0 ? "true" : "false", Q.dataset.pending = r.pending === !0 ? "true" : "false", Q.textContent = c;
  }
  function wn(c) {
    document.open(), document.write(c), document.close();
  }
  async function ff(c) {
    if (!c.ok)
      return _e(q("renderFailed"), { error: !0, loading: !1, statusOnly: !0 }), !1;
    const r = await c.text();
    return r.includes('data-cmux-diff-pending="true"') ? !1 : (wn(r), !0);
  }
  async function Yi() {
    try {
      const c = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
      await ff(c);
    } catch (c) {
      document.documentElement.dataset.cmuxDiffWait = "failed", _e(q("renderFailed"), { error: !0, loading: !1, statusOnly: !0 }), console.warn("cmux diff viewer deferred load failed", c);
    }
  }
  async function jn() {
    if (typeof Worker > "u")
      return null;
    try {
      const c = await import(Bt);
      Wl(c.registerCustomTheme, U.appearance.themes.light), Wl(c.registerCustomTheme, U.appearance.themes.dark);
      const r = new URL(te, window.location.href).href;
      return c.createDiffWorkerPool({
        workerURL: r,
        highlighterOptions: Gi()
      }) ?? null;
    } catch (c) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", c), null;
    }
  }
  function qn(c) {
    if (!c) {
      Sa("fallback");
      return;
    }
    Sa("enabled"), Yn(c.getStats?.());
    const r = c.subscribeToStatChanges?.((b) => {
      Yn(b);
    });
    typeof r == "function" && window.addEventListener("pagehide", r, { once: !0 });
  }
  function Sa(c) {
    document.body.dataset.workerPool = c;
  }
  function Yn(c) {
    !c || typeof c != "object" || (typeof c.managerState == "string" && (document.body.dataset.workerPoolState = c.managerState), Number.isFinite(c.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(c.totalWorkers)), typeof c.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(c.workersFailed)));
  }
  function Gi() {
    return {
      theme: U.appearance.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: m.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const ae = /^From\s+([a-f0-9]+)\s/im;
  function Li(c, r) {
    const b = c?.match(ae);
    return b?.[1] ? new TextDecoder().decode(new TextEncoder().encode(b[1].slice(0, 5))) : `${q("commit")} ${r + 1}`;
  }
  async function Xi({ CodeView: c, parsePatchFiles: r, processFile: b, treesModule: O }) {
    const N = cf(), H = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, G = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let W = performance.now(), st = performance.now(), pt = !0;
    const Ie = {
      initialBatchSize: Qn(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function Pe(E, C) {
      const J = kn(N, E, C);
      return J?.renamedItem && $n(J.renamedItem), J?.item;
    }
    function kn(E, C, J) {
      if (!C)
        return null;
      const P = Fl(C), dt = J == null ? P : `${J}/${P}`, mt = P.length === 0 ? void 0 : E.pathStateByTreePath.get(dt), Yt = mt == null ? void 0 : Fn(E, dt, mt), he = rl(C), De = {
        id: E.itemIdToFile.has(dt) ? Al(E, `${dt}?2`) : dt,
        type: "diff",
        fileDiff: C,
        version: 0
      }, lu = E.items.length;
      E.fileIndex += 1, E.items.push(De), E.pendingItems.push(De), E.pendingItemById.set(De.id, De), E.itemIdToFile.set(De.id, { fileOrder: lu, path: P }), E.itemIdByTreePath.set(dt, De.id), E.treePathByItemId.set(De.id, dt), E.diffStats.addedLines += he.added, E.diffStats.deletedLines += he.deleted, E.diffStats.fileCount += 1, E.diffStats.totalLinesOfCode += C.unifiedLineCount ?? C.splitLineCount ?? 0;
      const bf = E.statsByPath.get(dt);
      return E.statsByPath.set(dt, he), mt != null && !vf(bf, he) && (E.pendingStatsChanged = !0), P.length > 0 && (mt == null && E.paths.push(dt), E.pathToItemId.set(dt, De.id), $l(E, dt, C.type, mt?.sawDeleted === !0), E.pathStateByTreePath.set(dt, {
        currentItem: De,
        currentItemId: De.id,
        currentType: C.type,
        fileOrder: lu,
        sawDeleted: mt?.sawDeleted === !0 || C.type === "deleted"
      })), { item: De, renamedItem: Yt };
    }
    function Fn(E, C, J) {
      const P = J.currentItemId, dt = J.currentType === "deleted" ? "?deleted" : "?previous", mt = Al(E, `${C}${dt}`);
      if (J.currentItem.id = mt, J.currentItemId = mt, E.itemIdToFile.has(P)) {
        const Yt = E.itemIdToFile.get(P);
        E.itemIdToFile.delete(P), E.itemIdToFile.set(mt, Yt);
      }
      if (E.treePathByItemId.has(P) && (E.treePathByItemId.delete(P), E.treePathByItemId.set(mt, C)), E.pendingItemById.has(P)) {
        const Yt = E.pendingItemById.get(P);
        E.pendingItemById.delete(P), E.pendingItemById.set(mt, Yt);
        return;
      }
      return { oldId: P, newId: mt };
    }
    function Al(E, C) {
      if (!E.itemIdToFile.has(C))
        return C;
      let J = E.nextCollisionSuffixByBase.get(C) ?? 2, P = `${C}-${J}`;
      for (; E.itemIdToFile.has(P); )
        J += 1, P = `${C}-${J}`;
      return E.nextCollisionSuffixByBase.set(C, J + 1), P;
    }
    function $l(E, C, J, P) {
      if (P && J !== "deleted") {
        E.gitStatusByPath.delete(C) && Wn(E, C);
        return;
      }
      const dt = Kn(J);
      if (dt === "modified") {
        E.gitStatusByPath.delete(C) && Wn(E, C);
        return;
      }
      if (E.gitStatusByPath.get(C)?.status === dt)
        return;
      const Yt = { path: C, status: dt };
      E.gitStatusByPath.set(C, Yt), E.pendingGitStatusRemovePaths.delete(C), E.pendingGitStatusSetByPath.set(C, Yt);
    }
    function Wn(E, C) {
      E.pendingGitStatusSetByPath.delete(C), E.pendingGitStatusRemovePaths.add(C);
    }
    function $n(E) {
      if (B.delete(E.oldId) && B.add(E.newId), M.has(E.oldId)) {
        const C = M.get(E.oldId);
        M.delete(E.oldId), C && M.set(E.newId, C);
      }
      gf(E.oldId, E.newId), D?.updateItemId?.(E.oldId, E.newId);
    }
    async function en(E, C) {
      Pe(E, C) && await _l(!1);
    }
    async function _l(E) {
      if (N.pendingItems.length === 0)
        return;
      const C = performance.now();
      if (!E && pt && C - W >= 8 && N.pendingItems.length < Ie.initialBatchSize && C - st < Ie.initialMaxWait) {
        await Vi(), W = performance.now();
        return;
      }
      const J = pt ? Ie.initialBatchSize : Ie.incrementalBatchSize, P = pt ? Ie.initialMaxWait : Ie.incrementalMaxWait;
      if (E || N.pendingItems.length >= J || C - st >= P) {
        tl(), await Vi(), W = performance.now();
        return;
      }
    }
    function tl() {
      if (N.pendingItems.length === 0)
        return;
      const E = N.pendingItems.splice(0, N.pendingItems.length);
      N.pendingItemById.clear();
      const C = E, J = s.length > 0;
      k.push(...E);
      for (const P of E)
        M.set(P.id, P);
      if (C.length > 0) {
        s.push(...C);
        for (const P of C)
          B.add(P.id);
        D ? D.addItems(C) : (D = new c(Ki(), Y ?? void 0), D.setup(nt), D.setItems(s), D.render(!0), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.codeView = D));
      }
      $i(E), Dl(O, !1, E.length), G.flushCount += 1, G.maxBatchSize = Math.max(G.maxBatchSize, E.length), G.fileCount = k.length, G.renderableFileCount = s.length, Fa(G), st = performance.now(), pt && (pt = !1, document.body.dataset.loading = "false", Q.remove()), J || Ge(s[0]?.id ?? k[0]?.id ?? ""), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.items = k, window.__cmuxDiffViewer.codeViewItems = s, window.__cmuxDiffViewer.streamMetrics = G);
    }
    function ln() {
      D && (D.syncContainerHeight?.(), D.render(!0));
    }
    function Dl(E, C, J = 1) {
      if (H.treesModule = E, H.dirtyCount += J, C || H.lastRefreshAt === 0) {
        Le(H.treesModule);
        return;
      }
      const P = performance.now() - H.lastRefreshAt;
      if (H.dirtyCount >= 1e3 || P >= 1e3) {
        Le(H.treesModule);
        return;
      }
      if (H.timeout !== 0)
        return;
      const dt = Math.max(0, 1e3 - P);
      H.timeout = window.setTimeout(() => {
        H.timeout = 0, Le(H.treesModule);
      }, dt);
    }
    function Le(E) {
      H.timeout !== 0 && (window.clearTimeout(H.timeout), H.timeout = 0), H.dirtyCount = 0, H.lastRefreshAt = performance.now(), G.treeRefreshCount += 1, F = Qi(N), mf(F, E), de(), Fa(G);
    }
    const Ol = await fetch(U.patchURL, { cache: "no-store" });
    if (!Ol.ok)
      throw new Error(`${q("loadingDiff")} (${Ol.status})`);
    if (!Ol.body?.getReader) {
      const E = await Ol.text();
      await Ta(E, r, en), await _l(!0), ln(), Dl(O, !0), G.completedAt = performance.now();
      return;
    }
    const Da = new TextDecoder(), Pi = Ol.body.getReader(), Oa = "diff --git ", Ca = `
` + Oa, tu = Ca.length - 1, ne = /\S/;
    function Xe(E, C) {
      const J = Math.max(C, 0);
      if (J === 0 && E.startsWith(Oa))
        return 0;
      const P = E.indexOf(Ca, J);
      return P === -1 ? void 0 : P + 1;
    }
    function Ua(E, C) {
      return Math.max(C, E.length - tu);
    }
    function Ba(E, C, J) {
      const P = Math.max(C, 0), dt = Math.min(J, E.length);
      if (P >= dt)
        return;
      let mt = E.lastIndexOf(`
From `, dt - 1);
      for (; mt !== -1; ) {
        const Yt = mt + 1;
        if (Yt < P)
          return;
        if (Yt >= dt) {
          mt = E.lastIndexOf(`
From `, mt - 1);
          continue;
        }
        const he = E.indexOf(`
`, Yt + 1), Na = E.slice(Yt, he === -1 || he > dt ? dt : he);
        if (ae.test(Na))
          return Yt;
        mt = E.lastIndexOf(`
From `, mt - 1);
      }
    }
    function yf(E) {
      const C = Xe(E, 0);
      if (C == null || C <= 0)
        return;
      const J = E.slice(0, C);
      return ae.test(J) ? J : void 0;
    }
    async function an(E) {
      if (E.trim() === "")
        return;
      const C = yf(E);
      C != null && (Pn = Li(C, eu), eu += 1);
      const J = `cmux-diff-file-${N.fileIndex}`;
      await en(b(E, {
        cacheKey: J,
        isGitDiff: !0
      }), Pn);
    }
    function In() {
      let E, C = "", J = 0, P = !1;
      function dt() {
        if (E == null) {
          if (E = Xe(C, J), E == null)
            return J = Ua(C, 0), null;
          P = !0, J = E + 1;
        }
        for (; ; ) {
          const mt = E;
          if (mt == null)
            return null;
          const Yt = Xe(C, J);
          if (Yt == null)
            return J = Ua(C, mt + 1), null;
          const he = Ba(C, mt + 1, Yt) ?? Yt, Na = C.slice(0, he);
          if (C = C.slice(he), E = Xe(C, 0), J = E == null ? 0 : E + 1, ne.test(Na))
            return Na;
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
          if (!ne.test(C))
            return C = "", {};
          if (!P) {
            const he = C;
            return C = "", { fallbackPatchContent: he };
          }
          const Yt = C;
          return C = "", { fileText: Yt };
        }
      };
    }
    async function Cl(E) {
      let C;
      for (; (C = E.takeAvailableFile()) != null; )
        await an(C);
    }
    const el = In();
    let Pn, eu = 0;
    for (; ; ) {
      const { done: E, value: C } = await Pi.read();
      if (E) {
        const J = Da.decode();
        J.length > 0 && (el.push(J), await Cl(el));
        break;
      }
      el.push(Da.decode(C, { stream: !0 })), await Cl(el);
    }
    const nn = el.finish();
    nn.fileText != null ? (await an(nn.fileText), await Cl(el)) : nn.fallbackPatchContent != null && await Ta(nn.fallbackPatchContent, r, en), await _l(!0), ln(), Dl(O, !0), G.completedAt = performance.now(), Fa(G);
  }
  function Fa(c) {
    document.body.dataset.streamFileCount = String(c.fileCount ?? k.length), document.body.dataset.streamRenderableFileCount = String(c.renderableFileCount ?? s.length), document.body.dataset.streamFlushCount = String(c.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(c.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(c.treeRefreshCount ?? 0), Number.isFinite(c.completedAt) && c.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(c.completedAt - c.startedAt)));
  }
  async function Ta(c, r, b) {
    const O = r(c, "cmux-diff"), N = O.length > 1;
    for (const [H, G] of O.entries()) {
      const W = N ? Li(G.patchMetadata, H) : void 0;
      for (const st of G.files ?? [])
        await b(st, W);
    }
  }
  function cf() {
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
    const r = c.lastTreeSource, b = of(c), O = {
      diffStats: { ...c.diffStats },
      gitStatus: Array.from(c.gitStatusByPath.values()),
      gitStatusPatch: b,
      pathCount: c.paths.length,
      paths: c.paths,
      pathToItemId: c.pathToItemId,
      previousSource: r,
      statsChanged: c.pendingStatsChanged,
      statsByPath: c.statsByPath,
      treePathByItemId: c.treePathByItemId
    };
    return c.pendingStatsChanged = !1, c.lastTreeSource = O, O;
  }
  function of(c) {
    if (c.pendingGitStatusRemovePaths.size === 0 && c.pendingGitStatusSetByPath.size === 0)
      return;
    const r = {};
    return c.pendingGitStatusRemovePaths.size > 0 && (r.remove = Array.from(c.pendingGitStatusRemovePaths), c.pendingGitStatusRemovePaths.clear()), c.pendingGitStatusSetByPath.size > 0 && (r.set = Array.from(c.pendingGitStatusSetByPath.values()), c.pendingGitStatusSetByPath.clear()), r;
  }
  function Vi() {
    return new Promise((c) => {
      let r = !1, b = 0;
      const O = () => {
        r || (r = !0, b !== 0 && window.clearTimeout(b), c());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        b = window.setTimeout(O, 50), window.requestAnimationFrame(O);
      else if (typeof MessageChannel < "u") {
        const N = new MessageChannel();
        N.port1.onmessage = O, N.port2.postMessage(void 0);
      } else
        queueMicrotask(O);
    });
  }
  async function za() {
    return rt.value == null && (rt.value = fetch(U.patchURL, { cache: "no-store" }).then(async (c) => {
      if (!c.ok)
        throw new Error(`${q("loadingDiff")} (${c.status})`);
      return c.text();
    })), rt.value;
  }
  function pe(c) {
    const r = document.documentElement.style;
    r.setProperty("--cmux-diff-bg-light", c.themes.light.background), r.setProperty("--cmux-diff-bg-dark", c.themes.dark.background), r.setProperty("--cmux-diff-fg-light", c.themes.light.foreground), r.setProperty("--cmux-diff-fg-dark", c.themes.dark.foreground), r.setProperty("--cmux-diff-selection-bg-light", c.themes.light.selectionBackground), r.setProperty("--cmux-diff-selection-bg-dark", c.themes.dark.selectionBackground), r.setProperty("--cmux-diff-code-font-family", fl(c.fontFamily)), r.setProperty("--cmux-diff-font-size", `${c.fontSize}px`), r.setProperty("--cmux-diff-line-height", `${c.lineHeight}px`);
  }
  function fl(c) {
    const r = typeof c == "string" && c.trim() !== "" ? c.trim() : "Menlo";
    return `${JSON.stringify(r)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
  }
  function ve() {
    wt.innerHTML = Rt("files"), be.innerHTML = Rt("search"), se.innerHTML = Rt("sidebarCollapse"), Wt.innerHTML = Rt(m.layout), re.innerHTML = Rt("dots"), typeof U.externalURL == "string" && U.externalURL.length > 0 && (je.href = U.externalURL, je.innerHTML = Rt("external"), je.hidden = !1), wt.addEventListener("click", () => Ea(!m.filesVisible)), se.addEventListener("click", () => Ea(!1)), be.addEventListener("click", () => Gn(!m.fileSearchOpen)), Wt.addEventListener("click", () => sf(m.layout === "split" ? "unified" : "split")), re.addEventListener("click", () => Aa(jt.hidden)), document.addEventListener("click", (c) => {
      jt.hidden || c.target instanceof Node && _t.contains(c.target) || Aa(!1);
    }), document.addEventListener("keydown", (c) => {
      c.key === "Escape" && Aa(!1);
    }), rf(), de();
  }
  function rf() {
    const c = U.shortcuts ?? {}, r = Ma(c.diffViewerScrollDown), b = Ma(c.diffViewerScrollUp), O = Ma(c.diffViewerScrollToBottom), N = Ma(c.diffViewerScrollToTop), H = Ma(c.diffViewerOpenFileSearch);
    let G = null, W = 0;
    document.addEventListener("keydown", (pt) => {
      if (!(pt.defaultPrevented || $a(pt.target))) {
        if (G && !yl(G.shortcut.second, pt) && st(), G && yl(G.shortcut.second, pt)) {
          pt.preventDefault(), G.action(), st();
          return;
        }
        if (vl(r, pt)) {
          pt.preventDefault(), Kl(1);
          return;
        }
        if (vl(b, pt)) {
          pt.preventDefault(), Kl(-1);
          return;
        }
        if (vl(O, pt)) {
          pt.preventDefault(), nt.scrollTo({ top: nt.scrollHeight, behavior: "auto" });
          return;
        }
        if (vl(H, pt) && Z) {
          pt.preventDefault(), Ea(!0), Gn(!0);
          return;
        }
        N && Wa(N, pt) && (pt.preventDefault(), G = {
          shortcut: N,
          action: () => nt.scrollTo({ top: 0, behavior: "auto" })
        }, W = setTimeout(st, 700));
      }
    });
    function st() {
      G = null, W !== 0 && (clearTimeout(W), W = 0);
    }
  }
  function Ma(c) {
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
  function vl(c, r) {
    return c && !c.second && yl(c.first, r);
  }
  function Wa(c, r) {
    return c && c.second && yl(c.first, r);
  }
  function yl(c, r) {
    return !c || r.metaKey !== c.command || r.ctrlKey !== c.control || r.altKey !== c.option || r.shiftKey !== c.shift ? !1 : bl(r) === c.key;
  }
  function bl(c) {
    return c.code === "Space" ? "space" : typeof c.key != "string" || c.key.length === 0 ? "" : (c.key.length === 1, c.key.toLowerCase());
  }
  function $a(c) {
    const r = c instanceof Element ? c : null;
    return r ? !!r.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function Kl(c) {
    const r = Math.max(80, Math.floor(nt.clientHeight * 0.38));
    nt.scrollBy({ top: c * r, behavior: "auto" });
  }
  function Ki() {
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
      unsafeCSS: Ji(),
      theme: U.appearance.theme,
      themeType: "system"
    };
  }
  function Ji() {
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
  function $e() {
    const c = Ki();
    if (!D) {
      Jl();
      return;
    }
    D.setOptions(c), Jl(), D.render(!0);
  }
  function Jl() {
    Y?.setRenderOptions && Y.setRenderOptions(Gi()).then(() => D?.render(!0)).catch((c) => console.warn("cmux diff worker render options update failed", c));
  }
  function sf(c) {
    m.layout = c === "unified" ? "unified" : "split", de(), $e();
  }
  function Ea(c) {
    m.filesVisible = c, document.body.dataset.filesHidden = c ? "false" : "true", at.setAttribute("aria-hidden", String(!c)), c ? at.removeAttribute("inert") : at.setAttribute("inert", ""), de();
  }
  function Gn(c) {
    m.fileSearchOpen = !!c, Z && (m.fileSearchOpen ? Z.openSearch("") : Z.closeSearch()), de();
  }
  function ki(c) {
    m.collapsed = c;
    const r = s.map((N) => ({
      ...N,
      collapsed: c,
      version: (N.version ?? 0) + 1
    })), b = new Map(r.map((N) => [N.id, N])), O = k.map((N) => b.get(N.id) ?? {
      ...N,
      collapsed: c,
      version: (N.version ?? 0) + 1
    });
    s.splice(0, s.length, ...r), k.splice(0, k.length, ...O), D && (D.setItems(s), D.render(!0)), de();
  }
  function de() {
    wt.setAttribute("aria-pressed", String(m.filesVisible)), wt.title = m.filesVisible ? q("hideFiles") : q("showFiles"), wt.setAttribute("aria-label", wt.title), se.title = q("hideFiles"), se.setAttribute("aria-label", se.title), Wt.innerHTML = Rt(m.layout), Wt.title = m.layout === "split" ? q("switchToUnifiedDiff") : q("switchToSplitDiff"), Wt.setAttribute("aria-label", Wt.title), re.setAttribute("aria-expanded", String(!jt.hidden)), document.documentElement.dataset.layout = m.layout, document.documentElement.dataset.wordWrap = String(m.wordWrap), document.documentElement.dataset.diffIndicators = m.diffIndicators, be.disabled = !Z, be.setAttribute("aria-pressed", String(m.fileSearchOpen)), be.title = m.fileSearchOpen ? q("hideFileSearch") : q("showFileSearch"), be.setAttribute("aria-label", be.title);
  }
  function Aa(c) {
    c && Ia(), jt.hidden = !c, de();
  }
  function Ia() {
    jt.textContent = "";
    const c = [
      { label: q("refresh"), icon: "refresh", action: () => window.location.reload() },
      { label: m.wordWrap ? q("disableWordWrap") : q("enableWordWrap"), icon: "wrap", checked: m.wordWrap, action: () => {
        m.wordWrap = !m.wordWrap, $e();
      } },
      { label: m.collapsed ? q("expandAllDiffs") : q("collapseAllDiffs"), icon: "collapse", checked: m.collapsed, action: () => ki(!m.collapsed) },
      "separator",
      { label: m.filesVisible ? q("hideFiles") : q("showFiles"), icon: "files", checked: m.filesVisible, action: () => Ea(!m.filesVisible) },
      { label: m.expandUnchanged ? q("collapseUnchangedContext") : q("expandUnchangedContext"), icon: "document", checked: m.expandUnchanged, action: () => {
        m.expandUnchanged = !m.expandUnchanged, $e();
      } },
      { label: m.showBackgrounds ? q("hideBackgrounds") : q("showBackgrounds"), icon: "background", checked: m.showBackgrounds, action: () => {
        m.showBackgrounds = !m.showBackgrounds, $e();
      } },
      { label: m.lineNumbers ? q("hideLineNumbers") : q("showLineNumbers"), icon: "numbers", checked: m.lineNumbers, action: () => {
        m.lineNumbers = !m.lineNumbers, $e();
      } },
      { label: m.wordDiffs ? q("disableWordDiffs") : q("enableWordDiffs"), icon: "word", checked: m.wordDiffs, action: () => {
        m.wordDiffs = !m.wordDiffs, $e();
      } },
      { kind: "segment", label: q("indicatorStyle"), icon: "bars", options: [
        { value: "bars", icon: "bars", label: q("bars") },
        { value: "classic", icon: "classic", label: q("classic") },
        { value: "none", icon: "eye", label: q("none") }
      ] },
      "separator",
      { label: q("copyGitApplyCommand"), icon: "clipboard", action: cl }
    ];
    for (const r of c) {
      if (r === "separator") {
        const N = document.createElement("div");
        N.className = "menu-separator", jt.append(N);
        continue;
      }
      if (r.kind === "segment") {
        const N = document.createElement("div");
        N.className = "menu-item menu-segment", N.setAttribute("role", "presentation"), N.innerHTML = `${Rt(r.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
        const H = N.querySelector(".menu-label");
        H && (H.textContent = r.label);
        const G = N.querySelector(".menu-segment-controls");
        if (!G)
          continue;
        for (const W of r.options) {
          const st = document.createElement("button");
          st.type = "button", st.className = "segment-button", st.title = W.label, st.setAttribute("aria-label", W.label), st.setAttribute("aria-pressed", String(m.diffIndicators === W.value)), st.innerHTML = Rt(W.icon), st.addEventListener("click", () => {
            m.diffIndicators = W.value, $e(), Ia(), de();
          }), G.append(st);
        }
        jt.append(N);
        continue;
      }
      const b = document.createElement("button");
      b.type = "button", b.className = "menu-item", b.setAttribute("role", r.checked == null ? "menuitem" : "menuitemcheckbox"), r.checked != null && b.setAttribute("aria-checked", String(!!r.checked)), b.disabled = !!r.disabled, b.innerHTML = `${Rt(r.icon)}<span class="menu-label"></span><span class="menu-check">${r.checked ? Rt("check") : ""}</span>`;
      const O = b.querySelector(".menu-label");
      O && (O.textContent = r.label), b.addEventListener("click", () => {
        b.disabled || (r.action?.(), Ia(), de());
      }), jt.append(b);
    }
  }
  function Fi(c) {
    const r = new Set(c.split(/\r?\n/));
    let b = "CMUX_DIFF_PATCH", O = 0;
    for (; r.has(b); )
      O += 1, b = `CMUX_DIFF_PATCH_${O}`;
    return b;
  }
  async function cl() {
    const r = await za(), b = r.endsWith(`
`) ? r : `${r}
`, O = Fi(b), N = `git apply <<'${O}'
${b}${O}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(N);
      } catch {
        Zt(N);
      }
    else
      Zt(N);
    re.title = q("copiedGitApplyCommand"), re.setAttribute("aria-label", q("copiedGitApplyCommand"));
  }
  function Zt(c) {
    const r = document.createElement("textarea");
    r.value = c, r.setAttribute("readonly", ""), r.style.position = "fixed", r.style.left = "-9999px", document.body.append(r), r.select(), document.execCommand("copy"), r.remove();
  }
  function me(c) {
    if (we.textContent = xl(), !Array.isArray(c) || c.length < 2)
      return;
    Vt.textContent = "";
    const r = c.find((b) => b.selected) ?? c.find((b) => !b.disabled);
    for (const b of c) {
      const O = document.createElement("option");
      O.value = b.value, O.textContent = b.label, O.disabled = b.disabled || !b.url, O.selected = b.value === r?.value, b.message && (O.title = b.message), Vt.append(O);
    }
    we.textContent = r?.sourceLabel ?? xl(), Vt.hidden = !1, Vt.addEventListener("change", () => {
      const b = c.find((O) => O.value === Vt.value);
      if (!b?.url) {
        Vt.value = r?.value ?? "";
        return;
      }
      _e(q("loadingDiff"), { pending: !0 }), window.location.href = b.url;
    });
  }
  function xl() {
    return [U.sourceLabel, U.repoRoot, U.branchBaseRef].filter((r) => typeof r == "string" && r.trim() !== "").join(" | ");
  }
  function Pa(c, r, b, O) {
    if (!c || !Array.isArray(r) || r.length < 2)
      return;
    c.textContent = "";
    const N = r.find((H) => H.selected) ?? r.find((H) => !H.disabled);
    for (const H of r) {
      const G = document.createElement("option");
      G.value = H.value, G.textContent = H.label, G.disabled = H.disabled || !H.url, G.selected = H.value === N?.value, H.message && (G.title = H.message), c.append(G);
    }
    c.hidden = !1, c.title = O, c.addEventListener("change", () => {
      const H = r.find((G) => G.value === c.value);
      if (!H?.url) {
        c.value = N?.value ?? b ?? "";
        return;
      }
      _e(q("loadingDiff"), { pending: !0 }), window.location.href = H.url;
    });
  }
  function df(c, r) {
    const b = Sl(c), O = Ln(r);
    if (qt(c, []), Z && (Z.cleanUp?.(), Z = null), R = null, m.fileSearchOpen = !1, Nt.textContent = "", Ae.textContent = `${b}`, El(c), O)
      try {
        Wi(c, r), de();
        return;
      } catch (H) {
        console.warn("cmux diff file tree setup failed", H);
      }
    const N = ol(c);
    qt(c, N), Xn(N), de();
  }
  function mf(c, r) {
    const b = Sl(c);
    if (qt(c, []), Ae.textContent = `${b}`, El(c), Z && Nt.dataset.treeMode === "pierre" && r?.preparePresortedFileTreeInput) {
      _a(c, r);
      return;
    }
    if (Z || Nt.childElementCount === 0) {
      df(c, r);
      return;
    }
    const O = ol(c);
    qt(c, O), Nt.textContent = "", Xn(O);
  }
  function Wi(c, r) {
    const { FileTree: b, preparePresortedFileTreeInput: O } = r, N = Tl(c);
    R = c;
    const H = N[0];
    zl(c), Nt.dataset.treeMode = "pierre", Z = new b({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: H ? [H] : [],
      initialVisibleRowCount: Qn(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: O(N),
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: c.gitStatus,
      renderRowDecoration(G) {
        if (G.item.kind !== "file")
          return null;
        const W = I.get(G.item.path);
        return W == null || W.added === 0 && W.deleted === 0 ? null : {
          text: `+${W.added} -${W.deleted}`,
          title: `${W.added} ${q("additions")}, ${W.deleted} ${q("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Ml(),
      onSelectionChange(G) {
        if (gl)
          return;
        const W = G[G.length - 1], st = Ye.get(W);
        st && kl(st);
      }
    }), Z.render({ containerWrapper: Nt });
  }
  function _a(c, r) {
    const b = R, O = Tl(c);
    R = c, zl(c);
    let N = !1;
    const H = ug(b, c, O);
    if (H.kind === "append") {
      const G = H.addedPaths;
      if (G.length > 0)
        try {
          Z.batch(G.map((W) => ({ type: "add", path: W })));
        } catch (W) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", W), Z.resetPaths(O, {
            preparedInput: r.preparePresortedFileTreeInput(O)
          }), N = !0;
        }
    } else
      Z.resetPaths(O, {
        preparedInput: r.preparePresortedFileTreeInput(O)
      }), N = !0;
    c.gitStatusPatch ? typeof Z.applyGitStatusPatch == "function" ? Z.applyGitStatusPatch(c.gitStatusPatch) : Z.setGitStatus(c.gitStatus) : (N || c.statsChanged === !0) && Z.setGitStatus(c.gitStatus);
  }
  function Ln(c) {
    return !!(c?.FileTree && c?.preparePresortedFileTreeInput);
  }
  function Sl(c) {
    return c?.pathCount ?? c?.entries?.length ?? 0;
  }
  function ol(c) {
    const r = c?.pathCount ?? c?.entries?.length ?? 0, b = c?.entries ?? [];
    if (b.length > 0)
      return b.length === r ? b : b.slice(0, r);
    const O = Tl(c), N = c?.pathToItemId, H = c?.statsByPath;
    return O.map((G) => {
      const W = N instanceof Map ? N.get(G) : void 0, st = W ? M.get(W) : void 0, pt = st?.fileDiff ?? {};
      return {
        item: st ?? { id: W ?? G, fileDiff: pt },
        path: G,
        status: Zn(pt),
        stats: H instanceof Map ? H.get(G) ?? rl(pt) : rl(pt)
      };
    });
  }
  function Tl(c) {
    const r = c?.pathCount ?? c?.paths?.length ?? 0, b = c?.paths ?? [];
    return b.length === r ? b : b.slice(0, r);
  }
  function zl(c) {
    if (c?.statsByPath instanceof Map) {
      I = c.statsByPath;
      return;
    }
    I = /* @__PURE__ */ new Map();
    const r = ol(c);
    for (const b of r)
      I.set(b.path, b.stats);
  }
  function qt(c, r) {
    if (c?.pathToItemId instanceof Map && c?.treePathByItemId instanceof Map)
      Ye = c.pathToItemId, ul = c.treePathByItemId;
    else if (c?.pathToItemId instanceof Map) {
      Ye = c.pathToItemId, ul = /* @__PURE__ */ new Map();
      for (const [b, O] of Ye)
        ul.set(O, b);
    } else {
      Ye = /* @__PURE__ */ new Map(), ul = /* @__PURE__ */ new Map();
      for (const b of r) {
        const O = b.item?.id;
        O && (Ye.set(b.path, O), ul.set(O, b.path));
      }
    }
    xt && !Ye.has(xt) && (xt = "");
  }
  function Xn(c) {
    delete Nt.dataset.treeMode;
    for (const r of c) {
      const b = r.item, O = b.fileDiff ?? {}, N = r.stats ?? rl(O), H = document.createElement("button");
      H.type = "button", H.className = "file-entry", H.dataset.itemId = b.id, H.title = Fl(O), H.innerHTML = `
      <span class="file-status">${pf(O)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${N.added}</span>
        <span class="stat-del">-${N.deleted}</span>
      </span>
    `;
      const G = H.querySelector(".file-name");
      G && (G.textContent = Fl(O)), H.addEventListener("click", () => kl(b.id)), Nt.append(H);
    }
  }
  function Qn() {
    const c = window.visualViewport?.height ?? window.innerHeight;
    return !Number.isFinite(c) || c <= 0 ? 25 : Math.min(96, Math.max(25, Math.ceil(c / 24)));
  }
  function Ml() {
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
  function El(c) {
    const r = c?.diffStats;
    if (r && Number.isFinite(r.addedLines) && Number.isFinite(r.deletedLines) && Number.isFinite(r.fileCount)) {
      le.textContent = `${r.fileCount}`, il.textContent = `+${r.addedLines}`, qe.textContent = `-${r.deletedLines}`;
      return;
    }
    hf(c?.entries ?? []);
  }
  function hf(c) {
    const r = c.reduce((b, O) => {
      const N = O.stats ?? rl(O.item?.fileDiff ?? {});
      return b.added += N.added, b.deleted += N.deleted, b;
    }, { added: 0, deleted: 0 });
    le.textContent = `${c.length}`, il.textContent = `+${r.added}`, qe.textContent = `-${r.deleted}`;
  }
  function Vn(c) {
    bt.textContent = "";
    const r = document.createElement("option");
    r.value = "", r.textContent = q("jumpToFile"), bt.append(r), bt.dataset.initialized = "true";
    for (const b of c) {
      const O = document.createElement("option");
      O.value = b.id, O.textContent = Fl(b.fileDiff ?? {}), bt.append(O);
    }
    bt.hidden = c.length === 0, bt.onchange = () => {
      bt.value && kl(bt.value);
    };
  }
  function $i(c) {
    if (c.length === 0)
      return;
    bt.dataset.initialized !== "true" && Vn([]);
    const r = document.createDocumentFragment();
    for (const b of c) {
      const O = document.createElement("option");
      O.value = b.id, O.textContent = Fl(b.fileDiff ?? {}), r.append(O);
    }
    bt.append(r), bt.hidden = !1;
  }
  function gf(c, r) {
    if (bt.dataset.initialized === "true") {
      for (const b of bt.options)
        if (b.value === c) {
          b.value = r;
          return;
        }
    }
  }
  function kl(c) {
    if (!D)
      return;
    const r = tn(c);
    r && (D.scrollTo({ type: "item", id: r, align: "start", behavior: "smooth-auto" }), Ge(r));
  }
  function tn(c) {
    if (B.has(c))
      return c;
    const r = k.findIndex((b) => b.id === c);
    if (r === -1)
      return s[0]?.id ?? "";
    for (let b = r + 1; b < k.length; b += 1)
      if (B.has(k[b].id))
        return k[b].id;
    for (let b = r - 1; b >= 0; b -= 1)
      if (B.has(k[b].id))
        return k[b].id;
    return "";
  }
  function Ge(c) {
    if (!(!c || It === c)) {
      It = c, xe(c);
      for (const r of Nt.querySelectorAll(".file-entry"))
        r.setAttribute("aria-current", r.dataset.itemId === c ? "true" : "false");
      bt.value !== c && (bt.value = c);
    }
  }
  function xe(c) {
    if (!Z)
      return;
    const r = ul.get(c);
    if (!(!r || r === xt)) {
      gl = !0;
      try {
        xt && Z.getItem(xt)?.deselect(), Z.getItem(r)?.select(), Z.scrollToPath(r, { focus: !1, offset: "nearest" }), xt = r;
      } finally {
        Hn(() => {
          gl = !1;
        });
      }
    }
  }
  function Fl(c) {
    return c.name ?? c.newName ?? c.oldName ?? c.prevName ?? q("untitled");
  }
  function pf(c) {
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
  function Zn(c) {
    return Kn(c.type);
  }
  function Kn(c) {
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
  function rl(c) {
    const r = { added: 0, deleted: 0 };
    for (const b of c.hunks ?? [])
      r.added += b.additionLines ?? 0, r.deleted += b.deletionLines ?? 0;
    return r;
  }
  function vf(c, r) {
    return c?.added === r.added && c?.deleted === r.deleted;
  }
  function Rt(c) {
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
  function Wl(c, r) {
    c(r.name, () => Promise.resolve(Jn(r)));
  }
  function Ii(c, r, b, O) {
    const N = Array.from(new Set([
      c.theme?.light,
      c.theme?.dark
    ].filter(Boolean))), H = Array.from(new Set(r.flatMap((G) => {
      const W = G.fileDiff ?? {}, st = W.name ?? W.newName ?? W.oldName ?? W.prevName ?? "", pt = W.lang ?? b(st) ?? "text";
      return pt ? [pt] : [];
    })));
    return O({
      themes: N,
      langs: H.length > 0 ? H : ["text"]
    });
  }
  function Jn(c) {
    const r = c.palette ?? {}, b = c.foreground, O = c.background;
    return {
      name: c.name,
      displayName: c.ghosttyName,
      type: c.type,
      colors: {
        "editor.background": O,
        "editor.foreground": b,
        "terminal.background": O,
        "terminal.foreground": b,
        "terminal.ansiBlack": r[0] ?? b,
        "terminal.ansiRed": r[1] ?? b,
        "terminal.ansiGreen": r[2] ?? b,
        "terminal.ansiYellow": r[3] ?? b,
        "terminal.ansiBlue": r[4] ?? b,
        "terminal.ansiMagenta": r[5] ?? b,
        "terminal.ansiCyan": r[6] ?? b,
        "terminal.ansiWhite": r[7] ?? b,
        "terminal.ansiBrightBlack": r[8] ?? b,
        "terminal.ansiBrightRed": r[9] ?? r[1] ?? b,
        "terminal.ansiBrightGreen": r[10] ?? r[2] ?? b,
        "terminal.ansiBrightYellow": r[11] ?? r[3] ?? b,
        "terminal.ansiBrightBlue": r[12] ?? r[4] ?? b,
        "terminal.ansiBrightMagenta": r[13] ?? r[5] ?? b,
        "terminal.ansiBrightCyan": r[14] ?? r[6] ?? b,
        "terminal.ansiBrightWhite": r[15] ?? b,
        "gitDecoration.addedResourceForeground": r[10] ?? r[2] ?? "#32d74b",
        "gitDecoration.deletedResourceForeground": r[9] ?? r[1] ?? "#ff453a",
        "gitDecoration.modifiedResourceForeground": r[12] ?? r[4] ?? "#0a84ff",
        "editor.selectionBackground": c.selectionBackground,
        "editor.selectionForeground": c.selectionForeground
      },
      tokenColors: [
        { settings: { foreground: b, background: O } },
        { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: r[8] ?? b, fontStyle: "italic" } },
        { scope: ["string", "constant.other.symbol"], settings: { foreground: r[2] ?? b } },
        { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: r[3] ?? b } },
        { scope: ["keyword", "storage", "storage.type"], settings: { foreground: r[5] ?? b } },
        { scope: ["entity.name.function", "support.function"], settings: { foreground: r[4] ?? b } },
        { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: r[6] ?? b } },
        { scope: ["variable", "meta.definition.variable"], settings: { foreground: b } },
        { scope: ["invalid", "message.error"], settings: { foreground: r[9] ?? r[1] ?? b } }
      ]
    };
  }
}
function Ct(T, L) {
  return T.payload?.labels?.[L] ?? L;
}
const og = ["82%", "64%", "76%", "58%", "70%", "46%"], rg = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
function sg() {
  return /* @__PURE__ */ X.jsx("div", { className: "diff-loading-placeholder p-2", "aria-hidden": "true", children: og.map((T, L) => /* @__PURE__ */ X.jsxs("div", { className: "grid h-[30px] grid-cols-[17px_minmax(0,1fr)_44px] items-center gap-2 rounded-md px-[7px]", children: [
    /* @__PURE__ */ X.jsx("span", { className: "size-[17px] rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ X.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: T } }),
    /* @__PURE__ */ X.jsx("span", { className: "h-3 justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: { width: L % 2 === 0 ? "34px" : "24px" } })
  ] }, `${T}-${L}`)) });
}
function dg() {
  return /* @__PURE__ */ X.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    /* @__PURE__ */ X.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
      /* @__PURE__ */ X.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ X.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ X.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
    ] }),
    /* @__PURE__ */ X.jsx("div", { className: "space-y-[13px] px-3 py-1", children: rg.map((T, L) => /* @__PURE__ */ X.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
      /* @__PURE__ */ X.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
      /* @__PURE__ */ X.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: T } })
    ] }, `${T}-${L}`)) })
  ] });
}
function mg({ config: T }) {
  return /* @__PURE__ */ X.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    /* @__PURE__ */ X.jsx("select", { id: "source-select", "aria-label": Ct(T, "diffTarget"), hidden: !0 }),
    /* @__PURE__ */ X.jsx("select", { id: "repo-select", "aria-label": Ct(T, "repoPath"), hidden: !0 }),
    /* @__PURE__ */ X.jsx("select", { id: "base-select", "aria-label": Ct(T, "branchBase"), hidden: !0 }),
    /* @__PURE__ */ X.jsx("span", { id: "source-detail" })
  ] });
}
function hg({ config: T }) {
  return /* @__PURE__ */ X.jsxs("header", { id: "toolbar", children: [
    /* @__PURE__ */ X.jsx(mg, { config: T }),
    /* @__PURE__ */ X.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ X.jsx("select", { id: "jump-select", "aria-label": Ct(T, "jumpToFile"), hidden: !0 }) }),
    /* @__PURE__ */ X.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
      /* @__PURE__ */ X.jsx(
        "a",
        {
          id: "external-link",
          className: "toolbar-icon",
          href: T.payload?.externalURL ?? "#",
          target: "_blank",
          rel: "noreferrer",
          title: Ct(T, "openSourceURL"),
          "aria-label": Ct(T, "openSourceURL"),
          hidden: !0
        }
      ),
      /* @__PURE__ */ X.jsx(
        "button",
        {
          id: "files-toggle",
          className: "toolbar-icon",
          type: "button",
          title: Ct(T, "hideFiles"),
          "aria-label": Ct(T, "hideFiles"),
          "aria-pressed": "true"
        }
      ),
      /* @__PURE__ */ X.jsx(
        "button",
        {
          id: "layout-toggle",
          className: "toolbar-icon",
          type: "button",
          title: Ct(T, "switchToUnifiedDiff"),
          "aria-label": Ct(T, "switchToUnifiedDiff")
        }
      ),
      /* @__PURE__ */ X.jsx(
        "button",
        {
          id: "options-button",
          className: "toolbar-icon",
          type: "button",
          title: Ct(T, "options"),
          "aria-label": Ct(T, "options"),
          "aria-expanded": "false",
          "aria-haspopup": "menu"
        }
      )
    ] }),
    /* @__PURE__ */ X.jsx("div", { id: "options-menu", role: "menu", "aria-label": Ct(T, "options"), hidden: !0 })
  ] });
}
function gg({ config: T }) {
  return /* @__PURE__ */ X.jsxs("aside", { id: "files-sidebar", "aria-label": Ct(T, "changedFiles"), children: [
    /* @__PURE__ */ X.jsxs("div", { id: "files-header", children: [
      /* @__PURE__ */ X.jsxs("span", { id: "files-title", children: [
        /* @__PURE__ */ X.jsx("span", { children: Ct(T, "files") }),
        /* @__PURE__ */ X.jsx("span", { id: "files-count" })
      ] }),
      /* @__PURE__ */ X.jsxs("span", { id: "files-header-actions", children: [
        /* @__PURE__ */ X.jsx(
          "button",
          {
            id: "file-search-toggle",
            type: "button",
            title: Ct(T, "showFileSearch"),
            "aria-label": Ct(T, "showFileSearch"),
            "aria-pressed": "false"
          }
        ),
        /* @__PURE__ */ X.jsx(
          "button",
          {
            id: "file-collapse-toggle",
            type: "button",
            title: Ct(T, "hideFiles"),
            "aria-label": Ct(T, "hideFiles")
          }
        )
      ] })
    ] }),
    /* @__PURE__ */ X.jsx("div", { id: "file-list", children: /* @__PURE__ */ X.jsx(sg, {}) }),
    /* @__PURE__ */ X.jsxs("div", { id: "files-footer", "aria-label": Ct(T, "diffStats"), children: [
      /* @__PURE__ */ X.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ X.jsx("span", { children: Ct(T, "files") }),
        /* @__PURE__ */ X.jsx("strong", { id: "stats-files", children: "0" })
      ] }),
      /* @__PURE__ */ X.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ X.jsx("span", { children: Ct(T, "additions") }),
        /* @__PURE__ */ X.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" })
      ] }),
      /* @__PURE__ */ X.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ X.jsx("span", { children: Ct(T, "deletions") }),
        /* @__PURE__ */ X.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" })
      ] })
    ] })
  ] });
}
function pg({ config: T }) {
  const L = im.useRef(!1), lt = im.useCallback((v) => {
    !v || L.current || (L.current = !0, cg(T));
  }, [T]);
  return /* @__PURE__ */ X.jsxs("div", { id: "app", ref: lt, children: [
    /* @__PURE__ */ X.jsx(hg, { config: T }),
    /* @__PURE__ */ X.jsxs("section", { id: "content", children: [
      /* @__PURE__ */ X.jsx(gg, { config: T }),
      /* @__PURE__ */ X.jsxs("main", { id: "viewer", "aria-label": Ct(T, "diffViewer"), children: [
        /* @__PURE__ */ X.jsx("div", { id: "status", children: T.payload?.statusMessage ?? Ct(T, "loadingDiff") }),
        /* @__PURE__ */ X.jsx(dg, {})
      ] })
    ] })
  ] });
}
const vg = '@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-space-y-reverse:0;--tw-border-style:solid}}}@layer theme{:root,:host{--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--spacing:.25rem;--radius-md:.375rem;--default-font-family:var(--font-sans);--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab,red,red)){::placeholder{color:color-mix(in oklab,currentcolor 50%,transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}}@layer components;@layer utilities{.\\@container{container-type:inline-size}.collapse{visibility:collapse}.visible{visibility:visible}.fixed{position:fixed}.static{position:static}.mx-3\\.5{margin-inline:calc(var(--spacing) * 3.5)}.mt-3\\.5{margin-top:calc(var(--spacing) * 3.5)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.flex{display:flex}.grid{display:grid}.hidden{display:none}.size-\\[17px\\]{width:17px;height:17px}.h-3{height:calc(var(--spacing) * 3)}.h-9{height:calc(var(--spacing) * 9)}.h-\\[30px\\]{height:30px}.h-px{height:1px}.w-2\\/5{width:40%}.min-w-0{min-width:calc(var(--spacing) * 0)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.grid-cols-\\[17px_minmax\\(0\\,1fr\\)_44px\\]{grid-template-columns:17px minmax(0,1fr) 44px}.grid-cols-\\[42px_minmax\\(0\\,1fr\\)\\]{grid-template-columns:42px minmax(0,1fr)}.grid-cols-\\[72px_minmax\\(0\\,1fr\\)_96px\\]{grid-template-columns:72px minmax(0,1fr) 96px}.items-center{align-items:center}.justify-center{justify-content:center}.gap-1\\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}:where(.space-y-\\[13px\\]>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(13px * var(--tw-space-y-reverse));margin-block-end:calc(13px * calc(1 - var(--tw-space-y-reverse)))}.justify-self-end{justify-self:flex-end}.rounded{border-radius:.25rem}.rounded-\\[5px\\]{border-radius:5px}.rounded-md{border-radius:var(--radius-md)}.border{border-style:var(--tw-border-style);border-width:1px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:color-mix(in lab,var(--cmux-diff-fg) 18%,transparent)}}.border-\\[var\\(--cmux-diff-border\\)\\]{border-color:var(--cmux-diff-border)}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.bg-\\[var\\(--cmux-diff-muted-bg\\)\\]{background-color:var(--cmux-diff-muted-bg)}.p-2{padding:calc(var(--spacing) * 2)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-\\[7px\\]{padding-inline:7px}.py-1{padding-block:calc(var(--spacing) * 1)}.pt-3{padding-top:calc(var(--spacing) * 3)}.italic{font-style:italic}.opacity-70{opacity:.7}}:root{color-scheme:light dark;--cmux-diff-bg-light:#fff;--cmux-diff-bg-dark:#000;--cmux-diff-fg-light:#000;--cmux-diff-fg-dark:#fff;--cmux-diff-selection-bg-light:#abd8ff;--cmux-diff-selection-bg-dark:#3f638b;--cmux-diff-ui-font-family:system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size:12px;--cmux-diff-ui-line-height:16px;--cmux-diff-code-font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size:10px;--cmux-diff-line-height:20px;--cmux-diff-bg:var(--cmux-diff-bg-light);--cmux-diff-fg:var(--cmux-diff-fg-light);--cmux-diff-border:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-border:color-mix(in lab, var(--cmux-diff-fg) 12%, transparent)}}:root{--cmux-diff-sidebar-bg:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-sidebar-bg:color-mix(in lab, var(--cmux-diff-bg) 98%, var(--cmux-diff-fg))}}:root{--cmux-diff-muted-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-muted-bg:color-mix(in lab, var(--cmux-diff-fg) 8%, transparent)}}:root{--cmux-diff-hover-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-hover-bg:color-mix(in lab, var(--cmux-diff-fg) 10%, transparent)}}:root{--cmux-diff-accent:light-dark(#0a84ff,#7ab7ff);background:var(--cmux-diff-bg);color:var(--cmux-diff-fg)}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg:var(--cmux-diff-bg-dark);--cmux-diff-fg:var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{height:100%;overflow:hidden}body{background:var(--cmux-diff-bg);height:100vh;min-height:0;color:var(--cmux-diff-fg);font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height);flex-direction:column;margin:0;display:flex;overflow:hidden}#app{overscroll-behavior:contain;contain:strict;background:inherit;height:100vh;min-height:0;color:inherit;grid-template-rows:auto minmax(0,1fr);display:grid;overflow:hidden}#toolbar{border-bottom:1px solid var(--cmux-diff-fg);flex:none;align-items:center;gap:7px;min-height:32px;padding:3px 8px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#toolbar{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}#toolbar{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#toolbar{background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg))}}#toolbar{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#toolbar{color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg))}}#toolbar{z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{align-items:center;gap:6px;min-width:0;display:flex}.toolbar-left{flex:0 36%}.toolbar-middle{flex:auto;justify-content:center}.toolbar-actions{flex:none}#source-select,#repo-select,#base-select,#jump-select{appearance:none;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,var(--cmux-diff-fg);border:1px solid #0000;border-radius:6px;min-width:118px;max-width:min(30vw,320px);height:24px;padding:0 24px 0 9px}@supports (color:color-mix(in lab,red,red)){#source-select,#repo-select,#base-select,#jump-select{background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent)}}#source-select,#repo-select,#base-select,#jump-select{color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent)}}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent)}}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline-offset:1px}#source-detail{text-overflow:ellipsis;white-space:nowrap;min-width:0;color:var(--cmux-diff-fg);overflow:hidden}@supports (color:color-mix(in lab,red,red)){#source-detail{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}.toolbar-icon{width:28px;height:26px;color:var(--cmux-diff-fg);background:0 0;border:1px solid #0000;border-radius:6px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.toolbar-icon{color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg))}}.toolbar-icon{cursor:pointer;padding:0}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true],.toolbar-icon[aria-pressed=true]{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:16px;height:16px;display:block}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{border:1px solid var(--cmux-diff-fg);min-width:246px;padding:8px;position:absolute;top:calc(100% + 7px);right:10px}@supports (color:color-mix(in lab,red,red)){#options-menu{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent)}}#options-menu{background:var(--cmux-diff-bg);border-radius:8px}@supports (color:color-mix(in lab,red,red)){#options-menu{background:color-mix(in lab,var(--cmux-diff-bg) 94%,var(--cmux-diff-fg))}}#options-menu{z-index:100;box-shadow:0 16px 34px lab(0% none none/.28)}#options-menu[hidden]{display:none}.menu-separator{background:var(--cmux-diff-fg);height:1px;margin:7px 6px}@supports (color:color-mix(in lab,red,red)){.menu-separator{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.menu-item{width:100%;min-height:31px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:6px;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;display:grid}@supports (color:color-mix(in lab,red,red)){.menu-item{color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg))}}.menu-item{font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.menu-item:hover:not(:disabled){color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:0 0}.menu-segment-controls{background:var(--cmux-diff-bg);border-radius:7px;justify-self:end;align-items:center;gap:2px;padding:2px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.menu-segment-controls{background:color-mix(in lab,var(--cmux-diff-bg) 82%,var(--cmux-diff-fg))}}.segment-button{width:27px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.segment-button{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.segment-button{padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.segment-button:hover,.segment-button[aria-pressed=true],.menu-item:disabled{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}}.menu-label{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.menu-check{justify-self:end}#content{--cmux-diff-files-width:clamp(190px, 22vw, 252px);grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);overscroll-behavior:contain;contain:strict;background:inherit;flex:auto;grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";min-width:0;min-height:0;display:grid;position:relative;overflow:hidden}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{border-left:1px solid var(--cmux-diff-border);background:var(--cmux-diff-bg);flex-direction:column;grid-area:files;width:100%;min-width:0;height:100%;min-height:0;display:flex;position:relative;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#files-sidebar{background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg))}}#files-sidebar{contain:strict;opacity:1;transition:opacity .1s,visibility linear}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s,visibility 0s linear .1s}body[data-status-only=true] #files-sidebar{display:none}#files-header{z-index:1;border-bottom:1px solid var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:8px;min-height:30px;padding:0 7px 0 10px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#files-header{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-header{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#files-header{background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg))}}#files-header{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#files-header{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}#files-title{align-items:center;gap:6px;min-width:0;display:inline-flex}#files-header-actions{flex:none;align-items:center;gap:2px;display:inline-flex}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;flex:none;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){#file-search-toggle,#file-collapse-toggle{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}#file-search-toggle,#file-collapse-toggle{padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:15px;height:15px}#file-list{--trees-bg-override:var(--cmux-diff-sidebar-bg);--trees-fg-override:var(--cmux-diff-fg);flex:auto;min-height:0;padding:6px 4px 6px 6px;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-override:color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg))}}#file-list{--trees-fg-muted-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-muted-override:color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg))}}#file-list{--trees-bg-muted-override:var(--cmux-diff-hover-bg);--trees-selected-bg-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-selected-bg-override:color-mix(in lab, var(--cmux-diff-fg) 11%, transparent)}}#file-list{--trees-selected-fg-override:var(--cmux-diff-fg);--trees-selected-focused-border-color-override:transparent;--trees-border-color-override:var(--cmux-diff-border);--trees-focus-ring-color-override:var(--cmux-diff-accent)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-focus-ring-color-override:color-mix(in lab, var(--cmux-diff-accent) 72%, transparent)}}#file-list{--trees-font-family-override:var(--cmux-diff-ui-font-family);--trees-font-size-override:var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override:500;--trees-density-override:.78;--trees-border-radius-override:5px;--trees-item-padding-x-override:7px;--trees-item-margin-x-override:0;--trees-padding-inline-override:0;--trees-search-bg-override:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-search-bg-override:color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))}}#file-list{--trees-status-added-override:light-dark(#257a3e,#8fd88f);--trees-status-modified-override:var(--cmux-diff-accent);--trees-status-renamed-override:light-dark(#a26300,#ffd166);--trees-status-deleted-override:light-dark(#b42318,#ff8a80)}body[data-loading=false] .diff-loading-placeholder{display:none}#file-list file-tree-container{width:100%;height:100%}#files-footer{border-top:1px solid var(--cmux-diff-fg);flex:none;padding:7px 10px 8px}@supports (color:color-mix(in lab,red,red)){#files-footer{border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-footer{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#files-footer{background:color-mix(in lab,var(--cmux-diff-bg) 97%,var(--cmux-diff-fg))}}.stats-row{min-height:19px;color:var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:10px;display:flex}@supports (color:color-mix(in lab,red,red)){.stats-row{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}.stats-row strong{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg))}}.stats-row strong{font-weight:600}.file-entry{width:100%;min-height:30px;color:inherit;font:inherit;text-align:left;background:0 0;border:0;border-radius:6px;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;padding:3px 7px;display:grid}.file-entry:hover,.file-entry[aria-current=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.file-status{width:17px;height:17px;color:var(--cmux-diff-fg);border:1px solid;border-radius:5px;justify-content:center;align-items:center;font-size:9px;line-height:1;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-status{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.file-name{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.file-stats{color:var(--cmux-diff-fg);gap:5px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-stats{color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));overscroll-behavior:contain;overflow-anchor:none;contain:strict;border-bottom:1px solid var(--cmux-diff-border);background:inherit;grid-area:viewer;width:100%;min-width:0;height:100%;min-height:0;position:relative;overflow:clip auto}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border);display:block;overflow:clip}#status{z-index:2;border-bottom:1px solid var(--cmux-diff-fg);align-items:center;gap:10px;min-height:40px;padding:10px 14px;display:flex;position:sticky;top:0}@supports (color:color-mix(in lab,red,red)){#status{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#status{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#status{background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg))}}#status{font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status{color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{content:"";border:2px solid var(--cmux-diff-fg);flex:none;width:14px;height:14px}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent)}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-radius:50%;animation:.8s linear infinite cmuxDiffPendingSpin}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before,body[data-loading=true] #status:before{animation:none}}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}';
function yg() {
  const T = document.getElementById("cmux-diff-viewer-config");
  if (!T?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(T.textContent);
}
function bg() {
  const T = document.createElement("style");
  T.dataset.cmuxDiffViewerStyle = "true", T.textContent = vg, document.head.append(T);
}
const xa = yg();
bg();
typeof xa.payload?.title == "string" && xa.payload.title.trim() !== "" && (document.title = xa.payload.title);
document.body.dataset.filesHidden = "false";
document.body.dataset.loading = xa.payload?.pendingReplacement || !xa.payload?.statusMessage ? "true" : "false";
document.body.dataset.statusOnly = xa.payload?.statusMessage && !xa.payload.pendingReplacement ? "true" : "false";
const um = document.getElementById("root");
if (!um)
  throw new Error("Missing cmux diff viewer root");
ig.createRoot(um).render(/* @__PURE__ */ X.jsx(pg, { config: xa }));
