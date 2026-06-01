var ho = { exports: {} }, qi = {};
var Jd;
function $h() {
  if (Jd) return qi;
  Jd = 1;
  var A = /* @__PURE__ */ Symbol.for("react.transitional.element"), w = /* @__PURE__ */ Symbol.for("react.fragment");
  function W(h, st, Ut) {
    var Bt = null;
    if (Ut !== void 0 && (Bt = "" + Ut), st.key !== void 0 && (Bt = "" + st.key), "key" in st) {
      Ut = {};
      for (var le in st)
        le !== "key" && (Ut[le] = st[le]);
    } else Ut = st;
    return st = Ut.ref, {
      $$typeof: A,
      type: h,
      key: Bt,
      ref: st !== void 0 ? st : null,
      props: Ut
    };
  }
  return qi.Fragment = w, qi.jsx = W, qi.jsxs = W, qi;
}
var kd;
function Ih() {
  return kd || (kd = 1, ho.exports = $h()), ho.exports;
}
var Q = Ih(), go = { exports: {} }, Gi = {}, po = { exports: {} }, vo = {};
var Fd;
function Ph() {
  return Fd || (Fd = 1, (function(A) {
    function w(b, U) {
      var N = b.length;
      b.push(U);
      t: for (; 0 < N; ) {
        var k = N - 1 >>> 1, tt = b[k];
        if (0 < st(tt, U))
          b[k] = U, b[N] = tt, N = k;
        else break t;
      }
    }
    function W(b) {
      return b.length === 0 ? null : b[0];
    }
    function h(b) {
      if (b.length === 0) return null;
      var U = b[0], N = b.pop();
      if (N !== U) {
        b[0] = N;
        t: for (var k = 0, tt = b.length, d = tt >>> 1; k < d; ) {
          var z = 2 * (k + 1) - 1, B = b[z], q = z + 1, F = b[q];
          if (0 > st(B, N))
            q < tt && 0 > st(F, B) ? (b[k] = F, b[q] = N, k = q) : (b[k] = B, b[z] = N, k = z);
          else if (q < tt && 0 > st(F, N))
            b[k] = F, b[q] = N, k = q;
          else break t;
        }
      }
      return U;
    }
    function st(b, U) {
      var N = b.sortIndex - U.sortIndex;
      return N !== 0 ? N : b.id - U.id;
    }
    if (A.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var Ut = performance;
      A.unstable_now = function() {
        return Ut.now();
      };
    } else {
      var Bt = Date, le = Bt.now();
      A.unstable_now = function() {
        return Bt.now() - le;
      };
    }
    var D = [], _ = [], it = 1, K = null, yt = 3, pe = !1, me = !1, Wt = !1, _t = !1, ae = typeof setTimeout == "function" ? setTimeout : null, ve = typeof clearTimeout == "function" ? clearTimeout : null, Nt = typeof setImmediate < "u" ? setImmediate : null;
    function $t(b) {
      for (var U = W(_); U !== null; ) {
        if (U.callback === null) h(_);
        else if (U.startTime <= b)
          h(_), U.sortIndex = U.expirationTime, w(D, U);
        else break;
        U = W(_);
      }
    }
    function Kt(b) {
      if (Wt = !1, $t(b), !me)
        if (W(D) !== null)
          me = !0, It || (It = !0, ie());
        else {
          var U = W(_);
          U !== null && H(Kt, U.startTime - b);
        }
    }
    var It = !1, $ = -1, ne = 5, Pt = -1;
    function Ye() {
      return _t ? !0 : !(A.unstable_now() - Pt < ne);
    }
    function Oe() {
      if (_t = !1, It) {
        var b = A.unstable_now();
        Pt = b;
        var U = !0;
        try {
          t: {
            me = !1, Wt && (Wt = !1, ve($), $ = -1), pe = !0;
            var N = yt;
            try {
              e: {
                for ($t(b), K = W(D); K !== null && !(K.expirationTime > b && Ye()); ) {
                  var k = K.callback;
                  if (typeof k == "function") {
                    K.callback = null, yt = K.priorityLevel;
                    var tt = k(
                      K.expirationTime <= b
                    );
                    if (b = A.unstable_now(), typeof tt == "function") {
                      K.callback = tt, $t(b), U = !0;
                      break e;
                    }
                    K === W(D) && h(D), $t(b);
                  } else h(D);
                  K = W(D);
                }
                if (K !== null) U = !0;
                else {
                  var d = W(_);
                  d !== null && H(
                    Kt,
                    d.startTime - b
                  ), U = !1;
                }
              }
              break t;
            } finally {
              K = null, yt = N, pe = !1;
            }
            U = void 0;
          }
        } finally {
          U ? ie() : It = !1;
        }
      }
    }
    var ie;
    if (typeof Nt == "function")
      ie = function() {
        Nt(Oe);
      };
    else if (typeof MessageChannel < "u") {
      var il = new MessageChannel(), X = il.port2;
      il.port1.onmessage = Oe, ie = function() {
        X.postMessage(null);
      };
    } else
      ie = function() {
        ae(Oe, 0);
      };
    function H(b, U) {
      $ = ae(function() {
        b(A.unstable_now());
      }, U);
    }
    A.unstable_IdlePriority = 5, A.unstable_ImmediatePriority = 1, A.unstable_LowPriority = 4, A.unstable_NormalPriority = 3, A.unstable_Profiling = null, A.unstable_UserBlockingPriority = 2, A.unstable_cancelCallback = function(b) {
      b.callback = null;
    }, A.unstable_forceFrameRate = function(b) {
      0 > b || 125 < b ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : ne = 0 < b ? Math.floor(1e3 / b) : 5;
    }, A.unstable_getCurrentPriorityLevel = function() {
      return yt;
    }, A.unstable_next = function(b) {
      switch (yt) {
        case 1:
        case 2:
        case 3:
          var U = 3;
          break;
        default:
          U = yt;
      }
      var N = yt;
      yt = U;
      try {
        return b();
      } finally {
        yt = N;
      }
    }, A.unstable_requestPaint = function() {
      _t = !0;
    }, A.unstable_runWithPriority = function(b, U) {
      switch (b) {
        case 1:
        case 2:
        case 3:
        case 4:
        case 5:
          break;
        default:
          b = 3;
      }
      var N = yt;
      yt = b;
      try {
        return U();
      } finally {
        yt = N;
      }
    }, A.unstable_scheduleCallback = function(b, U, N) {
      var k = A.unstable_now();
      switch (typeof N == "object" && N !== null ? (N = N.delay, N = typeof N == "number" && 0 < N ? k + N : k) : N = k, b) {
        case 1:
          var tt = -1;
          break;
        case 2:
          tt = 250;
          break;
        case 5:
          tt = 1073741823;
          break;
        case 4:
          tt = 1e4;
          break;
        default:
          tt = 5e3;
      }
      return tt = N + tt, b = {
        id: it++,
        callback: U,
        priorityLevel: b,
        startTime: N,
        expirationTime: tt,
        sortIndex: -1
      }, N > k ? (b.sortIndex = N, w(_, b), W(D) === null && b === W(_) && (Wt ? (ve($), $ = -1) : Wt = !0, H(Kt, N - k))) : (b.sortIndex = tt, w(D, b), me || pe || (me = !0, It || (It = !0, ie()))), b;
    }, A.unstable_shouldYield = Ye, A.unstable_wrapCallback = function(b) {
      var U = yt;
      return function() {
        var N = yt;
        yt = U;
        try {
          return b.apply(this, arguments);
        } finally {
          yt = N;
        }
      };
    };
  })(vo)), vo;
}
var Wd;
function tg() {
  return Wd || (Wd = 1, po.exports = Ph()), po.exports;
}
var yo = { exports: {} }, P = {};
var $d;
function eg() {
  if ($d) return P;
  $d = 1;
  var A = /* @__PURE__ */ Symbol.for("react.transitional.element"), w = /* @__PURE__ */ Symbol.for("react.portal"), W = /* @__PURE__ */ Symbol.for("react.fragment"), h = /* @__PURE__ */ Symbol.for("react.strict_mode"), st = /* @__PURE__ */ Symbol.for("react.profiler"), Ut = /* @__PURE__ */ Symbol.for("react.consumer"), Bt = /* @__PURE__ */ Symbol.for("react.context"), le = /* @__PURE__ */ Symbol.for("react.forward_ref"), D = /* @__PURE__ */ Symbol.for("react.suspense"), _ = /* @__PURE__ */ Symbol.for("react.memo"), it = /* @__PURE__ */ Symbol.for("react.lazy"), K = /* @__PURE__ */ Symbol.for("react.activity"), yt = Symbol.iterator;
  function pe(d) {
    return d === null || typeof d != "object" ? null : (d = yt && d[yt] || d["@@iterator"], typeof d == "function" ? d : null);
  }
  var me = {
    isMounted: function() {
      return !1;
    },
    enqueueForceUpdate: function() {
    },
    enqueueReplaceState: function() {
    },
    enqueueSetState: function() {
    }
  }, Wt = Object.assign, _t = {};
  function ae(d, z, B) {
    this.props = d, this.context = z, this.refs = _t, this.updater = B || me;
  }
  ae.prototype.isReactComponent = {}, ae.prototype.setState = function(d, z) {
    if (typeof d != "object" && typeof d != "function" && d != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, d, z, "setState");
  }, ae.prototype.forceUpdate = function(d) {
    this.updater.enqueueForceUpdate(this, d, "forceUpdate");
  };
  function ve() {
  }
  ve.prototype = ae.prototype;
  function Nt(d, z, B) {
    this.props = d, this.context = z, this.refs = _t, this.updater = B || me;
  }
  var $t = Nt.prototype = new ve();
  $t.constructor = Nt, Wt($t, ae.prototype), $t.isPureReactComponent = !0;
  var Kt = Array.isArray;
  function It() {
  }
  var $ = { H: null, A: null, T: null, S: null }, ne = Object.prototype.hasOwnProperty;
  function Pt(d, z, B) {
    var q = B.ref;
    return {
      $$typeof: A,
      type: d,
      key: z,
      ref: q !== void 0 ? q : null,
      props: B
    };
  }
  function Ye(d, z) {
    return Pt(d.type, z, d.props);
  }
  function Oe(d) {
    return typeof d == "object" && d !== null && d.$$typeof === A;
  }
  function ie(d) {
    var z = { "=": "=0", ":": "=2" };
    return "$" + d.replace(/[=:]/g, function(B) {
      return z[B];
    });
  }
  var il = /\/+/g;
  function X(d, z) {
    return typeof d == "object" && d !== null && d.key != null ? ie("" + d.key) : z.toString(36);
  }
  function H(d) {
    switch (d.status) {
      case "fulfilled":
        return d.value;
      case "rejected":
        throw d.reason;
      default:
        switch (typeof d.status == "string" ? d.then(It, It) : (d.status = "pending", d.then(
          function(z) {
            d.status === "pending" && (d.status = "fulfilled", d.value = z);
          },
          function(z) {
            d.status === "pending" && (d.status = "rejected", d.reason = z);
          }
        )), d.status) {
          case "fulfilled":
            return d.value;
          case "rejected":
            throw d.reason;
        }
    }
    throw d;
  }
  function b(d, z, B, q, F) {
    var at = typeof d;
    (at === "undefined" || at === "boolean") && (d = null);
    var mt = !1;
    if (d === null) mt = !0;
    else
      switch (at) {
        case "bigint":
        case "string":
        case "number":
          mt = !0;
          break;
        case "object":
          switch (d.$$typeof) {
            case A:
            case w:
              mt = !0;
              break;
            case it:
              return mt = d._init, b(
                mt(d._payload),
                z,
                B,
                q,
                F
              );
          }
      }
    if (mt)
      return F = F(d), mt = q === "" ? "." + X(d, 0) : q, Kt(F) ? (B = "", mt != null && (B = mt.replace(il, "$&/") + "/"), b(F, z, B, "", function(Ce) {
        return Ce;
      })) : F != null && (Oe(F) && (F = Ye(
        F,
        B + (F.key == null || d && d.key === F.key ? "" : ("" + F.key).replace(
          il,
          "$&/"
        ) + "/") + mt
      )), z.push(F)), 1;
    mt = 0;
    var wt = q === "" ? "." : q + ":";
    if (Kt(d))
      for (var Dt = 0; Dt < d.length; Dt++)
        q = d[Dt], at = wt + X(q, Dt), mt += b(
          q,
          z,
          B,
          at,
          F
        );
    else if (Dt = pe(d), typeof Dt == "function")
      for (d = Dt.call(d), Dt = 0; !(q = d.next()).done; )
        q = q.value, at = wt + X(q, Dt++), mt += b(
          q,
          z,
          B,
          at,
          F
        );
    else if (at === "object") {
      if (typeof d.then == "function")
        return b(
          H(d),
          z,
          B,
          q,
          F
        );
      throw z = String(d), Error(
        "Objects are not valid as a React child (found: " + (z === "[object Object]" ? "object with keys {" + Object.keys(d).join(", ") + "}" : z) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return mt;
  }
  function U(d, z, B) {
    if (d == null) return d;
    var q = [], F = 0;
    return b(d, q, "", "", function(at) {
      return z.call(B, at, F++);
    }), q;
  }
  function N(d) {
    if (d._status === -1) {
      var z = d._result;
      z = z(), z.then(
        function(B) {
          (d._status === 0 || d._status === -1) && (d._status = 1, d._result = B);
        },
        function(B) {
          (d._status === 0 || d._status === -1) && (d._status = 2, d._result = B);
        }
      ), d._status === -1 && (d._status = 0, d._result = z);
    }
    if (d._status === 1) return d._result.default;
    throw d._result;
  }
  var k = typeof reportError == "function" ? reportError : function(d) {
    if (typeof window == "object" && typeof window.ErrorEvent == "function") {
      var z = new window.ErrorEvent("error", {
        bubbles: !0,
        cancelable: !0,
        message: typeof d == "object" && d !== null && typeof d.message == "string" ? String(d.message) : String(d),
        error: d
      });
      if (!window.dispatchEvent(z)) return;
    } else if (typeof process == "object" && typeof process.emit == "function") {
      process.emit("uncaughtException", d);
      return;
    }
    console.error(d);
  }, tt = {
    map: U,
    forEach: function(d, z, B) {
      U(
        d,
        function() {
          z.apply(this, arguments);
        },
        B
      );
    },
    count: function(d) {
      var z = 0;
      return U(d, function() {
        z++;
      }), z;
    },
    toArray: function(d) {
      return U(d, function(z) {
        return z;
      }) || [];
    },
    only: function(d) {
      if (!Oe(d))
        throw Error(
          "React.Children.only expected to receive a single React element child."
        );
      return d;
    }
  };
  return P.Activity = K, P.Children = tt, P.Component = ae, P.Fragment = W, P.Profiler = st, P.PureComponent = Nt, P.StrictMode = h, P.Suspense = D, P.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = $, P.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(d) {
      return $.H.useMemoCache(d);
    }
  }, P.cache = function(d) {
    return function() {
      return d.apply(null, arguments);
    };
  }, P.cacheSignal = function() {
    return null;
  }, P.cloneElement = function(d, z, B) {
    if (d == null)
      throw Error(
        "The argument must be a React element, but you passed " + d + "."
      );
    var q = Wt({}, d.props), F = d.key;
    if (z != null)
      for (at in z.key !== void 0 && (F = "" + z.key), z)
        !ne.call(z, at) || at === "key" || at === "__self" || at === "__source" || at === "ref" && z.ref === void 0 || (q[at] = z[at]);
    var at = arguments.length - 2;
    if (at === 1) q.children = B;
    else if (1 < at) {
      for (var mt = Array(at), wt = 0; wt < at; wt++)
        mt[wt] = arguments[wt + 2];
      q.children = mt;
    }
    return Pt(d.type, F, q);
  }, P.createContext = function(d) {
    return d = {
      $$typeof: Bt,
      _currentValue: d,
      _currentValue2: d,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, d.Provider = d, d.Consumer = {
      $$typeof: Ut,
      _context: d
    }, d;
  }, P.createElement = function(d, z, B) {
    var q, F = {}, at = null;
    if (z != null)
      for (q in z.key !== void 0 && (at = "" + z.key), z)
        ne.call(z, q) && q !== "key" && q !== "__self" && q !== "__source" && (F[q] = z[q]);
    var mt = arguments.length - 2;
    if (mt === 1) F.children = B;
    else if (1 < mt) {
      for (var wt = Array(mt), Dt = 0; Dt < mt; Dt++)
        wt[Dt] = arguments[Dt + 2];
      F.children = wt;
    }
    if (d && d.defaultProps)
      for (q in mt = d.defaultProps, mt)
        F[q] === void 0 && (F[q] = mt[q]);
    return Pt(d, at, F);
  }, P.createRef = function() {
    return { current: null };
  }, P.forwardRef = function(d) {
    return { $$typeof: le, render: d };
  }, P.isValidElement = Oe, P.lazy = function(d) {
    return {
      $$typeof: it,
      _payload: { _status: -1, _result: d },
      _init: N
    };
  }, P.memo = function(d, z) {
    return {
      $$typeof: _,
      type: d,
      compare: z === void 0 ? null : z
    };
  }, P.startTransition = function(d) {
    var z = $.T, B = {};
    $.T = B;
    try {
      var q = d(), F = $.S;
      F !== null && F(B, q), typeof q == "object" && q !== null && typeof q.then == "function" && q.then(It, k);
    } catch (at) {
      k(at);
    } finally {
      z !== null && B.types !== null && (z.types = B.types), $.T = z;
    }
  }, P.unstable_useCacheRefresh = function() {
    return $.H.useCacheRefresh();
  }, P.use = function(d) {
    return $.H.use(d);
  }, P.useActionState = function(d, z, B) {
    return $.H.useActionState(d, z, B);
  }, P.useCallback = function(d, z) {
    return $.H.useCallback(d, z);
  }, P.useContext = function(d) {
    return $.H.useContext(d);
  }, P.useDebugValue = function() {
  }, P.useDeferredValue = function(d, z) {
    return $.H.useDeferredValue(d, z);
  }, P.useEffect = function(d, z) {
    return $.H.useEffect(d, z);
  }, P.useEffectEvent = function(d) {
    return $.H.useEffectEvent(d);
  }, P.useId = function() {
    return $.H.useId();
  }, P.useImperativeHandle = function(d, z, B) {
    return $.H.useImperativeHandle(d, z, B);
  }, P.useInsertionEffect = function(d, z) {
    return $.H.useInsertionEffect(d, z);
  }, P.useLayoutEffect = function(d, z) {
    return $.H.useLayoutEffect(d, z);
  }, P.useMemo = function(d, z) {
    return $.H.useMemo(d, z);
  }, P.useOptimistic = function(d, z) {
    return $.H.useOptimistic(d, z);
  }, P.useReducer = function(d, z, B) {
    return $.H.useReducer(d, z, B);
  }, P.useRef = function(d) {
    return $.H.useRef(d);
  }, P.useState = function(d) {
    return $.H.useState(d);
  }, P.useSyncExternalStore = function(d, z, B) {
    return $.H.useSyncExternalStore(
      d,
      z,
      B
    );
  }, P.useTransition = function() {
    return $.H.useTransition();
  }, P.version = "19.2.3", P;
}
var Id;
function xo() {
  return Id || (Id = 1, yo.exports = eg()), yo.exports;
}
var bo = { exports: {} }, ge = {};
var Pd;
function lg() {
  if (Pd) return ge;
  Pd = 1;
  var A = xo();
  function w(D) {
    var _ = "https://react.dev/errors/" + D;
    if (1 < arguments.length) {
      _ += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var it = 2; it < arguments.length; it++)
        _ += "&args[]=" + encodeURIComponent(arguments[it]);
    }
    return "Minified React error #" + D + "; visit " + _ + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function W() {
  }
  var h = {
    d: {
      f: W,
      r: function() {
        throw Error(w(522));
      },
      D: W,
      C: W,
      L: W,
      m: W,
      X: W,
      S: W,
      M: W
    },
    p: 0,
    findDOMNode: null
  }, st = /* @__PURE__ */ Symbol.for("react.portal");
  function Ut(D, _, it) {
    var K = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: st,
      key: K == null ? null : "" + K,
      children: D,
      containerInfo: _,
      implementation: it
    };
  }
  var Bt = A.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function le(D, _) {
    if (D === "font") return "";
    if (typeof _ == "string")
      return _ === "use-credentials" ? _ : "";
  }
  return ge.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = h, ge.createPortal = function(D, _) {
    var it = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!_ || _.nodeType !== 1 && _.nodeType !== 9 && _.nodeType !== 11)
      throw Error(w(299));
    return Ut(D, _, null, it);
  }, ge.flushSync = function(D) {
    var _ = Bt.T, it = h.p;
    try {
      if (Bt.T = null, h.p = 2, D) return D();
    } finally {
      Bt.T = _, h.p = it, h.d.f();
    }
  }, ge.preconnect = function(D, _) {
    typeof D == "string" && (_ ? (_ = _.crossOrigin, _ = typeof _ == "string" ? _ === "use-credentials" ? _ : "" : void 0) : _ = null, h.d.C(D, _));
  }, ge.prefetchDNS = function(D) {
    typeof D == "string" && h.d.D(D);
  }, ge.preinit = function(D, _) {
    if (typeof D == "string" && _ && typeof _.as == "string") {
      var it = _.as, K = le(it, _.crossOrigin), yt = typeof _.integrity == "string" ? _.integrity : void 0, pe = typeof _.fetchPriority == "string" ? _.fetchPriority : void 0;
      it === "style" ? h.d.S(
        D,
        typeof _.precedence == "string" ? _.precedence : void 0,
        {
          crossOrigin: K,
          integrity: yt,
          fetchPriority: pe
        }
      ) : it === "script" && h.d.X(D, {
        crossOrigin: K,
        integrity: yt,
        fetchPriority: pe,
        nonce: typeof _.nonce == "string" ? _.nonce : void 0
      });
    }
  }, ge.preinitModule = function(D, _) {
    if (typeof D == "string")
      if (typeof _ == "object" && _ !== null) {
        if (_.as == null || _.as === "script") {
          var it = le(
            _.as,
            _.crossOrigin
          );
          h.d.M(D, {
            crossOrigin: it,
            integrity: typeof _.integrity == "string" ? _.integrity : void 0,
            nonce: typeof _.nonce == "string" ? _.nonce : void 0
          });
        }
      } else _ == null && h.d.M(D);
  }, ge.preload = function(D, _) {
    if (typeof D == "string" && typeof _ == "object" && _ !== null && typeof _.as == "string") {
      var it = _.as, K = le(it, _.crossOrigin);
      h.d.L(D, it, {
        crossOrigin: K,
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
  }, ge.preloadModule = function(D, _) {
    if (typeof D == "string")
      if (_) {
        var it = le(_.as, _.crossOrigin);
        h.d.m(D, {
          as: typeof _.as == "string" && _.as !== "script" ? _.as : void 0,
          crossOrigin: it,
          integrity: typeof _.integrity == "string" ? _.integrity : void 0
        });
      } else h.d.m(D);
  }, ge.requestFormReset = function(D) {
    h.d.r(D);
  }, ge.unstable_batchedUpdates = function(D, _) {
    return D(_);
  }, ge.useFormState = function(D, _, it) {
    return Bt.H.useFormState(D, _, it);
  }, ge.useFormStatus = function() {
    return Bt.H.useHostTransitionStatus();
  }, ge.version = "19.2.3", ge;
}
var tm;
function ag() {
  if (tm) return bo.exports;
  tm = 1;
  function A() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(A);
      } catch (w) {
        console.error(w);
      }
  }
  return A(), bo.exports = lg(), bo.exports;
}
var em;
function ng() {
  if (em) return Gi;
  em = 1;
  var A = tg(), w = xo(), W = ag();
  function h(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function st(t) {
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
  function le(t) {
    if (t.tag === 31) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function D(t) {
    if (Ut(t) !== t)
      throw Error(h(188));
  }
  function _(t) {
    var e = t.alternate;
    if (!e) {
      if (e = Ut(t), e === null) throw Error(h(188));
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
          if (i === l) return D(n), t;
          if (i === a) return D(n), e;
          i = i.sibling;
        }
        throw Error(h(188));
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
          if (!u) throw Error(h(189));
        }
      }
      if (l.alternate !== a) throw Error(h(190));
    }
    if (l.tag !== 3) throw Error(h(188));
    return l.stateNode.current === l ? t : e;
  }
  function it(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t;
    for (t = t.child; t !== null; ) {
      if (e = it(t), e !== null) return e;
      t = t.sibling;
    }
    return null;
  }
  var K = Object.assign, yt = /* @__PURE__ */ Symbol.for("react.element"), pe = /* @__PURE__ */ Symbol.for("react.transitional.element"), me = /* @__PURE__ */ Symbol.for("react.portal"), Wt = /* @__PURE__ */ Symbol.for("react.fragment"), _t = /* @__PURE__ */ Symbol.for("react.strict_mode"), ae = /* @__PURE__ */ Symbol.for("react.profiler"), ve = /* @__PURE__ */ Symbol.for("react.consumer"), Nt = /* @__PURE__ */ Symbol.for("react.context"), $t = /* @__PURE__ */ Symbol.for("react.forward_ref"), Kt = /* @__PURE__ */ Symbol.for("react.suspense"), It = /* @__PURE__ */ Symbol.for("react.suspense_list"), $ = /* @__PURE__ */ Symbol.for("react.memo"), ne = /* @__PURE__ */ Symbol.for("react.lazy"), Pt = /* @__PURE__ */ Symbol.for("react.activity"), Ye = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), Oe = Symbol.iterator;
  function ie(t) {
    return t === null || typeof t != "object" ? null : (t = Oe && t[Oe] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var il = /* @__PURE__ */ Symbol.for("react.client.reference");
  function X(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === il ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case Wt:
        return "Fragment";
      case ae:
        return "Profiler";
      case _t:
        return "StrictMode";
      case Kt:
        return "Suspense";
      case It:
        return "SuspenseList";
      case Pt:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case me:
          return "Portal";
        case Nt:
          return t.displayName || "Context";
        case ve:
          return (t._context.displayName || "Context") + ".Consumer";
        case $t:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case $:
          return e = t.displayName || null, e !== null ? e : X(t.type) || "Memo";
        case ne:
          e = t._payload, t = t._init;
          try {
            return X(t(e));
          } catch {
          }
      }
    return null;
  }
  var H = Array.isArray, b = w.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, U = W.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, N = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, k = [], tt = -1;
  function d(t) {
    return { current: t };
  }
  function z(t) {
    0 > tt || (t.current = k[tt], k[tt] = null, tt--);
  }
  function B(t, e) {
    tt++, k[tt] = t.current, t.current = e;
  }
  var q = d(null), F = d(null), at = d(null), mt = d(null);
  function wt(t, e) {
    switch (B(at, e), B(F, t), B(q, null), e.nodeType) {
      case 9:
      case 11:
        t = (t = e.documentElement) && (t = t.namespaceURI) ? pd(t) : 0;
        break;
      default:
        if (t = e.tagName, e = e.namespaceURI)
          e = pd(e), t = vd(e, t);
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
    z(q), B(q, t);
  }
  function Dt() {
    z(q), z(F), z(at);
  }
  function Ce(t) {
    t.memoizedState !== null && B(mt, t);
    var e = q.current, l = vd(e, t.type);
    e !== l && (B(F, t), B(q, l));
  }
  function $e(t) {
    F.current === t && (z(q), z(F)), mt.current === t && (z(mt), Ni._currentValue = N);
  }
  var Va, Yi;
  function ue(t) {
    if (Va === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        Va = e && e[1] || "", Yi = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + Va + t + Yi;
  }
  var Yn = !1;
  function Ln(t, e) {
    if (!t || Yn) return "";
    Yn = !0;
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
                  var v = x;
                }
                Reflect.construct(t, [], E);
              } else {
                try {
                  E.call();
                } catch (x) {
                  v = x;
                }
                t.call(E.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (x) {
                v = x;
              }
              (E = t()) && typeof E.catch == "function" && E.catch(function() {
              });
            }
          } catch (x) {
            if (x && v && typeof x.stack == "string")
              return [x.stack, v.stack];
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
`), p = f.split(`
`);
        for (n = a = 0; a < r.length && !r[a].includes("DetermineComponentFrameRoot"); )
          a++;
        for (; n < p.length && !p[n].includes(
          "DetermineComponentFrameRoot"
        ); )
          n++;
        if (a === r.length || n === p.length)
          for (a = r.length - 1, n = p.length - 1; 1 <= a && 0 <= n && r[a] !== p[n]; )
            n--;
        for (; 1 <= a && 0 <= n; a--, n--)
          if (r[a] !== p[n]) {
            if (a !== 1 || n !== 1)
              do
                if (a--, n--, 0 > n || r[a] !== p[n]) {
                  var S = `
` + r[a].replace(" at new ", " at ");
                  return t.displayName && S.includes("<anonymous>") && (S = S.replace("<anonymous>", t.displayName)), S;
                }
              while (1 <= a && 0 <= n);
            break;
          }
      }
    } finally {
      Yn = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? ue(l) : "";
  }
  function of(t, e) {
    switch (t.tag) {
      case 26:
      case 27:
      case 5:
        return ue(t.type);
      case 16:
        return ue("Lazy");
      case 13:
        return t.child !== e && e !== null ? ue("Suspense Fallback") : ue("Suspense");
      case 19:
        return ue("SuspenseList");
      case 0:
      case 15:
        return Ln(t.type, !1);
      case 11:
        return Ln(t.type.render, !1);
      case 1:
        return Ln(t.type, !0);
      case 31:
        return ue("Activity");
      default:
        return "";
    }
  }
  function Li(t) {
    try {
      var e = "", l = null;
      do
        e += of(t, l), l = t, t = t.return;
      while (t);
      return e;
    } catch (a) {
      return `
Error generating stack: ` + a.message + `
` + a.stack;
    }
  }
  var Xn = Object.prototype.hasOwnProperty, da = A.unstable_scheduleCallback, ma = A.unstable_cancelCallback, Xi = A.unstable_shouldYield, Qn = A.unstable_requestPaint, he = A.unstable_now, rf = A.unstable_getCurrentPriorityLevel, Za = A.unstable_ImmediatePriority, Vn = A.unstable_UserBlockingPriority, Ka = A.unstable_NormalPriority, sf = A.unstable_LowPriority, Qi = A.unstable_IdlePriority, Vi = A.log, df = A.unstable_setDisableYieldValue, ha = null, ye = null;
  function ul(t) {
    if (typeof Vi == "function" && df(t), ye && typeof ye.setStrictMode == "function")
      try {
        ye.setStrictMode(ha, t);
      } catch {
      }
  }
  var be = Math.clz32 ? Math.clz32 : Ja, ga = Math.log, Zi = Math.LN2;
  function Ja(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (ga(t) / Zi | 0) | 0;
  }
  var ka = 256, pl = 262144, Fa = 4194304;
  function vl(t) {
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
  function pa(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, i = t.suspendedLanes, u = t.pingedLanes;
    t = t.warmLanes;
    var f = a & 134217727;
    return f !== 0 ? (a = f & ~i, a !== 0 ? n = vl(a) : (u &= f, u !== 0 ? n = vl(u) : l || (l = f & ~t, l !== 0 && (n = vl(l))))) : (f = a & ~i, f !== 0 ? n = vl(f) : u !== 0 ? n = vl(u) : l || (l = a & ~t, l !== 0 && (n = vl(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function Hl(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function mf(t, e) {
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
  function fl() {
    var t = Fa;
    return Fa <<= 1, (Fa & 62914560) === 0 && (Fa = 4194304), t;
  }
  function Wa(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function va(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function $a(t, e, l, a, n, i) {
    var u = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var f = t.entanglements, r = t.expirationTimes, p = t.hiddenUpdates;
    for (l = u & ~l; 0 < l; ) {
      var S = 31 - be(l), E = 1 << S;
      f[S] = 0, r[S] = -1;
      var v = p[S];
      if (v !== null)
        for (p[S] = null, S = 0; S < v.length; S++) {
          var x = v[S];
          x !== null && (x.lane &= -536870913);
        }
      l &= ~E;
    }
    a !== 0 && Zn(t, a, 0), i !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= i & ~(u & ~e));
  }
  function Zn(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - be(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function Ki(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - be(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function xe(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : ya(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function ya(t) {
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
  function ba(t) {
    return t &= -t, 2 < t ? 8 < t ? (t & 134217727) !== 0 ? 32 : 268435456 : 8 : 2;
  }
  function Ji() {
    var t = U.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Yd(t.type));
  }
  function ki(t, e) {
    var l = U.p;
    try {
      return U.p = t, e();
    } finally {
      U.p = l;
    }
  }
  var Ie = Math.random().toString(36).slice(2), Jt = "__reactFiber$" + Ie, fe = "__reactProps$" + Ie, yl = "__reactContainer$" + Ie, Kn = "__reactEvents$" + Ie, hf = "__reactListeners$" + Ie, gf = "__reactHandles$" + Ie, Fi = "__reactResources$" + Ie, xa = "__reactMarker$" + Ie;
  function Ia(t) {
    delete t[Jt], delete t[fe], delete t[Kn], delete t[hf], delete t[gf];
  }
  function cl(t) {
    var e = t[Jt];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[yl] || l[Jt]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Md(t); t !== null; ) {
            if (l = t[Jt]) return l;
            t = Md(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function ol(t) {
    if (t = t[Jt] || t[yl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function jl(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(h(33));
  }
  function Pe(t) {
    var e = t[Fi];
    return e || (e = t[Fi] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function Gt(t) {
    t[xa] = !0;
  }
  var Jn = /* @__PURE__ */ new Set(), Wi = {};
  function rl(t, e) {
    ql(t, e), ql(t + "Capture", e);
  }
  function ql(t, e) {
    for (Wi[t] = e, t = 0; t < e.length; t++)
      Jn.add(e[t]);
  }
  var $i = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), Ii = {}, Pi = {};
  function kn(t) {
    return Xn.call(Pi, t) ? !0 : Xn.call(Ii, t) ? !1 : $i.test(t) ? Pi[t] = !0 : (Ii[t] = !0, !1);
  }
  function Pa(t, e, l) {
    if (kn(e))
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
  function te(t) {
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
  function tn(t) {
    if (!t._valueTracker) {
      var e = tu(t) ? "checked" : "value";
      t._valueTracker = pf(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function Gl(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = tu(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function en(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var Ue = /[\n"\\]/g;
  function ce(t) {
    return t.replace(
      Ue,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function Fn(t, e, l, a, n, i, u, f) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + te(e)) : t.value !== "" + te(e) && (t.value = "" + te(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? c(t, u, te(e)) : l != null ? c(t, u, te(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), f != null && typeof f != "function" && typeof f != "symbol" && typeof f != "boolean" ? t.name = "" + te(f) : t.removeAttribute("name");
  }
  function eu(t, e, l, a, n, i, u, f) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        tn(t);
        return;
      }
      l = l != null ? "" + te(l) : "", e = e != null ? "" + te(e) : l, f || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = f ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), tn(t);
  }
  function c(t, e, l) {
    e === "number" && en(t.ownerDocument) === t || t.defaultValue === "" + l || (t.defaultValue = "" + l);
  }
  function o(t, e, l, a) {
    if (t = t.options, e) {
      e = {};
      for (var n = 0; n < l.length; n++)
        e["$" + l[n]] = !0;
      for (l = 0; l < t.length; l++)
        n = e.hasOwnProperty("$" + t[l].value), t[l].selected !== n && (t[l].selected = n), n && a && (t[l].defaultSelected = !0);
    } else {
      for (l = "" + te(l), e = null, n = 0; n < t.length; n++) {
        if (t[n].value === l) {
          t[n].selected = !0, a && (t[n].defaultSelected = !0);
          return;
        }
        e !== null || t[n].disabled || (e = t[n]);
      }
      e !== null && (e.selected = !0);
    }
  }
  function y(t, e, l) {
    if (e != null && (e = "" + te(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + te(l) : "";
  }
  function C(t, e, l, a) {
    if (e == null) {
      if (a != null) {
        if (l != null) throw Error(h(92));
        if (H(a)) {
          if (1 < a.length) throw Error(h(93));
          a = a[0];
        }
        l = a;
      }
      l == null && (l = ""), e = l;
    }
    l = te(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), tn(t);
  }
  function R(t, e) {
    if (e) {
      var l = t.firstChild;
      if (l && l === t.lastChild && l.nodeType === 3) {
        l.nodeValue = e;
        return;
      }
    }
    t.textContent = e;
  }
  var j = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function L(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || j.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function I(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(h(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && L(t, n, a);
    } else
      for (var i in e)
        e.hasOwnProperty(i) && L(t, i, e[i]);
  }
  function ct(t) {
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
  var bt = /* @__PURE__ */ new Map([
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
  ]), Yl = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function ln(t) {
    return Yl.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function el() {
  }
  var Wn = null;
  function an(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Ll = null, bl = null;
  function lu(t) {
    var e = ol(t);
    if (e && (t = e.stateNode)) {
      var l = t[fe] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if (Fn(
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
              'input[name="' + ce(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[fe] || null;
                if (!n) throw Error(h(90));
                Fn(
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
              a = l[e], a.form === t.form && Gl(a);
          }
          break t;
        case "textarea":
          y(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && o(t, !!l.multiple, e, !1);
      }
    }
  }
  var Ta = !1;
  function nn(t, e, l) {
    if (Ta) return t(e, l);
    Ta = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (Ta = !1, (Ll !== null || bl !== null) && (Yu(), Ll && (e = Ll, t = bl, bl = Ll = null, lu(e), t)))
        for (e = 0; e < t.length; e++) lu(t[e]);
    }
  }
  function za(t, e) {
    var l = t.stateNode;
    if (l === null) return null;
    var a = l[fe] || null;
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
        h(231, e, typeof l)
      );
    return l;
  }
  var Le = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), Ma = !1;
  if (Le)
    try {
      var xl = {};
      Object.defineProperty(xl, "passive", {
        get: function() {
          Ma = !0;
        }
      }), window.addEventListener("test", xl, xl), window.removeEventListener("test", xl, xl);
    } catch {
      Ma = !1;
    }
  var ze = null, un = null, fn = null;
  function $n() {
    if (fn) return fn;
    var t, e = un, l = e.length, a, n = "value" in ze ? ze.value : ze.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return fn = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function Ea(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function cn() {
    return !0;
  }
  function In() {
    return !1;
  }
  function kt(t) {
    function e(l, a, n, i, u) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = i, this.target = u, this.currentTarget = null;
      for (var f in t)
        t.hasOwnProperty(f) && (l = t[f], this[f] = l ? l(i) : i[f]);
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? cn : In, this.isPropagationStopped = In, this;
    }
    return K(e.prototype, {
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
  var sl = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, on = kt(sl), Aa = K({}, sl, { view: 0, detail: 0 }), au = kt(Aa), Pn, _a, Xe, Da = K({}, Aa, {
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
    getModifierState: yf,
    button: 0,
    buttons: 0,
    relatedTarget: function(t) {
      return t.relatedTarget === void 0 ? t.fromElement === t.srcElement ? t.toElement : t.fromElement : t.relatedTarget;
    },
    movementX: function(t) {
      return "movementX" in t ? t.movementX : (t !== Xe && (Xe && t.type === "mousemove" ? (Pn = t.screenX - Xe.screenX, _a = t.screenY - Xe.screenY) : _a = Pn = 0, Xe = t), Pn);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : _a;
    }
  }), ti = kt(Da), rn = K({}, Da, { dataTransfer: 0 }), M = kt(rn), O = K({}, Aa, { relatedTarget: 0 }), J = kt(O), et = K({}, sl, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), ht = kt(et), gt = K({}, sl, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), Ht = kt(gt), Se = K({}, sl, { data: 0 }), Xl = kt(Se), Be = {
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
  }, nu = {
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
  }, vf = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function fm(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = vf[t]) ? !!e[t] : !1;
  }
  function yf() {
    return fm;
  }
  var cm = K({}, Aa, {
    key: function(t) {
      if (t.key) {
        var e = Be[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = Ea(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? nu[t.keyCode] || "Unidentified" : "";
    },
    code: 0,
    location: 0,
    ctrlKey: 0,
    shiftKey: 0,
    altKey: 0,
    metaKey: 0,
    repeat: 0,
    locale: 0,
    getModifierState: yf,
    charCode: function(t) {
      return t.type === "keypress" ? Ea(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? Ea(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), om = kt(cm), rm = K({}, Da, {
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
  }), So = kt(rm), sm = K({}, Aa, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: yf
  }), dm = kt(sm), mm = K({}, sl, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), hm = kt(mm), gm = K({}, Da, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), pm = kt(gm), vm = K({}, sl, {
    newState: 0,
    oldState: 0
  }), ym = kt(vm), bm = [9, 13, 27, 32], bf = Le && "CompositionEvent" in window, ei = null;
  Le && "documentMode" in document && (ei = document.documentMode);
  var xm = Le && "TextEvent" in window && !ei, To = Le && (!bf || ei && 8 < ei && 11 >= ei), zo = " ", Mo = !1;
  function Eo(t, e) {
    switch (t) {
      case "keyup":
        return bm.indexOf(e.keyCode) !== -1;
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
  function Ao(t) {
    return t = t.detail, typeof t == "object" && "data" in t ? t.data : null;
  }
  var sn = !1;
  function Sm(t, e) {
    switch (t) {
      case "compositionend":
        return Ao(e);
      case "keypress":
        return e.which !== 32 ? null : (Mo = !0, zo);
      case "textInput":
        return t = e.data, t === zo && Mo ? null : t;
      default:
        return null;
    }
  }
  function Tm(t, e) {
    if (sn)
      return t === "compositionend" || !bf && Eo(t, e) ? (t = $n(), fn = un = ze = null, sn = !1, t) : null;
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
        return To && e.locale !== "ko" ? null : e.data;
      default:
        return null;
    }
  }
  var zm = {
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
  function _o(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e === "input" ? !!zm[t.type] : e === "textarea";
  }
  function Do(t, e, l, a) {
    Ll ? bl ? bl.push(a) : bl = [a] : Ll = a, e = Ju(e, "onChange"), 0 < e.length && (l = new on(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var li = null, ai = null;
  function Mm(t) {
    rd(t, 0);
  }
  function iu(t) {
    var e = jl(t);
    if (Gl(e)) return t;
  }
  function Oo(t, e) {
    if (t === "change") return e;
  }
  var Co = !1;
  if (Le) {
    var xf;
    if (Le) {
      var Sf = "oninput" in document;
      if (!Sf) {
        var Uo = document.createElement("div");
        Uo.setAttribute("oninput", "return;"), Sf = typeof Uo.oninput == "function";
      }
      xf = Sf;
    } else xf = !1;
    Co = xf && (!document.documentMode || 9 < document.documentMode);
  }
  function Bo() {
    li && (li.detachEvent("onpropertychange", Ro), ai = li = null);
  }
  function Ro(t) {
    if (t.propertyName === "value" && iu(ai)) {
      var e = [];
      Do(
        e,
        ai,
        t,
        an(t)
      ), nn(Mm, e);
    }
  }
  function Em(t, e, l) {
    t === "focusin" ? (Bo(), li = e, ai = l, li.attachEvent("onpropertychange", Ro)) : t === "focusout" && Bo();
  }
  function Am(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return iu(ai);
  }
  function _m(t, e) {
    if (t === "click") return iu(e);
  }
  function Dm(t, e) {
    if (t === "input" || t === "change")
      return iu(e);
  }
  function Om(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var Re = typeof Object.is == "function" ? Object.is : Om;
  function ni(t, e) {
    if (Re(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!Xn.call(e, n) || !Re(t[n], e[n]))
        return !1;
    }
    return !0;
  }
  function No(t) {
    for (; t && t.firstChild; ) t = t.firstChild;
    return t;
  }
  function wo(t, e) {
    var l = No(t);
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
      l = No(l);
    }
  }
  function Ho(t, e) {
    return t && e ? t === e ? !0 : t && t.nodeType === 3 ? !1 : e && e.nodeType === 3 ? Ho(t, e.parentNode) : "contains" in t ? t.contains(e) : t.compareDocumentPosition ? !!(t.compareDocumentPosition(e) & 16) : !1 : !1;
  }
  function jo(t) {
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
  function Tf(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var Cm = Le && "documentMode" in document && 11 >= document.documentMode, dn = null, zf = null, ii = null, Mf = !1;
  function qo(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Mf || dn == null || dn !== en(a) || (a = dn, "selectionStart" in a && Tf(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), ii && ni(ii, a) || (ii = a, a = Ju(zf, "onSelect"), 0 < a.length && (e = new on(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = dn)));
  }
  function Oa(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var mn = {
    animationend: Oa("Animation", "AnimationEnd"),
    animationiteration: Oa("Animation", "AnimationIteration"),
    animationstart: Oa("Animation", "AnimationStart"),
    transitionrun: Oa("Transition", "TransitionRun"),
    transitionstart: Oa("Transition", "TransitionStart"),
    transitioncancel: Oa("Transition", "TransitionCancel"),
    transitionend: Oa("Transition", "TransitionEnd")
  }, Ef = {}, Go = {};
  Le && (Go = document.createElement("div").style, "AnimationEvent" in window || (delete mn.animationend.animation, delete mn.animationiteration.animation, delete mn.animationstart.animation), "TransitionEvent" in window || delete mn.transitionend.transition);
  function Ca(t) {
    if (Ef[t]) return Ef[t];
    if (!mn[t]) return t;
    var e = mn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Go)
        return Ef[t] = e[l];
    return t;
  }
  var Yo = Ca("animationend"), Lo = Ca("animationiteration"), Xo = Ca("animationstart"), Um = Ca("transitionrun"), Bm = Ca("transitionstart"), Rm = Ca("transitioncancel"), Qo = Ca("transitionend"), Vo = /* @__PURE__ */ new Map(), Af = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Af.push("scrollEnd");
  function ll(t, e) {
    Vo.set(t, e), rl(e, [t]);
  }
  var uu = typeof reportError == "function" ? reportError : function(t) {
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
  }, Qe = [], hn = 0, _f = 0;
  function fu() {
    for (var t = hn, e = _f = hn = 0; e < t; ) {
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
      i !== 0 && Zo(l, n, i);
    }
  }
  function cu(t, e, l, a) {
    Qe[hn++] = t, Qe[hn++] = e, Qe[hn++] = l, Qe[hn++] = a, _f |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Df(t, e, l, a) {
    return cu(t, e, l, a), ou(t);
  }
  function Ua(t, e) {
    return cu(t, null, null, e), ou(t);
  }
  function Zo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, i = t.return; i !== null; )
      i.childLanes |= l, a = i.alternate, a !== null && (a.childLanes |= l), i.tag === 22 && (t = i.stateNode, t === null || t._visibility & 1 || (n = !0)), t = i, i = i.return;
    return t.tag === 3 ? (i = t.stateNode, n && e !== null && (n = 31 - be(l), t = i.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), i) : null;
  }
  function ou(t) {
    if (50 < _i)
      throw _i = 0, jc = null, Error(h(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var gn = {};
  function Nm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function Ne(t, e, l, a) {
    return new Nm(t, e, l, a);
  }
  function Of(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function Sl(t, e) {
    var l = t.alternate;
    return l === null ? (l = Ne(
      t.tag,
      e,
      t.key,
      t.mode
    ), l.elementType = t.elementType, l.type = t.type, l.stateNode = t.stateNode, l.alternate = t, t.alternate = l) : (l.pendingProps = e, l.type = t.type, l.flags = 0, l.subtreeFlags = 0, l.deletions = null), l.flags = t.flags & 65011712, l.childLanes = t.childLanes, l.lanes = t.lanes, l.child = t.child, l.memoizedProps = t.memoizedProps, l.memoizedState = t.memoizedState, l.updateQueue = t.updateQueue, e = t.dependencies, l.dependencies = e === null ? null : { lanes: e.lanes, firstContext: e.firstContext }, l.sibling = t.sibling, l.index = t.index, l.ref = t.ref, l.refCleanup = t.refCleanup, l;
  }
  function Ko(t, e) {
    t.flags &= 65011714;
    var l = t.alternate;
    return l === null ? (t.childLanes = 0, t.lanes = e, t.child = null, t.subtreeFlags = 0, t.memoizedProps = null, t.memoizedState = null, t.updateQueue = null, t.dependencies = null, t.stateNode = null) : (t.childLanes = l.childLanes, t.lanes = l.lanes, t.child = l.child, t.subtreeFlags = 0, t.deletions = null, t.memoizedProps = l.memoizedProps, t.memoizedState = l.memoizedState, t.updateQueue = l.updateQueue, t.type = l.type, e = l.dependencies, t.dependencies = e === null ? null : {
      lanes: e.lanes,
      firstContext: e.firstContext
    }), t;
  }
  function ru(t, e, l, a, n, i) {
    var u = 0;
    if (a = t, typeof t == "function") Of(t) && (u = 1);
    else if (typeof t == "string")
      u = Gh(
        t,
        l,
        q.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case Pt:
          return t = Ne(31, l, e, n), t.elementType = Pt, t.lanes = i, t;
        case Wt:
          return Ba(l.children, n, i, e);
        case _t:
          u = 8, n |= 24;
          break;
        case ae:
          return t = Ne(12, l, e, n | 2), t.elementType = ae, t.lanes = i, t;
        case Kt:
          return t = Ne(13, l, e, n), t.elementType = Kt, t.lanes = i, t;
        case It:
          return t = Ne(19, l, e, n), t.elementType = It, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case Nt:
                u = 10;
                break t;
              case ve:
                u = 9;
                break t;
              case $t:
                u = 11;
                break t;
              case $:
                u = 14;
                break t;
              case ne:
                u = 16, a = null;
                break t;
            }
          u = 29, l = Error(
            h(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = Ne(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function Ba(t, e, l, a) {
    return t = Ne(7, t, a, e), t.lanes = l, t;
  }
  function Cf(t, e, l) {
    return t = Ne(6, t, null, e), t.lanes = l, t;
  }
  function Jo(t) {
    var e = Ne(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function Uf(t, e, l) {
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
  var ko = /* @__PURE__ */ new WeakMap();
  function Ve(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = ko.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Li(e)
      }, ko.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Li(e)
    };
  }
  var pn = [], vn = 0, su = null, ui = 0, Ze = [], Ke = 0, Ql = null, dl = 1, ml = "";
  function Tl(t, e) {
    pn[vn++] = ui, pn[vn++] = su, su = t, ui = e;
  }
  function Fo(t, e, l) {
    Ze[Ke++] = dl, Ze[Ke++] = ml, Ze[Ke++] = Ql, Ql = t;
    var a = dl;
    t = ml;
    var n = 32 - be(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - be(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, dl = 1 << 32 - be(e) + n | l << n | a, ml = i + t;
    } else
      dl = 1 << i | l << n | a, ml = t;
  }
  function Bf(t) {
    t.return !== null && (Tl(t, 1), Fo(t, 1, 0));
  }
  function Rf(t) {
    for (; t === su; )
      su = pn[--vn], pn[vn] = null, ui = pn[--vn], pn[vn] = null;
    for (; t === Ql; )
      Ql = Ze[--Ke], Ze[Ke] = null, ml = Ze[--Ke], Ze[Ke] = null, dl = Ze[--Ke], Ze[Ke] = null;
  }
  function Wo(t, e) {
    Ze[Ke++] = dl, Ze[Ke++] = ml, Ze[Ke++] = Ql, dl = e.id, ml = e.overflow, Ql = t;
  }
  var oe = null, Ot = null, dt = !1, Vl = null, Je = !1, Nf = Error(h(519));
  function Zl(t) {
    var e = Error(
      h(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw fi(Ve(e, t)), Nf;
  }
  function $o(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[Jt] = t, e[fe] = a, l) {
      case "dialog":
        ft("cancel", e), ft("close", e);
        break;
      case "iframe":
      case "object":
      case "embed":
        ft("load", e);
        break;
      case "video":
      case "audio":
        for (l = 0; l < Oi.length; l++)
          ft(Oi[l], e);
        break;
      case "source":
        ft("error", e);
        break;
      case "img":
      case "image":
      case "link":
        ft("error", e), ft("load", e);
        break;
      case "details":
        ft("toggle", e);
        break;
      case "input":
        ft("invalid", e), eu(
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
        ft("invalid", e);
        break;
      case "textarea":
        ft("invalid", e), C(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || hd(e.textContent, l) ? (a.popover != null && (ft("beforetoggle", e), ft("toggle", e)), a.onScroll != null && ft("scroll", e), a.onScrollEnd != null && ft("scrollend", e), a.onClick != null && (e.onclick = el), e = !0) : e = !1, e || Zl(t, !0);
  }
  function Io(t) {
    for (oe = t.return; oe; )
      switch (oe.tag) {
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
          oe = oe.return;
      }
  }
  function yn(t) {
    if (t !== oe) return !1;
    if (!dt) return Io(t), dt = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || Ic(t.type, t.memoizedProps)), l = !l), l && Ot && Zl(t), Io(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(h(317));
      Ot = zd(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(h(317));
      Ot = zd(t);
    } else
      e === 27 ? (e = Ot, ia(t.type) ? (t = ao, ao = null, Ot = t) : Ot = e) : Ot = oe ? Fe(t.stateNode.nextSibling) : null;
    return !0;
  }
  function Ra() {
    Ot = oe = null, dt = !1;
  }
  function wf() {
    var t = Vl;
    return t !== null && (_e === null ? _e = t : _e.push.apply(
      _e,
      t
    ), Vl = null), t;
  }
  function fi(t) {
    Vl === null ? Vl = [t] : Vl.push(t);
  }
  var Hf = d(null), Na = null, zl = null;
  function Kl(t, e, l) {
    B(Hf, e._currentValue), e._currentValue = l;
  }
  function Ml(t) {
    t._currentValue = Hf.current, z(Hf);
  }
  function jf(t, e, l) {
    for (; t !== null; ) {
      var a = t.alternate;
      if ((t.childLanes & e) !== e ? (t.childLanes |= e, a !== null && (a.childLanes |= e)) : a !== null && (a.childLanes & e) !== e && (a.childLanes |= e), t === l) break;
      t = t.return;
    }
  }
  function qf(t, e, l, a) {
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
              i.lanes |= l, f = i.alternate, f !== null && (f.lanes |= l), jf(
                i.return,
                l,
                t
              ), a || (u = null);
              break t;
            }
          i = f.next;
        }
      } else if (n.tag === 18) {
        if (u = n.return, u === null) throw Error(h(341));
        u.lanes |= l, i = u.alternate, i !== null && (i.lanes |= l), jf(u, l, t), u = null;
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
        if (u === null) throw Error(h(387));
        if (u = u.memoizedProps, u !== null) {
          var f = n.type;
          Re(n.pendingProps.value, u.value) || (t !== null ? t.push(f) : t = [f]);
        }
      } else if (n === mt.current) {
        if (u = n.alternate, u === null) throw Error(h(387));
        u.memoizedState.memoizedState !== n.memoizedState.memoizedState && (t !== null ? t.push(Ni) : t = [Ni]);
      }
      n = n.return;
    }
    t !== null && qf(
      e,
      t,
      l,
      a
    ), e.flags |= 262144;
  }
  function du(t) {
    for (t = t.firstContext; t !== null; ) {
      if (!Re(
        t.context._currentValue,
        t.memoizedValue
      ))
        return !0;
      t = t.next;
    }
    return !1;
  }
  function wa(t) {
    Na = t, zl = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function re(t) {
    return Po(Na, t);
  }
  function mu(t, e) {
    return Na === null && wa(t), Po(t, e);
  }
  function Po(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, zl === null) {
      if (t === null) throw Error(h(308));
      zl = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else zl = zl.next = e;
    return l;
  }
  var wm = typeof AbortController < "u" ? AbortController : function() {
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
  }, Hm = A.unstable_scheduleCallback, jm = A.unstable_NormalPriority, Xt = {
    $$typeof: Nt,
    Consumer: null,
    Provider: null,
    _currentValue: null,
    _currentValue2: null,
    _threadCount: 0
  };
  function Gf() {
    return {
      controller: new wm(),
      data: /* @__PURE__ */ new Map(),
      refCount: 0
    };
  }
  function ci(t) {
    t.refCount--, t.refCount === 0 && Hm(jm, function() {
      t.controller.abort();
    });
  }
  var oi = null, Yf = 0, xn = 0, Sn = null;
  function qm(t, e) {
    if (oi === null) {
      var l = oi = [];
      Yf = 0, xn = Qc(), Sn = {
        status: "pending",
        value: void 0,
        then: function(a) {
          l.push(a);
        }
      };
    }
    return Yf++, e.then(tr, tr), e;
  }
  function tr() {
    if (--Yf === 0 && oi !== null) {
      Sn !== null && (Sn.status = "fulfilled");
      var t = oi;
      oi = null, xn = 0, Sn = null;
      for (var e = 0; e < t.length; e++) (0, t[e])();
    }
  }
  function Gm(t, e) {
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
  var er = b.S;
  b.S = function(t, e) {
    qs = he(), typeof e == "object" && e !== null && typeof e.then == "function" && qm(t, e), er !== null && er(t, e);
  };
  var Ha = d(null);
  function Lf() {
    var t = Ha.current;
    return t !== null ? t : At.pooledCache;
  }
  function hu(t, e) {
    e === null ? B(Ha, Ha.current) : B(Ha, e.pool);
  }
  function lr() {
    var t = Lf();
    return t === null ? null : { parent: Xt._currentValue, pool: t };
  }
  var Tn = Error(h(460)), Xf = Error(h(474)), gu = Error(h(542)), pu = { then: function() {
  } };
  function ar(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function nr(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(el, el), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, ur(t), t;
      default:
        if (typeof e.status == "string") e.then(el, el);
        else {
          if (t = At, t !== null && 100 < t.shellSuspendCounter)
            throw Error(h(482));
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
            throw t = e.reason, ur(t), t;
        }
        throw qa = e, Tn;
    }
  }
  function ja(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (qa = l, Tn) : l;
    }
  }
  var qa = null;
  function ir() {
    if (qa === null) throw Error(h(459));
    var t = qa;
    return qa = null, t;
  }
  function ur(t) {
    if (t === Tn || t === gu)
      throw Error(h(483));
  }
  var zn = null, ri = 0;
  function vu(t) {
    var e = ri;
    return ri += 1, zn === null && (zn = []), nr(zn, t, e);
  }
  function si(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function yu(t, e) {
    throw e.$$typeof === yt ? Error(h(525)) : (t = Object.prototype.toString.call(e), Error(
      h(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function fr(t) {
    function e(m, s) {
      if (t) {
        var g = m.deletions;
        g === null ? (m.deletions = [s], m.flags |= 16) : g.push(s);
      }
    }
    function l(m, s) {
      if (!t) return null;
      for (; s !== null; )
        e(m, s), s = s.sibling;
      return null;
    }
    function a(m) {
      for (var s = /* @__PURE__ */ new Map(); m !== null; )
        m.key !== null ? s.set(m.key, m) : s.set(m.index, m), m = m.sibling;
      return s;
    }
    function n(m, s) {
      return m = Sl(m, s), m.index = 0, m.sibling = null, m;
    }
    function i(m, s, g) {
      return m.index = g, t ? (g = m.alternate, g !== null ? (g = g.index, g < s ? (m.flags |= 67108866, s) : g) : (m.flags |= 67108866, s)) : (m.flags |= 1048576, s);
    }
    function u(m) {
      return t && m.alternate === null && (m.flags |= 67108866), m;
    }
    function f(m, s, g, T) {
      return s === null || s.tag !== 6 ? (s = Cf(g, m.mode, T), s.return = m, s) : (s = n(s, g), s.return = m, s);
    }
    function r(m, s, g, T) {
      var V = g.type;
      return V === Wt ? S(
        m,
        s,
        g.props.children,
        T,
        g.key
      ) : s !== null && (s.elementType === V || typeof V == "object" && V !== null && V.$$typeof === ne && ja(V) === s.type) ? (s = n(s, g.props), si(s, g), s.return = m, s) : (s = ru(
        g.type,
        g.key,
        g.props,
        null,
        m.mode,
        T
      ), si(s, g), s.return = m, s);
    }
    function p(m, s, g, T) {
      return s === null || s.tag !== 4 || s.stateNode.containerInfo !== g.containerInfo || s.stateNode.implementation !== g.implementation ? (s = Uf(g, m.mode, T), s.return = m, s) : (s = n(s, g.children || []), s.return = m, s);
    }
    function S(m, s, g, T, V) {
      return s === null || s.tag !== 7 ? (s = Ba(
        g,
        m.mode,
        T,
        V
      ), s.return = m, s) : (s = n(s, g), s.return = m, s);
    }
    function E(m, s, g) {
      if (typeof s == "string" && s !== "" || typeof s == "number" || typeof s == "bigint")
        return s = Cf(
          "" + s,
          m.mode,
          g
        ), s.return = m, s;
      if (typeof s == "object" && s !== null) {
        switch (s.$$typeof) {
          case pe:
            return g = ru(
              s.type,
              s.key,
              s.props,
              null,
              m.mode,
              g
            ), si(g, s), g.return = m, g;
          case me:
            return s = Uf(
              s,
              m.mode,
              g
            ), s.return = m, s;
          case ne:
            return s = ja(s), E(m, s, g);
        }
        if (H(s) || ie(s))
          return s = Ba(
            s,
            m.mode,
            g,
            null
          ), s.return = m, s;
        if (typeof s.then == "function")
          return E(m, vu(s), g);
        if (s.$$typeof === Nt)
          return E(
            m,
            mu(m, s),
            g
          );
        yu(m, s);
      }
      return null;
    }
    function v(m, s, g, T) {
      var V = s !== null ? s.key : null;
      if (typeof g == "string" && g !== "" || typeof g == "number" || typeof g == "bigint")
        return V !== null ? null : f(m, s, "" + g, T);
      if (typeof g == "object" && g !== null) {
        switch (g.$$typeof) {
          case pe:
            return g.key === V ? r(m, s, g, T) : null;
          case me:
            return g.key === V ? p(m, s, g, T) : null;
          case ne:
            return g = ja(g), v(m, s, g, T);
        }
        if (H(g) || ie(g))
          return V !== null ? null : S(m, s, g, T, null);
        if (typeof g.then == "function")
          return v(
            m,
            s,
            vu(g),
            T
          );
        if (g.$$typeof === Nt)
          return v(
            m,
            s,
            mu(m, g),
            T
          );
        yu(m, g);
      }
      return null;
    }
    function x(m, s, g, T, V) {
      if (typeof T == "string" && T !== "" || typeof T == "number" || typeof T == "bigint")
        return m = m.get(g) || null, f(s, m, "" + T, V);
      if (typeof T == "object" && T !== null) {
        switch (T.$$typeof) {
          case pe:
            return m = m.get(
              T.key === null ? g : T.key
            ) || null, r(s, m, T, V);
          case me:
            return m = m.get(
              T.key === null ? g : T.key
            ) || null, p(s, m, T, V);
          case ne:
            return T = ja(T), x(
              m,
              s,
              g,
              T,
              V
            );
        }
        if (H(T) || ie(T))
          return m = m.get(g) || null, S(s, m, T, V, null);
        if (typeof T.then == "function")
          return x(
            m,
            s,
            g,
            vu(T),
            V
          );
        if (T.$$typeof === Nt)
          return x(
            m,
            s,
            g,
            mu(s, T),
            V
          );
        yu(s, T);
      }
      return null;
    }
    function G(m, s, g, T) {
      for (var V = null, pt = null, Y = s, nt = s = 0, rt = null; Y !== null && nt < g.length; nt++) {
        Y.index > nt ? (rt = Y, Y = null) : rt = Y.sibling;
        var vt = v(
          m,
          Y,
          g[nt],
          T
        );
        if (vt === null) {
          Y === null && (Y = rt);
          break;
        }
        t && Y && vt.alternate === null && e(m, Y), s = i(vt, s, nt), pt === null ? V = vt : pt.sibling = vt, pt = vt, Y = rt;
      }
      if (nt === g.length)
        return l(m, Y), dt && Tl(m, nt), V;
      if (Y === null) {
        for (; nt < g.length; nt++)
          Y = E(m, g[nt], T), Y !== null && (s = i(
            Y,
            s,
            nt
          ), pt === null ? V = Y : pt.sibling = Y, pt = Y);
        return dt && Tl(m, nt), V;
      }
      for (Y = a(Y); nt < g.length; nt++)
        rt = x(
          Y,
          m,
          nt,
          g[nt],
          T
        ), rt !== null && (t && rt.alternate !== null && Y.delete(
          rt.key === null ? nt : rt.key
        ), s = i(
          rt,
          s,
          nt
        ), pt === null ? V = rt : pt.sibling = rt, pt = rt);
      return t && Y.forEach(function(ra) {
        return e(m, ra);
      }), dt && Tl(m, nt), V;
    }
    function Z(m, s, g, T) {
      if (g == null) throw Error(h(151));
      for (var V = null, pt = null, Y = s, nt = s = 0, rt = null, vt = g.next(); Y !== null && !vt.done; nt++, vt = g.next()) {
        Y.index > nt ? (rt = Y, Y = null) : rt = Y.sibling;
        var ra = v(m, Y, vt.value, T);
        if (ra === null) {
          Y === null && (Y = rt);
          break;
        }
        t && Y && ra.alternate === null && e(m, Y), s = i(ra, s, nt), pt === null ? V = ra : pt.sibling = ra, pt = ra, Y = rt;
      }
      if (vt.done)
        return l(m, Y), dt && Tl(m, nt), V;
      if (Y === null) {
        for (; !vt.done; nt++, vt = g.next())
          vt = E(m, vt.value, T), vt !== null && (s = i(vt, s, nt), pt === null ? V = vt : pt.sibling = vt, pt = vt);
        return dt && Tl(m, nt), V;
      }
      for (Y = a(Y); !vt.done; nt++, vt = g.next())
        vt = x(Y, m, nt, vt.value, T), vt !== null && (t && vt.alternate !== null && Y.delete(vt.key === null ? nt : vt.key), s = i(vt, s, nt), pt === null ? V = vt : pt.sibling = vt, pt = vt);
      return t && Y.forEach(function(Wh) {
        return e(m, Wh);
      }), dt && Tl(m, nt), V;
    }
    function Et(m, s, g, T) {
      if (typeof g == "object" && g !== null && g.type === Wt && g.key === null && (g = g.props.children), typeof g == "object" && g !== null) {
        switch (g.$$typeof) {
          case pe:
            t: {
              for (var V = g.key; s !== null; ) {
                if (s.key === V) {
                  if (V = g.type, V === Wt) {
                    if (s.tag === 7) {
                      l(
                        m,
                        s.sibling
                      ), T = n(
                        s,
                        g.props.children
                      ), T.return = m, m = T;
                      break t;
                    }
                  } else if (s.elementType === V || typeof V == "object" && V !== null && V.$$typeof === ne && ja(V) === s.type) {
                    l(
                      m,
                      s.sibling
                    ), T = n(s, g.props), si(T, g), T.return = m, m = T;
                    break t;
                  }
                  l(m, s);
                  break;
                } else e(m, s);
                s = s.sibling;
              }
              g.type === Wt ? (T = Ba(
                g.props.children,
                m.mode,
                T,
                g.key
              ), T.return = m, m = T) : (T = ru(
                g.type,
                g.key,
                g.props,
                null,
                m.mode,
                T
              ), si(T, g), T.return = m, m = T);
            }
            return u(m);
          case me:
            t: {
              for (V = g.key; s !== null; ) {
                if (s.key === V)
                  if (s.tag === 4 && s.stateNode.containerInfo === g.containerInfo && s.stateNode.implementation === g.implementation) {
                    l(
                      m,
                      s.sibling
                    ), T = n(s, g.children || []), T.return = m, m = T;
                    break t;
                  } else {
                    l(m, s);
                    break;
                  }
                else e(m, s);
                s = s.sibling;
              }
              T = Uf(g, m.mode, T), T.return = m, m = T;
            }
            return u(m);
          case ne:
            return g = ja(g), Et(
              m,
              s,
              g,
              T
            );
        }
        if (H(g))
          return G(
            m,
            s,
            g,
            T
          );
        if (ie(g)) {
          if (V = ie(g), typeof V != "function") throw Error(h(150));
          return g = V.call(g), Z(
            m,
            s,
            g,
            T
          );
        }
        if (typeof g.then == "function")
          return Et(
            m,
            s,
            vu(g),
            T
          );
        if (g.$$typeof === Nt)
          return Et(
            m,
            s,
            mu(m, g),
            T
          );
        yu(m, g);
      }
      return typeof g == "string" && g !== "" || typeof g == "number" || typeof g == "bigint" ? (g = "" + g, s !== null && s.tag === 6 ? (l(m, s.sibling), T = n(s, g), T.return = m, m = T) : (l(m, s), T = Cf(g, m.mode, T), T.return = m, m = T), u(m)) : l(m, s);
    }
    return function(m, s, g, T) {
      try {
        ri = 0;
        var V = Et(
          m,
          s,
          g,
          T
        );
        return zn = null, V;
      } catch (Y) {
        if (Y === Tn || Y === gu) throw Y;
        var pt = Ne(29, Y, null, m.mode);
        return pt.lanes = T, pt.return = m, pt;
      }
    };
  }
  var Ga = fr(!0), cr = fr(!1), Jl = !1;
  function Qf(t) {
    t.updateQueue = {
      baseState: t.memoizedState,
      firstBaseUpdate: null,
      lastBaseUpdate: null,
      shared: { pending: null, lanes: 0, hiddenCallbacks: null },
      callbacks: null
    };
  }
  function Vf(t, e) {
    t = t.updateQueue, e.updateQueue === t && (e.updateQueue = {
      baseState: t.baseState,
      firstBaseUpdate: t.firstBaseUpdate,
      lastBaseUpdate: t.lastBaseUpdate,
      shared: t.shared,
      callbacks: null
    });
  }
  function kl(t) {
    return { lane: t, tag: 0, payload: null, callback: null, next: null };
  }
  function Fl(t, e, l) {
    var a = t.updateQueue;
    if (a === null) return null;
    if (a = a.shared, (xt & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = ou(t), Zo(t, null, l), e;
    }
    return cu(t, a, e, l), ou(t);
  }
  function di(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Ki(t, l);
    }
  }
  function Zf(t, e) {
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
  var Kf = !1;
  function mi() {
    if (Kf) {
      var t = Sn;
      if (t !== null) throw t;
    }
  }
  function hi(t, e, l, a) {
    Kf = !1;
    var n = t.updateQueue;
    Jl = !1;
    var i = n.firstBaseUpdate, u = n.lastBaseUpdate, f = n.shared.pending;
    if (f !== null) {
      n.shared.pending = null;
      var r = f, p = r.next;
      r.next = null, u === null ? i = p : u.next = p, u = r;
      var S = t.alternate;
      S !== null && (S = S.updateQueue, f = S.lastBaseUpdate, f !== u && (f === null ? S.firstBaseUpdate = p : f.next = p, S.lastBaseUpdate = r));
    }
    if (i !== null) {
      var E = n.baseState;
      u = 0, S = p = r = null, f = i;
      do {
        var v = f.lane & -536870913, x = v !== f.lane;
        if (x ? (ot & v) === v : (a & v) === v) {
          v !== 0 && v === xn && (Kf = !0), S !== null && (S = S.next = {
            lane: 0,
            tag: f.tag,
            payload: f.payload,
            callback: null,
            next: null
          });
          t: {
            var G = t, Z = f;
            v = e;
            var Et = l;
            switch (Z.tag) {
              case 1:
                if (G = Z.payload, typeof G == "function") {
                  E = G.call(Et, E, v);
                  break t;
                }
                E = G;
                break t;
              case 3:
                G.flags = G.flags & -65537 | 128;
              case 0:
                if (G = Z.payload, v = typeof G == "function" ? G.call(Et, E, v) : G, v == null) break t;
                E = K({}, E, v);
                break t;
              case 2:
                Jl = !0;
            }
          }
          v = f.callback, v !== null && (t.flags |= 64, x && (t.flags |= 8192), x = n.callbacks, x === null ? n.callbacks = [v] : x.push(v));
        } else
          x = {
            lane: v,
            tag: f.tag,
            payload: f.payload,
            callback: f.callback,
            next: null
          }, S === null ? (p = S = x, r = E) : S = S.next = x, u |= v;
        if (f = f.next, f === null) {
          if (f = n.shared.pending, f === null)
            break;
          x = f, f = x.next, x.next = null, n.lastBaseUpdate = x, n.shared.pending = null;
        }
      } while (!0);
      S === null && (r = E), n.baseState = r, n.firstBaseUpdate = p, n.lastBaseUpdate = S, i === null && (n.shared.lanes = 0), ta |= u, t.lanes = u, t.memoizedState = E;
    }
  }
  function or(t, e) {
    if (typeof t != "function")
      throw Error(h(191, t));
    t.call(e);
  }
  function rr(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        or(l[t], e);
  }
  var Mn = d(null), bu = d(0);
  function sr(t, e) {
    t = Rl, B(bu, t), B(Mn, e), Rl = t | e.baseLanes;
  }
  function Jf() {
    B(bu, Rl), B(Mn, Mn.current);
  }
  function kf() {
    Rl = bu.current, z(Mn), z(bu);
  }
  var we = d(null), ke = null;
  function Wl(t) {
    var e = t.alternate;
    B(Yt, Yt.current & 1), B(we, t), ke === null && (e === null || Mn.current !== null || e.memoizedState !== null) && (ke = t);
  }
  function Ff(t) {
    B(Yt, Yt.current), B(we, t), ke === null && (ke = t);
  }
  function dr(t) {
    t.tag === 22 ? (B(Yt, Yt.current), B(we, t), ke === null && (ke = t)) : $l();
  }
  function $l() {
    B(Yt, Yt.current), B(we, we.current);
  }
  function He(t) {
    z(we), ke === t && (ke = null), z(Yt);
  }
  var Yt = d(0);
  function xu(t) {
    for (var e = t; e !== null; ) {
      if (e.tag === 13) {
        var l = e.memoizedState;
        if (l !== null && (l = l.dehydrated, l === null || eo(l) || lo(l)))
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
  var El = 0, lt = null, zt = null, Qt = null, Su = !1, En = !1, Ya = !1, Tu = 0, gi = 0, An = null, Ym = 0;
  function jt() {
    throw Error(h(321));
  }
  function Wf(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!Re(t[l], e[l])) return !1;
    return !0;
  }
  function $f(t, e, l, a, n, i) {
    return El = i, lt = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, b.H = t === null || t.memoizedState === null ? Fr : dc, Ya = !1, i = l(a, n), Ya = !1, En && (i = hr(
      e,
      l,
      a,
      n
    )), mr(t), i;
  }
  function mr(t) {
    b.H = yi;
    var e = zt !== null && zt.next !== null;
    if (El = 0, Qt = zt = lt = null, Su = !1, gi = 0, An = null, e) throw Error(h(300));
    t === null || Vt || (t = t.dependencies, t !== null && du(t) && (Vt = !0));
  }
  function hr(t, e, l, a) {
    lt = t;
    var n = 0;
    do {
      if (En && (An = null), gi = 0, En = !1, 25 <= n) throw Error(h(301));
      if (n += 1, Qt = zt = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      b.H = Wr, i = e(l, a);
    } while (En);
    return i;
  }
  function Lm() {
    var t = b.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? pi(e) : e, t = t.useState()[0], (zt !== null ? zt.memoizedState : null) !== t && (lt.flags |= 1024), e;
  }
  function If() {
    var t = Tu !== 0;
    return Tu = 0, t;
  }
  function Pf(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function tc(t) {
    if (Su) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      Su = !1;
    }
    El = 0, Qt = zt = lt = null, En = !1, gi = Tu = 0, An = null;
  }
  function Te() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return Qt === null ? lt.memoizedState = Qt = t : Qt = Qt.next = t, Qt;
  }
  function Lt() {
    if (zt === null) {
      var t = lt.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = zt.next;
    var e = Qt === null ? lt.memoizedState : Qt.next;
    if (e !== null)
      Qt = e, zt = t;
    else {
      if (t === null)
        throw lt.alternate === null ? Error(h(467)) : Error(h(310));
      zt = t, t = {
        memoizedState: zt.memoizedState,
        baseState: zt.baseState,
        baseQueue: zt.baseQueue,
        queue: zt.queue,
        next: null
      }, Qt === null ? lt.memoizedState = Qt = t : Qt = Qt.next = t;
    }
    return Qt;
  }
  function zu() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function pi(t) {
    var e = gi;
    return gi += 1, An === null && (An = []), t = nr(An, t, e), e = lt, (Qt === null ? e.memoizedState : Qt.next) === null && (e = e.alternate, b.H = e === null || e.memoizedState === null ? Fr : dc), t;
  }
  function Mu(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return pi(t);
      if (t.$$typeof === Nt) return re(t);
    }
    throw Error(h(438, String(t)));
  }
  function ec(t) {
    var e = null, l = lt.updateQueue;
    if (l !== null && (e = l.memoCache), e == null) {
      var a = lt.alternate;
      a !== null && (a = a.updateQueue, a !== null && (a = a.memoCache, a != null && (e = {
        data: a.data.map(function(n) {
          return n.slice();
        }),
        index: 0
      })));
    }
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = zu(), lt.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = Ye;
    return e.index++, l;
  }
  function Al(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function Eu(t) {
    var e = Lt();
    return lc(e, zt, t);
  }
  function lc(t, e, l) {
    var a = t.queue;
    if (a === null) throw Error(h(311));
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
      var f = u = null, r = null, p = e, S = !1;
      do {
        var E = p.lane & -536870913;
        if (E !== p.lane ? (ot & E) === E : (El & E) === E) {
          var v = p.revertLane;
          if (v === 0)
            r !== null && (r = r.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: p.action,
              hasEagerState: p.hasEagerState,
              eagerState: p.eagerState,
              next: null
            }), E === xn && (S = !0);
          else if ((El & v) === v) {
            p = p.next, v === xn && (S = !0);
            continue;
          } else
            E = {
              lane: 0,
              revertLane: p.revertLane,
              gesture: null,
              action: p.action,
              hasEagerState: p.hasEagerState,
              eagerState: p.eagerState,
              next: null
            }, r === null ? (f = r = E, u = i) : r = r.next = E, lt.lanes |= v, ta |= v;
          E = p.action, Ya && l(i, E), i = p.hasEagerState ? p.eagerState : l(i, E);
        } else
          v = {
            lane: E,
            revertLane: p.revertLane,
            gesture: p.gesture,
            action: p.action,
            hasEagerState: p.hasEagerState,
            eagerState: p.eagerState,
            next: null
          }, r === null ? (f = r = v, u = i) : r = r.next = v, lt.lanes |= E, ta |= E;
        p = p.next;
      } while (p !== null && p !== e);
      if (r === null ? u = i : r.next = f, !Re(i, t.memoizedState) && (Vt = !0, S && (l = Sn, l !== null)))
        throw l;
      t.memoizedState = i, t.baseState = u, t.baseQueue = r, a.lastRenderedState = i;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function ac(t) {
    var e = Lt(), l = e.queue;
    if (l === null) throw Error(h(311));
    l.lastRenderedReducer = t;
    var a = l.dispatch, n = l.pending, i = e.memoizedState;
    if (n !== null) {
      l.pending = null;
      var u = n = n.next;
      do
        i = t(i, u.action), u = u.next;
      while (u !== n);
      Re(i, e.memoizedState) || (Vt = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function gr(t, e, l) {
    var a = lt, n = Lt(), i = dt;
    if (i) {
      if (l === void 0) throw Error(h(407));
      l = l();
    } else l = e();
    var u = !Re(
      (zt || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, Vt = !0), n = n.queue, uc(yr.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || Qt !== null && Qt.memoizedState.tag & 1) {
      if (a.flags |= 2048, _n(
        9,
        { destroy: void 0 },
        vr.bind(
          null,
          a,
          n,
          l,
          e
        ),
        null
      ), At === null) throw Error(h(349));
      i || (El & 127) !== 0 || pr(a, e, l);
    }
    return l;
  }
  function pr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = lt.updateQueue, e === null ? (e = zu(), lt.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
  }
  function vr(t, e, l, a) {
    e.value = l, e.getSnapshot = a, br(e) && xr(t);
  }
  function yr(t, e, l) {
    return l(function() {
      br(e) && xr(t);
    });
  }
  function br(t) {
    var e = t.getSnapshot;
    t = t.value;
    try {
      var l = e();
      return !Re(t, l);
    } catch {
      return !0;
    }
  }
  function xr(t) {
    var e = Ua(t, 2);
    e !== null && De(e, t, 2);
  }
  function nc(t) {
    var e = Te();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Ya) {
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
      lastRenderedReducer: Al,
      lastRenderedState: t
    }, e;
  }
  function Sr(t, e, l, a) {
    return t.baseState = l, lc(
      t,
      zt,
      typeof a == "function" ? a : Al
    );
  }
  function Xm(t, e, l, a, n) {
    if (Du(t)) throw Error(h(485));
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
      b.T !== null ? l(!0) : i.isTransition = !1, a(i), l = e.pending, l === null ? (i.next = e.pending = i, Tr(e, i)) : (i.next = l.next, e.pending = l.next = i);
    }
  }
  function Tr(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var i = b.T, u = {};
      b.T = u;
      try {
        var f = l(n, a), r = b.S;
        r !== null && r(u, f), zr(t, e, f);
      } catch (p) {
        ic(t, e, p);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), b.T = i;
      }
    } else
      try {
        i = l(n, a), zr(t, e, i);
      } catch (p) {
        ic(t, e, p);
      }
  }
  function zr(t, e, l) {
    l !== null && typeof l == "object" && typeof l.then == "function" ? l.then(
      function(a) {
        Mr(t, e, a);
      },
      function(a) {
        return ic(t, e, a);
      }
    ) : Mr(t, e, l);
  }
  function Mr(t, e, l) {
    e.status = "fulfilled", e.value = l, Er(e), t.state = l, e = t.pending, e !== null && (l = e.next, l === e ? t.pending = null : (l = l.next, e.next = l, Tr(t, l)));
  }
  function ic(t, e, l) {
    var a = t.pending;
    if (t.pending = null, a !== null) {
      a = a.next;
      do
        e.status = "rejected", e.reason = l, Er(e), e = e.next;
      while (e !== a);
    }
    t.action = null;
  }
  function Er(t) {
    t = t.listeners;
    for (var e = 0; e < t.length; e++) (0, t[e])();
  }
  function Ar(t, e) {
    return e;
  }
  function _r(t, e) {
    if (dt) {
      var l = At.formState;
      if (l !== null) {
        t: {
          var a = lt;
          if (dt) {
            if (Ot) {
              e: {
                for (var n = Ot, i = Je; n.nodeType !== 8; ) {
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
                Ot = Fe(
                  n.nextSibling
                ), a = n.data === "F!";
                break t;
              }
            }
            Zl(a);
          }
          a = !1;
        }
        a && (e = l[0]);
      }
    }
    return l = Te(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Ar,
      lastRenderedState: e
    }, l.queue = a, l = Kr.bind(
      null,
      lt,
      a
    ), a.dispatch = l, a = nc(!1), i = sc.bind(
      null,
      lt,
      !1,
      a.queue
    ), a = Te(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = Xm.bind(
      null,
      lt,
      n,
      i,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Dr(t) {
    var e = Lt();
    return Or(e, zt, t);
  }
  function Or(t, e, l) {
    if (e = lc(
      t,
      e,
      Ar
    )[0], t = Eu(Al)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = pi(e);
      } catch (u) {
        throw u === Tn ? gu : u;
      }
    else a = e;
    e = Lt();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (lt.flags |= 2048, _n(
      9,
      { destroy: void 0 },
      Qm.bind(null, n, l),
      null
    )), [a, i, t];
  }
  function Qm(t, e) {
    t.action = e;
  }
  function Cr(t) {
    var e = Lt(), l = zt;
    if (l !== null)
      return Or(e, l, t);
    Lt(), e = e.memoizedState, l = Lt();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function _n(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = lt.updateQueue, e === null && (e = zu(), lt.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Ur() {
    return Lt().memoizedState;
  }
  function Au(t, e, l, a) {
    var n = Te();
    lt.flags |= t, n.memoizedState = _n(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function _u(t, e, l, a) {
    var n = Lt();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    zt !== null && a !== null && Wf(a, zt.memoizedState.deps) ? n.memoizedState = _n(e, i, l, a) : (lt.flags |= t, n.memoizedState = _n(
      1 | e,
      i,
      l,
      a
    ));
  }
  function Br(t, e) {
    Au(8390656, 8, t, e);
  }
  function uc(t, e) {
    _u(2048, 8, t, e);
  }
  function Vm(t) {
    lt.flags |= 4;
    var e = lt.updateQueue;
    if (e === null)
      e = zu(), lt.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function Rr(t) {
    var e = Lt().memoizedState;
    return Vm({ ref: e, nextImpl: t }), function() {
      if ((xt & 2) !== 0) throw Error(h(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function Nr(t, e) {
    return _u(4, 2, t, e);
  }
  function wr(t, e) {
    return _u(4, 4, t, e);
  }
  function Hr(t, e) {
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
  function jr(t, e, l) {
    l = l != null ? l.concat([t]) : null, _u(4, 4, Hr.bind(null, e, t), l);
  }
  function fc() {
  }
  function qr(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && Wf(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Gr(t, e) {
    var l = Lt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && Wf(e, a[1]))
      return a[0];
    if (a = t(), Ya) {
      ul(!0);
      try {
        t();
      } finally {
        ul(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function cc(t, e, l) {
    return l === void 0 || (El & 1073741824) !== 0 && (ot & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Ys(), lt.lanes |= t, ta |= t, l);
  }
  function Yr(t, e, l, a) {
    return Re(l, e) ? l : Mn.current !== null ? (t = cc(t, l, a), Re(t, e) || (Vt = !0), t) : (El & 42) === 0 || (El & 1073741824) !== 0 && (ot & 261930) === 0 ? (Vt = !0, t.memoizedState = l) : (t = Ys(), lt.lanes |= t, ta |= t, e);
  }
  function Lr(t, e, l, a, n) {
    var i = U.p;
    U.p = i !== 0 && 8 > i ? i : 8;
    var u = b.T, f = {};
    b.T = f, sc(t, !1, e, l);
    try {
      var r = n(), p = b.S;
      if (p !== null && p(f, r), r !== null && typeof r == "object" && typeof r.then == "function") {
        var S = Gm(
          r,
          a
        );
        vi(
          t,
          e,
          S,
          Ge(t)
        );
      } else
        vi(
          t,
          e,
          a,
          Ge(t)
        );
    } catch (E) {
      vi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: E },
        Ge()
      );
    } finally {
      U.p = i, u !== null && f.types !== null && (u.types = f.types), b.T = u;
    }
  }
  function Zm() {
  }
  function oc(t, e, l, a) {
    if (t.tag !== 5) throw Error(h(476));
    var n = Xr(t).queue;
    Lr(
      t,
      n,
      e,
      N,
      l === null ? Zm : function() {
        return Qr(t), l(a);
      }
    );
  }
  function Xr(t) {
    var e = t.memoizedState;
    if (e !== null) return e;
    e = {
      memoizedState: N,
      baseState: N,
      baseQueue: null,
      queue: {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: Al,
        lastRenderedState: N
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
        lastRenderedReducer: Al,
        lastRenderedState: l
      },
      next: null
    }, t.memoizedState = e, t = t.alternate, t !== null && (t.memoizedState = e), e;
  }
  function Qr(t) {
    var e = Xr(t);
    e.next === null && (e = t.alternate.memoizedState), vi(
      t,
      e.next.queue,
      {},
      Ge()
    );
  }
  function rc() {
    return re(Ni);
  }
  function Vr() {
    return Lt().memoizedState;
  }
  function Zr() {
    return Lt().memoizedState;
  }
  function Km(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = Ge();
          t = kl(l);
          var a = Fl(e, t, l);
          a !== null && (De(a, e, l), di(a, e, l)), e = { cache: Gf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function Jm(t, e, l) {
    var a = Ge();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Du(t) ? Jr(e, l) : (l = Df(t, e, l, a), l !== null && (De(l, t, a), kr(l, e, a)));
  }
  function Kr(t, e, l) {
    var a = Ge();
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
    if (Du(t)) Jr(e, n);
    else {
      var i = t.alternate;
      if (t.lanes === 0 && (i === null || i.lanes === 0) && (i = e.lastRenderedReducer, i !== null))
        try {
          var u = e.lastRenderedState, f = i(u, l);
          if (n.hasEagerState = !0, n.eagerState = f, Re(f, u))
            return cu(t, e, n, 0), At === null && fu(), !1;
        } catch {
        }
      if (l = Df(t, e, n, a), l !== null)
        return De(l, t, a), kr(l, e, a), !0;
    }
    return !1;
  }
  function sc(t, e, l, a) {
    if (a = {
      lane: 2,
      revertLane: Qc(),
      gesture: null,
      action: a,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Du(t)) {
      if (e) throw Error(h(479));
    } else
      e = Df(
        t,
        l,
        a,
        2
      ), e !== null && De(e, t, 2);
  }
  function Du(t) {
    var e = t.alternate;
    return t === lt || e !== null && e === lt;
  }
  function Jr(t, e) {
    En = Su = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function kr(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Ki(t, l);
    }
  }
  var yi = {
    readContext: re,
    use: Mu,
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
  var Fr = {
    readContext: re,
    use: Mu,
    useCallback: function(t, e) {
      return Te().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: re,
    useEffect: Br,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, Au(
        4194308,
        4,
        Hr.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return Au(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      Au(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = Te();
      e = e === void 0 ? null : e;
      var a = t();
      if (Ya) {
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
      var a = Te();
      if (l !== void 0) {
        var n = l(e);
        if (Ya) {
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
      }, a.queue = t, t = t.dispatch = Jm.bind(
        null,
        lt,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = Te();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = nc(t);
      var e = t.queue, l = Kr.bind(null, lt, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: fc,
    useDeferredValue: function(t, e) {
      var l = Te();
      return cc(l, t, e);
    },
    useTransition: function() {
      var t = nc(!1);
      return t = Lr.bind(
        null,
        lt,
        t.queue,
        !0,
        !1
      ), Te().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = lt, n = Te();
      if (dt) {
        if (l === void 0)
          throw Error(h(407));
        l = l();
      } else {
        if (l = e(), At === null)
          throw Error(h(349));
        (ot & 127) !== 0 || pr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, Br(yr.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, _n(
        9,
        { destroy: void 0 },
        vr.bind(
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
      var t = Te(), e = At.identifierPrefix;
      if (dt) {
        var l = ml, a = dl;
        l = (a & ~(1 << 32 - be(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = Tu++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Ym++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: rc,
    useFormState: _r,
    useActionState: _r,
    useOptimistic: function(t) {
      var e = Te();
      e.memoizedState = e.baseState = t;
      var l = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: null,
        lastRenderedState: null
      };
      return e.queue = l, e = sc.bind(
        null,
        lt,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: ec,
    useCacheRefresh: function() {
      return Te().memoizedState = Km.bind(
        null,
        lt
      );
    },
    useEffectEvent: function(t) {
      var e = Te(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((xt & 2) !== 0)
          throw Error(h(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, dc = {
    readContext: re,
    use: Mu,
    useCallback: qr,
    useContext: re,
    useEffect: uc,
    useImperativeHandle: jr,
    useInsertionEffect: Nr,
    useLayoutEffect: wr,
    useMemo: Gr,
    useReducer: Eu,
    useRef: Ur,
    useState: function() {
      return Eu(Al);
    },
    useDebugValue: fc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return Yr(
        l,
        zt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = Eu(Al)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : pi(t),
        e
      ];
    },
    useSyncExternalStore: gr,
    useId: Vr,
    useHostTransitionStatus: rc,
    useFormState: Dr,
    useActionState: Dr,
    useOptimistic: function(t, e) {
      var l = Lt();
      return Sr(l, zt, t, e);
    },
    useMemoCache: ec,
    useCacheRefresh: Zr
  };
  dc.useEffectEvent = Rr;
  var Wr = {
    readContext: re,
    use: Mu,
    useCallback: qr,
    useContext: re,
    useEffect: uc,
    useImperativeHandle: jr,
    useInsertionEffect: Nr,
    useLayoutEffect: wr,
    useMemo: Gr,
    useReducer: ac,
    useRef: Ur,
    useState: function() {
      return ac(Al);
    },
    useDebugValue: fc,
    useDeferredValue: function(t, e) {
      var l = Lt();
      return zt === null ? cc(l, t, e) : Yr(
        l,
        zt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = ac(Al)[0], e = Lt().memoizedState;
      return [
        typeof t == "boolean" ? t : pi(t),
        e
      ];
    },
    useSyncExternalStore: gr,
    useId: Vr,
    useHostTransitionStatus: rc,
    useFormState: Cr,
    useActionState: Cr,
    useOptimistic: function(t, e) {
      var l = Lt();
      return zt !== null ? Sr(l, zt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ec,
    useCacheRefresh: Zr
  };
  Wr.useEffectEvent = Rr;
  function mc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : K({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var hc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = Ge(), n = kl(a);
      n.payload = e, l != null && (n.callback = l), e = Fl(t, n, a), e !== null && (De(e, t, a), di(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = Ge(), n = kl(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = Fl(t, n, a), e !== null && (De(e, t, a), di(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = Ge(), a = kl(l);
      a.tag = 2, e != null && (a.callback = e), e = Fl(t, a, l), e !== null && (De(e, t, l), di(e, t, l));
    }
  };
  function $r(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ni(l, a) || !ni(n, i) : !0;
  }
  function Ir(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && hc.enqueueReplaceState(e, e.state, null);
  }
  function La(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = K({}, l));
      for (var n in t)
        l[n] === void 0 && (l[n] = t[n]);
    }
    return l;
  }
  function Pr(t) {
    uu(t);
  }
  function ts(t) {
    console.error(t);
  }
  function es(t) {
    uu(t);
  }
  function Ou(t, e) {
    try {
      var l = t.onUncaughtError;
      l(e.value, { componentStack: e.stack });
    } catch (a) {
      setTimeout(function() {
        throw a;
      });
    }
  }
  function ls(t, e, l) {
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
  function gc(t, e, l) {
    return l = kl(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Ou(t, e);
    }, l;
  }
  function as(t) {
    return t = kl(t), t.tag = 3, t;
  }
  function ns(t, e, l, a) {
    var n = l.type.getDerivedStateFromError;
    if (typeof n == "function") {
      var i = a.value;
      t.payload = function() {
        return n(i);
      }, t.callback = function() {
        ls(e, l, a);
      };
    }
    var u = l.stateNode;
    u !== null && typeof u.componentDidCatch == "function" && (t.callback = function() {
      ls(e, l, a), typeof n != "function" && (ea === null ? ea = /* @__PURE__ */ new Set([this]) : ea.add(this));
      var f = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: f !== null ? f : ""
      });
    });
  }
  function km(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && bn(
        e,
        l,
        n,
        !0
      ), l = we.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return ke === null ? Lu() : l.alternate === null && qt === 0 && (qt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === pu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Yc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === pu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Yc(t, a, n)), !1;
        }
        throw Error(h(435, l.tag));
      }
      return Yc(t, a, n), Lu(), !1;
    }
    if (dt)
      return e = we.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== Nf && (t = Error(h(422), { cause: a }), fi(Ve(t, l)))) : (a !== Nf && (e = Error(h(423), {
        cause: a
      }), fi(
        Ve(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ve(a, l), n = gc(
        t.stateNode,
        a,
        n
      ), Zf(t, n), qt !== 4 && (qt = 2)), !1;
    var i = Error(h(520), { cause: a });
    if (i = Ve(i, l), Ai === null ? Ai = [i] : Ai.push(i), qt !== 4 && (qt = 2), e === null) return !0;
    a = Ve(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = gc(l.stateNode, a, t), Zf(l, t), !1;
        case 1:
          if (e = l.type, i = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || i !== null && typeof i.componentDidCatch == "function" && (ea === null || !ea.has(i))))
            return l.flags |= 65536, n &= -n, l.lanes |= n, n = as(n), ns(
              n,
              t,
              l,
              a
            ), Zf(l, n), !1;
      }
      l = l.return;
    } while (l !== null);
    return !1;
  }
  var pc = Error(h(461)), Vt = !1;
  function se(t, e, l, a) {
    e.child = t === null ? cr(e, null, l, a) : Ga(
      e,
      t.child,
      l,
      a
    );
  }
  function is(t, e, l, a, n) {
    l = l.render;
    var i = e.ref;
    if ("ref" in a) {
      var u = {};
      for (var f in a)
        f !== "ref" && (u[f] = a[f]);
    } else u = a;
    return wa(e), a = $f(
      t,
      e,
      l,
      u,
      i,
      n
    ), f = If(), t !== null && !Vt ? (Pf(t, e, n), _l(t, e, n)) : (dt && f && Bf(e), e.flags |= 1, se(t, e, a, n), e.child);
  }
  function us(t, e, l, a, n) {
    if (t === null) {
      var i = l.type;
      return typeof i == "function" && !Of(i) && i.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = i, fs(
        t,
        e,
        i,
        a,
        n
      )) : (t = ru(
        l.type,
        null,
        a,
        e,
        e.mode,
        n
      ), t.ref = e.ref, t.return = e, e.child = t);
    }
    if (i = t.child, !Mc(t, n)) {
      var u = i.memoizedProps;
      if (l = l.compare, l = l !== null ? l : ni, l(u, a) && t.ref === e.ref)
        return _l(t, e, n);
    }
    return e.flags |= 1, t = Sl(i, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function fs(t, e, l, a, n) {
    if (t !== null) {
      var i = t.memoizedProps;
      if (ni(i, a) && t.ref === e.ref)
        if (Vt = !1, e.pendingProps = a = i, Mc(t, n))
          (t.flags & 131072) !== 0 && (Vt = !0);
        else
          return e.lanes = t.lanes, _l(t, e, n);
    }
    return vc(
      t,
      e,
      l,
      a,
      n
    );
  }
  function cs(t, e, l, a) {
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
        return os(
          t,
          e,
          i,
          l,
          a
        );
      }
      if ((l & 536870912) !== 0)
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && hu(
          e,
          i !== null ? i.cachePool : null
        ), i !== null ? sr(e, i) : Jf(), dr(e);
      else
        return a = e.lanes = 536870912, os(
          t,
          e,
          i !== null ? i.baseLanes | l : l,
          l,
          a
        );
    } else
      i !== null ? (hu(e, i.cachePool), sr(e, i), $l(), e.memoizedState = null) : (t !== null && hu(e, null), Jf(), $l());
    return se(t, e, n, l), e.child;
  }
  function bi(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function os(t, e, l, a, n) {
    var i = Lf();
    return i = i === null ? null : { parent: Xt._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && hu(e, null), Jf(), dr(e), t !== null && bn(t, e, a, !0), e.childLanes = n, null;
  }
  function Cu(t, e) {
    return e = Bu(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function rs(t, e, l) {
    return Ga(e, t.child, null, l), t = Cu(e, e.pendingProps), t.flags |= 2, He(e), e.memoizedState = null, t;
  }
  function Fm(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (dt) {
        if (a.mode === "hidden")
          return t = Cu(e, a), e.lanes = 536870912, bi(null, t);
        if (Ff(e), (t = Ot) ? (t = Td(
          t,
          Je
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Ql !== null ? { id: dl, overflow: ml } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Jo(t), l.return = e, e.child = l, oe = e, Ot = null)) : t = null, t === null) throw Zl(e);
        return e.lanes = 536870912, null;
      }
      return Cu(e, a);
    }
    var i = t.memoizedState;
    if (i !== null) {
      var u = i.dehydrated;
      if (Ff(e), n)
        if (e.flags & 256)
          e.flags &= -257, e = rs(
            t,
            e,
            l
          );
        else if (e.memoizedState !== null)
          e.child = t.child, e.flags |= 128, e = null;
        else throw Error(h(558));
      else if (Vt || bn(t, e, l, !1), n = (l & t.childLanes) !== 0, Vt || n) {
        if (a = At, a !== null && (u = xe(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, Ua(t, u), De(a, t, u), pc;
        Lu(), e = rs(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, Ot = Fe(u.nextSibling), oe = e, dt = !0, Vl = null, Je = !1, t !== null && Wo(e, t), e = Cu(e, a), e.flags |= 4096;
      return e;
    }
    return t = Sl(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Uu(t, e) {
    var l = e.ref;
    if (l === null)
      t !== null && t.ref !== null && (e.flags |= 4194816);
    else {
      if (typeof l != "function" && typeof l != "object")
        throw Error(h(284));
      (t === null || t.ref !== l) && (e.flags |= 4194816);
    }
  }
  function vc(t, e, l, a, n) {
    return wa(e), l = $f(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = If(), t !== null && !Vt ? (Pf(t, e, n), _l(t, e, n)) : (dt && a && Bf(e), e.flags |= 1, se(t, e, l, n), e.child);
  }
  function ss(t, e, l, a, n, i) {
    return wa(e), e.updateQueue = null, l = hr(
      e,
      a,
      l,
      n
    ), mr(t), a = If(), t !== null && !Vt ? (Pf(t, e, i), _l(t, e, i)) : (dt && a && Bf(e), e.flags |= 1, se(t, e, l, i), e.child);
  }
  function ds(t, e, l, a, n) {
    if (wa(e), e.stateNode === null) {
      var i = gn, u = l.contextType;
      typeof u == "object" && u !== null && (i = re(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = hc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Qf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? re(u) : gn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (mc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && hc.enqueueReplaceState(i, i.state, null), hi(e, a, i, n), mi(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var f = e.memoizedProps, r = La(l, f);
      i.props = r;
      var p = i.context, S = l.contextType;
      u = gn, typeof S == "object" && S !== null && (u = re(S));
      var E = l.getDerivedStateFromProps;
      S = typeof E == "function" || typeof i.getSnapshotBeforeUpdate == "function", f = e.pendingProps !== f, S || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (f || p !== u) && Ir(
        e,
        i,
        a,
        u
      ), Jl = !1;
      var v = e.memoizedState;
      i.state = v, hi(e, a, i, n), mi(), p = e.memoizedState, f || v !== p || Jl ? (typeof E == "function" && (mc(
        e,
        l,
        E,
        a
      ), p = e.memoizedState), (r = Jl || $r(
        e,
        l,
        r,
        a,
        v,
        p,
        u
      )) ? (S || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = p), i.props = a, i.state = p, i.context = u, a = r) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, Vf(t, e), u = e.memoizedProps, S = La(l, u), i.props = S, E = e.pendingProps, v = i.context, p = l.contextType, r = gn, typeof p == "object" && p !== null && (r = re(p)), f = l.getDerivedStateFromProps, (p = typeof f == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== E || v !== r) && Ir(
        e,
        i,
        a,
        r
      ), Jl = !1, v = e.memoizedState, i.state = v, hi(e, a, i, n), mi();
      var x = e.memoizedState;
      u !== E || v !== x || Jl || t !== null && t.dependencies !== null && du(t.dependencies) ? (typeof f == "function" && (mc(
        e,
        l,
        f,
        a
      ), x = e.memoizedState), (S = Jl || $r(
        e,
        l,
        S,
        a,
        v,
        x,
        r
      ) || t !== null && t.dependencies !== null && du(t.dependencies)) ? (p || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, x, r), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        x,
        r
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && v === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && v === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = x), i.props = a, i.state = x, i.context = r, a = S) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && v === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && v === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return i = a, Uu(t, e), a = (e.flags & 128) !== 0, i || a ? (i = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : i.render(), e.flags |= 1, t !== null && a ? (e.child = Ga(
      e,
      t.child,
      null,
      n
    ), e.child = Ga(
      e,
      null,
      l,
      n
    )) : se(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = _l(
      t,
      e,
      n
    ), t;
  }
  function ms(t, e, l, a) {
    return Ra(), e.flags |= 256, se(t, e, l, a), e.child;
  }
  var yc = {
    dehydrated: null,
    treeContext: null,
    retryLane: 0,
    hydrationErrors: null
  };
  function bc(t) {
    return { baseLanes: t, cachePool: lr() };
  }
  function xc(t, e, l) {
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= qe), t;
  }
  function hs(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : (Yt.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (dt) {
        if (n ? Wl(e) : $l(), (t = Ot) ? (t = Td(
          t,
          Je
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Ql !== null ? { id: dl, overflow: ml } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Jo(t), l.return = e, e.child = l, oe = e, Ot = null)) : t = null, t === null) throw Zl(e);
        return lo(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var f = a.children;
      return a = a.fallback, n ? ($l(), n = e.mode, f = Bu(
        { mode: "hidden", children: f },
        n
      ), a = Ba(
        a,
        n,
        l,
        null
      ), f.return = e, a.return = e, f.sibling = a, e.child = f, a = e.child, a.memoizedState = bc(l), a.childLanes = xc(
        t,
        u,
        l
      ), e.memoizedState = yc, bi(null, a)) : (Wl(e), Sc(e, f));
    }
    var r = t.memoizedState;
    if (r !== null && (f = r.dehydrated, f !== null)) {
      if (i)
        e.flags & 256 ? (Wl(e), e.flags &= -257, e = Tc(
          t,
          e,
          l
        )) : e.memoizedState !== null ? ($l(), e.child = t.child, e.flags |= 128, e = null) : ($l(), f = a.fallback, n = e.mode, a = Bu(
          { mode: "visible", children: a.children },
          n
        ), f = Ba(
          f,
          n,
          l,
          null
        ), f.flags |= 2, a.return = e, f.return = e, a.sibling = f, e.child = a, Ga(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = bc(l), a.childLanes = xc(
          t,
          u,
          l
        ), e.memoizedState = yc, e = bi(null, a));
      else if (Wl(e), lo(f)) {
        if (u = f.nextSibling && f.nextSibling.dataset, u) var p = u.dgst;
        u = p, a = Error(h(419)), a.stack = "", a.digest = u, fi({ value: a, source: null, stack: null }), e = Tc(
          t,
          e,
          l
        );
      } else if (Vt || bn(t, e, l, !1), u = (l & t.childLanes) !== 0, Vt || u) {
        if (u = At, u !== null && (a = xe(u, l), a !== 0 && a !== r.retryLane))
          throw r.retryLane = a, Ua(t, a), De(u, t, a), pc;
        eo(f) || Lu(), e = Tc(
          t,
          e,
          l
        );
      } else
        eo(f) ? (e.flags |= 192, e.child = t.child, e = null) : (t = r.treeContext, Ot = Fe(
          f.nextSibling
        ), oe = e, dt = !0, Vl = null, Je = !1, t !== null && Wo(e, t), e = Sc(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? ($l(), f = a.fallback, n = e.mode, r = t.child, p = r.sibling, a = Sl(r, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = r.subtreeFlags & 65011712, p !== null ? f = Sl(
      p,
      f
    ) : (f = Ba(
      f,
      n,
      l,
      null
    ), f.flags |= 2), f.return = e, a.return = e, a.sibling = f, e.child = a, bi(null, a), a = e.child, f = t.child.memoizedState, f === null ? f = bc(l) : (n = f.cachePool, n !== null ? (r = Xt._currentValue, n = n.parent !== r ? { parent: r, pool: r } : n) : n = lr(), f = {
      baseLanes: f.baseLanes | l,
      cachePool: n
    }), a.memoizedState = f, a.childLanes = xc(
      t,
      u,
      l
    ), e.memoizedState = yc, bi(t.child, a)) : (Wl(e), l = t.child, t = l.sibling, l = Sl(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function Sc(t, e) {
    return e = Bu(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Bu(t, e) {
    return t = Ne(22, t, null, e), t.lanes = 0, t;
  }
  function Tc(t, e, l) {
    return Ga(e, t.child, null, l), t = Sc(
      e,
      e.pendingProps.children
    ), t.flags |= 2, e.memoizedState = null, t;
  }
  function gs(t, e, l) {
    t.lanes |= e;
    var a = t.alternate;
    a !== null && (a.lanes |= e), jf(t.return, e, l);
  }
  function zc(t, e, l, a, n, i) {
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
  function ps(t, e, l) {
    var a = e.pendingProps, n = a.revealOrder, i = a.tail;
    a = a.children;
    var u = Yt.current, f = (u & 2) !== 0;
    if (f ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, B(Yt, u), se(t, e, a, l), a = dt ? ui : 0, !f && t !== null && (t.flags & 128) !== 0)
      t: for (t = e.child; t !== null; ) {
        if (t.tag === 13)
          t.memoizedState !== null && gs(t, l, e);
        else if (t.tag === 19)
          gs(t, l, e);
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
          t = l.alternate, t !== null && xu(t) === null && (n = l), l = l.sibling;
        l = n, l === null ? (n = e.child, e.child = null) : (n = l.sibling, l.sibling = null), zc(
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
          if (t = n.alternate, t !== null && xu(t) === null) {
            e.child = n;
            break;
          }
          t = n.sibling, n.sibling = l, l = n, n = t;
        }
        zc(
          e,
          !0,
          l,
          null,
          i,
          a
        );
        break;
      case "together":
        zc(
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
  function _l(t, e, l) {
    if (t !== null && (e.dependencies = t.dependencies), ta |= e.lanes, (l & e.childLanes) === 0)
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
      throw Error(h(153));
    if (e.child !== null) {
      for (t = e.child, l = Sl(t, t.pendingProps), e.child = l, l.return = e; t.sibling !== null; )
        t = t.sibling, l = l.sibling = Sl(t, t.pendingProps), l.return = e;
      l.sibling = null;
    }
    return e.child;
  }
  function Mc(t, e) {
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && du(t)));
  }
  function Wm(t, e, l) {
    switch (e.tag) {
      case 3:
        wt(e, e.stateNode.containerInfo), Kl(e, Xt, t.memoizedState.cache), Ra();
        break;
      case 27:
      case 5:
        Ce(e);
        break;
      case 4:
        wt(e, e.stateNode.containerInfo);
        break;
      case 10:
        Kl(
          e,
          e.type,
          e.memoizedProps.value
        );
        break;
      case 31:
        if (e.memoizedState !== null)
          return e.flags |= 128, Ff(e), null;
        break;
      case 13:
        var a = e.memoizedState;
        if (a !== null)
          return a.dehydrated !== null ? (Wl(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? hs(t, e, l) : (Wl(e), t = _l(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        Wl(e);
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
            return ps(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), B(Yt, Yt.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, cs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        Kl(e, Xt, t.memoizedState.cache);
    }
    return _l(t, e, l);
  }
  function vs(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        Vt = !0;
      else {
        if (!Mc(t, l) && (e.flags & 128) === 0)
          return Vt = !1, Wm(
            t,
            e,
            l
          );
        Vt = (t.flags & 131072) !== 0;
      }
    else
      Vt = !1, dt && (e.flags & 1048576) !== 0 && Fo(e, ui, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = ja(e.elementType), e.type = t, typeof t == "function")
            Of(t) ? (a = La(t, a), e.tag = 1, e = ds(
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
              if (n === $t) {
                e.tag = 11, e = is(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === $) {
                e.tag = 14, e = us(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              }
            }
            throw e = X(t) || t, Error(h(306, e, ""));
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
        return a = e.type, n = La(
          a,
          e.pendingProps
        ), ds(
          t,
          e,
          a,
          n,
          l
        );
      case 3:
        t: {
          if (wt(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(h(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, Vf(t, e), hi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, Kl(e, Xt, a), a !== i.cache && qf(
            e,
            [Xt],
            l,
            !0
          ), mi(), a = u.element, i.isDehydrated)
            if (i = {
              element: a,
              isDehydrated: !1,
              cache: u.cache
            }, e.updateQueue.baseState = i, e.memoizedState = i, e.flags & 256) {
              e = ms(
                t,
                e,
                a,
                l
              );
              break t;
            } else if (a !== n) {
              n = Ve(
                Error(h(424)),
                e
              ), fi(n), e = ms(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Ot = Fe(t.firstChild), oe = e, dt = !0, Vl = null, Je = !0, l = cr(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (Ra(), a === n) {
              e = _l(
                t,
                e,
                l
              );
              break t;
            }
            se(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Uu(t, e), t === null ? (l = Dd(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : dt || (l = e.type, t = e.pendingProps, a = ku(
          at.current
        ).createElement(l), a[Jt] = e, a[fe] = t, de(a, l, t), Gt(a), e.stateNode = a) : e.memoizedState = Dd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return Ce(e), t === null && dt && (a = e.stateNode = Ed(
          e.type,
          e.pendingProps,
          at.current
        ), oe = e, Je = !0, n = Ot, ia(e.type) ? (ao = n, Ot = Fe(a.firstChild)) : Ot = n), se(
          t,
          e,
          e.pendingProps.children,
          l
        ), Uu(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && dt && ((n = a = Ot) && (a = Ah(
          a,
          e.type,
          e.pendingProps,
          Je
        ), a !== null ? (e.stateNode = a, oe = e, Ot = Fe(a.firstChild), Je = !1, n = !0) : n = !1), n || Zl(e)), Ce(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, Ic(n, i) ? a = null : u !== null && Ic(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = $f(
          t,
          e,
          Lm,
          null,
          null,
          l
        ), Ni._currentValue = n), Uu(t, e), se(t, e, a, l), e.child;
      case 6:
        return t === null && dt && ((t = l = Ot) && (l = _h(
          l,
          e.pendingProps,
          Je
        ), l !== null ? (e.stateNode = l, oe = e, Ot = null, t = !0) : t = !1), t || Zl(e)), null;
      case 13:
        return hs(t, e, l);
      case 4:
        return wt(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = Ga(
          e,
          null,
          a,
          l
        ) : se(t, e, a, l), e.child;
      case 11:
        return is(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return se(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return se(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return se(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, Kl(e, e.type, a.value), se(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, wa(e), n = re(n), a = a(n), e.flags |= 1, se(t, e, a, l), e.child;
      case 14:
        return us(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 15:
        return fs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 19:
        return ps(t, e, l);
      case 31:
        return Fm(t, e, l);
      case 22:
        return cs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return wa(e), a = re(Xt), t === null ? (n = Lf(), n === null && (n = At, i = Gf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Qf(e), Kl(e, Xt, n)) : ((t.lanes & l) !== 0 && (Vf(t, e), hi(e, null, null, l), mi()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), Kl(e, Xt, a)) : (a = i.cache, Kl(e, Xt, a), a !== n.cache && qf(
          e,
          [Xt],
          l,
          !0
        ))), se(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 29:
        throw e.pendingProps;
    }
    throw Error(h(156, e.tag));
  }
  function Dl(t) {
    t.flags |= 4;
  }
  function Ec(t, e, l, a, n) {
    if ((e = (t.mode & 32) !== 0) && (e = !1), e) {
      if (t.flags |= 16777216, (n & 335544128) === n)
        if (t.stateNode.complete) t.flags |= 8192;
        else if (Vs()) t.flags |= 8192;
        else
          throw qa = pu, Xf;
    } else t.flags &= -16777217;
  }
  function ys(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !Rd(e))
      if (Vs()) t.flags |= 8192;
      else
        throw qa = pu, Xf;
  }
  function Ru(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? fl() : 536870912, t.lanes |= e, Un |= e);
  }
  function xi(t, e) {
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
  function Ct(t) {
    var e = t.alternate !== null && t.alternate.child === t.child, l = 0, a = 0;
    if (e)
      for (var n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags & 65011712, a |= n.flags & 65011712, n.return = t, n = n.sibling;
    else
      for (n = t.child; n !== null; )
        l |= n.lanes | n.childLanes, a |= n.subtreeFlags, a |= n.flags, n.return = t, n = n.sibling;
    return t.subtreeFlags |= a, t.childLanes = l, e;
  }
  function $m(t, e, l) {
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
        return Ct(e), null;
      case 1:
        return Ct(e), null;
      case 3:
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), Ml(Xt), Dt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (yn(e) ? Dl(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, wf())), Ct(e), null;
      case 26:
        var n = e.type, i = e.memoizedState;
        return t === null ? (Dl(e), i !== null ? (Ct(e), ys(e, i)) : (Ct(e), Ec(
          e,
          n,
          null,
          a,
          l
        ))) : i ? i !== t.memoizedState ? (Dl(e), Ct(e), ys(e, i)) : (Ct(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Dl(e), Ct(e), Ec(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if ($e(e), l = at.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Dl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(h(166));
            return Ct(e), null;
          }
          t = q.current, yn(e) ? $o(e) : (t = Ed(n, a, l), e.stateNode = t, Dl(e));
        }
        return Ct(e), null;
      case 5:
        if ($e(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Dl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(h(166));
            return Ct(e), null;
          }
          if (i = q.current, yn(e))
            $o(e);
          else {
            var u = ku(
              at.current
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
            i[Jt] = e, i[fe] = a;
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
            t: switch (de(i, n, a), n) {
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
            a && Dl(e);
          }
        }
        return Ct(e), Ec(
          e,
          e.type,
          t === null ? null : t.memoizedProps,
          e.pendingProps,
          l
        ), null;
      case 6:
        if (t && e.stateNode != null)
          t.memoizedProps !== a && Dl(e);
        else {
          if (typeof a != "string" && e.stateNode === null)
            throw Error(h(166));
          if (t = at.current, yn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = oe, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[Jt] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || hd(t.nodeValue, l)), t || Zl(e, !0);
          } else
            t = ku(t).createTextNode(
              a
            ), t[Jt] = e, e.stateNode = t;
        }
        return Ct(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = yn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(h(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(h(557));
              t[Jt] = e;
            } else
              Ra(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ct(e), t = !1;
          } else
            l = wf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (He(e), e) : (He(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(h(558));
        }
        return Ct(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = yn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(h(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(h(317));
              n[Jt] = e;
            } else
              Ra(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ct(e), n = !1;
          } else
            n = wf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (He(e), e) : (He(e), null);
        }
        return He(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Ru(e, e.updateQueue), Ct(e), null);
      case 4:
        return Dt(), t === null && Jc(e.stateNode.containerInfo), Ct(e), null;
      case 10:
        return Ml(e.type), Ct(e), null;
      case 19:
        if (z(Yt), a = e.memoizedState, a === null) return Ct(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) xi(a, !1);
          else {
            if (qt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = xu(t), i !== null) {
                  for (e.flags |= 128, xi(a, !1), t = i.updateQueue, e.updateQueue = t, Ru(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    Ko(l, t), l = l.sibling;
                  return B(
                    Yt,
                    Yt.current & 1 | 2
                  ), dt && Tl(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && he() > qu && (e.flags |= 128, n = !0, xi(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = xu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Ru(e, t), xi(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !dt)
                return Ct(e), null;
            } else
              2 * he() - a.renderingStartTime > qu && l !== 536870912 && (e.flags |= 128, n = !0, xi(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = he(), t.sibling = null, l = Yt.current, B(
          Yt,
          n ? l & 1 | 2 : l & 1
        ), dt && Tl(e, a.treeForkCount), t) : (Ct(e), null);
      case 22:
      case 23:
        return He(e), kf(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Ct(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Ct(e), l = e.updateQueue, l !== null && Ru(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && z(Ha), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), Ml(Xt), Ct(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(h(156, e.tag));
  }
  function Im(t, e) {
    switch (Rf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return Ml(Xt), Dt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return $e(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (He(e), e.alternate === null)
            throw Error(h(340));
          Ra();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (He(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(h(340));
          Ra();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return z(Yt), null;
      case 4:
        return Dt(), null;
      case 10:
        return Ml(e.type), null;
      case 22:
      case 23:
        return He(e), kf(), t !== null && z(Ha), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return Ml(Xt), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function bs(t, e) {
    switch (Rf(e), e.tag) {
      case 3:
        Ml(Xt), Dt();
        break;
      case 26:
      case 27:
      case 5:
        $e(e);
        break;
      case 4:
        Dt();
        break;
      case 31:
        e.memoizedState !== null && He(e);
        break;
      case 13:
        He(e);
        break;
      case 19:
        z(Yt);
        break;
      case 10:
        Ml(e.type);
        break;
      case 22:
      case 23:
        He(e), kf(), t !== null && z(Ha);
        break;
      case 24:
        Ml(Xt);
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
      Tt(e, e.return, f);
    }
  }
  function Il(t, e, l) {
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
              var r = l, p = f;
              try {
                p();
              } catch (S) {
                Tt(
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
      Tt(e, e.return, S);
    }
  }
  function xs(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        rr(e, l);
      } catch (a) {
        Tt(t, t.return, a);
      }
    }
  }
  function Ss(t, e, l) {
    l.props = La(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      Tt(t, e, a);
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
      Tt(t, e, n);
    }
  }
  function hl(t, e) {
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
  function Ts(t) {
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
  function Ac(t, e, l) {
    try {
      var a = t.stateNode;
      xh(a, t.type, l, e), a[fe] = e;
    } catch (n) {
      Tt(t, t.return, n);
    }
  }
  function zs(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && ia(t.type) || t.tag === 4;
  }
  function _c(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || zs(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && ia(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Dc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = el));
    else if (a !== 4 && (a === 27 && ia(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Dc(t, e, l), t = t.sibling; t !== null; )
        Dc(t, e, l), t = t.sibling;
  }
  function Nu(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && ia(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (Nu(t, e, l), t = t.sibling; t !== null; )
        Nu(t, e, l), t = t.sibling;
  }
  function Ms(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      de(e, a, l), e[Jt] = t, e[fe] = l;
    } catch (i) {
      Tt(t, t.return, i);
    }
  }
  var Ol = !1, Zt = !1, Oc = !1, Es = typeof WeakSet == "function" ? WeakSet : Set, ee = null;
  function Pm(t, e) {
    if (t = t.containerInfo, Wc = ef, t = jo(t), Tf(t)) {
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
            var u = 0, f = -1, r = -1, p = 0, S = 0, E = t, v = null;
            e: for (; ; ) {
              for (var x; E !== l || n !== 0 && E.nodeType !== 3 || (f = u + n), E !== i || a !== 0 && E.nodeType !== 3 || (r = u + a), E.nodeType === 3 && (u += E.nodeValue.length), (x = E.firstChild) !== null; )
                v = E, E = x;
              for (; ; ) {
                if (E === t) break e;
                if (v === l && ++p === n && (f = u), v === i && ++S === a && (r = u), (x = E.nextSibling) !== null) break;
                E = v, v = E.parentNode;
              }
              E = x;
            }
            l = f === -1 || r === -1 ? null : { start: f, end: r };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for ($c = { focusedElem: t, selectionRange: l }, ef = !1, ee = e; ee !== null; )
      if (e = ee, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, ee = t;
      else
        for (; ee !== null; ) {
          switch (e = ee, i = e.alternate, t = e.flags, e.tag) {
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
                  var G = La(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    G,
                    i
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch (Z) {
                  Tt(
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
                  to(t);
                else if (l === 1)
                  switch (t.nodeName) {
                    case "HEAD":
                    case "HTML":
                    case "BODY":
                      to(t);
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
              if ((t & 1024) !== 0) throw Error(h(163));
          }
          if (t = e.sibling, t !== null) {
            t.return = e.return, ee = t;
            break;
          }
          ee = e.return;
        }
  }
  function As(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        Ul(t, l), a & 4 && Si(5, l);
        break;
      case 1:
        if (Ul(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              Tt(l, l.return, u);
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
              Tt(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && xs(l), a & 512 && Ti(l, l.return);
        break;
      case 3:
        if (Ul(t, l), a & 64 && (t = l.updateQueue, t !== null)) {
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
            rr(t, e);
          } catch (u) {
            Tt(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && Ms(l);
      case 26:
      case 5:
        Ul(t, l), e === null && a & 4 && Ts(l), a & 512 && Ti(l, l.return);
        break;
      case 12:
        Ul(t, l);
        break;
      case 31:
        Ul(t, l), a & 4 && Os(t, l);
        break;
      case 13:
        Ul(t, l), a & 4 && Cs(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = ch.bind(
          null,
          l
        ), Dh(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || Ol, !a) {
          e = e !== null && e.memoizedState !== null || Zt, n = Ol;
          var i = Zt;
          Ol = a, (Zt = e) && !i ? Bl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : Ul(t, l), Ol = n, Zt = i;
        }
        break;
      case 30:
        break;
      default:
        Ul(t, l);
    }
  }
  function _s(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, _s(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && Ia(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Rt = null, Me = !1;
  function Cl(t, e, l) {
    for (l = l.child; l !== null; )
      Ds(t, e, l), l = l.sibling;
  }
  function Ds(t, e, l) {
    if (ye && typeof ye.onCommitFiberUnmount == "function")
      try {
        ye.onCommitFiberUnmount(ha, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        Zt || hl(l, e), Cl(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        Zt || hl(l, e);
        var a = Rt, n = Me;
        ia(l.type) && (Rt = l.stateNode, Me = !1), Cl(
          t,
          e,
          l
        ), Ui(l.stateNode), Rt = a, Me = n;
        break;
      case 5:
        Zt || hl(l, e);
      case 6:
        if (a = Rt, n = Me, Rt = null, Cl(
          t,
          e,
          l
        ), Rt = a, Me = n, Rt !== null)
          if (Me)
            try {
              (Rt.nodeType === 9 ? Rt.body : Rt.nodeName === "HTML" ? Rt.ownerDocument.body : Rt).removeChild(l.stateNode);
            } catch (i) {
              Tt(
                l,
                e,
                i
              );
            }
          else
            try {
              Rt.removeChild(l.stateNode);
            } catch (i) {
              Tt(
                l,
                e,
                i
              );
            }
        break;
      case 18:
        Rt !== null && (Me ? (t = Rt, xd(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), Gn(t)) : xd(Rt, l.stateNode));
        break;
      case 4:
        a = Rt, n = Me, Rt = l.stateNode.containerInfo, Me = !0, Cl(
          t,
          e,
          l
        ), Rt = a, Me = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        Il(2, l, e), Zt || Il(4, l, e), Cl(
          t,
          e,
          l
        );
        break;
      case 1:
        Zt || (hl(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && Ss(
          l,
          e,
          a
        )), Cl(
          t,
          e,
          l
        );
        break;
      case 21:
        Cl(
          t,
          e,
          l
        );
        break;
      case 22:
        Zt = (a = Zt) || l.memoizedState !== null, Cl(
          t,
          e,
          l
        ), Zt = a;
        break;
      default:
        Cl(
          t,
          e,
          l
        );
    }
  }
  function Os(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null))) {
      t = t.dehydrated;
      try {
        Gn(t);
      } catch (l) {
        Tt(e, e.return, l);
      }
    }
  }
  function Cs(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        Gn(t);
      } catch (l) {
        Tt(e, e.return, l);
      }
  }
  function th(t) {
    switch (t.tag) {
      case 31:
      case 13:
      case 19:
        var e = t.stateNode;
        return e === null && (e = t.stateNode = new Es()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new Es()), e;
      default:
        throw Error(h(435, t.tag));
    }
  }
  function wu(t, e) {
    var l = th(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = oh.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function Ee(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], i = t, u = e, f = u;
        t: for (; f !== null; ) {
          switch (f.tag) {
            case 27:
              if (ia(f.type)) {
                Rt = f.stateNode, Me = !1;
                break t;
              }
              break;
            case 5:
              Rt = f.stateNode, Me = !1;
              break t;
            case 3:
            case 4:
              Rt = f.stateNode.containerInfo, Me = !0;
              break t;
          }
          f = f.return;
        }
        if (Rt === null) throw Error(h(160));
        Ds(i, u, n), Rt = null, Me = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Us(e, t), e = e.sibling;
  }
  var al = null;
  function Us(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Ee(e, t), Ae(t), a & 4 && (Il(3, t, t.return), Si(3, t), Il(5, t, t.return));
        break;
      case 1:
        Ee(e, t), Ae(t), a & 512 && (Zt || l === null || hl(l, l.return)), a & 64 && Ol && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = al;
        if (Ee(e, t), Ae(t), a & 512 && (Zt || l === null || hl(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[xa] || i[Jt] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), de(i, a, l), i[Jt] = t, Gt(i), a = i;
                      break t;
                    case "link":
                      var u = Ud(
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
                      i = n.createElement(a), de(i, a, l), n.head.appendChild(i);
                      break;
                    case "meta":
                      if (u = Ud(
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
                      i = n.createElement(a), de(i, a, l), n.head.appendChild(i);
                      break;
                    default:
                      throw Error(h(468, a));
                  }
                  i[Jt] = t, Gt(i), a = i;
                }
                t.stateNode = a;
              } else
                Bd(
                  n,
                  t.type,
                  t.stateNode
                );
            else
              t.stateNode = Cd(
                n,
                a,
                t.memoizedProps
              );
          else
            i !== a ? (i === null ? l.stateNode !== null && (l = l.stateNode, l.parentNode.removeChild(l)) : i.count--, a === null ? Bd(
              n,
              t.type,
              t.stateNode
            ) : Cd(
              n,
              a,
              t.memoizedProps
            )) : a === null && t.stateNode !== null && Ac(
              t,
              t.memoizedProps,
              l.memoizedProps
            );
        }
        break;
      case 27:
        Ee(e, t), Ae(t), a & 512 && (Zt || l === null || hl(l, l.return)), l !== null && a & 4 && Ac(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (Ee(e, t), Ae(t), a & 512 && (Zt || l === null || hl(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            R(n, "");
          } catch (G) {
            Tt(t, t.return, G);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Ac(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Oc = !0);
        break;
      case 6:
        if (Ee(e, t), Ae(t), a & 4) {
          if (t.stateNode === null)
            throw Error(h(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (G) {
            Tt(t, t.return, G);
          }
        }
        break;
      case 3:
        if ($u = null, n = al, al = Fu(e.containerInfo), Ee(e, t), al = n, Ae(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            Gn(e.containerInfo);
          } catch (G) {
            Tt(t, t.return, G);
          }
        Oc && (Oc = !1, Bs(t));
        break;
      case 4:
        a = al, al = Fu(
          t.stateNode.containerInfo
        ), Ee(e, t), Ae(t), al = a;
        break;
      case 12:
        Ee(e, t), Ae(t);
        break;
      case 31:
        Ee(e, t), Ae(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, wu(t, a)));
        break;
      case 13:
        Ee(e, t), Ae(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (ju = he()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, wu(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var r = l !== null && l.memoizedState !== null, p = Ol, S = Zt;
        if (Ol = p || n, Zt = S || r, Ee(e, t), Zt = S, Ol = p, Ae(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || r || Ol || Zt || Xa(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                r = l = e;
                try {
                  if (i = r.stateNode, n)
                    u = i.style, typeof u.setProperty == "function" ? u.setProperty("display", "none", "important") : u.display = "none";
                  else {
                    f = r.stateNode;
                    var E = r.memoizedProps.style, v = E != null && E.hasOwnProperty("display") ? E.display : null;
                    f.style.display = v == null || typeof v == "boolean" ? "" : ("" + v).trim();
                  }
                } catch (G) {
                  Tt(r, r.return, G);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                r = e;
                try {
                  r.stateNode.nodeValue = n ? "" : r.memoizedProps;
                } catch (G) {
                  Tt(r, r.return, G);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                r = e;
                try {
                  var x = r.stateNode;
                  n ? Sd(x, !0) : Sd(r.stateNode, !1);
                } catch (G) {
                  Tt(r, r.return, G);
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
        a & 4 && (a = t.updateQueue, a !== null && (l = a.retryQueue, l !== null && (a.retryQueue = null, wu(t, l))));
        break;
      case 19:
        Ee(e, t), Ae(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, wu(t, a)));
        break;
      case 30:
        break;
      case 21:
        break;
      default:
        Ee(e, t), Ae(t);
    }
  }
  function Ae(t) {
    var e = t.flags;
    if (e & 2) {
      try {
        for (var l, a = t.return; a !== null; ) {
          if (zs(a)) {
            l = a;
            break;
          }
          a = a.return;
        }
        if (l == null) throw Error(h(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, i = _c(t);
            Nu(t, i, n);
            break;
          case 5:
            var u = l.stateNode;
            l.flags & 32 && (R(u, ""), l.flags &= -33);
            var f = _c(t);
            Nu(t, f, u);
            break;
          case 3:
          case 4:
            var r = l.stateNode.containerInfo, p = _c(t);
            Dc(
              t,
              p,
              r
            );
            break;
          default:
            throw Error(h(161));
        }
      } catch (S) {
        Tt(t, t.return, S);
      }
      t.flags &= -3;
    }
    e & 4096 && (t.flags &= -4097);
  }
  function Bs(t) {
    if (t.subtreeFlags & 1024)
      for (t = t.child; t !== null; ) {
        var e = t;
        Bs(e), e.tag === 5 && e.flags & 1024 && e.stateNode.reset(), t = t.sibling;
      }
  }
  function Ul(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        As(t, e.alternate, e), e = e.sibling;
  }
  function Xa(t) {
    for (t = t.child; t !== null; ) {
      var e = t;
      switch (e.tag) {
        case 0:
        case 11:
        case 14:
        case 15:
          Il(4, e, e.return), Xa(e);
          break;
        case 1:
          hl(e, e.return);
          var l = e.stateNode;
          typeof l.componentWillUnmount == "function" && Ss(
            e,
            e.return,
            l
          ), Xa(e);
          break;
        case 27:
          Ui(e.stateNode);
        case 26:
        case 5:
          hl(e, e.return), Xa(e);
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
  function Bl(t, e, l) {
    for (l = l && (e.subtreeFlags & 8772) !== 0, e = e.child; e !== null; ) {
      var a = e.alternate, n = t, i = e, u = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          Bl(
            n,
            i,
            l
          ), Si(4, i);
          break;
        case 1:
          if (Bl(
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
              var r = n.shared.hiddenCallbacks;
              if (r !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < r.length; n++)
                  or(r[n], f);
            } catch (p) {
              Tt(a, a.return, p);
            }
          }
          l && u & 64 && xs(i), Ti(i, i.return);
          break;
        case 27:
          Ms(i);
        case 26:
        case 5:
          Bl(
            n,
            i,
            l
          ), l && a === null && u & 4 && Ts(i), Ti(i, i.return);
          break;
        case 12:
          Bl(
            n,
            i,
            l
          );
          break;
        case 31:
          Bl(
            n,
            i,
            l
          ), l && u & 4 && Os(n, i);
          break;
        case 13:
          Bl(
            n,
            i,
            l
          ), l && u & 4 && Cs(n, i);
          break;
        case 22:
          i.memoizedState === null && Bl(
            n,
            i,
            l
          ), Ti(i, i.return);
          break;
        case 30:
          break;
        default:
          Bl(
            n,
            i,
            l
          );
      }
      e = e.sibling;
    }
  }
  function Cc(t, e) {
    var l = null;
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && ci(l));
  }
  function Uc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ci(t));
  }
  function nl(t, e, l, a) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; )
        Rs(
          t,
          e,
          l,
          a
        ), e = e.sibling;
  }
  function Rs(t, e, l, a) {
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
        ), n & 2048 && Si(9, e);
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
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && ci(t)));
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
          } catch (r) {
            Tt(e, e.return, r);
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
        ) : zi(t, e) : i._visibility & 2 ? nl(
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
        )), n & 2048 && Cc(u, e);
        break;
      case 24:
        nl(
          t,
          e,
          l,
          a
        ), n & 2048 && Uc(e.alternate, e);
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
      var i = t, u = e, f = l, r = a, p = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          Dn(
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
          u.memoizedState !== null ? S._visibility & 2 ? Dn(
            i,
            u,
            f,
            r,
            n
          ) : zi(
            i,
            u
          ) : (S._visibility |= 2, Dn(
            i,
            u,
            f,
            r,
            n
          )), n && p & 2048 && Cc(
            u.alternate,
            u
          );
          break;
        case 24:
          Dn(
            i,
            u,
            f,
            r,
            n
          ), n && p & 2048 && Uc(u.alternate, u);
          break;
        default:
          Dn(
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
            zi(l, a), n & 2048 && Cc(
              a.alternate,
              a
            );
            break;
          case 24:
            zi(l, a), n & 2048 && Uc(a.alternate, a);
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
        Ns(
          t,
          e,
          l
        ), t = t.sibling;
  }
  function Ns(t, e, l) {
    switch (t.tag) {
      case 26:
        On(
          t,
          e,
          l
        ), t.flags & Mi && t.memoizedState !== null && Yh(
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
        al = Fu(t.stateNode.containerInfo), On(
          t,
          e,
          l
        ), al = a;
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
  function ws(t) {
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
          ee = a, js(
            a,
            t
          );
        }
      ws(t);
    }
    if (t.subtreeFlags & 10256)
      for (t = t.child; t !== null; )
        Hs(t), t = t.sibling;
  }
  function Hs(t) {
    switch (t.tag) {
      case 0:
      case 11:
      case 15:
        Ei(t), t.flags & 2048 && Il(9, t, t.return);
        break;
      case 3:
        Ei(t);
        break;
      case 12:
        Ei(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, Hu(t)) : Ei(t);
        break;
      default:
        Ei(t);
    }
  }
  function Hu(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          ee = a, js(
            a,
            t
          );
        }
      ws(t);
    }
    for (t = t.child; t !== null; ) {
      switch (e = t, e.tag) {
        case 0:
        case 11:
        case 15:
          Il(8, e, e.return), Hu(e);
          break;
        case 22:
          l = e.stateNode, l._visibility & 2 && (l._visibility &= -3, Hu(e));
          break;
        default:
          Hu(e);
      }
      t = t.sibling;
    }
  }
  function js(t, e) {
    for (; ee !== null; ) {
      var l = ee;
      switch (l.tag) {
        case 0:
        case 11:
        case 15:
          Il(8, l, e);
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
      if (a = l.child, a !== null) a.return = l, ee = a;
      else
        t: for (l = t; ee !== null; ) {
          a = ee;
          var n = a.sibling, i = a.return;
          if (_s(a), a === l) {
            ee = null;
            break t;
          }
          if (n !== null) {
            n.return = i, ee = n;
            break t;
          }
          ee = i;
        }
    }
  }
  var eh = {
    getCacheForType: function(t) {
      var e = re(Xt), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return re(Xt).controller.signal;
    }
  }, lh = typeof WeakMap == "function" ? WeakMap : Map, xt = 0, At = null, ut = null, ot = 0, St = 0, je = null, Pl = !1, Cn = !1, Bc = !1, Rl = 0, qt = 0, ta = 0, Qa = 0, Rc = 0, qe = 0, Un = 0, Ai = null, _e = null, Nc = !1, ju = 0, qs = 0, qu = 1 / 0, Gu = null, ea = null, Ft = 0, la = null, Bn = null, Nl = 0, wc = 0, Hc = null, Gs = null, _i = 0, jc = null;
  function Ge() {
    return (xt & 2) !== 0 && ot !== 0 ? ot & -ot : b.T !== null ? Qc() : Ji();
  }
  function Ys() {
    if (qe === 0)
      if ((ot & 536870912) === 0 || dt) {
        var t = pl;
        pl <<= 1, (pl & 3932160) === 0 && (pl = 262144), qe = t;
      } else qe = 536870912;
    return t = we.current, t !== null && (t.flags |= 32), qe;
  }
  function De(t, e, l) {
    (t === At && (St === 2 || St === 9) || t.cancelPendingCommit !== null) && (Rn(t, 0), aa(
      t,
      ot,
      qe,
      !1
    )), va(t, l), ((xt & 2) === 0 || t !== At) && (t === At && ((xt & 2) === 0 && (Qa |= l), qt === 4 && aa(
      t,
      ot,
      qe,
      !1
    )), gl(t));
  }
  function Ls(t, e, l) {
    if ((xt & 6) !== 0) throw Error(h(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Hl(t, e), n = a ? ih(t, e) : Gc(t, e, !0), i = a;
    do {
      if (n === 0) {
        Cn && !a && aa(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, i && !ah(l)) {
          n = Gc(t, e, !1), i = !1;
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
              if (r && (Rn(f, u).flags |= 256), u = Gc(
                f,
                u,
                !1
              ), u !== 2) {
                if (Bc && !r) {
                  f.errorRecoveryDisabledLanes |= i, Qa |= i, n = 4;
                  break t;
                }
                i = _e, _e = n, i !== null && (_e === null ? _e = i : _e.push.apply(
                  _e,
                  i
                ));
              }
              n = u;
            }
            if (i = !1, n !== 2) continue;
          }
        }
        if (n === 1) {
          Rn(t, 0), aa(t, e, 0, !0);
          break;
        }
        t: {
          switch (a = t, i = n, i) {
            case 0:
            case 1:
              throw Error(h(345));
            case 4:
              if ((e & 4194048) !== e) break;
            case 6:
              aa(
                a,
                e,
                qe,
                !Pl
              );
              break t;
            case 2:
              _e = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(h(329));
          }
          if ((e & 62914560) === e && (n = ju + 300 - he(), 10 < n)) {
            if (aa(
              a,
              e,
              qe,
              !Pl
            ), pa(a, 0, !0) !== 0) break t;
            Nl = e, a.timeoutHandle = yd(
              Xs.bind(
                null,
                a,
                l,
                _e,
                Gu,
                Nc,
                e,
                qe,
                Qa,
                Un,
                Pl,
                i,
                "Throttled",
                -0,
                0
              ),
              n
            );
            break t;
          }
          Xs(
            a,
            l,
            _e,
            Gu,
            Nc,
            e,
            qe,
            Qa,
            Un,
            Pl,
            i,
            null,
            -0,
            0
          );
        }
      }
      break;
    } while (!0);
    gl(t);
  }
  function Xs(t, e, l, a, n, i, u, f, r, p, S, E, v, x) {
    if (t.timeoutHandle = -1, E = e.subtreeFlags, E & 8192 || (E & 16785408) === 16785408) {
      E = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: el
      }, Ns(
        e,
        i,
        E
      );
      var G = (i & 62914560) === i ? ju - he() : (i & 4194048) === i ? qs - he() : 0;
      if (G = Lh(
        E,
        G
      ), G !== null) {
        Nl = i, t.cancelPendingCommit = G(
          Ws.bind(
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
            v,
            x
          )
        ), aa(t, i, u, !p);
        return;
      }
    }
    Ws(
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
  function ah(t) {
    for (var e = t; ; ) {
      var l = e.tag;
      if ((l === 0 || l === 11 || l === 15) && e.flags & 16384 && (l = e.updateQueue, l !== null && (l = l.stores, l !== null)))
        for (var a = 0; a < l.length; a++) {
          var n = l[a], i = n.getSnapshot;
          n = n.value;
          try {
            if (!Re(i(), n)) return !1;
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
  function aa(t, e, l, a) {
    e &= ~Rc, e &= ~Qa, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var i = 31 - be(n), u = 1 << i;
      a[i] = -1, n &= ~u;
    }
    l !== 0 && Zn(t, l, e);
  }
  function Yu() {
    return (xt & 6) === 0 ? (Di(0), !1) : !0;
  }
  function qc() {
    if (ut !== null) {
      if (St === 0)
        var t = ut.return;
      else
        t = ut, zl = Na = null, tc(t), zn = null, ri = 0, t = ut;
      for (; t !== null; )
        bs(t.alternate, t), t = t.return;
      ut = null;
    }
  }
  function Rn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, zh(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), Nl = 0, qc(), At = t, ut = l = Sl(t.current, null), ot = e, St = 0, je = null, Pl = !1, Cn = Hl(t, e), Bc = !1, Un = qe = Rc = Qa = ta = qt = 0, _e = Ai = null, Nc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - be(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return Rl = e, fu(), l;
  }
  function Qs(t, e) {
    lt = null, b.H = yi, e === Tn || e === gu ? (e = ir(), St = 3) : e === Xf ? (e = ir(), St = 4) : St = e === pc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, je = e, ut === null && (qt = 1, Ou(
      t,
      Ve(e, t.current)
    ));
  }
  function Vs() {
    var t = we.current;
    return t === null ? !0 : (ot & 4194048) === ot ? ke === null : (ot & 62914560) === ot || (ot & 536870912) !== 0 ? t === ke : !1;
  }
  function Zs() {
    var t = b.H;
    return b.H = yi, t === null ? yi : t;
  }
  function Ks() {
    var t = b.A;
    return b.A = eh, t;
  }
  function Lu() {
    qt = 4, Pl || (ot & 4194048) !== ot && we.current !== null || (Cn = !0), (ta & 134217727) === 0 && (Qa & 134217727) === 0 || At === null || aa(
      At,
      ot,
      qe,
      !1
    );
  }
  function Gc(t, e, l) {
    var a = xt;
    xt |= 2;
    var n = Zs(), i = Ks();
    (At !== t || ot !== e) && (Gu = null, Rn(t, e)), e = !1;
    var u = qt;
    t: do
      try {
        if (St !== 0 && ut !== null) {
          var f = ut, r = je;
          switch (St) {
            case 8:
              qc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              we.current === null && (e = !0);
              var p = St;
              if (St = 0, je = null, Nn(t, f, r, p), l && Cn) {
                u = 0;
                break t;
              }
              break;
            default:
              p = St, St = 0, je = null, Nn(t, f, r, p);
          }
        }
        nh(), u = qt;
        break;
      } catch (S) {
        Qs(t, S);
      }
    while (!0);
    return e && t.shellSuspendCounter++, zl = Na = null, xt = a, b.H = n, b.A = i, ut === null && (At = null, ot = 0, fu()), u;
  }
  function nh() {
    for (; ut !== null; ) Js(ut);
  }
  function ih(t, e) {
    var l = xt;
    xt |= 2;
    var a = Zs(), n = Ks();
    At !== t || ot !== e ? (Gu = null, qu = he() + 500, Rn(t, e)) : Cn = Hl(
      t,
      e
    );
    t: do
      try {
        if (St !== 0 && ut !== null) {
          e = ut;
          var i = je;
          e: switch (St) {
            case 1:
              St = 0, je = null, Nn(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (ar(i)) {
                St = 0, je = null, ks(e);
                break;
              }
              e = function() {
                St !== 2 && St !== 9 || At !== t || (St = 7), gl(t);
              }, i.then(e, e);
              break t;
            case 3:
              St = 7;
              break t;
            case 4:
              St = 5;
              break t;
            case 7:
              ar(i) ? (St = 0, je = null, ks(e)) : (St = 0, je = null, Nn(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (ut.tag) {
                case 26:
                  u = ut.memoizedState;
                case 5:
                case 27:
                  var f = ut;
                  if (u ? Rd(u) : f.stateNode.complete) {
                    St = 0, je = null;
                    var r = f.sibling;
                    if (r !== null) ut = r;
                    else {
                      var p = f.return;
                      p !== null ? (ut = p, Xu(p)) : ut = null;
                    }
                    break e;
                  }
              }
              St = 0, je = null, Nn(t, e, i, 5);
              break;
            case 6:
              St = 0, je = null, Nn(t, e, i, 6);
              break;
            case 8:
              qc(), qt = 6;
              break t;
            default:
              throw Error(h(462));
          }
        }
        uh();
        break;
      } catch (S) {
        Qs(t, S);
      }
    while (!0);
    return zl = Na = null, b.H = a, b.A = n, xt = l, ut !== null ? 0 : (At = null, ot = 0, fu(), qt);
  }
  function uh() {
    for (; ut !== null && !Xi(); )
      Js(ut);
  }
  function Js(t) {
    var e = vs(t.alternate, t, Rl);
    t.memoizedProps = t.pendingProps, e === null ? Xu(t) : ut = e;
  }
  function ks(t) {
    var e = t, l = e.alternate;
    switch (e.tag) {
      case 15:
      case 0:
        e = ss(
          l,
          e,
          e.pendingProps,
          e.type,
          void 0,
          ot
        );
        break;
      case 11:
        e = ss(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          ot
        );
        break;
      case 5:
        tc(e);
      default:
        bs(l, e), e = ut = Ko(e, Rl), e = vs(l, e, Rl);
    }
    t.memoizedProps = t.pendingProps, e === null ? Xu(t) : ut = e;
  }
  function Nn(t, e, l, a) {
    zl = Na = null, tc(e), zn = null, ri = 0;
    var n = e.return;
    try {
      if (km(
        t,
        n,
        e,
        l,
        ot
      )) {
        qt = 1, Ou(
          t,
          Ve(l, t.current)
        ), ut = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw ut = n, i;
      qt = 1, Ou(
        t,
        Ve(l, t.current)
      ), ut = null;
      return;
    }
    e.flags & 32768 ? (dt || a === 1 ? t = !0 : Cn || (ot & 536870912) !== 0 ? t = !1 : (Pl = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = we.current, a !== null && a.tag === 13 && (a.flags |= 16384))), Fs(e, t)) : Xu(e);
  }
  function Xu(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        Fs(
          e,
          Pl
        );
        return;
      }
      t = e.return;
      var l = $m(
        e.alternate,
        e,
        Rl
      );
      if (l !== null) {
        ut = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        ut = e;
        return;
      }
      ut = e = t;
    } while (e !== null);
    qt === 0 && (qt = 5);
  }
  function Fs(t, e) {
    do {
      var l = Im(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, ut = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        ut = t;
        return;
      }
      ut = t = l;
    } while (t !== null);
    qt = 6, ut = null;
  }
  function Ws(t, e, l, a, n, i, u, f, r) {
    t.cancelPendingCommit = null;
    do
      Qu();
    while (Ft !== 0);
    if ((xt & 6) !== 0) throw Error(h(327));
    if (e !== null) {
      if (e === t.current) throw Error(h(177));
      if (i = e.lanes | e.childLanes, i |= _f, $a(
        t,
        l,
        i,
        u,
        f,
        r
      ), t === At && (ut = At = null, ot = 0), Bn = e, la = t, Nl = l, wc = i, Hc = n, Gs = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, rh(Ka, function() {
        return ed(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = b.T, b.T = null, n = U.p, U.p = 2, u = xt, xt |= 4;
        try {
          Pm(t, e, l);
        } finally {
          xt = u, U.p = n, b.T = a;
        }
      }
      Ft = 1, $s(), Is(), Ps();
    }
  }
  function $s() {
    if (Ft === 1) {
      Ft = 0;
      var t = la, e = Bn, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = b.T, b.T = null;
        var a = U.p;
        U.p = 2;
        var n = xt;
        xt |= 4;
        try {
          Us(e, t);
          var i = $c, u = jo(t.containerInfo), f = i.focusedElem, r = i.selectionRange;
          if (u !== f && f && f.ownerDocument && Ho(
            f.ownerDocument.documentElement,
            f
          )) {
            if (r !== null && Tf(f)) {
              var p = r.start, S = r.end;
              if (S === void 0 && (S = p), "selectionStart" in f)
                f.selectionStart = p, f.selectionEnd = Math.min(
                  S,
                  f.value.length
                );
              else {
                var E = f.ownerDocument || document, v = E && E.defaultView || window;
                if (v.getSelection) {
                  var x = v.getSelection(), G = f.textContent.length, Z = Math.min(r.start, G), Et = r.end === void 0 ? Z : Math.min(r.end, G);
                  !x.extend && Z > Et && (u = Et, Et = Z, Z = u);
                  var m = wo(
                    f,
                    Z
                  ), s = wo(
                    f,
                    Et
                  );
                  if (m && s && (x.rangeCount !== 1 || x.anchorNode !== m.node || x.anchorOffset !== m.offset || x.focusNode !== s.node || x.focusOffset !== s.offset)) {
                    var g = E.createRange();
                    g.setStart(m.node, m.offset), x.removeAllRanges(), Z > Et ? (x.addRange(g), x.extend(s.node, s.offset)) : (g.setEnd(s.node, s.offset), x.addRange(g));
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
              var T = E[f];
              T.element.scrollLeft = T.left, T.element.scrollTop = T.top;
            }
          }
          ef = !!Wc, $c = Wc = null;
        } finally {
          xt = n, U.p = a, b.T = l;
        }
      }
      t.current = e, Ft = 2;
    }
  }
  function Is() {
    if (Ft === 2) {
      Ft = 0;
      var t = la, e = Bn, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = b.T, b.T = null;
        var a = U.p;
        U.p = 2;
        var n = xt;
        xt |= 4;
        try {
          As(t, e.alternate, e);
        } finally {
          xt = n, U.p = a, b.T = l;
        }
      }
      Ft = 3;
    }
  }
  function Ps() {
    if (Ft === 4 || Ft === 3) {
      Ft = 0, Qn();
      var t = la, e = Bn, l = Nl, a = Gs;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? Ft = 5 : (Ft = 0, Bn = la = null, td(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (ea = null), ba(l), e = e.stateNode, ye && typeof ye.onCommitFiberRoot == "function")
        try {
          ye.onCommitFiberRoot(
            ha,
            e,
            void 0,
            (e.current.flags & 128) === 128
          );
        } catch {
        }
      if (a !== null) {
        e = b.T, n = U.p, U.p = 2, b.T = null;
        try {
          for (var i = t.onRecoverableError, u = 0; u < a.length; u++) {
            var f = a[u];
            i(f.value, {
              componentStack: f.stack
            });
          }
        } finally {
          b.T = e, U.p = n;
        }
      }
      (Nl & 3) !== 0 && Qu(), gl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === jc ? _i++ : (_i = 0, jc = t) : _i = 0, Di(0);
    }
  }
  function td(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, ci(e)));
  }
  function Qu() {
    return $s(), Is(), Ps(), ed();
  }
  function ed() {
    if (Ft !== 5) return !1;
    var t = la, e = wc;
    wc = 0;
    var l = ba(Nl), a = b.T, n = U.p;
    try {
      U.p = 32 > l ? 32 : l, b.T = null, l = Hc, Hc = null;
      var i = la, u = Nl;
      if (Ft = 0, Bn = la = null, Nl = 0, (xt & 6) !== 0) throw Error(h(331));
      var f = xt;
      if (xt |= 4, Hs(i.current), Rs(
        i,
        i.current,
        u,
        l
      ), xt = f, Di(0, !1), ye && typeof ye.onPostCommitFiberRoot == "function")
        try {
          ye.onPostCommitFiberRoot(ha, i);
        } catch {
        }
      return !0;
    } finally {
      U.p = n, b.T = a, td(t, e);
    }
  }
  function ld(t, e, l) {
    e = Ve(l, e), e = gc(t.stateNode, e, 2), t = Fl(t, e, 2), t !== null && (va(t, 2), gl(t));
  }
  function Tt(t, e, l) {
    if (t.tag === 3)
      ld(t, t, l);
    else
      for (; e !== null; ) {
        if (e.tag === 3) {
          ld(
            e,
            t,
            l
          );
          break;
        } else if (e.tag === 1) {
          var a = e.stateNode;
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (ea === null || !ea.has(a))) {
            t = Ve(l, t), l = as(2), a = Fl(e, l, 2), a !== null && (ns(
              l,
              a,
              e,
              t
            ), va(a, 2), gl(a));
            break;
          }
        }
        e = e.return;
      }
  }
  function Yc(t, e, l) {
    var a = t.pingCache;
    if (a === null) {
      a = t.pingCache = new lh();
      var n = /* @__PURE__ */ new Set();
      a.set(e, n);
    } else
      n = a.get(e), n === void 0 && (n = /* @__PURE__ */ new Set(), a.set(e, n));
    n.has(l) || (Bc = !0, n.add(l), t = fh.bind(null, t, e, l), e.then(t, t));
  }
  function fh(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, At === t && (ot & l) === l && (qt === 4 || qt === 3 && (ot & 62914560) === ot && 300 > he() - ju ? (xt & 2) === 0 && Rn(t, 0) : Rc |= l, Un === ot && (Un = 0)), gl(t);
  }
  function ad(t, e) {
    e === 0 && (e = fl()), t = Ua(t, e), t !== null && (va(t, e), gl(t));
  }
  function ch(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), ad(t, l);
  }
  function oh(t, e) {
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
        throw Error(h(314));
    }
    a !== null && a.delete(e), ad(t, l);
  }
  function rh(t, e) {
    return da(t, e);
  }
  var Vu = null, wn = null, Lc = !1, Zu = !1, Xc = !1, na = 0;
  function gl(t) {
    t !== wn && t.next === null && (wn === null ? Vu = wn = t : wn = wn.next = t), Zu = !0, Lc || (Lc = !0, dh());
  }
  function Di(t, e) {
    if (!Xc && Zu) {
      Xc = !0;
      do
        for (var l = !1, a = Vu; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var i = 0;
            else {
              var u = a.suspendedLanes, f = a.pingedLanes;
              i = (1 << 31 - be(42 | t) + 1) - 1, i &= n & ~(u & ~f), i = i & 201326741 ? i & 201326741 | 1 : i ? i | 2 : 0;
            }
            i !== 0 && (l = !0, fd(a, i));
          } else
            i = ot, i = pa(
              a,
              a === At ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || Hl(a, i) || (l = !0, fd(a, i));
          a = a.next;
        }
      while (l);
      Xc = !1;
    }
  }
  function sh() {
    nd();
  }
  function nd() {
    Zu = Lc = !1;
    var t = 0;
    na !== 0 && Th() && (t = na);
    for (var e = he(), l = null, a = Vu; a !== null; ) {
      var n = a.next, i = id(a, e);
      i === 0 ? (a.next = null, l === null ? Vu = n : l.next = n, n === null && (wn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (Zu = !0)), a = n;
    }
    Ft !== 0 && Ft !== 5 || Di(t), na !== 0 && (na = 0);
  }
  function id(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - be(i), f = 1 << u, r = n[u];
      r === -1 ? ((f & l) === 0 || (f & a) !== 0) && (n[u] = mf(f, e)) : r <= e && (t.expiredLanes |= f), i &= ~f;
    }
    if (e = At, l = ot, l = pa(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (St === 2 || St === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && ma(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Hl(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && ma(a), ba(l)) {
        case 2:
        case 8:
          l = Vn;
          break;
        case 32:
          l = Ka;
          break;
        case 268435456:
          l = Qi;
          break;
        default:
          l = Ka;
      }
      return a = ud.bind(null, t), l = da(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && ma(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function ud(t, e) {
    if (Ft !== 0 && Ft !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Qu() && t.callbackNode !== l)
      return null;
    var a = ot;
    return a = pa(
      t,
      t === At ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Ls(t, a, e), id(t, he()), t.callbackNode != null && t.callbackNode === l ? ud.bind(null, t) : null);
  }
  function fd(t, e) {
    if (Qu()) return null;
    Ls(t, e, !0);
  }
  function dh() {
    Mh(function() {
      (xt & 6) !== 0 ? da(
        Za,
        sh
      ) : nd();
    });
  }
  function Qc() {
    if (na === 0) {
      var t = xn;
      t === 0 && (t = ka, ka <<= 1, (ka & 261888) === 0 && (ka = 256)), na = t;
    }
    return na;
  }
  function cd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : ln("" + t);
  }
  function od(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function mh(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = cd(
        (n[fe] || null).action
      ), u = a.submitter;
      u && (e = (e = u[fe] || null) ? cd(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
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
                if (na !== 0) {
                  var r = u ? od(n, u) : new FormData(n);
                  oc(
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
                typeof i == "function" && (f.preventDefault(), r = u ? od(n, u) : new FormData(n), oc(
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
  for (var Vc = 0; Vc < Af.length; Vc++) {
    var Zc = Af[Vc], hh = Zc.toLowerCase(), gh = Zc[0].toUpperCase() + Zc.slice(1);
    ll(
      hh,
      "on" + gh
    );
  }
  ll(Yo, "onAnimationEnd"), ll(Lo, "onAnimationIteration"), ll(Xo, "onAnimationStart"), ll("dblclick", "onDoubleClick"), ll("focusin", "onFocus"), ll("focusout", "onBlur"), ll(Um, "onTransitionRun"), ll(Bm, "onTransitionStart"), ll(Rm, "onTransitionCancel"), ll(Qo, "onTransitionEnd"), ql("onMouseEnter", ["mouseout", "mouseover"]), ql("onMouseLeave", ["mouseout", "mouseover"]), ql("onPointerEnter", ["pointerout", "pointerover"]), ql("onPointerLeave", ["pointerout", "pointerover"]), rl(
    "onChange",
    "change click focusin focusout input keydown keyup selectionchange".split(" ")
  ), rl(
    "onSelect",
    "focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(
      " "
    )
  ), rl("onBeforeInput", [
    "compositionend",
    "keypress",
    "textInput",
    "paste"
  ]), rl(
    "onCompositionEnd",
    "compositionend focusout keydown keypress keyup mousedown".split(" ")
  ), rl(
    "onCompositionStart",
    "compositionstart focusout keydown keypress keyup mousedown".split(" ")
  ), rl(
    "onCompositionUpdate",
    "compositionupdate focusout keydown keypress keyup mousedown".split(" ")
  );
  var Oi = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), ph = new Set(
    "beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(Oi)
  );
  function rd(t, e) {
    e = (e & 4) !== 0;
    for (var l = 0; l < t.length; l++) {
      var a = t[l], n = a.event;
      a = a.listeners;
      t: {
        var i = void 0;
        if (e)
          for (var u = a.length - 1; 0 <= u; u--) {
            var f = a[u], r = f.instance, p = f.currentTarget;
            if (f = f.listener, r !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = p;
            try {
              i(n);
            } catch (S) {
              uu(S);
            }
            n.currentTarget = null, i = r;
          }
        else
          for (u = 0; u < a.length; u++) {
            if (f = a[u], r = f.instance, p = f.currentTarget, f = f.listener, r !== i && n.isPropagationStopped())
              break t;
            i = f, n.currentTarget = p;
            try {
              i(n);
            } catch (S) {
              uu(S);
            }
            n.currentTarget = null, i = r;
          }
      }
    }
  }
  function ft(t, e) {
    var l = e[Kn];
    l === void 0 && (l = e[Kn] = /* @__PURE__ */ new Set());
    var a = t + "__bubble";
    l.has(a) || (sd(e, t, 2, !1), l.add(a));
  }
  function Kc(t, e, l) {
    var a = 0;
    e && (a |= 4), sd(
      l,
      t,
      a,
      e
    );
  }
  var Ku = "_reactListening" + Math.random().toString(36).slice(2);
  function Jc(t) {
    if (!t[Ku]) {
      t[Ku] = !0, Jn.forEach(function(l) {
        l !== "selectionchange" && (ph.has(l) || Kc(l, !1, t), Kc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[Ku] || (e[Ku] = !0, Kc("selectionchange", !1, e));
    }
  }
  function sd(t, e, l, a) {
    switch (Yd(e)) {
      case 2:
        var n = Vh;
        break;
      case 8:
        n = Zh;
        break;
      default:
        n = co;
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
  function kc(t, e, l, a, n) {
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
            if (u = cl(f), u === null) return;
            if (r = u.tag, r === 5 || r === 6 || r === 26 || r === 27) {
              a = i = u;
              continue t;
            }
            f = f.parentNode;
          }
        }
        a = a.return;
      }
    nn(function() {
      var p = i, S = an(l), E = [];
      t: {
        var v = Vo.get(t);
        if (v !== void 0) {
          var x = on, G = t;
          switch (t) {
            case "keypress":
              if (Ea(l) === 0) break t;
            case "keydown":
            case "keyup":
              x = om;
              break;
            case "focusin":
              G = "focus", x = J;
              break;
            case "focusout":
              G = "blur", x = J;
              break;
            case "beforeblur":
            case "afterblur":
              x = J;
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
              x = ti;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              x = M;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              x = dm;
              break;
            case Yo:
            case Lo:
            case Xo:
              x = ht;
              break;
            case Qo:
              x = hm;
              break;
            case "scroll":
            case "scrollend":
              x = au;
              break;
            case "wheel":
              x = pm;
              break;
            case "copy":
            case "cut":
            case "paste":
              x = Ht;
              break;
            case "gotpointercapture":
            case "lostpointercapture":
            case "pointercancel":
            case "pointerdown":
            case "pointermove":
            case "pointerout":
            case "pointerover":
            case "pointerup":
              x = So;
              break;
            case "toggle":
            case "beforetoggle":
              x = ym;
          }
          var Z = (e & 4) !== 0, Et = !Z && (t === "scroll" || t === "scrollend"), m = Z ? v !== null ? v + "Capture" : null : v;
          Z = [];
          for (var s = p, g; s !== null; ) {
            var T = s;
            if (g = T.stateNode, T = T.tag, T !== 5 && T !== 26 && T !== 27 || g === null || m === null || (T = za(s, m), T != null && Z.push(
              Ci(s, T, g)
            )), Et) break;
            s = s.return;
          }
          0 < Z.length && (v = new x(
            v,
            G,
            null,
            l,
            S
          ), E.push({ event: v, listeners: Z }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (v = t === "mouseover" || t === "pointerover", x = t === "mouseout" || t === "pointerout", v && l !== Wn && (G = l.relatedTarget || l.fromElement) && (cl(G) || G[yl]))
            break t;
          if ((x || v) && (v = S.window === S ? S : (v = S.ownerDocument) ? v.defaultView || v.parentWindow : window, x ? (G = l.relatedTarget || l.toElement, x = p, G = G ? cl(G) : null, G !== null && (Et = Ut(G), Z = G.tag, G !== Et || Z !== 5 && Z !== 27 && Z !== 6) && (G = null)) : (x = null, G = p), x !== G)) {
            if (Z = ti, T = "onMouseLeave", m = "onMouseEnter", s = "mouse", (t === "pointerout" || t === "pointerover") && (Z = So, T = "onPointerLeave", m = "onPointerEnter", s = "pointer"), Et = x == null ? v : jl(x), g = G == null ? v : jl(G), v = new Z(
              T,
              s + "leave",
              x,
              l,
              S
            ), v.target = Et, v.relatedTarget = g, T = null, cl(S) === p && (Z = new Z(
              m,
              s + "enter",
              G,
              l,
              S
            ), Z.target = g, Z.relatedTarget = Et, T = Z), Et = T, x && G)
              e: {
                for (Z = vh, m = x, s = G, g = 0, T = m; T; T = Z(T))
                  g++;
                T = 0;
                for (var V = s; V; V = Z(V))
                  T++;
                for (; 0 < g - T; )
                  m = Z(m), g--;
                for (; 0 < T - g; )
                  s = Z(s), T--;
                for (; g--; ) {
                  if (m === s || s !== null && m === s.alternate) {
                    Z = m;
                    break e;
                  }
                  m = Z(m), s = Z(s);
                }
                Z = null;
              }
            else Z = null;
            x !== null && dd(
              E,
              v,
              x,
              Z,
              !1
            ), G !== null && Et !== null && dd(
              E,
              Et,
              G,
              Z,
              !0
            );
          }
        }
        t: {
          if (v = p ? jl(p) : window, x = v.nodeName && v.nodeName.toLowerCase(), x === "select" || x === "input" && v.type === "file")
            var pt = Oo;
          else if (_o(v))
            if (Co)
              pt = Dm;
            else {
              pt = Am;
              var Y = Em;
            }
          else
            x = v.nodeName, !x || x.toLowerCase() !== "input" || v.type !== "checkbox" && v.type !== "radio" ? p && ct(p.elementType) && (pt = Oo) : pt = _m;
          if (pt && (pt = pt(t, p))) {
            Do(
              E,
              pt,
              l,
              S
            );
            break t;
          }
          Y && Y(t, v, p), t === "focusout" && p && v.type === "number" && p.memoizedProps.value != null && c(v, "number", v.value);
        }
        switch (Y = p ? jl(p) : window, t) {
          case "focusin":
            (_o(Y) || Y.contentEditable === "true") && (dn = Y, zf = p, ii = null);
            break;
          case "focusout":
            ii = zf = dn = null;
            break;
          case "mousedown":
            Mf = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Mf = !1, qo(E, l, S);
            break;
          case "selectionchange":
            if (Cm) break;
          case "keydown":
          case "keyup":
            qo(E, l, S);
        }
        var nt;
        if (bf)
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
          sn ? Eo(t, l) && (rt = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (rt = "onCompositionStart");
        rt && (To && l.locale !== "ko" && (sn || rt !== "onCompositionStart" ? rt === "onCompositionEnd" && sn && (nt = $n()) : (ze = S, un = "value" in ze ? ze.value : ze.textContent, sn = !0)), Y = Ju(p, rt), 0 < Y.length && (rt = new Xl(
          rt,
          t,
          null,
          l,
          S
        ), E.push({ event: rt, listeners: Y }), nt ? rt.data = nt : (nt = Ao(l), nt !== null && (rt.data = nt)))), (nt = xm ? Sm(t, l) : Tm(t, l)) && (rt = Ju(p, "onBeforeInput"), 0 < rt.length && (Y = new Xl(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          S
        ), E.push({
          event: Y,
          listeners: rt
        }), Y.data = nt)), mh(
          E,
          t,
          p,
          l,
          S
        );
      }
      rd(E, e);
    });
  }
  function Ci(t, e, l) {
    return {
      instance: t,
      listener: e,
      currentTarget: l
    };
  }
  function Ju(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, i = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = za(t, l), n != null && a.unshift(
        Ci(t, n, i)
      ), n = za(t, e), n != null && a.push(
        Ci(t, n, i)
      )), t.tag === 3) return a;
      t = t.return;
    }
    return [];
  }
  function vh(t) {
    if (t === null) return null;
    do
      t = t.return;
    while (t && t.tag !== 5 && t.tag !== 27);
    return t || null;
  }
  function dd(t, e, l, a, n) {
    for (var i = e._reactName, u = []; l !== null && l !== a; ) {
      var f = l, r = f.alternate, p = f.stateNode;
      if (f = f.tag, r !== null && r === a) break;
      f !== 5 && f !== 26 && f !== 27 || p === null || (r = p, n ? (p = za(l, i), p != null && u.unshift(
        Ci(l, p, r)
      )) : n || (p = za(l, i), p != null && u.push(
        Ci(l, p, r)
      ))), l = l.return;
    }
    u.length !== 0 && t.push({ event: e, listeners: u });
  }
  var yh = /\r\n?/g, bh = /\u0000|\uFFFD/g;
  function md(t) {
    return (typeof t == "string" ? t : "" + t).replace(yh, `
`).replace(bh, "");
  }
  function hd(t, e) {
    return e = md(e), md(t) === e;
  }
  function Mt(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || R(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && R(t, "" + a);
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
        I(t, a, i);
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
        a = ln("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = el);
        break;
      case "onScroll":
        a != null && ft("scroll", t);
        break;
      case "onScrollEnd":
        a != null && ft("scrollend", t);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(h(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(h(60));
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
        ft("beforetoggle", t), ft("toggle", t), Pa(t, "popover", a);
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
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = bt.get(l) || l, Pa(t, l, a));
    }
  }
  function Fc(t, e, l, a, n, i) {
    switch (l) {
      case "style":
        I(t, a, i);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(h(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(h(60));
            t.innerHTML = l;
          }
        }
        break;
      case "children":
        typeof a == "string" ? R(t, a) : (typeof a == "number" || typeof a == "bigint") && R(t, "" + a);
        break;
      case "onScroll":
        a != null && ft("scroll", t);
        break;
      case "onScrollEnd":
        a != null && ft("scrollend", t);
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
        if (!Wi.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[fe] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : Pa(t, l, a);
          }
    }
  }
  function de(t, e, l) {
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
        ft("error", t), ft("load", t);
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
                  throw Error(h(137, e));
                default:
                  Mt(t, e, i, u, l, null);
              }
          }
        n && Mt(t, e, "srcSet", l.srcSet, l, null), a && Mt(t, e, "src", l.src, l, null);
        return;
      case "input":
        ft("invalid", t);
        var f = i = u = n = null, r = null, p = null;
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
                    throw Error(h(137, e));
                  break;
                default:
                  Mt(t, e, a, S, l, null);
              }
          }
        eu(
          t,
          i,
          f,
          r,
          p,
          u,
          n,
          !1
        );
        return;
      case "select":
        ft("invalid", t), a = u = i = null;
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
        e = i, l = u, t.multiple = !!a, e != null ? o(t, !!a, e, !1) : l != null && o(t, !!a, l, !0);
        return;
      case "textarea":
        ft("invalid", t), i = n = a = null;
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
                if (f != null) throw Error(h(91));
                break;
              default:
                Mt(t, e, u, f, l, null);
            }
        C(t, a, n, i);
        return;
      case "option":
        for (r in l)
          l.hasOwnProperty(r) && (a = l[r], a != null) && (r === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : Mt(t, e, r, a, l, null));
        return;
      case "dialog":
        ft("beforetoggle", t), ft("toggle", t), ft("cancel", t), ft("close", t);
        break;
      case "iframe":
      case "object":
        ft("load", t);
        break;
      case "video":
      case "audio":
        for (a = 0; a < Oi.length; a++)
          ft(Oi[a], t);
        break;
      case "image":
        ft("error", t), ft("load", t);
        break;
      case "details":
        ft("toggle", t);
        break;
      case "embed":
      case "source":
      case "link":
        ft("error", t), ft("load", t);
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
                throw Error(h(137, e));
              default:
                Mt(t, e, p, a, l, null);
            }
        return;
      default:
        if (ct(e)) {
          for (S in l)
            l.hasOwnProperty(S) && (a = l[S], a !== void 0 && Fc(
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
  function xh(t, e, l, a) {
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
        var n = null, i = null, u = null, f = null, r = null, p = null, S = null;
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
                a.hasOwnProperty(x) || Mt(t, e, x, null, a, E);
            }
        }
        for (var v in a) {
          var x = a[v];
          if (E = l[v], a.hasOwnProperty(v) && (x != null || E != null))
            switch (v) {
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
                  throw Error(h(137, e));
                break;
              default:
                x !== E && Mt(
                  t,
                  e,
                  v,
                  x,
                  a,
                  E
                );
            }
        }
        Fn(
          t,
          u,
          f,
          r,
          p,
          S,
          i,
          n
        );
        return;
      case "select":
        x = u = f = v = null;
        for (i in l)
          if (r = l[i], l.hasOwnProperty(i) && r != null)
            switch (i) {
              case "value":
                break;
              case "multiple":
                x = r;
              default:
                a.hasOwnProperty(i) || Mt(
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
                v = i;
                break;
              case "defaultValue":
                f = i;
                break;
              case "multiple":
                u = i;
              default:
                i !== r && Mt(
                  t,
                  e,
                  n,
                  i,
                  a,
                  r
                );
            }
        e = f, l = u, a = x, v != null ? o(t, !!l, v, !1) : !!a != !!l && (e != null ? o(t, !!l, e, !0) : o(t, !!l, l ? [] : "", !1));
        return;
      case "textarea":
        x = v = null;
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
                v = n;
                break;
              case "defaultValue":
                x = n;
                break;
              case "children":
                break;
              case "dangerouslySetInnerHTML":
                if (n != null) throw Error(h(91));
                break;
              default:
                n !== i && Mt(t, e, u, n, a, i);
            }
        y(t, v, x);
        return;
      case "option":
        for (var G in l)
          v = l[G], l.hasOwnProperty(G) && v != null && !a.hasOwnProperty(G) && (G === "selected" ? t.selected = !1 : Mt(
            t,
            e,
            G,
            null,
            a,
            v
          ));
        for (r in a)
          v = a[r], x = l[r], a.hasOwnProperty(r) && v !== x && (v != null || x != null) && (r === "selected" ? t.selected = v && typeof v != "function" && typeof v != "symbol" : Mt(
            t,
            e,
            r,
            v,
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
          v = l[Z], l.hasOwnProperty(Z) && v != null && !a.hasOwnProperty(Z) && Mt(t, e, Z, null, a, v);
        for (p in a)
          if (v = a[p], x = l[p], a.hasOwnProperty(p) && v !== x && (v != null || x != null))
            switch (p) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (v != null)
                  throw Error(h(137, e));
                break;
              default:
                Mt(
                  t,
                  e,
                  p,
                  v,
                  a,
                  x
                );
            }
        return;
      default:
        if (ct(e)) {
          for (var Et in l)
            v = l[Et], l.hasOwnProperty(Et) && v !== void 0 && !a.hasOwnProperty(Et) && Fc(
              t,
              e,
              Et,
              void 0,
              a,
              v
            );
          for (S in a)
            v = a[S], x = l[S], !a.hasOwnProperty(S) || v === x || v === void 0 && x === void 0 || Fc(
              t,
              e,
              S,
              v,
              a,
              x
            );
          return;
        }
    }
    for (var m in l)
      v = l[m], l.hasOwnProperty(m) && v != null && !a.hasOwnProperty(m) && Mt(t, e, m, null, a, v);
    for (E in a)
      v = a[E], x = l[E], !a.hasOwnProperty(E) || v === x || v == null && x == null || Mt(t, e, E, v, a, x);
  }
  function gd(t) {
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
        var n = l[a], i = n.transferSize, u = n.initiatorType, f = n.duration;
        if (i && f && gd(u)) {
          for (u = 0, f = n.responseEnd, a += 1; a < l.length; a++) {
            var r = l[a], p = r.startTime;
            if (p > f) break;
            var S = r.transferSize, E = r.initiatorType;
            S && gd(E) && (r = r.responseEnd, u += S * (r < f ? 1 : (f - p) / (r - p)));
          }
          if (--a, e += 8 * (i + u) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var Wc = null, $c = null;
  function ku(t) {
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
  function vd(t, e) {
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
  function Ic(t, e) {
    return t === "textarea" || t === "noscript" || typeof e.children == "string" || typeof e.children == "number" || typeof e.children == "bigint" || typeof e.dangerouslySetInnerHTML == "object" && e.dangerouslySetInnerHTML !== null && e.dangerouslySetInnerHTML.__html != null;
  }
  var Pc = null;
  function Th() {
    var t = window.event;
    return t && t.type === "popstate" ? t === Pc ? !1 : (Pc = t, !0) : (Pc = null, !1);
  }
  var yd = typeof setTimeout == "function" ? setTimeout : void 0, zh = typeof clearTimeout == "function" ? clearTimeout : void 0, bd = typeof Promise == "function" ? Promise : void 0, Mh = typeof queueMicrotask == "function" ? queueMicrotask : typeof bd < "u" ? function(t) {
    return bd.resolve(null).then(t).catch(Eh);
  } : yd;
  function Eh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function ia(t) {
    return t === "head";
  }
  function xd(t, e) {
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
            var u = i.nextSibling, f = i.nodeName;
            i[xa] || f === "SCRIPT" || f === "STYLE" || f === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && Ui(t.ownerDocument.body);
      l = n;
    } while (l);
    Gn(e);
  }
  function Sd(t, e) {
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
  function to(t) {
    var e = t.firstChild;
    for (e && e.nodeType === 10 && (e = e.nextSibling); e; ) {
      var l = e;
      switch (e = e.nextSibling, l.nodeName) {
        case "HTML":
        case "HEAD":
        case "BODY":
          to(l), Ia(l);
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
  function Ah(t, e, l, a) {
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
      if (t = Fe(t.nextSibling), t === null) break;
    }
    return null;
  }
  function _h(t, e, l) {
    if (e === "") return null;
    for (; t.nodeType !== 3; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !l || (t = Fe(t.nextSibling), t === null)) return null;
    return t;
  }
  function Td(t, e) {
    for (; t.nodeType !== 8; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !e || (t = Fe(t.nextSibling), t === null)) return null;
    return t;
  }
  function eo(t) {
    return t.data === "$?" || t.data === "$~";
  }
  function lo(t) {
    return t.data === "$!" || t.data === "$?" && t.ownerDocument.readyState !== "loading";
  }
  function Dh(t, e) {
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
  var ao = null;
  function zd(t) {
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
  function Md(t) {
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
  function Ed(t, e, l) {
    switch (e = ku(l), t) {
      case "html":
        if (t = e.documentElement, !t) throw Error(h(452));
        return t;
      case "head":
        if (t = e.head, !t) throw Error(h(453));
        return t;
      case "body":
        if (t = e.body, !t) throw Error(h(454));
        return t;
      default:
        throw Error(h(451));
    }
  }
  function Ui(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    Ia(t);
  }
  var We = /* @__PURE__ */ new Map(), Ad = /* @__PURE__ */ new Set();
  function Fu(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var wl = U.d;
  U.d = {
    f: Oh,
    r: Ch,
    D: Uh,
    C: Bh,
    L: Rh,
    m: Nh,
    X: Hh,
    S: wh,
    M: jh
  };
  function Oh() {
    var t = wl.f(), e = Yu();
    return t || e;
  }
  function Ch(t) {
    var e = ol(t);
    e !== null && e.tag === 5 && e.type === "form" ? Qr(e) : wl.r(t);
  }
  var Hn = typeof document > "u" ? null : document;
  function _d(t, e, l) {
    var a = Hn;
    if (a && typeof e == "string" && e) {
      var n = ce(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Ad.has(n) || (Ad.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), de(e, "link", t), Gt(e), a.head.appendChild(e)));
    }
  }
  function Uh(t) {
    wl.D(t), _d("dns-prefetch", t, null);
  }
  function Bh(t, e) {
    wl.C(t, e), _d("preconnect", t, e);
  }
  function Rh(t, e, l) {
    wl.L(t, e, l);
    var a = Hn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + ce(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + ce(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + ce(
        l.imageSizes
      ) + '"]')) : n += '[href="' + ce(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = jn(t);
          break;
        case "script":
          i = qn(t);
      }
      We.has(i) || (t = K(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), We.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Bi(i)) || e === "script" && a.querySelector(Ri(i)) || (e = a.createElement("link"), de(e, "link", t), Gt(e), a.head.appendChild(e)));
    }
  }
  function Nh(t, e) {
    wl.m(t, e);
    var l = Hn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + ce(a) + '"][href="' + ce(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = qn(t);
      }
      if (!We.has(i) && (t = K({ rel: "modulepreload", href: t }, e), We.set(i, t), l.querySelector(n) === null)) {
        switch (a) {
          case "audioworklet":
          case "paintworklet":
          case "serviceworker":
          case "sharedworker":
          case "worker":
          case "script":
            if (l.querySelector(Ri(i)))
              return;
        }
        a = l.createElement("link"), de(a, "link", t), Gt(a), l.head.appendChild(a);
      }
    }
  }
  function wh(t, e, l) {
    wl.S(t, e, l);
    var a = Hn;
    if (a && t) {
      var n = Pe(a).hoistableStyles, i = jn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var f = { loading: 0, preload: null };
        if (u = a.querySelector(
          Bi(i)
        ))
          f.loading = 5;
        else {
          t = K(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = We.get(i)) && no(t, l);
          var r = u = a.createElement("link");
          Gt(r), de(r, "link", t), r._p = new Promise(function(p, S) {
            r.onload = p, r.onerror = S;
          }), r.addEventListener("load", function() {
            f.loading |= 1;
          }), r.addEventListener("error", function() {
            f.loading |= 2;
          }), f.loading |= 4, Wu(u, e, a);
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
    wl.X(t, e);
    var l = Hn;
    if (l && t) {
      var a = Pe(l).hoistableScripts, n = qn(t), i = a.get(n);
      i || (i = l.querySelector(Ri(n)), i || (t = K({ src: t, async: !0 }, e), (e = We.get(n)) && io(t, e), i = l.createElement("script"), Gt(i), de(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function jh(t, e) {
    wl.M(t, e);
    var l = Hn;
    if (l && t) {
      var a = Pe(l).hoistableScripts, n = qn(t), i = a.get(n);
      i || (i = l.querySelector(Ri(n)), i || (t = K({ src: t, async: !0, type: "module" }, e), (e = We.get(n)) && io(t, e), i = l.createElement("script"), Gt(i), de(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Dd(t, e, l, a) {
    var n = (n = at.current) ? Fu(n) : null;
    if (!n) throw Error(h(446));
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
          )) && !i._p && (u.instance = i, u.state.loading = 5), We.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, We.set(t, l), i || qh(
            n,
            t,
            l,
            u.state
          ))), e && a === null)
            throw Error(h(528, ""));
          return u;
        }
        if (e && a !== null)
          throw Error(h(529, ""));
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
        throw Error(h(444, t));
    }
  }
  function jn(t) {
    return 'href="' + ce(t) + '"';
  }
  function Bi(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Od(t) {
    return K({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function qh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), de(e, "link", l), Gt(e), t.head.appendChild(e));
  }
  function qn(t) {
    return '[src="' + ce(t) + '"]';
  }
  function Ri(t) {
    return "script[async]" + t;
  }
  function Cd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + ce(l.href) + '"]'
          );
          if (a)
            return e.instance = a, Gt(a), a;
          var n = K({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), Gt(a), de(a, "style", n), Wu(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = jn(l.href);
          var i = t.querySelector(
            Bi(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, Gt(i), i;
          a = Od(l), (n = We.get(n)) && no(a, n), i = (t.ownerDocument || t).createElement("link"), Gt(i);
          var u = i;
          return u._p = new Promise(function(f, r) {
            u.onload = f, u.onerror = r;
          }), de(i, "link", a), e.state.loading |= 4, Wu(i, l.precedence, t), e.instance = i;
        case "script":
          return i = qn(l.src), (n = t.querySelector(
            Ri(i)
          )) ? (e.instance = n, Gt(n), n) : (a = l, (n = We.get(i)) && (a = K({}, l), io(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Gt(n), de(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(h(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, Wu(a, l.precedence, t));
    return e.instance;
  }
  function Wu(t, e, l) {
    for (var a = l.querySelectorAll(
      'link[rel="stylesheet"][data-precedence],style[data-precedence]'
    ), n = a.length ? a[a.length - 1] : null, i = n, u = 0; u < a.length; u++) {
      var f = a[u];
      if (f.dataset.precedence === e) i = f;
      else if (i !== n) break;
    }
    i ? i.parentNode.insertBefore(t, i.nextSibling) : (e = l.nodeType === 9 ? l.head : l, e.insertBefore(t, e.firstChild));
  }
  function no(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.title == null && (t.title = e.title);
  }
  function io(t, e) {
    t.crossOrigin == null && (t.crossOrigin = e.crossOrigin), t.referrerPolicy == null && (t.referrerPolicy = e.referrerPolicy), t.integrity == null && (t.integrity = e.integrity);
  }
  var $u = null;
  function Ud(t, e, l) {
    if ($u === null) {
      var a = /* @__PURE__ */ new Map(), n = $u = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = $u, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var i = l[n];
      if (!(i[xa] || i[Jt] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
        var u = i.getAttribute(e) || "";
        u = t + u;
        var f = a.get(u);
        f ? f.push(i) : a.set(u, [i]);
      }
    }
    return a;
  }
  function Bd(t, e, l) {
    t = t.ownerDocument || t, t.head.insertBefore(
      l,
      e === "title" ? t.querySelector("head > title") : null
    );
  }
  function Gh(t, e, l) {
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
  function Rd(t) {
    return !(t.type === "stylesheet" && (t.state.loading & 3) === 0);
  }
  function Yh(t, e, l, a) {
    if (l.type === "stylesheet" && (typeof a.media != "string" || matchMedia(a.media).matches !== !1) && (l.state.loading & 4) === 0) {
      if (l.instance === null) {
        var n = jn(a.href), i = e.querySelector(
          Bi(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = Iu.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, Gt(i);
          return;
        }
        i = e.ownerDocument || e, a = Od(a), (n = We.get(n)) && no(a, n), i = i.createElement("link"), Gt(i);
        var u = i;
        u._p = new Promise(function(f, r) {
          u.onload = f, u.onerror = r;
        }), de(i, "link", a), l.instance = i;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = Iu.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var uo = 0;
  function Lh(t, e) {
    return t.stylesheets && t.count === 0 && tf(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && tf(t, t.stylesheets), t.unsuspend) {
          var i = t.unsuspend;
          t.unsuspend = null, i();
        }
      }, 6e4 + e);
      0 < t.imgBytes && uo === 0 && (uo = 62500 * Sh());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && tf(t, t.stylesheets), t.unsuspend)) {
            var i = t.unsuspend;
            t.unsuspend = null, i();
          }
        },
        (t.imgBytes > uo ? 50 : 800) + e
      );
      return t.unsuspend = l, function() {
        t.unsuspend = null, clearTimeout(a), clearTimeout(n);
      };
    } : null;
  }
  function Iu() {
    if (this.count--, this.count === 0 && (this.imgCount === 0 || !this.waitingForImages)) {
      if (this.stylesheets) tf(this, this.stylesheets);
      else if (this.unsuspend) {
        var t = this.unsuspend;
        this.unsuspend = null, t();
      }
    }
  }
  var Pu = null;
  function tf(t, e) {
    t.stylesheets = null, t.unsuspend !== null && (t.count++, Pu = /* @__PURE__ */ new Map(), e.forEach(Xh, t), Pu = null, Iu.call(t));
  }
  function Xh(t, e) {
    if (!(e.state.loading & 4)) {
      var l = Pu.get(t);
      if (l) var a = l.get(null);
      else {
        l = /* @__PURE__ */ new Map(), Pu.set(t, l);
        for (var n = t.querySelectorAll(
          "link[data-precedence],style[data-precedence]"
        ), i = 0; i < n.length; i++) {
          var u = n[i];
          (u.nodeName === "LINK" || u.getAttribute("media") !== "not all") && (l.set(u.dataset.precedence, u), a = u);
        }
        a && l.set(null, a);
      }
      n = e.instance, u = n.getAttribute("data-precedence"), i = l.get(u) || a, i === a && l.set(null, n), l.set(u, n), this.count++, a = Iu.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), i ? i.parentNode.insertBefore(n, i.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Ni = {
    $$typeof: Nt,
    Provider: null,
    Consumer: null,
    _currentValue: N,
    _currentValue2: N,
    _threadCount: 0
  };
  function Qh(t, e, l, a, n, i, u, f, r) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Wa(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Wa(0), this.hiddenUpdates = Wa(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = r, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function Nd(t, e, l, a, n, i, u, f, r, p, S, E) {
    return t = new Qh(
      t,
      e,
      l,
      u,
      r,
      p,
      S,
      E,
      f
    ), e = 1, i === !0 && (e |= 24), i = Ne(3, null, null, e), t.current = i, i.stateNode = t, e = Gf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Qf(i), t;
  }
  function wd(t) {
    return t ? (t = gn, t) : gn;
  }
  function Hd(t, e, l, a, n, i) {
    n = wd(n), a.context === null ? a.context = n : a.pendingContext = n, a = kl(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = Fl(t, a, e), l !== null && (De(l, t, e), di(l, t, e));
  }
  function jd(t, e) {
    if (t = t.memoizedState, t !== null && t.dehydrated !== null) {
      var l = t.retryLane;
      t.retryLane = l !== 0 && l < e ? l : e;
    }
  }
  function fo(t, e) {
    jd(t, e), (t = t.alternate) && jd(t, e);
  }
  function qd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Ua(t, 67108864);
      e !== null && De(e, t, 67108864), fo(t, 67108864);
    }
  }
  function Gd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Ge();
      e = ya(e);
      var l = Ua(t, e);
      l !== null && De(l, t, e), fo(t, e);
    }
  }
  var ef = !0;
  function Vh(t, e, l, a) {
    var n = b.T;
    b.T = null;
    var i = U.p;
    try {
      U.p = 2, co(t, e, l, a);
    } finally {
      U.p = i, b.T = n;
    }
  }
  function Zh(t, e, l, a) {
    var n = b.T;
    b.T = null;
    var i = U.p;
    try {
      U.p = 8, co(t, e, l, a);
    } finally {
      U.p = i, b.T = n;
    }
  }
  function co(t, e, l, a) {
    if (ef) {
      var n = oo(a);
      if (n === null)
        kc(
          t,
          e,
          a,
          lf,
          l
        ), Ld(t, a);
      else if (Jh(
        n,
        t,
        e,
        l,
        a
      ))
        a.stopPropagation();
      else if (Ld(t, a), e & 4 && -1 < Kh.indexOf(t)) {
        for (; n !== null; ) {
          var i = ol(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = vl(i.pendingLanes);
                  if (u !== 0) {
                    var f = i;
                    for (f.pendingLanes |= 2, f.entangledLanes |= 2; u; ) {
                      var r = 1 << 31 - be(u);
                      f.entanglements[1] |= r, u &= ~r;
                    }
                    gl(i), (xt & 6) === 0 && (qu = he() + 500, Di(0));
                  }
                }
                break;
              case 31:
              case 13:
                f = Ua(i, 2), f !== null && De(f, i, 2), Yu(), fo(i, 2);
            }
          if (i = oo(a), i === null && kc(
            t,
            e,
            a,
            lf,
            l
          ), i === n) break;
          n = i;
        }
        n !== null && a.stopPropagation();
      } else
        kc(
          t,
          e,
          a,
          null,
          l
        );
    }
  }
  function oo(t) {
    return t = an(t), ro(t);
  }
  var lf = null;
  function ro(t) {
    if (lf = null, t = cl(t), t !== null) {
      var e = Ut(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = Bt(e), t !== null) return t;
          t = null;
        } else if (l === 31) {
          if (t = le(e), t !== null) return t;
          t = null;
        } else if (l === 3) {
          if (e.stateNode.current.memoizedState.isDehydrated)
            return e.tag === 3 ? e.stateNode.containerInfo : null;
          t = null;
        } else e !== t && (t = null);
      }
    }
    return lf = t, null;
  }
  function Yd(t) {
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
        switch (rf()) {
          case Za:
            return 2;
          case Vn:
            return 8;
          case Ka:
          case sf:
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
  var so = !1, ua = null, fa = null, ca = null, wi = /* @__PURE__ */ new Map(), Hi = /* @__PURE__ */ new Map(), oa = [], Kh = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Ld(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        ua = null;
        break;
      case "dragenter":
      case "dragleave":
        fa = null;
        break;
      case "mouseover":
      case "mouseout":
        ca = null;
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
    }, e !== null && (e = ol(e), e !== null && qd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function Jh(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return ua = ji(
          ua,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return fa = ji(
          fa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return ca = ji(
          ca,
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
  function Xd(t) {
    var e = cl(t.target);
    if (e !== null) {
      var l = Ut(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = Bt(l), e !== null) {
            t.blockedOn = e, ki(t.priority, function() {
              Gd(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = le(l), e !== null) {
            t.blockedOn = e, ki(t.priority, function() {
              Gd(l);
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
  function af(t) {
    if (t.blockedOn !== null) return !1;
    for (var e = t.targetContainers; 0 < e.length; ) {
      var l = oo(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        Wn = a, l.target.dispatchEvent(a), Wn = null;
      } else
        return e = ol(l), e !== null && qd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function Qd(t, e, l) {
    af(t) && l.delete(e);
  }
  function kh() {
    so = !1, ua !== null && af(ua) && (ua = null), fa !== null && af(fa) && (fa = null), ca !== null && af(ca) && (ca = null), wi.forEach(Qd), Hi.forEach(Qd);
  }
  function nf(t, e) {
    t.blockedOn === e && (t.blockedOn = null, so || (so = !0, A.unstable_scheduleCallback(
      A.unstable_NormalPriority,
      kh
    )));
  }
  var uf = null;
  function Vd(t) {
    uf !== t && (uf = t, A.unstable_scheduleCallback(
      A.unstable_NormalPriority,
      function() {
        uf === t && (uf = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (ro(a || l) === null)
              continue;
            break;
          }
          var i = ol(l);
          i !== null && (t.splice(e, 3), e -= 3, oc(
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
      return nf(r, t);
    }
    ua !== null && nf(ua, t), fa !== null && nf(fa, t), ca !== null && nf(ca, t), wi.forEach(e), Hi.forEach(e);
    for (var l = 0; l < oa.length; l++) {
      var a = oa[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < oa.length && (l = oa[0], l.blockedOn === null); )
      Xd(l), l.blockedOn === null && oa.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[fe] || null;
        if (typeof i == "function")
          u || Vd(l);
        else if (u) {
          var f = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[fe] || null)
              f = u.formAction;
            else if (ro(n) !== null) continue;
          } else f = u.action;
          typeof f == "function" ? l[a + 1] = f : (l.splice(a, 3), a -= 3), Vd(l);
        }
      }
  }
  function Zd() {
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
  function mo(t) {
    this._internalRoot = t;
  }
  ff.prototype.render = mo.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(h(409));
    var l = e.current, a = Ge();
    Hd(l, a, t, e, null, null);
  }, ff.prototype.unmount = mo.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      Hd(t.current, 2, null, t, null, null), Yu(), e[yl] = null;
    }
  };
  function ff(t) {
    this._internalRoot = t;
  }
  ff.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = Ji();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < oa.length && e !== 0 && e < oa[l].priority; l++) ;
      oa.splice(l, 0, t), l === 0 && Xd(t);
    }
  };
  var Kd = w.version;
  if (Kd !== "19.2.3")
    throw Error(
      h(
        527,
        Kd,
        "19.2.3"
      )
    );
  U.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(h(188)) : (t = Object.keys(t).join(","), Error(h(268, t)));
    return t = _(e), t = t !== null ? it(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var Fh = {
    bundleType: 0,
    version: "19.2.3",
    rendererPackageName: "react-dom",
    currentDispatcherRef: b,
    reconcilerVersion: "19.2.3"
  };
  if (typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ < "u") {
    var cf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!cf.isDisabled && cf.supportsFiber)
      try {
        ha = cf.inject(
          Fh
        ), ye = cf;
      } catch {
      }
  }
  return Gi.createRoot = function(t, e) {
    if (!st(t)) throw Error(h(299));
    var l = !1, a = "", n = Pr, i = ts, u = es;
    return e != null && (e.unstable_strictMode === !0 && (l = !0), e.identifierPrefix !== void 0 && (a = e.identifierPrefix), e.onUncaughtError !== void 0 && (n = e.onUncaughtError), e.onCaughtError !== void 0 && (i = e.onCaughtError), e.onRecoverableError !== void 0 && (u = e.onRecoverableError)), e = Nd(
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
      Zd
    ), t[yl] = e.current, Jc(t), new mo(e);
  }, Gi.hydrateRoot = function(t, e, l) {
    if (!st(t)) throw Error(h(299));
    var a = !1, n = "", i = Pr, u = ts, f = es, r = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (i = l.onUncaughtError), l.onCaughtError !== void 0 && (u = l.onCaughtError), l.onRecoverableError !== void 0 && (f = l.onRecoverableError), l.formState !== void 0 && (r = l.formState)), e = Nd(
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
      Zd
    ), e.context = wd(null), l = e.current, a = Ge(), a = ya(a), n = kl(a), n.callback = null, Fl(l, n, a), l = a, e.current.lanes = l, va(e, l), gl(e), t[yl] = e.current, Jc(t), new ff(e);
  }, Gi.version = "19.2.3", Gi;
}
var lm;
function ig() {
  if (lm) return go.exports;
  lm = 1;
  function A() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(A);
      } catch (w) {
        console.error(w);
      }
  }
  return A(), go.exports = ng(), go.exports;
}
var ug = ig(), am = xo();
const fg = {
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
function nm() {
  return !1;
}
function im(A, w = {}) {
  const W = /* @__PURE__ */ new Set();
  return (h) => {
    const st = A?.[h];
    if (typeof st == "string" && st.trim() !== "")
      return st;
    if (w.assertMissing && !W.has(h))
      throw W.add(h), new Error(`Missing cmux diff viewer label: ${h}`);
    return fg[h];
  };
}
function cg(A, w, W) {
  if (!A)
    return { kind: "reset" };
  const h = A.pathCount ?? A.paths?.length ?? 0, st = w.pathCount ?? W.length;
  return !(w.previousSource === A || og(A, w)) || st < h ? { kind: "reset" } : {
    addedPaths: W.slice(h, st),
    kind: "append"
  };
}
function og(A, w) {
  const W = A.paths, h = w.paths, st = A.pathCount ?? W?.length ?? 0, Ut = w.pathCount ?? h?.length ?? 0;
  if (!Array.isArray(W) || !Array.isArray(h) || st > Ut)
    return !1;
  for (let Bt = 0; Bt < st; Bt += 1)
    if (W[Bt] !== h[Bt])
      return !1;
  return !0;
}
function rg(A) {
  const w = (c) => {
    const o = document.getElementById(c);
    if (!o)
      throw new Error(`Missing cmux diff viewer element: ${c}`);
    return o;
  }, W = A.assets ?? {}, h = (c, o) => {
    if (typeof c != "string" || c.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${o}`);
    return new URL(c, window.location.href).href;
  }, st = h(W.diffsModuleURL, "diffsModuleURL"), Ut = h(W.treesModuleURL, "treesModuleURL"), Bt = h(W.workerPoolModuleURL, "workerPoolModuleURL"), le = h(W.workerModuleURL, "workerModuleURL"), D = A.payload ?? {}, _ = w("viewer"), it = w("status"), K = w("toolbar"), yt = w("source-select"), pe = w("repo-select"), me = w("base-select"), Wt = w("source-detail"), _t = w("jump-select"), ae = w("external-link"), ve = w("files-toggle"), Nt = w("layout-toggle"), $t = w("options-button"), Kt = w("options-menu"), It = w("files-sidebar"), $ = w("file-list"), ne = w("files-count"), Pt = w("file-search-toggle"), Ye = w("file-collapse-toggle"), Oe = w("stats-files"), ie = w("stats-added"), il = w("stats-deleted"), X = im(D.labels, {
    assertMissing: nm()
  }), H = {
    layout: D.layout === "unified" ? "unified" : "split",
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
  let b, U, N;
  const k = [], tt = [], d = /* @__PURE__ */ new Map();
  let z = /* @__PURE__ */ new Set(), B = null, q = null, F = /* @__PURE__ */ new Map(), at = { value: null }, mt = "", wt = "", Dt = !1, Ce = /* @__PURE__ */ new Map(), $e = /* @__PURE__ */ new Map();
  typeof D.title == "string" && D.title.trim() !== "" && (document.title = D.title), ha(D.appearance), ul(), Jt(D.sourceOptions ?? []), yl(pe, D.repoOptions ?? [], D.repoRoot ?? "", X("repoPath")), yl(me, D.baseOptions ?? [], D.branchBaseRef ?? "", X("branchBase"));
  const Va = globalThis.queueMicrotask ?? ((c) => setTimeout(c, 0));
  D.pendingReplacement === !0 ? (ue(D.statusMessage ?? X("loadingDiff"), { loading: !0, pending: !0 }), of()) : typeof D.statusMessage == "string" && D.statusMessage.length > 0 ? ue(D.statusMessage, { error: D.statusIsError === !0, loading: !1, statusOnly: !0 }) : Va(() => {
    Yi().catch((c) => {
      console.error("cmux diff viewer render failed", c), ue(X("renderFailed"), { error: !0, loading: !1, statusOnly: !0 });
    });
  });
  async function Yi() {
    ue(X("loadingRenderer"), { loading: !0 });
    const [
      {
        CodeView: c,
        getFiletypeFromFileName: o,
        parsePatchFiles: y,
        preloadHighlighter: C,
        processFile: R,
        registerCustomTheme: j
      },
      L
    ] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(st),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(Ut).catch((ct) => (console.warn("cmux diff file tree import failed", ct), null))
    ]);
    if (ce(j, D.appearance.themes.light), ce(j, D.appearance.themes.dark), ue(X("parsingDiff"), { loading: !0 }), da("loading"), U = await Li(), $i(k), xe(), window.__cmuxDiffViewer = { codeView: b, items: k, state: H, workerPool: U }, Xn(U), U?.initialize?.()?.then?.(() => ma(U?.getStats?.()))?.catch?.((ct) => console.warn("cmux diff worker pool initialization failed", ct)), window.addEventListener("pagehide", () => U?.terminate?.(), { once: !0 }), await rf({
      CodeView: c,
      parsePatchFiles: y,
      processFile: R,
      treesModule: L
    }), k.length === 0)
      throw new Error(X("noFileDiffs"));
    U || Fn(D.appearance, tt.length > 0 ? tt : k, o, C).catch((ct) => console.warn("cmux diff highlighter preload failed", ct));
  }
  function ue(c, o = {}) {
    it.isConnected || _.replaceChildren(it), document.body.dataset.loading = o.loading === !0 || o.pending === !0 ? "true" : "false", document.body.dataset.statusOnly = o.statusOnly === !0 ? "true" : "false", it.dataset.error = o.error === !0 ? "true" : "false", it.dataset.pending = o.pending === !0 ? "true" : "false", it.textContent = c;
  }
  function Yn(c) {
    document.open(), document.write(c), document.close();
  }
  async function Ln(c) {
    if (!c.ok)
      return ue(X("renderFailed"), { error: !0, loading: !1, statusOnly: !0 }), !1;
    const o = await c.text();
    return o.includes('data-cmux-diff-pending="true"') ? !1 : (Yn(o), !0);
  }
  async function of() {
    try {
      const c = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
      await Ln(c);
    } catch (c) {
      document.documentElement.dataset.cmuxDiffWait = "failed", ue(X("renderFailed"), { error: !0, loading: !1, statusOnly: !0 }), console.warn("cmux diff viewer deferred load failed", c);
    }
  }
  async function Li() {
    if (typeof Worker > "u")
      return null;
    try {
      const c = await import(Bt);
      ce(c.registerCustomTheme, D.appearance.themes.light), ce(c.registerCustomTheme, D.appearance.themes.dark);
      const o = new URL(le, window.location.href).href;
      return c.createDiffWorkerPool({
        workerURL: o,
        highlighterOptions: Xi()
      }) ?? null;
    } catch (c) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", c), null;
    }
  }
  function Xn(c) {
    if (!c) {
      da("fallback");
      return;
    }
    da("enabled"), ma(c.getStats?.());
    const o = c.subscribeToStatChanges?.((y) => {
      ma(y);
    });
    typeof o == "function" && window.addEventListener("pagehide", o, { once: !0 });
  }
  function da(c) {
    document.body.dataset.workerPool = c;
  }
  function ma(c) {
    !c || typeof c != "object" || (typeof c.managerState == "string" && (document.body.dataset.workerPoolState = c.managerState), Number.isFinite(c.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(c.totalWorkers)), typeof c.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(c.workersFailed)));
  }
  function Xi() {
    return {
      theme: D.appearance.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: H.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const Qn = /^From\s+([a-f0-9]+)\s/im;
  function he(c, o) {
    const y = c?.match(Qn);
    return y?.[1] ? new TextDecoder().decode(new TextEncoder().encode(y[1].slice(0, 5))) : `${X("commit")} ${o + 1}`;
  }
  async function rf({ CodeView: c, parsePatchFiles: o, processFile: y, treesModule: C }) {
    const R = Ka(), j = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, L = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let I = performance.now(), ct = performance.now(), bt = !0;
    const Yl = {
      initialBatchSize: Jn(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function ln(M, O) {
      const J = el(R, M, O);
      return J?.renamedItem && lu(J.renamedItem), J?.item;
    }
    function el(M, O, J) {
      if (!O)
        return null;
      const et = te(O), ht = J == null ? et : `${J}/${et}`, gt = et.length === 0 ? void 0 : M.pathStateByTreePath.get(ht), Ht = gt == null ? void 0 : Wn(M, ht, gt), Se = Gl(O), Be = {
        id: M.itemIdToFile.has(ht) ? an(M, `${ht}?2`) : ht,
        type: "diff",
        fileDiff: O,
        version: 0
      }, nu = M.items.length;
      M.fileIndex += 1, M.items.push(Be), M.pendingItems.push(Be), M.pendingItemById.set(Be.id, Be), M.itemIdToFile.set(Be.id, { fileOrder: nu, path: et }), M.itemIdByTreePath.set(ht, Be.id), M.treePathByItemId.set(Be.id, ht), M.diffStats.addedLines += Se.added, M.diffStats.deletedLines += Se.deleted, M.diffStats.fileCount += 1, M.diffStats.totalLinesOfCode += O.unifiedLineCount ?? O.splitLineCount ?? 0;
      const vf = M.statsByPath.get(ht);
      return M.statsByPath.set(ht, Se), gt != null && !en(vf, Se) && (M.pendingStatsChanged = !0), et.length > 0 && (gt == null && M.paths.push(ht), M.pathToItemId.set(ht, Be.id), Ll(M, ht, O.type, gt?.sawDeleted === !0), M.pathStateByTreePath.set(ht, {
        currentItem: Be,
        currentItemId: Be.id,
        currentType: O.type,
        fileOrder: nu,
        sawDeleted: gt?.sawDeleted === !0 || O.type === "deleted"
      })), { item: Be, renamedItem: Ht };
    }
    function Wn(M, O, J) {
      const et = J.currentItemId, ht = J.currentType === "deleted" ? "?deleted" : "?previous", gt = an(M, `${O}${ht}`);
      if (J.currentItem.id = gt, J.currentItemId = gt, M.itemIdToFile.has(et)) {
        const Ht = M.itemIdToFile.get(et);
        M.itemIdToFile.delete(et), M.itemIdToFile.set(gt, Ht);
      }
      if (M.treePathByItemId.has(et) && (M.treePathByItemId.delete(et), M.treePathByItemId.set(gt, O)), M.pendingItemById.has(et)) {
        const Ht = M.pendingItemById.get(et);
        M.pendingItemById.delete(et), M.pendingItemById.set(gt, Ht);
        return;
      }
      return { oldId: et, newId: gt };
    }
    function an(M, O) {
      if (!M.itemIdToFile.has(O))
        return O;
      let J = M.nextCollisionSuffixByBase.get(O) ?? 2, et = `${O}-${J}`;
      for (; M.itemIdToFile.has(et); )
        J += 1, et = `${O}-${J}`;
      return M.nextCollisionSuffixByBase.set(O, J + 1), et;
    }
    function Ll(M, O, J, et) {
      if (et && J !== "deleted") {
        M.gitStatusByPath.delete(O) && bl(M, O);
        return;
      }
      const ht = tn(J);
      if (ht === "modified") {
        M.gitStatusByPath.delete(O) && bl(M, O);
        return;
      }
      if (M.gitStatusByPath.get(O)?.status === ht)
        return;
      const Ht = { path: O, status: ht };
      M.gitStatusByPath.set(O, Ht), M.pendingGitStatusRemovePaths.delete(O), M.pendingGitStatusSetByPath.set(O, Ht);
    }
    function bl(M, O) {
      M.pendingGitStatusSetByPath.delete(O), M.pendingGitStatusRemovePaths.add(O);
    }
    function lu(M) {
      if (z.delete(M.oldId) && z.add(M.newId), d.has(M.oldId)) {
        const O = d.get(M.oldId);
        d.delete(M.oldId), O && d.set(M.newId, O);
      }
      Pi(M.oldId, M.newId), b?.updateItemId?.(M.oldId, M.newId);
    }
    async function Ta(M, O) {
      ln(M, O) && await nn(!1);
    }
    async function nn(M) {
      if (R.pendingItems.length === 0)
        return;
      const O = performance.now();
      if (!M && bt && O - I >= 8 && R.pendingItems.length < Yl.initialBatchSize && O - ct < Yl.initialMaxWait) {
        await Vi(), I = performance.now();
        return;
      }
      const J = bt ? Yl.initialBatchSize : Yl.incrementalBatchSize, et = bt ? Yl.initialMaxWait : Yl.incrementalMaxWait;
      if (M || R.pendingItems.length >= J || O - ct >= et) {
        za(), await Vi(), I = performance.now();
        return;
      }
    }
    function za() {
      if (R.pendingItems.length === 0)
        return;
      const M = R.pendingItems.splice(0, R.pendingItems.length);
      R.pendingItemById.clear();
      const O = M, J = tt.length > 0;
      k.push(...M);
      for (const et of M)
        d.set(et.id, et);
      if (O.length > 0) {
        tt.push(...O);
        for (const et of O)
          z.add(et.id);
        b ? b.addItems(O) : (b = new c(Hl(), U ?? void 0), b.setup(_), b.setItems(tt), b.render(!0), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.codeView = b));
      }
      Ii(M), Ma(C, !1, M.length), L.flushCount += 1, L.maxBatchSize = Math.max(L.maxBatchSize, M.length), L.fileCount = k.length, L.renderableFileCount = tt.length, Za(L), ct = performance.now(), bt && (bt = !1, document.body.dataset.loading = "false", it.remove()), J || Sa(tt[0]?.id ?? k[0]?.id ?? ""), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.items = k, window.__cmuxDiffViewer.codeViewItems = tt, window.__cmuxDiffViewer.streamMetrics = L);
    }
    function Le() {
      b && (b.syncContainerHeight?.(), b.render(!0));
    }
    function Ma(M, O, J = 1) {
      if (j.treesModule = M, j.dirtyCount += J, O || j.lastRefreshAt === 0) {
        xl(j.treesModule);
        return;
      }
      const et = performance.now() - j.lastRefreshAt;
      if (j.dirtyCount >= 1e3 || et >= 1e3) {
        xl(j.treesModule);
        return;
      }
      if (j.timeout !== 0)
        return;
      const ht = Math.max(0, 1e3 - et);
      j.timeout = window.setTimeout(() => {
        j.timeout = 0, xl(j.treesModule);
      }, ht);
    }
    function xl(M) {
      j.timeout !== 0 && (window.clearTimeout(j.timeout), j.timeout = 0), j.dirtyCount = 0, j.lastRefreshAt = performance.now(), L.treeRefreshCount += 1, q = sf(R), hf(q, M), xe(), Za(L);
    }
    const ze = await fetch(D.patchURL, { cache: "no-store" });
    if (!ze.ok)
      throw new Error(`${X("loadingDiff")} (${ze.status})`);
    if (!ze.body?.getReader) {
      const M = await ze.text();
      await Vn(M, o, Ta), await nn(!0), Le(), Ma(C, !0), L.completedAt = performance.now();
      return;
    }
    const un = new TextDecoder(), fn = ze.body.getReader(), $n = "diff --git ", Ea = `
` + $n, cn = Ea.length - 1, In = /\S/;
    function kt(M, O) {
      const J = Math.max(O, 0);
      if (J === 0 && M.startsWith($n))
        return 0;
      const et = M.indexOf(Ea, J);
      return et === -1 ? void 0 : et + 1;
    }
    function sl(M, O) {
      return Math.max(O, M.length - cn);
    }
    function on(M, O, J) {
      const et = Math.max(O, 0), ht = Math.min(J, M.length);
      if (et >= ht)
        return;
      let gt = M.lastIndexOf(`
From `, ht - 1);
      for (; gt !== -1; ) {
        const Ht = gt + 1;
        if (Ht < et)
          return;
        if (Ht >= ht) {
          gt = M.lastIndexOf(`
From `, gt - 1);
          continue;
        }
        const Se = M.indexOf(`
`, Ht + 1), Xl = M.slice(Ht, Se === -1 || Se > ht ? ht : Se);
        if (Qn.test(Xl))
          return Ht;
        gt = M.lastIndexOf(`
From `, gt - 1);
      }
    }
    function Aa(M) {
      const O = kt(M, 0);
      if (O == null || O <= 0)
        return;
      const J = M.slice(0, O);
      return Qn.test(J) ? J : void 0;
    }
    async function au(M) {
      if (M.trim() === "")
        return;
      const O = Aa(M);
      O != null && (Da = he(O, ti), ti += 1);
      const J = `cmux-diff-file-${R.fileIndex}`;
      await Ta(y(M, {
        cacheKey: J,
        isGitDiff: !0
      }), Da);
    }
    function Pn() {
      let M, O = "", J = 0, et = !1;
      function ht() {
        if (M == null) {
          if (M = kt(O, J), M == null)
            return J = sl(O, 0), null;
          et = !0, J = M + 1;
        }
        for (; ; ) {
          const gt = M;
          if (gt == null)
            return null;
          const Ht = kt(O, J);
          if (Ht == null)
            return J = sl(O, gt + 1), null;
          const Se = on(O, gt + 1, Ht) ?? Ht, Xl = O.slice(0, Se);
          if (O = O.slice(Se), M = kt(O, 0), J = M == null ? 0 : M + 1, In.test(Xl))
            return Xl;
        }
      }
      return {
        push(gt) {
          gt.length > 0 && (O += gt);
        },
        takeAvailableFile: ht,
        finish() {
          const gt = ht();
          if (gt != null)
            return { fileText: gt };
          if (!In.test(O))
            return O = "", {};
          if (!et) {
            const Se = O;
            return O = "", { fallbackPatchContent: Se };
          }
          const Ht = O;
          return O = "", { fileText: Ht };
        }
      };
    }
    async function _a(M) {
      let O;
      for (; (O = M.takeAvailableFile()) != null; )
        await au(O);
    }
    const Xe = Pn();
    let Da, ti = 0;
    for (; ; ) {
      const { done: M, value: O } = await fn.read();
      if (M) {
        const J = un.decode();
        J.length > 0 && (Xe.push(J), await _a(Xe));
        break;
      }
      Xe.push(un.decode(O, { stream: !0 })), await _a(Xe);
    }
    const rn = Xe.finish();
    rn.fileText != null ? (await au(rn.fileText), await _a(Xe)) : rn.fallbackPatchContent != null && await Vn(rn.fallbackPatchContent, o, Ta), await nn(!0), Le(), Ma(C, !0), L.completedAt = performance.now(), Za(L);
  }
  function Za(c) {
    document.body.dataset.streamFileCount = String(c.fileCount ?? k.length), document.body.dataset.streamRenderableFileCount = String(c.renderableFileCount ?? tt.length), document.body.dataset.streamFlushCount = String(c.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(c.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(c.treeRefreshCount ?? 0), Number.isFinite(c.completedAt) && c.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(c.completedAt - c.startedAt)));
  }
  async function Vn(c, o, y) {
    const C = o(c, "cmux-diff"), R = C.length > 1;
    for (const [j, L] of C.entries()) {
      const I = R ? he(L.patchMetadata, j) : void 0;
      for (const ct of L.files ?? [])
        await y(ct, I);
    }
  }
  function Ka() {
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
  function sf(c) {
    const o = c.lastTreeSource, y = Qi(c), C = {
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
    return c.pendingStatsChanged = !1, c.lastTreeSource = C, C;
  }
  function Qi(c) {
    if (c.pendingGitStatusRemovePaths.size === 0 && c.pendingGitStatusSetByPath.size === 0)
      return;
    const o = {};
    return c.pendingGitStatusRemovePaths.size > 0 && (o.remove = Array.from(c.pendingGitStatusRemovePaths), c.pendingGitStatusRemovePaths.clear()), c.pendingGitStatusSetByPath.size > 0 && (o.set = Array.from(c.pendingGitStatusSetByPath.values()), c.pendingGitStatusSetByPath.clear()), o;
  }
  function Vi() {
    return new Promise((c) => {
      let o = !1, y = 0;
      const C = () => {
        o || (o = !0, y !== 0 && window.clearTimeout(y), c());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        y = window.setTimeout(C, 50), window.requestAnimationFrame(C);
      else if (typeof MessageChannel < "u") {
        const R = new MessageChannel();
        R.port1.onmessage = C, R.port2.postMessage(void 0);
      } else
        queueMicrotask(C);
    });
  }
  async function df() {
    return at.value == null && (at.value = fetch(D.patchURL, { cache: "no-store" }).then(async (c) => {
      if (!c.ok)
        throw new Error(`${X("loadingDiff")} (${c.status})`);
      return c.text();
    })), at.value;
  }
  function ha(c) {
    const o = document.documentElement.style;
    o.setProperty("--cmux-diff-bg-light", c.themes.light.background), o.setProperty("--cmux-diff-bg-dark", c.themes.dark.background), o.setProperty("--cmux-diff-fg-light", c.themes.light.foreground), o.setProperty("--cmux-diff-fg-dark", c.themes.dark.foreground), o.setProperty("--cmux-diff-selection-bg-light", c.themes.light.selectionBackground), o.setProperty("--cmux-diff-selection-bg-dark", c.themes.dark.selectionBackground), o.setProperty("--cmux-diff-code-font-family", ye(c.fontFamily)), o.setProperty("--cmux-diff-font-size", `${c.fontSize}px`), o.setProperty("--cmux-diff-line-height", `${c.lineHeight}px`);
  }
  function ye(c) {
    const o = typeof c == "string" && c.trim() !== "" ? c.trim() : "Menlo";
    return `${JSON.stringify(o)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
  }
  function ul() {
    ve.innerHTML = Ue("files"), Pt.innerHTML = Ue("search"), Ye.innerHTML = Ue("sidebarCollapse"), Nt.innerHTML = Ue(H.layout), $t.innerHTML = Ue("dots"), typeof D.externalURL == "string" && D.externalURL.length > 0 && (ae.href = D.externalURL, ae.innerHTML = Ue("external"), ae.hidden = !1), ve.addEventListener("click", () => $a(!H.filesVisible)), Ye.addEventListener("click", () => $a(!1)), Pt.addEventListener("click", () => Zn(!H.fileSearchOpen)), Nt.addEventListener("click", () => va(H.layout === "split" ? "unified" : "split")), $t.addEventListener("click", () => ya(Kt.hidden)), document.addEventListener("click", (c) => {
      Kt.hidden || c.target instanceof Node && K.contains(c.target) || ya(!1);
    }), document.addEventListener("keydown", (c) => {
      c.key === "Escape" && ya(!1);
    }), be(), xe();
  }
  function be() {
    const c = D.shortcuts ?? {}, o = ga(c.diffViewerScrollDown), y = ga(c.diffViewerScrollUp), C = ga(c.diffViewerScrollToBottom), R = ga(c.diffViewerScrollToTop), j = ga(c.diffViewerOpenFileSearch);
    let L = null, I = 0;
    document.addEventListener("keydown", (bt) => {
      if (!(bt.defaultPrevented || vl(bt.target))) {
        if (L && !pl(L.shortcut.second, bt) && ct(), L && pl(L.shortcut.second, bt)) {
          bt.preventDefault(), L.action(), ct();
          return;
        }
        if (Ja(o, bt)) {
          bt.preventDefault(), pa(1);
          return;
        }
        if (Ja(y, bt)) {
          bt.preventDefault(), pa(-1);
          return;
        }
        if (Ja(C, bt)) {
          bt.preventDefault(), _.scrollTo({ top: _.scrollHeight, behavior: "auto" });
          return;
        }
        if (Ja(j, bt) && N) {
          bt.preventDefault(), $a(!0), Zn(!0);
          return;
        }
        R && ka(R, bt) && (bt.preventDefault(), L = {
          shortcut: R,
          action: () => _.scrollTo({ top: 0, behavior: "auto" })
        }, I = setTimeout(ct, 700));
      }
    });
    function ct() {
      L = null, I !== 0 && (clearTimeout(I), I = 0);
    }
  }
  function ga(c) {
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
  function Ja(c, o) {
    return c && !c.second && pl(c.first, o);
  }
  function ka(c, o) {
    return c && c.second && pl(c.first, o);
  }
  function pl(c, o) {
    return !c || o.metaKey !== c.command || o.ctrlKey !== c.control || o.altKey !== c.option || o.shiftKey !== c.shift ? !1 : Fa(o) === c.key;
  }
  function Fa(c) {
    return c.code === "Space" ? "space" : typeof c.key != "string" || c.key.length === 0 ? "" : (c.key.length === 1, c.key.toLowerCase());
  }
  function vl(c) {
    const o = c instanceof Element ? c : null;
    return o ? !!o.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function pa(c) {
    const o = Math.max(80, Math.floor(_.clientHeight * 0.38));
    _.scrollBy({ top: c * o, behavior: "auto" });
  }
  function Hl() {
    return {
      layout: { paddingTop: 0, gap: 1, paddingBottom: 0 },
      diffStyle: H.layout,
      diffIndicators: H.diffIndicators,
      overflow: H.wordWrap ? "wrap" : "scroll",
      expandUnchanged: H.expandUnchanged,
      disableBackground: !H.showBackgrounds,
      disableLineNumbers: !H.lineNumbers,
      lineHoverHighlight: "number",
      enableLineSelection: !0,
      enableGutterUtility: !0,
      lineDiffType: H.wordDiffs ? "word" : "none",
      stickyHeaders: !0,
      unsafeCSS: mf(),
      theme: D.appearance.theme,
      themeType: "system"
    };
  }
  function mf() {
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
  function fl() {
    const c = Hl();
    if (!b) {
      Wa();
      return;
    }
    b.setOptions(c), Wa(), b.render(!0);
  }
  function Wa() {
    U?.setRenderOptions && U.setRenderOptions(Xi()).then(() => b?.render(!0)).catch((c) => console.warn("cmux diff worker render options update failed", c));
  }
  function va(c) {
    H.layout = c === "unified" ? "unified" : "split", xe(), fl();
  }
  function $a(c) {
    H.filesVisible = c, document.body.dataset.filesHidden = c ? "false" : "true", It.setAttribute("aria-hidden", String(!c)), c ? It.removeAttribute("inert") : It.setAttribute("inert", ""), xe();
  }
  function Zn(c) {
    H.fileSearchOpen = !!c, N && (H.fileSearchOpen ? N.openSearch("") : N.closeSearch()), xe();
  }
  function Ki(c) {
    H.collapsed = c;
    const o = tt.map((R) => ({
      ...R,
      collapsed: c,
      version: (R.version ?? 0) + 1
    })), y = new Map(o.map((R) => [R.id, R])), C = k.map((R) => y.get(R.id) ?? {
      ...R,
      collapsed: c,
      version: (R.version ?? 0) + 1
    });
    tt.splice(0, tt.length, ...o), k.splice(0, k.length, ...C), b && (b.setItems(tt), b.render(!0)), xe();
  }
  function xe() {
    ve.setAttribute("aria-pressed", String(H.filesVisible)), ve.title = H.filesVisible ? X("hideFiles") : X("showFiles"), ve.setAttribute("aria-label", ve.title), Ye.title = X("hideFiles"), Ye.setAttribute("aria-label", Ye.title), Nt.innerHTML = Ue(H.layout), Nt.title = H.layout === "split" ? X("switchToUnifiedDiff") : X("switchToSplitDiff"), Nt.setAttribute("aria-label", Nt.title), $t.setAttribute("aria-expanded", String(!Kt.hidden)), document.documentElement.dataset.layout = H.layout, document.documentElement.dataset.wordWrap = String(H.wordWrap), document.documentElement.dataset.diffIndicators = H.diffIndicators, Pt.disabled = !N, Pt.setAttribute("aria-pressed", String(H.fileSearchOpen)), Pt.title = H.fileSearchOpen ? X("hideFileSearch") : X("showFileSearch"), Pt.setAttribute("aria-label", Pt.title);
  }
  function ya(c) {
    c && ba(), Kt.hidden = !c, xe();
  }
  function ba() {
    Kt.textContent = "";
    const c = [
      { label: X("refresh"), icon: "refresh", action: () => window.location.reload() },
      { label: H.wordWrap ? X("disableWordWrap") : X("enableWordWrap"), icon: "wrap", checked: H.wordWrap, action: () => {
        H.wordWrap = !H.wordWrap, fl();
      } },
      { label: H.collapsed ? X("expandAllDiffs") : X("collapseAllDiffs"), icon: "collapse", checked: H.collapsed, action: () => Ki(!H.collapsed) },
      "separator",
      { label: H.filesVisible ? X("hideFiles") : X("showFiles"), icon: "files", checked: H.filesVisible, action: () => $a(!H.filesVisible) },
      { label: H.expandUnchanged ? X("collapseUnchangedContext") : X("expandUnchangedContext"), icon: "document", checked: H.expandUnchanged, action: () => {
        H.expandUnchanged = !H.expandUnchanged, fl();
      } },
      { label: H.showBackgrounds ? X("hideBackgrounds") : X("showBackgrounds"), icon: "background", checked: H.showBackgrounds, action: () => {
        H.showBackgrounds = !H.showBackgrounds, fl();
      } },
      { label: H.lineNumbers ? X("hideLineNumbers") : X("showLineNumbers"), icon: "numbers", checked: H.lineNumbers, action: () => {
        H.lineNumbers = !H.lineNumbers, fl();
      } },
      { label: H.wordDiffs ? X("disableWordDiffs") : X("enableWordDiffs"), icon: "word", checked: H.wordDiffs, action: () => {
        H.wordDiffs = !H.wordDiffs, fl();
      } },
      { kind: "segment", label: X("indicatorStyle"), icon: "bars", options: [
        { value: "bars", icon: "bars", label: X("bars") },
        { value: "classic", icon: "classic", label: X("classic") },
        { value: "none", icon: "eye", label: X("none") }
      ] },
      "separator",
      { label: X("copyGitApplyCommand"), icon: "clipboard", action: ki }
    ];
    for (const o of c) {
      if (o === "separator") {
        const R = document.createElement("div");
        R.className = "menu-separator", Kt.append(R);
        continue;
      }
      if (o.kind === "segment") {
        const R = document.createElement("div");
        R.className = "menu-item menu-segment", R.setAttribute("role", "presentation"), R.innerHTML = `${Ue(o.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
        const j = R.querySelector(".menu-label");
        j && (j.textContent = o.label);
        const L = R.querySelector(".menu-segment-controls");
        if (!L)
          continue;
        for (const I of o.options) {
          const ct = document.createElement("button");
          ct.type = "button", ct.className = "segment-button", ct.title = I.label, ct.setAttribute("aria-label", I.label), ct.setAttribute("aria-pressed", String(H.diffIndicators === I.value)), ct.innerHTML = Ue(I.icon), ct.addEventListener("click", () => {
            H.diffIndicators = I.value, fl(), ba(), xe();
          }), L.append(ct);
        }
        Kt.append(R);
        continue;
      }
      const y = document.createElement("button");
      y.type = "button", y.className = "menu-item", y.setAttribute("role", o.checked == null ? "menuitem" : "menuitemcheckbox"), o.checked != null && y.setAttribute("aria-checked", String(!!o.checked)), y.disabled = !!o.disabled, y.innerHTML = `${Ue(o.icon)}<span class="menu-label"></span><span class="menu-check">${o.checked ? Ue("check") : ""}</span>`;
      const C = y.querySelector(".menu-label");
      C && (C.textContent = o.label), y.addEventListener("click", () => {
        y.disabled || (o.action?.(), ba(), xe());
      }), Kt.append(y);
    }
  }
  function Ji(c) {
    const o = new Set(c.split(/\r?\n/));
    let y = "CMUX_DIFF_PATCH", C = 0;
    for (; o.has(y); )
      C += 1, y = `CMUX_DIFF_PATCH_${C}`;
    return y;
  }
  async function ki() {
    const o = await df(), y = o.endsWith(`
`) ? o : `${o}
`, C = Ji(y), R = `git apply <<'${C}'
${y}${C}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(R);
      } catch {
        Ie(R);
      }
    else
      Ie(R);
    $t.title = X("copiedGitApplyCommand"), $t.setAttribute("aria-label", X("copiedGitApplyCommand"));
  }
  function Ie(c) {
    const o = document.createElement("textarea");
    o.value = c, o.setAttribute("readonly", ""), o.style.position = "fixed", o.style.left = "-9999px", document.body.append(o), o.select(), document.execCommand("copy"), o.remove();
  }
  function Jt(c) {
    if (Wt.textContent = fe(), !Array.isArray(c) || c.length < 2)
      return;
    yt.textContent = "";
    const o = c.find((y) => y.selected) ?? c.find((y) => !y.disabled);
    for (const y of c) {
      const C = document.createElement("option");
      C.value = y.value, C.textContent = y.label, C.disabled = y.disabled || !y.url, C.selected = y.value === o?.value, y.message && (C.title = y.message), yt.append(C);
    }
    Wt.textContent = o?.sourceLabel ?? fe(), yt.hidden = !1, yt.addEventListener("change", () => {
      const y = c.find((C) => C.value === yt.value);
      if (!y?.url) {
        yt.value = o?.value ?? "";
        return;
      }
      ue(X("loadingDiff"), { pending: !0 }), window.location.href = y.url;
    });
  }
  function fe() {
    return [D.sourceLabel, D.repoRoot, D.branchBaseRef].filter((o) => typeof o == "string" && o.trim() !== "").join(" | ");
  }
  function yl(c, o, y, C) {
    if (!c || !Array.isArray(o) || o.length < 2)
      return;
    c.textContent = "";
    const R = o.find((j) => j.selected) ?? o.find((j) => !j.disabled);
    for (const j of o) {
      const L = document.createElement("option");
      L.value = j.value, L.textContent = j.label, L.disabled = j.disabled || !j.url, L.selected = j.value === R?.value, j.message && (L.title = j.message), c.append(L);
    }
    c.hidden = !1, c.title = C, c.addEventListener("change", () => {
      const j = o.find((L) => L.value === c.value);
      if (!j?.url) {
        c.value = R?.value ?? y ?? "";
        return;
      }
      ue(X("loadingDiff"), { pending: !0 }), window.location.href = j.url;
    });
  }
  function Kn(c, o) {
    const y = Ia(c), C = xa(o);
    if (Pe(c, []), N && (N.cleanUp?.(), N = null), B = null, H.fileSearchOpen = !1, $.textContent = "", ne.textContent = `${y}`, rl(c), C)
      try {
        gf(c, o), xe();
        return;
      } catch (j) {
        console.warn("cmux diff file tree setup failed", j);
      }
    const R = cl(c);
    Pe(c, R), Gt(R), xe();
  }
  function hf(c, o) {
    const y = Ia(c);
    if (Pe(c, []), ne.textContent = `${y}`, rl(c), N && $.dataset.treeMode === "pierre" && o?.preparePresortedFileTreeInput) {
      Fi(c, o);
      return;
    }
    if (N || $.childElementCount === 0) {
      Kn(c, o);
      return;
    }
    const C = cl(c);
    Pe(c, C), $.textContent = "", Gt(C);
  }
  function gf(c, o) {
    const { FileTree: y, preparePresortedFileTreeInput: C } = o, R = ol(c);
    B = c;
    const j = R[0];
    jl(c), $.dataset.treeMode = "pierre", N = new y({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: j ? [j] : [],
      initialVisibleRowCount: Jn(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: C(R),
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: c.gitStatus,
      renderRowDecoration(L) {
        if (L.item.kind !== "file")
          return null;
        const I = F.get(L.item.path);
        return I == null || I.added === 0 && I.deleted === 0 ? null : {
          text: `+${I.added} -${I.deleted}`,
          title: `${I.added} ${X("additions")}, ${I.deleted} ${X("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Wi(),
      onSelectionChange(L) {
        if (Dt)
          return;
        const I = L[L.length - 1], ct = Ce.get(I);
        ct && kn(ct);
      }
    }), N.render({ containerWrapper: $ });
  }
  function Fi(c, o) {
    const y = B, C = ol(c);
    B = c, jl(c);
    let R = !1;
    const j = cg(y, c, C);
    if (j.kind === "append") {
      const L = j.addedPaths;
      if (L.length > 0)
        try {
          N.batch(L.map((I) => ({ type: "add", path: I })));
        } catch (I) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", I), N.resetPaths(C, {
            preparedInput: o.preparePresortedFileTreeInput(C)
          }), R = !0;
        }
    } else
      N.resetPaths(C, {
        preparedInput: o.preparePresortedFileTreeInput(C)
      }), R = !0;
    c.gitStatusPatch ? typeof N.applyGitStatusPatch == "function" ? N.applyGitStatusPatch(c.gitStatusPatch) : N.setGitStatus(c.gitStatus) : (R || c.statsChanged === !0) && N.setGitStatus(c.gitStatus);
  }
  function xa(c) {
    return !!(c?.FileTree && c?.preparePresortedFileTreeInput);
  }
  function Ia(c) {
    return c?.pathCount ?? c?.entries?.length ?? 0;
  }
  function cl(c) {
    const o = c?.pathCount ?? c?.entries?.length ?? 0, y = c?.entries ?? [];
    if (y.length > 0)
      return y.length === o ? y : y.slice(0, o);
    const C = ol(c), R = c?.pathToItemId, j = c?.statsByPath;
    return C.map((L) => {
      const I = R instanceof Map ? R.get(L) : void 0, ct = I ? d.get(I) : void 0, bt = ct?.fileDiff ?? {};
      return {
        item: ct ?? { id: I ?? L, fileDiff: bt },
        path: L,
        status: pf(bt),
        stats: j instanceof Map ? j.get(L) ?? Gl(bt) : Gl(bt)
      };
    });
  }
  function ol(c) {
    const o = c?.pathCount ?? c?.paths?.length ?? 0, y = c?.paths ?? [];
    return y.length === o ? y : y.slice(0, o);
  }
  function jl(c) {
    if (c?.statsByPath instanceof Map) {
      F = c.statsByPath;
      return;
    }
    F = /* @__PURE__ */ new Map();
    const o = cl(c);
    for (const y of o)
      F.set(y.path, y.stats);
  }
  function Pe(c, o) {
    if (c?.pathToItemId instanceof Map && c?.treePathByItemId instanceof Map)
      Ce = c.pathToItemId, $e = c.treePathByItemId;
    else if (c?.pathToItemId instanceof Map) {
      Ce = c.pathToItemId, $e = /* @__PURE__ */ new Map();
      for (const [y, C] of Ce)
        $e.set(C, y);
    } else {
      Ce = /* @__PURE__ */ new Map(), $e = /* @__PURE__ */ new Map();
      for (const y of o) {
        const C = y.item?.id;
        C && (Ce.set(y.path, C), $e.set(C, y.path));
      }
    }
    wt && !Ce.has(wt) && (wt = "");
  }
  function Gt(c) {
    delete $.dataset.treeMode;
    for (const o of c) {
      const y = o.item, C = y.fileDiff ?? {}, R = o.stats ?? Gl(C), j = document.createElement("button");
      j.type = "button", j.className = "file-entry", j.dataset.itemId = y.id, j.title = te(C), j.innerHTML = `
      <span class="file-status">${tu(C)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${R.added}</span>
        <span class="stat-del">-${R.deleted}</span>
      </span>
    `;
      const L = j.querySelector(".file-name");
      L && (L.textContent = te(C)), j.addEventListener("click", () => kn(y.id)), $.append(j);
    }
  }
  function Jn() {
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
  function rl(c) {
    const o = c?.diffStats;
    if (o && Number.isFinite(o.addedLines) && Number.isFinite(o.deletedLines) && Number.isFinite(o.fileCount)) {
      Oe.textContent = `${o.fileCount}`, ie.textContent = `+${o.addedLines}`, il.textContent = `-${o.deletedLines}`;
      return;
    }
    ql(c?.entries ?? []);
  }
  function ql(c) {
    const o = c.reduce((y, C) => {
      const R = C.stats ?? Gl(C.item?.fileDiff ?? {});
      return y.added += R.added, y.deleted += R.deleted, y;
    }, { added: 0, deleted: 0 });
    Oe.textContent = `${c.length}`, ie.textContent = `+${o.added}`, il.textContent = `-${o.deleted}`;
  }
  function $i(c) {
    _t.textContent = "";
    const o = document.createElement("option");
    o.value = "", o.textContent = X("jumpToFile"), _t.append(o), _t.dataset.initialized = "true";
    for (const y of c) {
      const C = document.createElement("option");
      C.value = y.id, C.textContent = te(y.fileDiff ?? {}), _t.append(C);
    }
    _t.hidden = c.length === 0, _t.onchange = () => {
      _t.value && kn(_t.value);
    };
  }
  function Ii(c) {
    if (c.length === 0)
      return;
    _t.dataset.initialized !== "true" && $i([]);
    const o = document.createDocumentFragment();
    for (const y of c) {
      const C = document.createElement("option");
      C.value = y.id, C.textContent = te(y.fileDiff ?? {}), o.append(C);
    }
    _t.append(o), _t.hidden = !1;
  }
  function Pi(c, o) {
    if (_t.dataset.initialized === "true") {
      for (const y of _t.options)
        if (y.value === c) {
          y.value = o;
          return;
        }
    }
  }
  function kn(c) {
    if (!b)
      return;
    const o = Pa(c);
    o && (b.scrollTo({ type: "item", id: o, align: "start", behavior: "smooth-auto" }), Sa(o));
  }
  function Pa(c) {
    if (z.has(c))
      return c;
    const o = k.findIndex((y) => y.id === c);
    if (o === -1)
      return tt[0]?.id ?? "";
    for (let y = o + 1; y < k.length; y += 1)
      if (z.has(k[y].id))
        return k[y].id;
    for (let y = o - 1; y >= 0; y -= 1)
      if (z.has(k[y].id))
        return k[y].id;
    return "";
  }
  function Sa(c) {
    if (!(!c || mt === c)) {
      mt = c, tl(c);
      for (const o of $.querySelectorAll(".file-entry"))
        o.setAttribute("aria-current", o.dataset.itemId === c ? "true" : "false");
      _t.value !== c && (_t.value = c);
    }
  }
  function tl(c) {
    if (!N)
      return;
    const o = $e.get(c);
    if (!(!o || o === wt)) {
      Dt = !0;
      try {
        wt && N.getItem(wt)?.deselect(), N.getItem(o)?.select(), N.scrollToPath(o, { focus: !1, offset: "nearest" }), wt = o;
      } finally {
        Va(() => {
          Dt = !1;
        });
      }
    }
  }
  function te(c) {
    return c.name ?? c.newName ?? c.oldName ?? c.prevName ?? X("untitled");
  }
  function tu(c) {
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
  function pf(c) {
    return tn(c.type);
  }
  function tn(c) {
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
  function Gl(c) {
    const o = { added: 0, deleted: 0 };
    for (const y of c.hunks ?? [])
      o.added += y.additionLines ?? 0, o.deleted += y.deletionLines ?? 0;
    return o;
  }
  function en(c, o) {
    return c?.added === o.added && c?.deleted === o.deleted;
  }
  function Ue(c) {
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
  function ce(c, o) {
    c(o.name, () => Promise.resolve(eu(o)));
  }
  function Fn(c, o, y, C) {
    const R = Array.from(new Set([
      c.theme?.light,
      c.theme?.dark
    ].filter(Boolean))), j = Array.from(new Set(o.flatMap((L) => {
      const I = L.fileDiff ?? {}, ct = I.name ?? I.newName ?? I.oldName ?? I.prevName ?? "", bt = I.lang ?? y(ct) ?? "text";
      return bt ? [bt] : [];
    })));
    return C({
      themes: R,
      langs: j.length > 0 ? j : ["text"]
    });
  }
  function eu(c) {
    const o = c.palette ?? {}, y = c.foreground, C = c.background;
    return {
      name: c.name,
      displayName: c.ghosttyName,
      type: c.type,
      colors: {
        "editor.background": C,
        "editor.foreground": y,
        "terminal.background": C,
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
        { settings: { foreground: y, background: C } },
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
const sg = ["82%", "64%", "76%", "58%", "70%", "46%"], dg = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
function mg() {
  return /* @__PURE__ */ Q.jsx("div", { className: "diff-loading-placeholder p-2", "aria-hidden": "true", children: sg.map((A, w) => /* @__PURE__ */ Q.jsxs("div", { className: "grid h-[30px] grid-cols-[17px_minmax(0,1fr)_44px] items-center gap-2 rounded-md px-[7px]", children: [
    /* @__PURE__ */ Q.jsx("span", { className: "size-[17px] rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ Q.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: A } }),
    /* @__PURE__ */ Q.jsx("span", { className: "h-3 justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: { width: w % 2 === 0 ? "34px" : "24px" } })
  ] }, `${A}-${w}`)) });
}
function hg() {
  return /* @__PURE__ */ Q.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    /* @__PURE__ */ Q.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
      /* @__PURE__ */ Q.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ Q.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
      /* @__PURE__ */ Q.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
    ] }),
    /* @__PURE__ */ Q.jsx("div", { className: "space-y-[13px] px-3 py-1", children: dg.map((A, w) => /* @__PURE__ */ Q.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
      /* @__PURE__ */ Q.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
      /* @__PURE__ */ Q.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: { width: A } })
    ] }, `${A}-${w}`)) })
  ] });
}
function gg({ label: A }) {
  return /* @__PURE__ */ Q.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    /* @__PURE__ */ Q.jsx("select", { id: "source-select", "aria-label": A("diffTarget"), hidden: !0 }),
    /* @__PURE__ */ Q.jsx("select", { id: "repo-select", "aria-label": A("repoPath"), hidden: !0 }),
    /* @__PURE__ */ Q.jsx("select", { id: "base-select", "aria-label": A("branchBase"), hidden: !0 }),
    /* @__PURE__ */ Q.jsx("span", { id: "source-detail" })
  ] });
}
function pg({ config: A, label: w }) {
  return /* @__PURE__ */ Q.jsxs("header", { id: "toolbar", children: [
    /* @__PURE__ */ Q.jsx(gg, { config: A, label: w }),
    /* @__PURE__ */ Q.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ Q.jsx("select", { id: "jump-select", "aria-label": w("jumpToFile"), hidden: !0 }) }),
    /* @__PURE__ */ Q.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
      /* @__PURE__ */ Q.jsx(
        "a",
        {
          id: "external-link",
          className: "toolbar-icon",
          href: A.payload?.externalURL ?? "#",
          target: "_blank",
          rel: "noreferrer",
          title: w("openSourceURL"),
          "aria-label": w("openSourceURL"),
          hidden: !0
        }
      ),
      /* @__PURE__ */ Q.jsx(
        "button",
        {
          id: "files-toggle",
          className: "toolbar-icon",
          type: "button",
          title: w("hideFiles"),
          "aria-label": w("hideFiles"),
          "aria-pressed": "true"
        }
      ),
      /* @__PURE__ */ Q.jsx(
        "button",
        {
          id: "layout-toggle",
          className: "toolbar-icon",
          type: "button",
          title: w("switchToUnifiedDiff"),
          "aria-label": w("switchToUnifiedDiff")
        }
      ),
      /* @__PURE__ */ Q.jsx(
        "button",
        {
          id: "options-button",
          className: "toolbar-icon",
          type: "button",
          title: w("options"),
          "aria-label": w("options"),
          "aria-expanded": "false",
          "aria-haspopup": "menu"
        }
      )
    ] }),
    /* @__PURE__ */ Q.jsx("div", { id: "options-menu", role: "menu", "aria-label": w("options"), hidden: !0 })
  ] });
}
function vg({ label: A }) {
  return /* @__PURE__ */ Q.jsxs("aside", { id: "files-sidebar", "aria-label": A("changedFiles"), children: [
    /* @__PURE__ */ Q.jsxs("div", { id: "files-header", children: [
      /* @__PURE__ */ Q.jsxs("span", { id: "files-title", children: [
        /* @__PURE__ */ Q.jsx("span", { children: A("files") }),
        /* @__PURE__ */ Q.jsx("span", { id: "files-count" })
      ] }),
      /* @__PURE__ */ Q.jsxs("span", { id: "files-header-actions", children: [
        /* @__PURE__ */ Q.jsx(
          "button",
          {
            id: "file-search-toggle",
            type: "button",
            title: A("showFileSearch"),
            "aria-label": A("showFileSearch"),
            "aria-pressed": "false"
          }
        ),
        /* @__PURE__ */ Q.jsx(
          "button",
          {
            id: "file-collapse-toggle",
            type: "button",
            title: A("hideFiles"),
            "aria-label": A("hideFiles")
          }
        )
      ] })
    ] }),
    /* @__PURE__ */ Q.jsx("div", { id: "file-list", children: /* @__PURE__ */ Q.jsx(mg, {}) }),
    /* @__PURE__ */ Q.jsxs("div", { id: "files-footer", "aria-label": A("diffStats"), children: [
      /* @__PURE__ */ Q.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ Q.jsx("span", { children: A("files") }),
        /* @__PURE__ */ Q.jsx("strong", { id: "stats-files", children: "0" })
      ] }),
      /* @__PURE__ */ Q.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ Q.jsx("span", { children: A("additions") }),
        /* @__PURE__ */ Q.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" })
      ] }),
      /* @__PURE__ */ Q.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ Q.jsx("span", { children: A("deletions") }),
        /* @__PURE__ */ Q.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" })
      ] })
    ] })
  ] });
}
function yg({ config: A }) {
  const w = am.useRef(!1), W = im(A.payload?.labels, {
    assertMissing: nm()
  }), h = am.useCallback((st) => {
    !st || w.current || (w.current = !0, rg(A));
  }, [A]);
  return /* @__PURE__ */ Q.jsxs("div", { id: "app", ref: h, children: [
    /* @__PURE__ */ Q.jsx(pg, { config: A, label: W }),
    /* @__PURE__ */ Q.jsxs("section", { id: "content", children: [
      /* @__PURE__ */ Q.jsx(vg, { config: A, label: W }),
      /* @__PURE__ */ Q.jsxs("main", { id: "viewer", "aria-label": W("diffViewer"), children: [
        /* @__PURE__ */ Q.jsx("div", { id: "status", children: A.payload?.statusMessage ?? W("loadingDiff") }),
        /* @__PURE__ */ Q.jsx(hg, {})
      ] })
    ] })
  ] });
}
const bg = '@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-space-y-reverse:0;--tw-border-style:solid}}}@layer theme{:root,:host{--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--spacing:.25rem;--radius-md:.375rem;--default-font-family:var(--font-sans);--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab,red,red)){::placeholder{color:color-mix(in oklab,currentcolor 50%,transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}}@layer components;@layer utilities{.\\@container{container-type:inline-size}.collapse{visibility:collapse}.visible{visibility:visible}.fixed{position:fixed}.static{position:static}.mx-3\\.5{margin-inline:calc(var(--spacing) * 3.5)}.mt-3\\.5{margin-top:calc(var(--spacing) * 3.5)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.flex{display:flex}.grid{display:grid}.hidden{display:none}.size-\\[17px\\]{width:17px;height:17px}.h-3{height:calc(var(--spacing) * 3)}.h-9{height:calc(var(--spacing) * 9)}.h-\\[30px\\]{height:30px}.h-px{height:1px}.w-2\\/5{width:40%}.min-w-0{min-width:calc(var(--spacing) * 0)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.grid-cols-\\[17px_minmax\\(0\\,1fr\\)_44px\\]{grid-template-columns:17px minmax(0,1fr) 44px}.grid-cols-\\[42px_minmax\\(0\\,1fr\\)\\]{grid-template-columns:42px minmax(0,1fr)}.grid-cols-\\[72px_minmax\\(0\\,1fr\\)_96px\\]{grid-template-columns:72px minmax(0,1fr) 96px}.items-center{align-items:center}.justify-center{justify-content:center}.gap-1\\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}:where(.space-y-\\[13px\\]>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(13px * var(--tw-space-y-reverse));margin-block-end:calc(13px * calc(1 - var(--tw-space-y-reverse)))}.justify-self-end{justify-self:flex-end}.rounded{border-radius:.25rem}.rounded-\\[5px\\]{border-radius:5px}.rounded-md{border-radius:var(--radius-md)}.border{border-style:var(--tw-border-style);border-width:1px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:color-mix(in lab,var(--cmux-diff-fg) 18%,transparent)}}.border-\\[var\\(--cmux-diff-border\\)\\]{border-color:var(--cmux-diff-border)}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.bg-\\[var\\(--cmux-diff-muted-bg\\)\\]{background-color:var(--cmux-diff-muted-bg)}.p-2{padding:calc(var(--spacing) * 2)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-\\[7px\\]{padding-inline:7px}.py-1{padding-block:calc(var(--spacing) * 1)}.pt-3{padding-top:calc(var(--spacing) * 3)}.italic{font-style:italic}.opacity-70{opacity:.7}}:root{color-scheme:light dark;--cmux-diff-bg-light:#fff;--cmux-diff-bg-dark:#000;--cmux-diff-fg-light:#000;--cmux-diff-fg-dark:#fff;--cmux-diff-selection-bg-light:#abd8ff;--cmux-diff-selection-bg-dark:#3f638b;--cmux-diff-ui-font-family:system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size:12px;--cmux-diff-ui-line-height:16px;--cmux-diff-code-font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size:10px;--cmux-diff-line-height:20px;--cmux-diff-bg:var(--cmux-diff-bg-light);--cmux-diff-fg:var(--cmux-diff-fg-light);--cmux-diff-border:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-border:color-mix(in lab, var(--cmux-diff-fg) 12%, transparent)}}:root{--cmux-diff-sidebar-bg:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-sidebar-bg:color-mix(in lab, var(--cmux-diff-bg) 98%, var(--cmux-diff-fg))}}:root{--cmux-diff-muted-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-muted-bg:color-mix(in lab, var(--cmux-diff-fg) 8%, transparent)}}:root{--cmux-diff-hover-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-hover-bg:color-mix(in lab, var(--cmux-diff-fg) 10%, transparent)}}:root{--cmux-diff-accent:light-dark(#0a84ff,#7ab7ff);background:var(--cmux-diff-bg);color:var(--cmux-diff-fg)}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg:var(--cmux-diff-bg-dark);--cmux-diff-fg:var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{height:100%;overflow:hidden}body{background:var(--cmux-diff-bg);height:100vh;min-height:0;color:var(--cmux-diff-fg);font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height);flex-direction:column;margin:0;display:flex;overflow:hidden}#app{overscroll-behavior:contain;contain:strict;background:inherit;height:100vh;min-height:0;color:inherit;grid-template-rows:auto minmax(0,1fr);display:grid;overflow:hidden}#toolbar{border-bottom:1px solid var(--cmux-diff-fg);flex:none;align-items:center;gap:7px;min-height:32px;padding:3px 8px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#toolbar{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}#toolbar{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#toolbar{background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg))}}#toolbar{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#toolbar{color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg))}}#toolbar{z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{align-items:center;gap:6px;min-width:0;display:flex}.toolbar-left{flex:0 36%}.toolbar-middle{flex:auto;justify-content:center}.toolbar-actions{flex:none}#source-select,#repo-select,#base-select,#jump-select{appearance:none;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,var(--cmux-diff-fg);border:1px solid #0000;border-radius:6px;min-width:118px;max-width:min(30vw,320px);height:24px;padding:0 24px 0 9px}@supports (color:color-mix(in lab,red,red)){#source-select,#repo-select,#base-select,#jump-select{background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent)}}#source-select,#repo-select,#base-select,#jump-select{color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent)}}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent)}}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline-offset:1px}#source-detail{text-overflow:ellipsis;white-space:nowrap;min-width:0;color:var(--cmux-diff-fg);overflow:hidden}@supports (color:color-mix(in lab,red,red)){#source-detail{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}.toolbar-icon{width:28px;height:26px;color:var(--cmux-diff-fg);background:0 0;border:1px solid #0000;border-radius:6px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.toolbar-icon{color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg))}}.toolbar-icon{cursor:pointer;padding:0}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true],.toolbar-icon[aria-pressed=true]{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:16px;height:16px;display:block}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{border:1px solid var(--cmux-diff-fg);min-width:246px;padding:8px;position:absolute;top:calc(100% + 7px);right:10px}@supports (color:color-mix(in lab,red,red)){#options-menu{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent)}}#options-menu{background:var(--cmux-diff-bg);border-radius:8px}@supports (color:color-mix(in lab,red,red)){#options-menu{background:color-mix(in lab,var(--cmux-diff-bg) 94%,var(--cmux-diff-fg))}}#options-menu{z-index:100;box-shadow:0 16px 34px lab(0% none none/.28)}#options-menu[hidden]{display:none}.menu-separator{background:var(--cmux-diff-fg);height:1px;margin:7px 6px}@supports (color:color-mix(in lab,red,red)){.menu-separator{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.menu-item{width:100%;min-height:31px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:6px;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;display:grid}@supports (color:color-mix(in lab,red,red)){.menu-item{color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg))}}.menu-item{font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.menu-item:hover:not(:disabled){color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:0 0}.menu-segment-controls{background:var(--cmux-diff-bg);border-radius:7px;justify-self:end;align-items:center;gap:2px;padding:2px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.menu-segment-controls{background:color-mix(in lab,var(--cmux-diff-bg) 82%,var(--cmux-diff-fg))}}.segment-button{width:27px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.segment-button{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.segment-button{padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.segment-button:hover,.segment-button[aria-pressed=true],.menu-item:disabled{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}}.menu-label{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.menu-check{justify-self:end}#content{--cmux-diff-files-width:clamp(190px, 22vw, 252px);grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);overscroll-behavior:contain;contain:strict;background:inherit;flex:auto;grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";min-width:0;min-height:0;display:grid;position:relative;overflow:hidden}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{border-left:1px solid var(--cmux-diff-border);background:var(--cmux-diff-bg);flex-direction:column;grid-area:files;width:100%;min-width:0;height:100%;min-height:0;display:flex;position:relative;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#files-sidebar{background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg))}}#files-sidebar{contain:strict;opacity:1;transition:opacity .1s,visibility linear}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s,visibility 0s linear .1s}body[data-status-only=true] #files-sidebar{display:none}#files-header{z-index:1;border-bottom:1px solid var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:8px;min-height:30px;padding:0 7px 0 10px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#files-header{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-header{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#files-header{background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg))}}#files-header{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#files-header{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}#files-title{align-items:center;gap:6px;min-width:0;display:inline-flex}#files-header-actions{flex:none;align-items:center;gap:2px;display:inline-flex}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;flex:none;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){#file-search-toggle,#file-collapse-toggle{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}#file-search-toggle,#file-collapse-toggle{padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:15px;height:15px}#file-list{--trees-bg-override:var(--cmux-diff-sidebar-bg);--trees-fg-override:var(--cmux-diff-fg);flex:auto;min-height:0;padding:6px 4px 6px 6px;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-override:color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg))}}#file-list{--trees-fg-muted-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-muted-override:color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg))}}#file-list{--trees-bg-muted-override:var(--cmux-diff-hover-bg);--trees-selected-bg-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-selected-bg-override:color-mix(in lab, var(--cmux-diff-fg) 11%, transparent)}}#file-list{--trees-selected-fg-override:var(--cmux-diff-fg);--trees-selected-focused-border-color-override:transparent;--trees-border-color-override:var(--cmux-diff-border);--trees-focus-ring-color-override:var(--cmux-diff-accent)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-focus-ring-color-override:color-mix(in lab, var(--cmux-diff-accent) 72%, transparent)}}#file-list{--trees-font-family-override:var(--cmux-diff-ui-font-family);--trees-font-size-override:var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override:500;--trees-density-override:.78;--trees-border-radius-override:5px;--trees-item-padding-x-override:7px;--trees-item-margin-x-override:0;--trees-padding-inline-override:0;--trees-search-bg-override:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-search-bg-override:color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))}}#file-list{--trees-status-added-override:light-dark(#257a3e,#8fd88f);--trees-status-modified-override:var(--cmux-diff-accent);--trees-status-renamed-override:light-dark(#a26300,#ffd166);--trees-status-deleted-override:light-dark(#b42318,#ff8a80)}body[data-loading=false] .diff-loading-placeholder{display:none}#file-list file-tree-container{width:100%;height:100%}#files-footer{border-top:1px solid var(--cmux-diff-fg);flex:none;padding:7px 10px 8px}@supports (color:color-mix(in lab,red,red)){#files-footer{border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-footer{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#files-footer{background:color-mix(in lab,var(--cmux-diff-bg) 97%,var(--cmux-diff-fg))}}.stats-row{min-height:19px;color:var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:10px;display:flex}@supports (color:color-mix(in lab,red,red)){.stats-row{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}.stats-row strong{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg))}}.stats-row strong{font-weight:600}.file-entry{width:100%;min-height:30px;color:inherit;font:inherit;text-align:left;background:0 0;border:0;border-radius:6px;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;padding:3px 7px;display:grid}.file-entry:hover,.file-entry[aria-current=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.file-status{width:17px;height:17px;color:var(--cmux-diff-fg);border:1px solid;border-radius:5px;justify-content:center;align-items:center;font-size:9px;line-height:1;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-status{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.file-name{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.file-stats{color:var(--cmux-diff-fg);gap:5px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-stats{color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));overscroll-behavior:contain;overflow-anchor:none;contain:strict;border-bottom:1px solid var(--cmux-diff-border);background:inherit;grid-area:viewer;width:100%;min-width:0;height:100%;min-height:0;position:relative;overflow:clip auto}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border);display:block;overflow:clip}#status{z-index:2;border-bottom:1px solid var(--cmux-diff-fg);align-items:center;gap:10px;min-height:40px;padding:10px 14px;display:flex;position:sticky;top:0}@supports (color:color-mix(in lab,red,red)){#status{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#status{background:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#status{background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg))}}#status{font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status{color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{content:"";border:2px solid var(--cmux-diff-fg);flex:none;width:14px;height:14px}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent)}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-radius:50%;animation:.8s linear infinite cmuxDiffPendingSpin}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before,body[data-loading=true] #status:before{animation:none}}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}';
function xg() {
  const A = document.getElementById("cmux-diff-viewer-config");
  if (!A?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(A.textContent);
}
function Sg() {
  const A = document.createElement("style");
  A.dataset.cmuxDiffViewerStyle = "true", A.textContent = bg, document.head.append(A);
}
const sa = xg();
Sg();
typeof sa.payload?.title == "string" && sa.payload.title.trim() !== "" && (document.title = sa.payload.title);
document.body.dataset.filesHidden = "false";
document.body.dataset.loading = sa.payload?.pendingReplacement || !sa.payload?.statusMessage ? "true" : "false";
document.body.dataset.statusOnly = sa.payload?.statusMessage && !sa.payload.pendingReplacement ? "true" : "false";
const um = document.getElementById("root");
if (!um)
  throw new Error("Missing cmux diff viewer root");
ug.createRoot(um).render(/* @__PURE__ */ Q.jsx(yg, { config: sa }));
