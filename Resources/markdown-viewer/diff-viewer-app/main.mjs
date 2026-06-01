var go = { exports: {} }, wu = {};
var Fd;
function Fh() {
  if (Fd) return wu;
  Fd = 1;
  var _ = /* @__PURE__ */ Symbol.for("react.transitional.element"), xt = /* @__PURE__ */ Symbol.for("react.fragment");
  function st(p, Nt, Lt) {
    var kt = null;
    if (Lt !== void 0 && (kt = "" + Lt), Nt.key !== void 0 && (kt = "" + Nt.key), "key" in Nt) {
      Lt = {};
      for (var K in Nt)
        K !== "key" && (Lt[K] = Nt[K]);
    } else Lt = Nt;
    return Nt = Lt.ref, {
      $$typeof: _,
      type: p,
      key: kt,
      ref: Nt !== void 0 ? Nt : null,
      props: Lt
    };
  }
  return wu.Fragment = xt, wu.jsx = st, wu.jsxs = st, wu;
}
var Wd;
function Wh() {
  return Wd || (Wd = 1, go.exports = Fh()), go.exports;
}
var lt = Wh(), vo = { exports: {} }, Yu = {}, po = { exports: {} }, bo = {};
var $d;
function $h() {
  return $d || ($d = 1, (function(_) {
    function xt(b, U) {
      var B = b.length;
      b.push(U);
      t: for (; 0 < B; ) {
        var J = B - 1 >>> 1, $ = b[J];
        if (0 < Nt($, U))
          b[J] = U, b[B] = $, B = J;
        else break t;
      }
    }
    function st(b) {
      return b.length === 0 ? null : b[0];
    }
    function p(b) {
      if (b.length === 0) return null;
      var U = b[0], B = b.pop();
      if (B !== U) {
        b[0] = B;
        t: for (var J = 0, $ = b.length, d = $ >>> 1; J < d; ) {
          var z = 2 * (J + 1) - 1, C = b[z], q = z + 1, k = b[q];
          if (0 > Nt(C, B))
            q < $ && 0 > Nt(k, C) ? (b[J] = k, b[q] = B, J = q) : (b[J] = C, b[z] = B, J = z);
          else if (q < $ && 0 > Nt(k, B))
            b[J] = k, b[q] = B, J = q;
          else break t;
        }
      }
      return U;
    }
    function Nt(b, U) {
      var B = b.sortIndex - U.sortIndex;
      return B !== 0 ? B : b.id - U.id;
    }
    if (_.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var Lt = performance;
      _.unstable_now = function() {
        return Lt.now();
      };
    } else {
      var kt = Date, K = kt.now();
      _.unstable_now = function() {
        return kt.now() - K;
      };
    }
    var L = [], A = [], at = 1, V = null, gt = 3, ve = !1, me = !1, It = !1, At = !1, ae = typeof setTimeout == "function" ? setTimeout : null, pe = typeof clearTimeout == "function" ? clearTimeout : null, Ht = typeof setImmediate < "u" ? setImmediate : null;
    function Pt(b) {
      for (var U = st(A); U !== null; ) {
        if (U.callback === null) p(A);
        else if (U.startTime <= b)
          p(A), U.sortIndex = U.expirationTime, xt(L, U);
        else break;
        U = st(A);
      }
    }
    function Ft(b) {
      if (It = !1, Pt(b), !me)
        if (st(L) !== null)
          me = !0, te || (te = !0, ue());
        else {
          var U = st(A);
          U !== null && N(Ft, U.startTime - b);
        }
    }
    var te = !1, F = -1, ne = 5, ee = -1;
    function Ye() {
      return At ? !0 : !(_.unstable_now() - ee < ne);
    }
    function Oe() {
      if (At = !1, te) {
        var b = _.unstable_now();
        ee = b;
        var U = !0;
        try {
          t: {
            me = !1, It && (It = !1, pe(F), F = -1), ve = !0;
            var B = gt;
            try {
              e: {
                for (Pt(b), V = st(L); V !== null && !(V.expirationTime > b && Ye()); ) {
                  var J = V.callback;
                  if (typeof J == "function") {
                    V.callback = null, gt = V.priorityLevel;
                    var $ = J(
                      V.expirationTime <= b
                    );
                    if (b = _.unstable_now(), typeof $ == "function") {
                      V.callback = $, Pt(b), U = !0;
                      break e;
                    }
                    V === st(L) && p(L), Pt(b);
                  } else p(L);
                  V = st(L);
                }
                if (V !== null) U = !0;
                else {
                  var d = st(A);
                  d !== null && N(
                    Ft,
                    d.startTime - b
                  ), U = !1;
                }
              }
              break t;
            } finally {
              V = null, gt = B, ve = !1;
            }
            U = void 0;
          }
        } finally {
          U ? ue() : te = !1;
        }
      }
    }
    var ue;
    if (typeof Ht == "function")
      ue = function() {
        Ht(Oe);
      };
    else if (typeof MessageChannel < "u") {
      var il = new MessageChannel(), G = il.port2;
      il.port1.onmessage = Oe, ue = function() {
        G.postMessage(null);
      };
    } else
      ue = function() {
        ae(Oe, 0);
      };
    function N(b, U) {
      F = ae(function() {
        b(_.unstable_now());
      }, U);
    }
    _.unstable_IdlePriority = 5, _.unstable_ImmediatePriority = 1, _.unstable_LowPriority = 4, _.unstable_NormalPriority = 3, _.unstable_Profiling = null, _.unstable_UserBlockingPriority = 2, _.unstable_cancelCallback = function(b) {
      b.callback = null;
    }, _.unstable_forceFrameRate = function(b) {
      0 > b || 125 < b ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : ne = 0 < b ? Math.floor(1e3 / b) : 5;
    }, _.unstable_getCurrentPriorityLevel = function() {
      return gt;
    }, _.unstable_next = function(b) {
      switch (gt) {
        case 1:
        case 2:
        case 3:
          var U = 3;
          break;
        default:
          U = gt;
      }
      var B = gt;
      gt = U;
      try {
        return b();
      } finally {
        gt = B;
      }
    }, _.unstable_requestPaint = function() {
      At = !0;
    }, _.unstable_runWithPriority = function(b, U) {
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
      var B = gt;
      gt = b;
      try {
        return U();
      } finally {
        gt = B;
      }
    }, _.unstable_scheduleCallback = function(b, U, B) {
      var J = _.unstable_now();
      switch (typeof B == "object" && B !== null ? (B = B.delay, B = typeof B == "number" && 0 < B ? J + B : J) : B = J, b) {
        case 1:
          var $ = -1;
          break;
        case 2:
          $ = 250;
          break;
        case 5:
          $ = 1073741823;
          break;
        case 4:
          $ = 1e4;
          break;
        default:
          $ = 5e3;
      }
      return $ = B + $, b = {
        id: at++,
        callback: U,
        priorityLevel: b,
        startTime: B,
        expirationTime: $,
        sortIndex: -1
      }, B > J ? (b.sortIndex = B, xt(A, b), st(L) === null && b === st(A) && (It ? (pe(F), F = -1) : It = !0, N(Ft, B - J))) : (b.sortIndex = $, xt(L, b), me || ve || (me = !0, te || (te = !0, ue()))), b;
    }, _.unstable_shouldYield = Ye, _.unstable_wrapCallback = function(b) {
      var U = gt;
      return function() {
        var B = gt;
        gt = U;
        try {
          return b.apply(this, arguments);
        } finally {
          gt = B;
        }
      };
    };
  })(bo)), bo;
}
var Id;
function Ih() {
  return Id || (Id = 1, po.exports = $h()), po.exports;
}
var So = { exports: {} }, W = {};
var Pd;
function Ph() {
  if (Pd) return W;
  Pd = 1;
  var _ = /* @__PURE__ */ Symbol.for("react.transitional.element"), xt = /* @__PURE__ */ Symbol.for("react.portal"), st = /* @__PURE__ */ Symbol.for("react.fragment"), p = /* @__PURE__ */ Symbol.for("react.strict_mode"), Nt = /* @__PURE__ */ Symbol.for("react.profiler"), Lt = /* @__PURE__ */ Symbol.for("react.consumer"), kt = /* @__PURE__ */ Symbol.for("react.context"), K = /* @__PURE__ */ Symbol.for("react.forward_ref"), L = /* @__PURE__ */ Symbol.for("react.suspense"), A = /* @__PURE__ */ Symbol.for("react.memo"), at = /* @__PURE__ */ Symbol.for("react.lazy"), V = /* @__PURE__ */ Symbol.for("react.activity"), gt = Symbol.iterator;
  function ve(d) {
    return d === null || typeof d != "object" ? null : (d = gt && d[gt] || d["@@iterator"], typeof d == "function" ? d : null);
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
  }, It = Object.assign, At = {};
  function ae(d, z, C) {
    this.props = d, this.context = z, this.refs = At, this.updater = C || me;
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
  function pe() {
  }
  pe.prototype = ae.prototype;
  function Ht(d, z, C) {
    this.props = d, this.context = z, this.refs = At, this.updater = C || me;
  }
  var Pt = Ht.prototype = new pe();
  Pt.constructor = Ht, It(Pt, ae.prototype), Pt.isPureReactComponent = !0;
  var Ft = Array.isArray;
  function te() {
  }
  var F = { H: null, A: null, T: null, S: null }, ne = Object.prototype.hasOwnProperty;
  function ee(d, z, C) {
    var q = C.ref;
    return {
      $$typeof: _,
      type: d,
      key: z,
      ref: q !== void 0 ? q : null,
      props: C
    };
  }
  function Ye(d, z) {
    return ee(d.type, z, d.props);
  }
  function Oe(d) {
    return typeof d == "object" && d !== null && d.$$typeof === _;
  }
  function ue(d) {
    var z = { "=": "=0", ":": "=2" };
    return "$" + d.replace(/[=:]/g, function(C) {
      return z[C];
    });
  }
  var il = /\/+/g;
  function G(d, z) {
    return typeof d == "object" && d !== null && d.key != null ? ue("" + d.key) : z.toString(36);
  }
  function N(d) {
    switch (d.status) {
      case "fulfilled":
        return d.value;
      case "rejected":
        throw d.reason;
      default:
        switch (typeof d.status == "string" ? d.then(te, te) : (d.status = "pending", d.then(
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
  function b(d, z, C, q, k) {
    var tt = typeof d;
    (tt === "undefined" || tt === "boolean") && (d = null);
    var rt = !1;
    if (d === null) rt = !0;
    else
      switch (tt) {
        case "bigint":
        case "string":
        case "number":
          rt = !0;
          break;
        case "object":
          switch (d.$$typeof) {
            case _:
            case xt:
              rt = !0;
              break;
            case at:
              return rt = d._init, b(
                rt(d._payload),
                z,
                C,
                q,
                k
              );
          }
      }
    if (rt)
      return k = k(d), rt = q === "" ? "." + G(d, 0) : q, Ft(k) ? (C = "", rt != null && (C = rt.replace(il, "$&/") + "/"), b(k, z, C, "", function(Ue) {
        return Ue;
      })) : k != null && (Oe(k) && (k = Ye(
        k,
        C + (k.key == null || d && d.key === k.key ? "" : ("" + k.key).replace(
          il,
          "$&/"
        ) + "/") + rt
      )), z.push(k)), 1;
    rt = 0;
    var qt = q === "" ? "." : q + ":";
    if (Ft(d))
      for (var _t = 0; _t < d.length; _t++)
        q = d[_t], tt = qt + G(q, _t), rt += b(
          q,
          z,
          C,
          tt,
          k
        );
    else if (_t = ve(d), typeof _t == "function")
      for (d = _t.call(d), _t = 0; !(q = d.next()).done; )
        q = q.value, tt = qt + G(q, _t++), rt += b(
          q,
          z,
          C,
          tt,
          k
        );
    else if (tt === "object") {
      if (typeof d.then == "function")
        return b(
          N(d),
          z,
          C,
          q,
          k
        );
      throw z = String(d), Error(
        "Objects are not valid as a React child (found: " + (z === "[object Object]" ? "object with keys {" + Object.keys(d).join(", ") + "}" : z) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return rt;
  }
  function U(d, z, C) {
    if (d == null) return d;
    var q = [], k = 0;
    return b(d, q, "", "", function(tt) {
      return z.call(C, tt, k++);
    }), q;
  }
  function B(d) {
    if (d._status === -1) {
      var z = d._result;
      z = z(), z.then(
        function(C) {
          (d._status === 0 || d._status === -1) && (d._status = 1, d._result = C);
        },
        function(C) {
          (d._status === 0 || d._status === -1) && (d._status = 2, d._result = C);
        }
      ), d._status === -1 && (d._status = 0, d._result = z);
    }
    if (d._status === 1) return d._result.default;
    throw d._result;
  }
  var J = typeof reportError == "function" ? reportError : function(d) {
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
  }, $ = {
    map: U,
    forEach: function(d, z, C) {
      U(
        d,
        function() {
          z.apply(this, arguments);
        },
        C
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
  return W.Activity = V, W.Children = $, W.Component = ae, W.Fragment = st, W.Profiler = Nt, W.PureComponent = Ht, W.StrictMode = p, W.Suspense = L, W.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = F, W.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(d) {
      return F.H.useMemoCache(d);
    }
  }, W.cache = function(d) {
    return function() {
      return d.apply(null, arguments);
    };
  }, W.cacheSignal = function() {
    return null;
  }, W.cloneElement = function(d, z, C) {
    if (d == null)
      throw Error(
        "The argument must be a React element, but you passed " + d + "."
      );
    var q = It({}, d.props), k = d.key;
    if (z != null)
      for (tt in z.key !== void 0 && (k = "" + z.key), z)
        !ne.call(z, tt) || tt === "key" || tt === "__self" || tt === "__source" || tt === "ref" && z.ref === void 0 || (q[tt] = z[tt]);
    var tt = arguments.length - 2;
    if (tt === 1) q.children = C;
    else if (1 < tt) {
      for (var rt = Array(tt), qt = 0; qt < tt; qt++)
        rt[qt] = arguments[qt + 2];
      q.children = rt;
    }
    return ee(d.type, k, q);
  }, W.createContext = function(d) {
    return d = {
      $$typeof: kt,
      _currentValue: d,
      _currentValue2: d,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, d.Provider = d, d.Consumer = {
      $$typeof: Lt,
      _context: d
    }, d;
  }, W.createElement = function(d, z, C) {
    var q, k = {}, tt = null;
    if (z != null)
      for (q in z.key !== void 0 && (tt = "" + z.key), z)
        ne.call(z, q) && q !== "key" && q !== "__self" && q !== "__source" && (k[q] = z[q]);
    var rt = arguments.length - 2;
    if (rt === 1) k.children = C;
    else if (1 < rt) {
      for (var qt = Array(rt), _t = 0; _t < rt; _t++)
        qt[_t] = arguments[_t + 2];
      k.children = qt;
    }
    if (d && d.defaultProps)
      for (q in rt = d.defaultProps, rt)
        k[q] === void 0 && (k[q] = rt[q]);
    return ee(d, tt, k);
  }, W.createRef = function() {
    return { current: null };
  }, W.forwardRef = function(d) {
    return { $$typeof: K, render: d };
  }, W.isValidElement = Oe, W.lazy = function(d) {
    return {
      $$typeof: at,
      _payload: { _status: -1, _result: d },
      _init: B
    };
  }, W.memo = function(d, z) {
    return {
      $$typeof: A,
      type: d,
      compare: z === void 0 ? null : z
    };
  }, W.startTransition = function(d) {
    var z = F.T, C = {};
    F.T = C;
    try {
      var q = d(), k = F.S;
      k !== null && k(C, q), typeof q == "object" && q !== null && typeof q.then == "function" && q.then(te, J);
    } catch (tt) {
      J(tt);
    } finally {
      z !== null && C.types !== null && (z.types = C.types), F.T = z;
    }
  }, W.unstable_useCacheRefresh = function() {
    return F.H.useCacheRefresh();
  }, W.use = function(d) {
    return F.H.use(d);
  }, W.useActionState = function(d, z, C) {
    return F.H.useActionState(d, z, C);
  }, W.useCallback = function(d, z) {
    return F.H.useCallback(d, z);
  }, W.useContext = function(d) {
    return F.H.useContext(d);
  }, W.useDebugValue = function() {
  }, W.useDeferredValue = function(d, z) {
    return F.H.useDeferredValue(d, z);
  }, W.useEffect = function(d, z) {
    return F.H.useEffect(d, z);
  }, W.useEffectEvent = function(d) {
    return F.H.useEffectEvent(d);
  }, W.useId = function() {
    return F.H.useId();
  }, W.useImperativeHandle = function(d, z, C) {
    return F.H.useImperativeHandle(d, z, C);
  }, W.useInsertionEffect = function(d, z) {
    return F.H.useInsertionEffect(d, z);
  }, W.useLayoutEffect = function(d, z) {
    return F.H.useLayoutEffect(d, z);
  }, W.useMemo = function(d, z) {
    return F.H.useMemo(d, z);
  }, W.useOptimistic = function(d, z) {
    return F.H.useOptimistic(d, z);
  }, W.useReducer = function(d, z, C) {
    return F.H.useReducer(d, z, C);
  }, W.useRef = function(d) {
    return F.H.useRef(d);
  }, W.useState = function(d) {
    return F.H.useState(d);
  }, W.useSyncExternalStore = function(d, z, C) {
    return F.H.useSyncExternalStore(
      d,
      z,
      C
    );
  }, W.useTransition = function() {
    return F.H.useTransition();
  }, W.version = "19.2.3", W;
}
var tm;
function To() {
  return tm || (tm = 1, So.exports = Ph()), So.exports;
}
var xo = { exports: {} }, ge = {};
var em;
function t0() {
  if (em) return ge;
  em = 1;
  var _ = To();
  function xt(L) {
    var A = "https://react.dev/errors/" + L;
    if (1 < arguments.length) {
      A += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var at = 2; at < arguments.length; at++)
        A += "&args[]=" + encodeURIComponent(arguments[at]);
    }
    return "Minified React error #" + L + "; visit " + A + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function st() {
  }
  var p = {
    d: {
      f: st,
      r: function() {
        throw Error(xt(522));
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
  }, Nt = /* @__PURE__ */ Symbol.for("react.portal");
  function Lt(L, A, at) {
    var V = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: Nt,
      key: V == null ? null : "" + V,
      children: L,
      containerInfo: A,
      implementation: at
    };
  }
  var kt = _.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function K(L, A) {
    if (L === "font") return "";
    if (typeof A == "string")
      return A === "use-credentials" ? A : "";
  }
  return ge.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = p, ge.createPortal = function(L, A) {
    var at = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!A || A.nodeType !== 1 && A.nodeType !== 9 && A.nodeType !== 11)
      throw Error(xt(299));
    return Lt(L, A, null, at);
  }, ge.flushSync = function(L) {
    var A = kt.T, at = p.p;
    try {
      if (kt.T = null, p.p = 2, L) return L();
    } finally {
      kt.T = A, p.p = at, p.d.f();
    }
  }, ge.preconnect = function(L, A) {
    typeof L == "string" && (A ? (A = A.crossOrigin, A = typeof A == "string" ? A === "use-credentials" ? A : "" : void 0) : A = null, p.d.C(L, A));
  }, ge.prefetchDNS = function(L) {
    typeof L == "string" && p.d.D(L);
  }, ge.preinit = function(L, A) {
    if (typeof L == "string" && A && typeof A.as == "string") {
      var at = A.as, V = K(at, A.crossOrigin), gt = typeof A.integrity == "string" ? A.integrity : void 0, ve = typeof A.fetchPriority == "string" ? A.fetchPriority : void 0;
      at === "style" ? p.d.S(
        L,
        typeof A.precedence == "string" ? A.precedence : void 0,
        {
          crossOrigin: V,
          integrity: gt,
          fetchPriority: ve
        }
      ) : at === "script" && p.d.X(L, {
        crossOrigin: V,
        integrity: gt,
        fetchPriority: ve,
        nonce: typeof A.nonce == "string" ? A.nonce : void 0
      });
    }
  }, ge.preinitModule = function(L, A) {
    if (typeof L == "string")
      if (typeof A == "object" && A !== null) {
        if (A.as == null || A.as === "script") {
          var at = K(
            A.as,
            A.crossOrigin
          );
          p.d.M(L, {
            crossOrigin: at,
            integrity: typeof A.integrity == "string" ? A.integrity : void 0,
            nonce: typeof A.nonce == "string" ? A.nonce : void 0
          });
        }
      } else A == null && p.d.M(L);
  }, ge.preload = function(L, A) {
    if (typeof L == "string" && typeof A == "object" && A !== null && typeof A.as == "string") {
      var at = A.as, V = K(at, A.crossOrigin);
      p.d.L(L, at, {
        crossOrigin: V,
        integrity: typeof A.integrity == "string" ? A.integrity : void 0,
        nonce: typeof A.nonce == "string" ? A.nonce : void 0,
        type: typeof A.type == "string" ? A.type : void 0,
        fetchPriority: typeof A.fetchPriority == "string" ? A.fetchPriority : void 0,
        referrerPolicy: typeof A.referrerPolicy == "string" ? A.referrerPolicy : void 0,
        imageSrcSet: typeof A.imageSrcSet == "string" ? A.imageSrcSet : void 0,
        imageSizes: typeof A.imageSizes == "string" ? A.imageSizes : void 0,
        media: typeof A.media == "string" ? A.media : void 0
      });
    }
  }, ge.preloadModule = function(L, A) {
    if (typeof L == "string")
      if (A) {
        var at = K(A.as, A.crossOrigin);
        p.d.m(L, {
          as: typeof A.as == "string" && A.as !== "script" ? A.as : void 0,
          crossOrigin: at,
          integrity: typeof A.integrity == "string" ? A.integrity : void 0
        });
      } else p.d.m(L);
  }, ge.requestFormReset = function(L) {
    p.d.r(L);
  }, ge.unstable_batchedUpdates = function(L, A) {
    return L(A);
  }, ge.useFormState = function(L, A, at) {
    return kt.H.useFormState(L, A, at);
  }, ge.useFormStatus = function() {
    return kt.H.useHostTransitionStatus();
  }, ge.version = "19.2.3", ge;
}
var lm;
function e0() {
  if (lm) return xo.exports;
  lm = 1;
  function _() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(_);
      } catch (xt) {
        console.error(xt);
      }
  }
  return _(), xo.exports = t0(), xo.exports;
}
var am;
function l0() {
  if (am) return Yu;
  am = 1;
  var _ = Ih(), xt = To(), st = e0();
  function p(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function Nt(t) {
    return !(!t || t.nodeType !== 1 && t.nodeType !== 9 && t.nodeType !== 11);
  }
  function Lt(t) {
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
  function K(t) {
    if (t.tag === 31) {
      var e = t.memoizedState;
      if (e === null && (t = t.alternate, t !== null && (e = t.memoizedState)), e !== null) return e.dehydrated;
    }
    return null;
  }
  function L(t) {
    if (Lt(t) !== t)
      throw Error(p(188));
  }
  function A(t) {
    var e = t.alternate;
    if (!e) {
      if (e = Lt(t), e === null) throw Error(p(188));
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
          if (u === l) return L(n), t;
          if (u === a) return L(n), e;
          u = u.sibling;
        }
        throw Error(p(188));
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
          if (!i) throw Error(p(189));
        }
      }
      if (l.alternate !== a) throw Error(p(190));
    }
    if (l.tag !== 3) throw Error(p(188));
    return l.stateNode.current === l ? t : e;
  }
  function at(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t;
    for (t = t.child; t !== null; ) {
      if (e = at(t), e !== null) return e;
      t = t.sibling;
    }
    return null;
  }
  var V = Object.assign, gt = /* @__PURE__ */ Symbol.for("react.element"), ve = /* @__PURE__ */ Symbol.for("react.transitional.element"), me = /* @__PURE__ */ Symbol.for("react.portal"), It = /* @__PURE__ */ Symbol.for("react.fragment"), At = /* @__PURE__ */ Symbol.for("react.strict_mode"), ae = /* @__PURE__ */ Symbol.for("react.profiler"), pe = /* @__PURE__ */ Symbol.for("react.consumer"), Ht = /* @__PURE__ */ Symbol.for("react.context"), Pt = /* @__PURE__ */ Symbol.for("react.forward_ref"), Ft = /* @__PURE__ */ Symbol.for("react.suspense"), te = /* @__PURE__ */ Symbol.for("react.suspense_list"), F = /* @__PURE__ */ Symbol.for("react.memo"), ne = /* @__PURE__ */ Symbol.for("react.lazy"), ee = /* @__PURE__ */ Symbol.for("react.activity"), Ye = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), Oe = Symbol.iterator;
  function ue(t) {
    return t === null || typeof t != "object" ? null : (t = Oe && t[Oe] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var il = /* @__PURE__ */ Symbol.for("react.client.reference");
  function G(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === il ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case It:
        return "Fragment";
      case ae:
        return "Profiler";
      case At:
        return "StrictMode";
      case Ft:
        return "Suspense";
      case te:
        return "SuspenseList";
      case ee:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case me:
          return "Portal";
        case Ht:
          return t.displayName || "Context";
        case pe:
          return (t._context.displayName || "Context") + ".Consumer";
        case Pt:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case F:
          return e = t.displayName || null, e !== null ? e : G(t.type) || "Memo";
        case ne:
          e = t._payload, t = t._init;
          try {
            return G(t(e));
          } catch {
          }
      }
    return null;
  }
  var N = Array.isArray, b = xt.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, U = st.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, B = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, J = [], $ = -1;
  function d(t) {
    return { current: t };
  }
  function z(t) {
    0 > $ || (t.current = J[$], J[$] = null, $--);
  }
  function C(t, e) {
    $++, J[$] = t.current, t.current = e;
  }
  var q = d(null), k = d(null), tt = d(null), rt = d(null);
  function qt(t, e) {
    switch (C(tt, e), C(k, t), C(q, null), e.nodeType) {
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
    z(q), C(q, t);
  }
  function _t() {
    z(q), z(k), z(tt);
  }
  function Ue(t) {
    t.memoizedState !== null && C(rt, t);
    var e = q.current, l = bd(e, t.type);
    e !== l && (C(k, t), C(q, l));
  }
  function $e(t) {
    k.current === t && (z(q), z(k)), rt.current === t && (z(rt), Nu._currentValue = B);
  }
  var Ka, Gu;
  function ie(t) {
    if (Ka === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        Ka = e && e[1] || "", Gu = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + Ka + t + Gu;
  }
  var qn = !1;
  function jn(t, e) {
    if (!t || qn) return "";
    qn = !0;
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
                  var v = S;
                }
                Reflect.construct(t, [], E);
              } else {
                try {
                  E.call();
                } catch (S) {
                  v = S;
                }
                t.call(E.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (S) {
                v = S;
              }
              (E = t()) && typeof E.catch == "function" && E.catch(function() {
              });
            }
          } catch (S) {
            if (S && v && typeof S.stack == "string")
              return [S.stack, v.stack];
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
        var o = i.split(`
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
                  var x = `
` + o[a].replace(" at new ", " at ");
                  return t.displayName && x.includes("<anonymous>") && (x = x.replace("<anonymous>", t.displayName)), x;
                }
              while (1 <= a && 0 <= n);
            break;
          }
      }
    } finally {
      qn = !1, Error.prepareStackTrace = l;
    }
    return (l = t ? t.displayName || t.name : "") ? ie(l) : "";
  }
  function ff(t, e) {
    switch (t.tag) {
      case 26:
      case 27:
      case 5:
        return ie(t.type);
      case 16:
        return ie("Lazy");
      case 13:
        return t.child !== e && e !== null ? ie("Suspense Fallback") : ie("Suspense");
      case 19:
        return ie("SuspenseList");
      case 0:
      case 15:
        return jn(t.type, !1);
      case 11:
        return jn(t.type.render, !1);
      case 1:
        return jn(t.type, !0);
      case 31:
        return ie("Activity");
      default:
        return "";
    }
  }
  function Lu(t) {
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
  var wn = Object.prototype.hasOwnProperty, ya = _.unstable_scheduleCallback, ga = _.unstable_cancelCallback, Xu = _.unstable_shouldYield, Yn = _.unstable_requestPaint, he = _.unstable_now, cf = _.unstable_getCurrentPriorityLevel, Ja = _.unstable_ImmediatePriority, Gn = _.unstable_UserBlockingPriority, ka = _.unstable_NormalPriority, of = _.unstable_LowPriority, Qu = _.unstable_IdlePriority, Vu = _.log, sf = _.unstable_setDisableYieldValue, va = null, be = null;
  function fl(t) {
    if (typeof Vu == "function" && sf(t), be && typeof be.setStrictMode == "function")
      try {
        be.setStrictMode(va, t);
      } catch {
      }
  }
  var Se = Math.clz32 ? Math.clz32 : Fa, pa = Math.log, Zu = Math.LN2;
  function Fa(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - (pa(t) / Zu | 0) | 0;
  }
  var Wa = 256, gl = 262144, $a = 4194304;
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
  function ba(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, u = t.suspendedLanes, i = t.pingedLanes;
    t = t.warmLanes;
    var f = a & 134217727;
    return f !== 0 ? (a = f & ~u, a !== 0 ? n = vl(a) : (i &= f, i !== 0 ? n = vl(i) : l || (l = f & ~t, l !== 0 && (n = vl(l))))) : (f = a & ~u, f !== 0 ? n = vl(f) : i !== 0 ? n = vl(i) : l || (l = a & ~t, l !== 0 && (n = vl(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & u) === 0 && (u = n & -n, l = e & -e, u >= l || u === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function Xl(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function rf(t, e) {
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
  function cl() {
    var t = $a;
    return $a <<= 1, ($a & 62914560) === 0 && ($a = 4194304), t;
  }
  function Ia(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function Sa(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function Pa(t, e, l, a, n, u) {
    var i = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var f = t.entanglements, o = t.expirationTimes, y = t.hiddenUpdates;
    for (l = i & ~l; 0 < l; ) {
      var x = 31 - Se(l), E = 1 << x;
      f[x] = 0, o[x] = -1;
      var v = y[x];
      if (v !== null)
        for (y[x] = null, x = 0; x < v.length; x++) {
          var S = v[x];
          S !== null && (S.lane &= -536870913);
        }
      l &= ~E;
    }
    a !== 0 && Ln(t, a, 0), u !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= u & ~(i & ~e));
  }
  function Ln(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - Se(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function Ku(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - Se(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function xe(t, e) {
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
  function Ta(t) {
    return t &= -t, 2 < t ? 8 < t ? (t & 134217727) !== 0 ? 32 : 268435456 : 8 : 2;
  }
  function Ju() {
    var t = U.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Xd(t.type));
  }
  function ku(t, e) {
    var l = U.p;
    try {
      return U.p = t, e();
    } finally {
      U.p = l;
    }
  }
  var Ie = Math.random().toString(36).slice(2), Wt = "__reactFiber$" + Ie, fe = "__reactProps$" + Ie, pl = "__reactContainer$" + Ie, Xn = "__reactEvents$" + Ie, df = "__reactListeners$" + Ie, mf = "__reactHandles$" + Ie, Fu = "__reactResources$" + Ie, za = "__reactMarker$" + Ie;
  function tn(t) {
    delete t[Wt], delete t[fe], delete t[Xn], delete t[df], delete t[mf];
  }
  function ol(t) {
    var e = t[Wt];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[pl] || l[Wt]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Ad(t); t !== null; ) {
            if (l = t[Wt]) return l;
            t = Ad(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function sl(t) {
    if (t = t[Wt] || t[pl]) {
      var e = t.tag;
      if (e === 5 || e === 6 || e === 13 || e === 31 || e === 26 || e === 27 || e === 3)
        return t;
    }
    return null;
  }
  function Ma(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t.stateNode;
    throw Error(p(33));
  }
  function bl(t) {
    var e = t[Fu];
    return e || (e = t[Fu] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function jt(t) {
    t[za] = !0;
  }
  var Qn = /* @__PURE__ */ new Set(), Vn = {};
  function Sl(t, e) {
    xl(t, e), xl(t + "Capture", e);
  }
  function xl(t, e) {
    for (Vn[t] = e, t = 0; t < e.length; t++)
      Qn.add(e[t]);
  }
  var hf = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), Zn = {}, Wu = {};
  function yf(t) {
    return wn.call(Wu, t) ? !0 : wn.call(Zn, t) ? !1 : hf.test(t) ? Wu[t] = !0 : (Zn[t] = !0, !1);
  }
  function Ql(t, e, l) {
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
  function en(t, e, l) {
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
  function ze(t) {
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
  function Vl(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function gf(t, e, l) {
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
      var e = Vl(t) ? "checked" : "value";
      t._valueTracker = gf(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function Jn(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = Vl(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
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
  function Bt(t) {
    return t.replace(
      vf,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function Zl(t, e, l, a, n, u, i, f) {
    t.name = "", i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" ? t.type = i : t.removeAttribute("type"), e != null ? i === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + ze(e)) : t.value !== "" + ze(e) && (t.value = "" + ze(e)) : i !== "submit" && i !== "reset" || t.removeAttribute("value"), e != null ? kn(t, i, ze(e)) : l != null ? kn(t, i, ze(l)) : a != null && t.removeAttribute("value"), n == null && u != null && (t.defaultChecked = !!u), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), f != null && typeof f != "function" && typeof f != "symbol" && typeof f != "boolean" ? t.name = "" + ze(f) : t.removeAttribute("name");
  }
  function $u(t, e, l, a, n, u, i, f) {
    if (u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.type = u), e != null || l != null) {
      if (!(u !== "submit" && u !== "reset" || e != null)) {
        Kn(t);
        return;
      }
      l = l != null ? "" + ze(l) : "", e = e != null ? "" + ze(e) : l, f || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = f ? t.checked : !!a, t.defaultChecked = !!a, i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.name = i), Kn(t);
  }
  function kn(t, e, l) {
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
      for (l = "" + ze(l), e = null, n = 0; n < t.length; n++) {
        if (t[n].value === l) {
          t[n].selected = !0, a && (t[n].defaultSelected = !0);
          return;
        }
        e !== null || t[n].disabled || (e = t[n]);
      }
      e !== null && (e.selected = !0);
    }
  }
  function s(t, e, l) {
    if (e != null && (e = "" + ze(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + ze(l) : "";
  }
  function g(t, e, l, a) {
    if (e == null) {
      if (a != null) {
        if (l != null) throw Error(p(92));
        if (N(a)) {
          if (1 < a.length) throw Error(p(93));
          a = a[0];
        }
        l = a;
      }
      l == null && (l = ""), e = l;
    }
    l = ze(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), Kn(t);
  }
  function D(t, e) {
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
  function R(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || j.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function H(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(p(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && R(t, n, a);
    } else
      for (var u in e)
        e.hasOwnProperty(u) && R(t, u, e[u]);
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
  ]), vt = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function Pe(t) {
    return vt.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function tl() {
  }
  var Fn = null;
  function Wn(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Tl = null, Kl = null;
  function $n(t) {
    var e = sl(t);
    if (e && (t = e.stateNode)) {
      var l = t[fe] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if (Zl(
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
              'input[name="' + Bt(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[fe] || null;
                if (!n) throw Error(p(90));
                Zl(
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
              a = l[e], a.form === t.form && Jn(a);
          }
          break t;
        case "textarea":
          s(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && c(t, !!l.multiple, e, !1);
      }
    }
  }
  var In = !1;
  function ln(t, e, l) {
    if (In) return t(e, l);
    In = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (In = !1, (Tl !== null || Kl !== null) && (ji(), Tl && (e = Tl, t = Kl, Kl = Tl = null, $n(e), t)))
        for (e = 0; e < t.length; e++) $n(t[e]);
    }
  }
  function zl(t, e) {
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
        p(231, e, typeof l)
      );
    return l;
  }
  var el = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), an = !1;
  if (el)
    try {
      var Ml = {};
      Object.defineProperty(Ml, "passive", {
        get: function() {
          an = !0;
        }
      }), window.addEventListener("test", Ml, Ml), window.removeEventListener("test", Ml, Ml);
    } catch {
      an = !1;
    }
  var Le = null, El = null, Ea = null;
  function Iu() {
    if (Ea) return Ea;
    var t, e = El, l = e.length, a, n = "value" in Le ? Le.value : Le.textContent, u = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var i = l - t;
    for (a = 1; a <= i && e[l - a] === n[u - a]; a++) ;
    return Ea = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function Aa(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function _a() {
    return !0;
  }
  function Pu() {
    return !1;
  }
  function ce(t) {
    function e(l, a, n, u, i) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = u, this.target = i, this.currentTarget = null;
      for (var f in t)
        t.hasOwnProperty(f) && (l = t[f], this[f] = l ? l(u) : u[f]);
      return this.isDefaultPrevented = (u.defaultPrevented != null ? u.defaultPrevented : u.returnValue === !1) ? _a : Pu, this.isPropagationStopped = Pu, this;
    }
    return V(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = _a);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = _a);
      },
      persist: function() {
      },
      isPersistent: _a
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
  }, Da = ce(Xe), Oa = V({}, Xe, { view: 0, detail: 0 }), pf = ce(Oa), nn, Pn, Al, ll = V({}, Oa, {
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
      return "movementX" in t ? t.movementX : (t !== Al && (Al && t.type === "mousemove" ? (nn = t.screenX - Al.screenX, Pn = t.screenY - Al.screenY) : Pn = nn = 0, Al = t), nn);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : Pn;
    }
  }), tu = ce(ll), ti = V({}, ll, { dataTransfer: 0 }), un = ce(ti), M = V({}, Oa, { relatedTarget: 0 }), O = ce(M), Z = V({}, Xe, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), I = ce(Z), dt = V({}, Xe, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), mt = ce(dt), wt = V({}, Xe, { data: 0 }), ye = ce(wt), Ua = {
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
  }, Ce = {
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
  }, ei = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function bf(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = ei[t]) ? !!e[t] : !1;
  }
  function Sf() {
    return bf;
  }
  var im = V({}, Oa, {
    key: function(t) {
      if (t.key) {
        var e = Ua[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = Aa(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? Ce[t.keyCode] || "Unidentified" : "";
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
      return t.type === "keypress" ? Aa(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? Aa(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), fm = ce(im), cm = V({}, ll, {
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
  }), zo = ce(cm), om = V({}, Oa, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: Sf
  }), sm = ce(om), rm = V({}, Xe, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), dm = ce(rm), mm = V({}, ll, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), hm = ce(mm), ym = V({}, Xe, {
    newState: 0,
    oldState: 0
  }), gm = ce(ym), vm = [9, 13, 27, 32], xf = el && "CompositionEvent" in window, eu = null;
  el && "documentMode" in document && (eu = document.documentMode);
  var pm = el && "TextEvent" in window && !eu, Mo = el && (!xf || eu && 8 < eu && 11 >= eu), Eo = " ", Ao = !1;
  function _o(t, e) {
    switch (t) {
      case "keyup":
        return vm.indexOf(e.keyCode) !== -1;
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
  var fn = !1;
  function bm(t, e) {
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
    if (fn)
      return t === "compositionend" || !xf && _o(t, e) ? (t = Iu(), Ea = El = Le = null, fn = !1, t) : null;
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
  var xm = {
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
    return e === "input" ? !!xm[t.type] : e === "textarea";
  }
  function Uo(t, e, l, a) {
    Tl ? Kl ? Kl.push(a) : Kl = [a] : Tl = a, e = Vi(e, "onChange"), 0 < e.length && (l = new Da(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var lu = null, au = null;
  function Tm(t) {
    dd(t, 0);
  }
  function li(t) {
    var e = Ma(t);
    if (Jn(e)) return t;
  }
  function Co(t, e) {
    if (t === "change") return e;
  }
  var Bo = !1;
  if (el) {
    var Tf;
    if (el) {
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
    if (t.propertyName === "value" && li(au)) {
      var e = [];
      Uo(
        e,
        au,
        t,
        Wn(t)
      ), ln(Tm, e);
    }
  }
  function zm(t, e, l) {
    t === "focusin" ? (No(), lu = e, au = l, lu.attachEvent("onpropertychange", Ho)) : t === "focusout" && No();
  }
  function Mm(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return li(au);
  }
  function Em(t, e) {
    if (t === "click") return li(e);
  }
  function Am(t, e) {
    if (t === "input" || t === "change")
      return li(e);
  }
  function _m(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var Be = typeof Object.is == "function" ? Object.is : _m;
  function nu(t, e) {
    if (Be(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!wn.call(e, n) || !Be(t[n], e[n]))
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
  var Dm = el && "documentMode" in document && 11 >= document.documentMode, cn = null, Ef = null, uu = null, Af = !1;
  function Go(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Af || cn == null || cn !== rl(a) || (a = cn, "selectionStart" in a && Mf(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), uu && nu(uu, a) || (uu = a, a = Vi(Ef, "onSelect"), 0 < a.length && (e = new Da(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = cn)));
  }
  function Ca(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var on = {
    animationend: Ca("Animation", "AnimationEnd"),
    animationiteration: Ca("Animation", "AnimationIteration"),
    animationstart: Ca("Animation", "AnimationStart"),
    transitionrun: Ca("Transition", "TransitionRun"),
    transitionstart: Ca("Transition", "TransitionStart"),
    transitioncancel: Ca("Transition", "TransitionCancel"),
    transitionend: Ca("Transition", "TransitionEnd")
  }, _f = {}, Lo = {};
  el && (Lo = document.createElement("div").style, "AnimationEvent" in window || (delete on.animationend.animation, delete on.animationiteration.animation, delete on.animationstart.animation), "TransitionEvent" in window || delete on.transitionend.transition);
  function Ba(t) {
    if (_f[t]) return _f[t];
    if (!on[t]) return t;
    var e = on[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Lo)
        return _f[t] = e[l];
    return t;
  }
  var Xo = Ba("animationend"), Qo = Ba("animationiteration"), Vo = Ba("animationstart"), Om = Ba("transitionrun"), Um = Ba("transitionstart"), Cm = Ba("transitioncancel"), Zo = Ba("transitionend"), Ko = /* @__PURE__ */ new Map(), Df = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Df.push("scrollEnd");
  function al(t, e) {
    Ko.set(t, e), Sl(e, [t]);
  }
  var ai = typeof reportError == "function" ? reportError : function(t) {
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
  }, Qe = [], sn = 0, Of = 0;
  function ni() {
    for (var t = sn, e = Of = sn = 0; e < t; ) {
      var l = Qe[e];
      Qe[e++] = null;
      var a = Qe[e];
      Qe[e++] = null;
      var n = Qe[e];
      Qe[e++] = null;
      var u = Qe[e];
      if (Qe[e++] = null, a !== null && n !== null) {
        var i = a.pending;
        i === null ? n.next = n : (n.next = i.next, i.next = n), a.pending = n;
      }
      u !== 0 && Jo(l, n, u);
    }
  }
  function ui(t, e, l, a) {
    Qe[sn++] = t, Qe[sn++] = e, Qe[sn++] = l, Qe[sn++] = a, Of |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function Uf(t, e, l, a) {
    return ui(t, e, l, a), ii(t);
  }
  function Ra(t, e) {
    return ui(t, null, null, e), ii(t);
  }
  function Jo(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, u = t.return; u !== null; )
      u.childLanes |= l, a = u.alternate, a !== null && (a.childLanes |= l), u.tag === 22 && (t = u.stateNode, t === null || t._visibility & 1 || (n = !0)), t = u, u = u.return;
    return t.tag === 3 ? (u = t.stateNode, n && e !== null && (n = 31 - Se(l), t = u.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), u) : null;
  }
  function ii(t) {
    if (50 < _u)
      throw _u = 0, Yc = null, Error(p(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var rn = {};
  function Bm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function Re(t, e, l, a) {
    return new Bm(t, e, l, a);
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
  function fi(t, e, l, a, n, u) {
    var i = 0;
    if (a = t, typeof t == "function") Cf(t) && (i = 1);
    else if (typeof t == "string")
      i = jh(
        t,
        l,
        q.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case ee:
          return t = Re(31, l, e, n), t.elementType = ee, t.lanes = u, t;
        case It:
          return Na(l.children, n, u, e);
        case At:
          i = 8, n |= 24;
          break;
        case ae:
          return t = Re(12, l, e, n | 2), t.elementType = ae, t.lanes = u, t;
        case Ft:
          return t = Re(13, l, e, n), t.elementType = Ft, t.lanes = u, t;
        case te:
          return t = Re(19, l, e, n), t.elementType = te, t.lanes = u, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case Ht:
                i = 10;
                break t;
              case pe:
                i = 9;
                break t;
              case Pt:
                i = 11;
                break t;
              case F:
                i = 14;
                break t;
              case ne:
                i = 16, a = null;
                break t;
            }
          i = 29, l = Error(
            p(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = Re(i, l, e, n), e.elementType = t, e.type = a, e.lanes = u, e;
  }
  function Na(t, e, l, a) {
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
  function Ve(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = Wo.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Lu(e)
      }, Wo.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Lu(e)
    };
  }
  var dn = [], mn = 0, ci = null, iu = 0, Ze = [], Ke = 0, Jl = null, dl = 1, ml = "";
  function Dl(t, e) {
    dn[mn++] = iu, dn[mn++] = ci, ci = t, iu = e;
  }
  function $o(t, e, l) {
    Ze[Ke++] = dl, Ze[Ke++] = ml, Ze[Ke++] = Jl, Jl = t;
    var a = dl;
    t = ml;
    var n = 32 - Se(a) - 1;
    a &= ~(1 << n), l += 1;
    var u = 32 - Se(e) + n;
    if (30 < u) {
      var i = n - n % 5;
      u = (a & (1 << i) - 1).toString(32), a >>= i, n -= i, dl = 1 << 32 - Se(e) + n | l << n | a, ml = u + t;
    } else
      dl = 1 << u | l << n | a, ml = t;
  }
  function Nf(t) {
    t.return !== null && (Dl(t, 1), $o(t, 1, 0));
  }
  function Hf(t) {
    for (; t === ci; )
      ci = dn[--mn], dn[mn] = null, iu = dn[--mn], dn[mn] = null;
    for (; t === Jl; )
      Jl = Ze[--Ke], Ze[Ke] = null, ml = Ze[--Ke], Ze[Ke] = null, dl = Ze[--Ke], Ze[Ke] = null;
  }
  function Io(t, e) {
    Ze[Ke++] = dl, Ze[Ke++] = ml, Ze[Ke++] = Jl, dl = e.id, ml = e.overflow, Jl = t;
  }
  var oe = null, Ot = null, ot = !1, kl = null, Je = !1, qf = Error(p(519));
  function Fl(t) {
    var e = Error(
      p(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw fu(Ve(e, t)), qf;
  }
  function Po(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[Wt] = t, e[fe] = a, l) {
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
        for (l = 0; l < Ou.length; l++)
          ut(Ou[l], e);
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
        ut("invalid", e), $u(
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
        ut("invalid", e), g(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || gd(e.textContent, l) ? (a.popover != null && (ut("beforetoggle", e), ut("toggle", e)), a.onScroll != null && ut("scroll", e), a.onScrollEnd != null && ut("scrollend", e), a.onClick != null && (e.onclick = tl), e = !0) : e = !1, e || Fl(t, !0);
  }
  function ts(t) {
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
  function hn(t) {
    if (t !== oe) return !1;
    if (!ot) return ts(t), ot = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || to(t.type, t.memoizedProps)), l = !l), l && Ot && Fl(t), ts(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(p(317));
      Ot = Ed(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(p(317));
      Ot = Ed(t);
    } else
      e === 27 ? (e = Ot, oa(t.type) ? (t = uo, uo = null, Ot = t) : Ot = e) : Ot = oe ? Fe(t.stateNode.nextSibling) : null;
    return !0;
  }
  function Ha() {
    Ot = oe = null, ot = !1;
  }
  function jf() {
    var t = kl;
    return t !== null && (_e === null ? _e = t : _e.push.apply(
      _e,
      t
    ), kl = null), t;
  }
  function fu(t) {
    kl === null ? kl = [t] : kl.push(t);
  }
  var wf = d(null), qa = null, Ol = null;
  function Wl(t, e, l) {
    C(wf, e._currentValue), e._currentValue = l;
  }
  function Ul(t) {
    t._currentValue = wf.current, z(wf);
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
          for (var o = 0; o < e.length; o++)
            if (f.context === e[o]) {
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
        if (i = n.return, i === null) throw Error(p(341));
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
  function yn(t, e, l, a) {
    t = null;
    for (var n = e, u = !1; n !== null; ) {
      if (!u) {
        if ((n.flags & 524288) !== 0) u = !0;
        else if ((n.flags & 262144) !== 0) break;
      }
      if (n.tag === 10) {
        var i = n.alternate;
        if (i === null) throw Error(p(387));
        if (i = i.memoizedProps, i !== null) {
          var f = n.type;
          Be(n.pendingProps.value, i.value) || (t !== null ? t.push(f) : t = [f]);
        }
      } else if (n === rt.current) {
        if (i = n.alternate, i === null) throw Error(p(387));
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
  function oi(t) {
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
  function ja(t) {
    qa = t, Ol = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function se(t) {
    return es(qa, t);
  }
  function si(t, e) {
    return qa === null && ja(t), es(t, e);
  }
  function es(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Ol === null) {
      if (t === null) throw Error(p(308));
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
  }, Nm = _.unstable_scheduleCallback, Hm = _.unstable_NormalPriority, Vt = {
    $$typeof: Ht,
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
  function cu(t) {
    t.refCount--, t.refCount === 0 && Nm(Hm, function() {
      t.controller.abort();
    });
  }
  var ou = null, Xf = 0, gn = 0, vn = null;
  function qm(t, e) {
    if (ou === null) {
      var l = ou = [];
      Xf = 0, gn = Zc(), vn = {
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
      vn !== null && (vn.status = "fulfilled");
      var t = ou;
      ou = null, gn = 0, vn = null;
      for (var e = 0; e < t.length; e++) (0, t[e])();
    }
  }
  function jm(t, e) {
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
  var as = b.S;
  b.S = function(t, e) {
    Gr = he(), typeof e == "object" && e !== null && typeof e.then == "function" && qm(t, e), as !== null && as(t, e);
  };
  var wa = d(null);
  function Qf() {
    var t = wa.current;
    return t !== null ? t : Et.pooledCache;
  }
  function ri(t, e) {
    e === null ? C(wa, wa.current) : C(wa, e.pool);
  }
  function ns() {
    var t = Qf();
    return t === null ? null : { parent: Vt._currentValue, pool: t };
  }
  var pn = Error(p(460)), Vf = Error(p(474)), di = Error(p(542)), mi = { then: function() {
  } };
  function us(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function is(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(tl, tl), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, cs(t), t;
      default:
        if (typeof e.status == "string") e.then(tl, tl);
        else {
          if (t = Et, t !== null && 100 < t.shellSuspendCounter)
            throw Error(p(482));
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
        throw Ga = e, pn;
    }
  }
  function Ya(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (Ga = l, pn) : l;
    }
  }
  var Ga = null;
  function fs() {
    if (Ga === null) throw Error(p(459));
    var t = Ga;
    return Ga = null, t;
  }
  function cs(t) {
    if (t === pn || t === di)
      throw Error(p(483));
  }
  var bn = null, su = 0;
  function hi(t) {
    var e = su;
    return su += 1, bn === null && (bn = []), is(bn, t, e);
  }
  function ru(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function yi(t, e) {
    throw e.$$typeof === gt ? Error(p(525)) : (t = Object.prototype.toString.call(e), Error(
      p(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function os(t) {
    function e(m, r) {
      if (t) {
        var h = m.deletions;
        h === null ? (m.deletions = [r], m.flags |= 16) : h.push(r);
      }
    }
    function l(m, r) {
      if (!t) return null;
      for (; r !== null; )
        e(m, r), r = r.sibling;
      return null;
    }
    function a(m) {
      for (var r = /* @__PURE__ */ new Map(); m !== null; )
        m.key !== null ? r.set(m.key, m) : r.set(m.index, m), m = m.sibling;
      return r;
    }
    function n(m, r) {
      return m = _l(m, r), m.index = 0, m.sibling = null, m;
    }
    function u(m, r, h) {
      return m.index = h, t ? (h = m.alternate, h !== null ? (h = h.index, h < r ? (m.flags |= 67108866, r) : h) : (m.flags |= 67108866, r)) : (m.flags |= 1048576, r);
    }
    function i(m) {
      return t && m.alternate === null && (m.flags |= 67108866), m;
    }
    function f(m, r, h, T) {
      return r === null || r.tag !== 6 ? (r = Bf(h, m.mode, T), r.return = m, r) : (r = n(r, h), r.return = m, r);
    }
    function o(m, r, h, T) {
      var X = h.type;
      return X === It ? x(
        m,
        r,
        h.props.children,
        T,
        h.key
      ) : r !== null && (r.elementType === X || typeof X == "object" && X !== null && X.$$typeof === ne && Ya(X) === r.type) ? (r = n(r, h.props), ru(r, h), r.return = m, r) : (r = fi(
        h.type,
        h.key,
        h.props,
        null,
        m.mode,
        T
      ), ru(r, h), r.return = m, r);
    }
    function y(m, r, h, T) {
      return r === null || r.tag !== 4 || r.stateNode.containerInfo !== h.containerInfo || r.stateNode.implementation !== h.implementation ? (r = Rf(h, m.mode, T), r.return = m, r) : (r = n(r, h.children || []), r.return = m, r);
    }
    function x(m, r, h, T, X) {
      return r === null || r.tag !== 7 ? (r = Na(
        h,
        m.mode,
        T,
        X
      ), r.return = m, r) : (r = n(r, h), r.return = m, r);
    }
    function E(m, r, h) {
      if (typeof r == "string" && r !== "" || typeof r == "number" || typeof r == "bigint")
        return r = Bf(
          "" + r,
          m.mode,
          h
        ), r.return = m, r;
      if (typeof r == "object" && r !== null) {
        switch (r.$$typeof) {
          case ve:
            return h = fi(
              r.type,
              r.key,
              r.props,
              null,
              m.mode,
              h
            ), ru(h, r), h.return = m, h;
          case me:
            return r = Rf(
              r,
              m.mode,
              h
            ), r.return = m, r;
          case ne:
            return r = Ya(r), E(m, r, h);
        }
        if (N(r) || ue(r))
          return r = Na(
            r,
            m.mode,
            h,
            null
          ), r.return = m, r;
        if (typeof r.then == "function")
          return E(m, hi(r), h);
        if (r.$$typeof === Ht)
          return E(
            m,
            si(m, r),
            h
          );
        yi(m, r);
      }
      return null;
    }
    function v(m, r, h, T) {
      var X = r !== null ? r.key : null;
      if (typeof h == "string" && h !== "" || typeof h == "number" || typeof h == "bigint")
        return X !== null ? null : f(m, r, "" + h, T);
      if (typeof h == "object" && h !== null) {
        switch (h.$$typeof) {
          case ve:
            return h.key === X ? o(m, r, h, T) : null;
          case me:
            return h.key === X ? y(m, r, h, T) : null;
          case ne:
            return h = Ya(h), v(m, r, h, T);
        }
        if (N(h) || ue(h))
          return X !== null ? null : x(m, r, h, T, null);
        if (typeof h.then == "function")
          return v(
            m,
            r,
            hi(h),
            T
          );
        if (h.$$typeof === Ht)
          return v(
            m,
            r,
            si(m, h),
            T
          );
        yi(m, h);
      }
      return null;
    }
    function S(m, r, h, T, X) {
      if (typeof T == "string" && T !== "" || typeof T == "number" || typeof T == "bigint")
        return m = m.get(h) || null, f(r, m, "" + T, X);
      if (typeof T == "object" && T !== null) {
        switch (T.$$typeof) {
          case ve:
            return m = m.get(
              T.key === null ? h : T.key
            ) || null, o(r, m, T, X);
          case me:
            return m = m.get(
              T.key === null ? h : T.key
            ) || null, y(r, m, T, X);
          case ne:
            return T = Ya(T), S(
              m,
              r,
              h,
              T,
              X
            );
        }
        if (N(T) || ue(T))
          return m = m.get(h) || null, x(r, m, T, X, null);
        if (typeof T.then == "function")
          return S(
            m,
            r,
            h,
            hi(T),
            X
          );
        if (T.$$typeof === Ht)
          return S(
            m,
            r,
            h,
            si(r, T),
            X
          );
        yi(r, T);
      }
      return null;
    }
    function w(m, r, h, T) {
      for (var X = null, ht = null, Y = r, et = r = 0, ft = null; Y !== null && et < h.length; et++) {
        Y.index > et ? (ft = Y, Y = null) : ft = Y.sibling;
        var yt = v(
          m,
          Y,
          h[et],
          T
        );
        if (yt === null) {
          Y === null && (Y = ft);
          break;
        }
        t && Y && yt.alternate === null && e(m, Y), r = u(yt, r, et), ht === null ? X = yt : ht.sibling = yt, ht = yt, Y = ft;
      }
      if (et === h.length)
        return l(m, Y), ot && Dl(m, et), X;
      if (Y === null) {
        for (; et < h.length; et++)
          Y = E(m, h[et], T), Y !== null && (r = u(
            Y,
            r,
            et
          ), ht === null ? X = Y : ht.sibling = Y, ht = Y);
        return ot && Dl(m, et), X;
      }
      for (Y = a(Y); et < h.length; et++)
        ft = S(
          Y,
          m,
          et,
          h[et],
          T
        ), ft !== null && (t && ft.alternate !== null && Y.delete(
          ft.key === null ? et : ft.key
        ), r = u(
          ft,
          r,
          et
        ), ht === null ? X = ft : ht.sibling = ft, ht = ft);
      return t && Y.forEach(function(ha) {
        return e(m, ha);
      }), ot && Dl(m, et), X;
    }
    function Q(m, r, h, T) {
      if (h == null) throw Error(p(151));
      for (var X = null, ht = null, Y = r, et = r = 0, ft = null, yt = h.next(); Y !== null && !yt.done; et++, yt = h.next()) {
        Y.index > et ? (ft = Y, Y = null) : ft = Y.sibling;
        var ha = v(m, Y, yt.value, T);
        if (ha === null) {
          Y === null && (Y = ft);
          break;
        }
        t && Y && ha.alternate === null && e(m, Y), r = u(ha, r, et), ht === null ? X = ha : ht.sibling = ha, ht = ha, Y = ft;
      }
      if (yt.done)
        return l(m, Y), ot && Dl(m, et), X;
      if (Y === null) {
        for (; !yt.done; et++, yt = h.next())
          yt = E(m, yt.value, T), yt !== null && (r = u(yt, r, et), ht === null ? X = yt : ht.sibling = yt, ht = yt);
        return ot && Dl(m, et), X;
      }
      for (Y = a(Y); !yt.done; et++, yt = h.next())
        yt = S(Y, m, et, yt.value, T), yt !== null && (t && yt.alternate !== null && Y.delete(yt.key === null ? et : yt.key), r = u(yt, r, et), ht === null ? X = yt : ht.sibling = yt, ht = yt);
      return t && Y.forEach(function(kh) {
        return e(m, kh);
      }), ot && Dl(m, et), X;
    }
    function Mt(m, r, h, T) {
      if (typeof h == "object" && h !== null && h.type === It && h.key === null && (h = h.props.children), typeof h == "object" && h !== null) {
        switch (h.$$typeof) {
          case ve:
            t: {
              for (var X = h.key; r !== null; ) {
                if (r.key === X) {
                  if (X = h.type, X === It) {
                    if (r.tag === 7) {
                      l(
                        m,
                        r.sibling
                      ), T = n(
                        r,
                        h.props.children
                      ), T.return = m, m = T;
                      break t;
                    }
                  } else if (r.elementType === X || typeof X == "object" && X !== null && X.$$typeof === ne && Ya(X) === r.type) {
                    l(
                      m,
                      r.sibling
                    ), T = n(r, h.props), ru(T, h), T.return = m, m = T;
                    break t;
                  }
                  l(m, r);
                  break;
                } else e(m, r);
                r = r.sibling;
              }
              h.type === It ? (T = Na(
                h.props.children,
                m.mode,
                T,
                h.key
              ), T.return = m, m = T) : (T = fi(
                h.type,
                h.key,
                h.props,
                null,
                m.mode,
                T
              ), ru(T, h), T.return = m, m = T);
            }
            return i(m);
          case me:
            t: {
              for (X = h.key; r !== null; ) {
                if (r.key === X)
                  if (r.tag === 4 && r.stateNode.containerInfo === h.containerInfo && r.stateNode.implementation === h.implementation) {
                    l(
                      m,
                      r.sibling
                    ), T = n(r, h.children || []), T.return = m, m = T;
                    break t;
                  } else {
                    l(m, r);
                    break;
                  }
                else e(m, r);
                r = r.sibling;
              }
              T = Rf(h, m.mode, T), T.return = m, m = T;
            }
            return i(m);
          case ne:
            return h = Ya(h), Mt(
              m,
              r,
              h,
              T
            );
        }
        if (N(h))
          return w(
            m,
            r,
            h,
            T
          );
        if (ue(h)) {
          if (X = ue(h), typeof X != "function") throw Error(p(150));
          return h = X.call(h), Q(
            m,
            r,
            h,
            T
          );
        }
        if (typeof h.then == "function")
          return Mt(
            m,
            r,
            hi(h),
            T
          );
        if (h.$$typeof === Ht)
          return Mt(
            m,
            r,
            si(m, h),
            T
          );
        yi(m, h);
      }
      return typeof h == "string" && h !== "" || typeof h == "number" || typeof h == "bigint" ? (h = "" + h, r !== null && r.tag === 6 ? (l(m, r.sibling), T = n(r, h), T.return = m, m = T) : (l(m, r), T = Bf(h, m.mode, T), T.return = m, m = T), i(m)) : l(m, r);
    }
    return function(m, r, h, T) {
      try {
        su = 0;
        var X = Mt(
          m,
          r,
          h,
          T
        );
        return bn = null, X;
      } catch (Y) {
        if (Y === pn || Y === di) throw Y;
        var ht = Re(29, Y, null, m.mode);
        return ht.lanes = T, ht.return = m, ht;
      }
    };
  }
  var La = os(!0), ss = os(!1), $l = !1;
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
  function Il(t) {
    return { lane: t, tag: 0, payload: null, callback: null, next: null };
  }
  function Pl(t, e, l) {
    var a = t.updateQueue;
    if (a === null) return null;
    if (a = a.shared, (pt & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = ii(t), Jo(t, null, l), e;
    }
    return ui(t, a, e, l), ii(t);
  }
  function du(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Ku(t, l);
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
      var t = vn;
      if (t !== null) throw t;
    }
  }
  function hu(t, e, l, a) {
    kf = !1;
    var n = t.updateQueue;
    $l = !1;
    var u = n.firstBaseUpdate, i = n.lastBaseUpdate, f = n.shared.pending;
    if (f !== null) {
      n.shared.pending = null;
      var o = f, y = o.next;
      o.next = null, i === null ? u = y : i.next = y, i = o;
      var x = t.alternate;
      x !== null && (x = x.updateQueue, f = x.lastBaseUpdate, f !== i && (f === null ? x.firstBaseUpdate = y : f.next = y, x.lastBaseUpdate = o));
    }
    if (u !== null) {
      var E = n.baseState;
      i = 0, x = y = o = null, f = u;
      do {
        var v = f.lane & -536870913, S = v !== f.lane;
        if (S ? (it & v) === v : (a & v) === v) {
          v !== 0 && v === gn && (kf = !0), x !== null && (x = x.next = {
            lane: 0,
            tag: f.tag,
            payload: f.payload,
            callback: null,
            next: null
          });
          t: {
            var w = t, Q = f;
            v = e;
            var Mt = l;
            switch (Q.tag) {
              case 1:
                if (w = Q.payload, typeof w == "function") {
                  E = w.call(Mt, E, v);
                  break t;
                }
                E = w;
                break t;
              case 3:
                w.flags = w.flags & -65537 | 128;
              case 0:
                if (w = Q.payload, v = typeof w == "function" ? w.call(Mt, E, v) : w, v == null) break t;
                E = V({}, E, v);
                break t;
              case 2:
                $l = !0;
            }
          }
          v = f.callback, v !== null && (t.flags |= 64, S && (t.flags |= 8192), S = n.callbacks, S === null ? n.callbacks = [v] : S.push(v));
        } else
          S = {
            lane: v,
            tag: f.tag,
            payload: f.payload,
            callback: f.callback,
            next: null
          }, x === null ? (y = x = S, o = E) : x = x.next = S, i |= v;
        if (f = f.next, f === null) {
          if (f = n.shared.pending, f === null)
            break;
          S = f, f = S.next, S.next = null, n.lastBaseUpdate = S, n.shared.pending = null;
        }
      } while (!0);
      x === null && (o = E), n.baseState = o, n.firstBaseUpdate = y, n.lastBaseUpdate = x, u === null && (n.shared.lanes = 0), na |= i, t.lanes = i, t.memoizedState = E;
    }
  }
  function rs(t, e) {
    if (typeof t != "function")
      throw Error(p(191, t));
    t.call(e);
  }
  function ds(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        rs(l[t], e);
  }
  var Sn = d(null), gi = d(0);
  function ms(t, e) {
    t = Yl, C(gi, t), C(Sn, e), Yl = t | e.baseLanes;
  }
  function Ff() {
    C(gi, Yl), C(Sn, Sn.current);
  }
  function Wf() {
    Yl = gi.current, z(Sn), z(gi);
  }
  var Ne = d(null), ke = null;
  function ta(t) {
    var e = t.alternate;
    C(Xt, Xt.current & 1), C(Ne, t), ke === null && (e === null || Sn.current !== null || e.memoizedState !== null) && (ke = t);
  }
  function $f(t) {
    C(Xt, Xt.current), C(Ne, t), ke === null && (ke = t);
  }
  function hs(t) {
    t.tag === 22 ? (C(Xt, Xt.current), C(Ne, t), ke === null && (ke = t)) : ea();
  }
  function ea() {
    C(Xt, Xt.current), C(Ne, Ne.current);
  }
  function He(t) {
    z(Ne), ke === t && (ke = null), z(Xt);
  }
  var Xt = d(0);
  function vi(t) {
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
  var Cl = 0, P = null, Tt = null, Zt = null, pi = !1, xn = !1, Xa = !1, bi = 0, yu = 0, Tn = null, wm = 0;
  function Yt() {
    throw Error(p(321));
  }
  function If(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!Be(t[l], e[l])) return !1;
    return !0;
  }
  function Pf(t, e, l, a, n, u) {
    return Cl = u, P = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, b.H = t === null || t.memoizedState === null ? $s : hc, Xa = !1, u = l(a, n), Xa = !1, xn && (u = gs(
      e,
      l,
      a,
      n
    )), ys(t), u;
  }
  function ys(t) {
    b.H = pu;
    var e = Tt !== null && Tt.next !== null;
    if (Cl = 0, Zt = Tt = P = null, pi = !1, yu = 0, Tn = null, e) throw Error(p(300));
    t === null || Kt || (t = t.dependencies, t !== null && oi(t) && (Kt = !0));
  }
  function gs(t, e, l, a) {
    P = t;
    var n = 0;
    do {
      if (xn && (Tn = null), yu = 0, xn = !1, 25 <= n) throw Error(p(301));
      if (n += 1, Zt = Tt = null, t.updateQueue != null) {
        var u = t.updateQueue;
        u.lastEffect = null, u.events = null, u.stores = null, u.memoCache != null && (u.memoCache.index = 0);
      }
      b.H = Is, u = e(l, a);
    } while (xn);
    return u;
  }
  function Ym() {
    var t = b.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? gu(e) : e, t = t.useState()[0], (Tt !== null ? Tt.memoizedState : null) !== t && (P.flags |= 1024), e;
  }
  function tc() {
    var t = bi !== 0;
    return bi = 0, t;
  }
  function ec(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function lc(t) {
    if (pi) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      pi = !1;
    }
    Cl = 0, Zt = Tt = P = null, xn = !1, yu = bi = 0, Tn = null;
  }
  function Te() {
    var t = {
      memoizedState: null,
      baseState: null,
      baseQueue: null,
      queue: null,
      next: null
    };
    return Zt === null ? P.memoizedState = Zt = t : Zt = Zt.next = t, Zt;
  }
  function Qt() {
    if (Tt === null) {
      var t = P.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = Tt.next;
    var e = Zt === null ? P.memoizedState : Zt.next;
    if (e !== null)
      Zt = e, Tt = t;
    else {
      if (t === null)
        throw P.alternate === null ? Error(p(467)) : Error(p(310));
      Tt = t, t = {
        memoizedState: Tt.memoizedState,
        baseState: Tt.baseState,
        baseQueue: Tt.baseQueue,
        queue: Tt.queue,
        next: null
      }, Zt === null ? P.memoizedState = Zt = t : Zt = Zt.next = t;
    }
    return Zt;
  }
  function Si() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function gu(t) {
    var e = yu;
    return yu += 1, Tn === null && (Tn = []), t = is(Tn, t, e), e = P, (Zt === null ? e.memoizedState : Zt.next) === null && (e = e.alternate, b.H = e === null || e.memoizedState === null ? $s : hc), t;
  }
  function xi(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return gu(t);
      if (t.$$typeof === Ht) return se(t);
    }
    throw Error(p(438, String(t)));
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
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = Si(), P.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = Ye;
    return e.index++, l;
  }
  function Bl(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function Ti(t) {
    var e = Qt();
    return nc(e, Tt, t);
  }
  function nc(t, e, l) {
    var a = t.queue;
    if (a === null) throw Error(p(311));
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
      var f = i = null, o = null, y = e, x = !1;
      do {
        var E = y.lane & -536870913;
        if (E !== y.lane ? (it & E) === E : (Cl & E) === E) {
          var v = y.revertLane;
          if (v === 0)
            o !== null && (o = o.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: y.action,
              hasEagerState: y.hasEagerState,
              eagerState: y.eagerState,
              next: null
            }), E === gn && (x = !0);
          else if ((Cl & v) === v) {
            y = y.next, v === gn && (x = !0);
            continue;
          } else
            E = {
              lane: 0,
              revertLane: y.revertLane,
              gesture: null,
              action: y.action,
              hasEagerState: y.hasEagerState,
              eagerState: y.eagerState,
              next: null
            }, o === null ? (f = o = E, i = u) : o = o.next = E, P.lanes |= v, na |= v;
          E = y.action, Xa && l(u, E), u = y.hasEagerState ? y.eagerState : l(u, E);
        } else
          v = {
            lane: E,
            revertLane: y.revertLane,
            gesture: y.gesture,
            action: y.action,
            hasEagerState: y.hasEagerState,
            eagerState: y.eagerState,
            next: null
          }, o === null ? (f = o = v, i = u) : o = o.next = v, P.lanes |= E, na |= E;
        y = y.next;
      } while (y !== null && y !== e);
      if (o === null ? i = u : o.next = f, !Be(u, t.memoizedState) && (Kt = !0, x && (l = vn, l !== null)))
        throw l;
      t.memoizedState = u, t.baseState = i, t.baseQueue = o, a.lastRenderedState = u;
    }
    return n === null && (a.lanes = 0), [t.memoizedState, a.dispatch];
  }
  function uc(t) {
    var e = Qt(), l = e.queue;
    if (l === null) throw Error(p(311));
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
    var a = P, n = Qt(), u = ot;
    if (u) {
      if (l === void 0) throw Error(p(407));
      l = l();
    } else l = e();
    var i = !Be(
      (Tt || n).memoizedState,
      l
    );
    if (i && (n.memoizedState = l, Kt = !0), n = n.queue, cc(Ss.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || i || Zt !== null && Zt.memoizedState.tag & 1) {
      if (a.flags |= 2048, zn(
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
      ), Et === null) throw Error(p(349));
      u || (Cl & 127) !== 0 || ps(a, e, l);
    }
    return l;
  }
  function ps(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = P.updateQueue, e === null ? (e = Si(), P.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
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
    var e = Ra(t, 2);
    e !== null && De(e, t, 2);
  }
  function ic(t) {
    var e = Te();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Xa) {
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
      lastRenderedReducer: Bl,
      lastRenderedState: t
    }, e;
  }
  function zs(t, e, l, a) {
    return t.baseState = l, nc(
      t,
      Tt,
      typeof a == "function" ? a : Bl
    );
  }
  function Gm(t, e, l, a, n) {
    if (Ei(t)) throw Error(p(485));
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
      b.T !== null ? l(!0) : u.isTransition = !1, a(u), l = e.pending, l === null ? (u.next = e.pending = u, Ms(e, u)) : (u.next = l.next, e.pending = l.next = u);
    }
  }
  function Ms(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var u = b.T, i = {};
      b.T = i;
      try {
        var f = l(n, a), o = b.S;
        o !== null && o(i, f), Es(t, e, f);
      } catch (y) {
        fc(t, e, y);
      } finally {
        u !== null && i.types !== null && (u.types = i.types), b.T = u;
      }
    } else
      try {
        u = l(n, a), Es(t, e, u);
      } catch (y) {
        fc(t, e, y);
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
    if (ot) {
      var l = Et.formState;
      if (l !== null) {
        t: {
          var a = P;
          if (ot) {
            if (Ot) {
              e: {
                for (var n = Ot, u = Je; n.nodeType !== 8; ) {
                  if (!u) {
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
                u = n.data, n = u === "F!" || u === "F" ? n : null;
              }
              if (n) {
                Ot = Fe(
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
    return l = Te(), l.memoizedState = l.baseState = e, a = {
      pending: null,
      lanes: 0,
      dispatch: null,
      lastRenderedReducer: Ds,
      lastRenderedState: e
    }, l.queue = a, l = ks.bind(
      null,
      P,
      a
    ), a.dispatch = l, a = ic(!1), u = mc.bind(
      null,
      P,
      !1,
      a.queue
    ), a = Te(), n = {
      state: e,
      dispatch: null,
      action: t,
      pending: null
    }, a.queue = n, l = Gm.bind(
      null,
      P,
      n,
      u,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Us(t) {
    var e = Qt();
    return Cs(e, Tt, t);
  }
  function Cs(t, e, l) {
    if (e = nc(
      t,
      e,
      Ds
    )[0], t = Ti(Bl)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = gu(e);
      } catch (i) {
        throw i === pn ? di : i;
      }
    else a = e;
    e = Qt();
    var n = e.queue, u = n.dispatch;
    return l !== e.memoizedState && (P.flags |= 2048, zn(
      9,
      { destroy: void 0 },
      Lm.bind(null, n, l),
      null
    )), [a, u, t];
  }
  function Lm(t, e) {
    t.action = e;
  }
  function Bs(t) {
    var e = Qt(), l = Tt;
    if (l !== null)
      return Cs(e, l, t);
    Qt(), e = e.memoizedState, l = Qt();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function zn(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = P.updateQueue, e === null && (e = Si(), P.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function Rs() {
    return Qt().memoizedState;
  }
  function zi(t, e, l, a) {
    var n = Te();
    P.flags |= t, n.memoizedState = zn(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Mi(t, e, l, a) {
    var n = Qt();
    a = a === void 0 ? null : a;
    var u = n.memoizedState.inst;
    Tt !== null && a !== null && If(a, Tt.memoizedState.deps) ? n.memoizedState = zn(e, u, l, a) : (P.flags |= t, n.memoizedState = zn(
      1 | e,
      u,
      l,
      a
    ));
  }
  function Ns(t, e) {
    zi(8390656, 8, t, e);
  }
  function cc(t, e) {
    Mi(2048, 8, t, e);
  }
  function Xm(t) {
    P.flags |= 4;
    var e = P.updateQueue;
    if (e === null)
      e = Si(), P.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function Hs(t) {
    var e = Qt().memoizedState;
    return Xm({ ref: e, nextImpl: t }), function() {
      if ((pt & 2) !== 0) throw Error(p(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function qs(t, e) {
    return Mi(4, 2, t, e);
  }
  function js(t, e) {
    return Mi(4, 4, t, e);
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
    l = l != null ? l.concat([t]) : null, Mi(4, 4, ws.bind(null, e, t), l);
  }
  function oc() {
  }
  function Gs(t, e) {
    var l = Qt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && If(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Ls(t, e) {
    var l = Qt();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && If(e, a[1]))
      return a[0];
    if (a = t(), Xa) {
      fl(!0);
      try {
        t();
      } finally {
        fl(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function sc(t, e, l) {
    return l === void 0 || (Cl & 1073741824) !== 0 && (it & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Xr(), P.lanes |= t, na |= t, l);
  }
  function Xs(t, e, l, a) {
    return Be(l, e) ? l : Sn.current !== null ? (t = sc(t, l, a), Be(t, e) || (Kt = !0), t) : (Cl & 42) === 0 || (Cl & 1073741824) !== 0 && (it & 261930) === 0 ? (Kt = !0, t.memoizedState = l) : (t = Xr(), P.lanes |= t, na |= t, e);
  }
  function Qs(t, e, l, a, n) {
    var u = U.p;
    U.p = u !== 0 && 8 > u ? u : 8;
    var i = b.T, f = {};
    b.T = f, mc(t, !1, e, l);
    try {
      var o = n(), y = b.S;
      if (y !== null && y(f, o), o !== null && typeof o == "object" && typeof o.then == "function") {
        var x = jm(
          o,
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
      U.p = u, i !== null && f.types !== null && (i.types = f.types), b.T = i;
    }
  }
  function Qm() {
  }
  function rc(t, e, l, a) {
    if (t.tag !== 5) throw Error(p(476));
    var n = Vs(t).queue;
    Qs(
      t,
      n,
      e,
      B,
      l === null ? Qm : function() {
        return Zs(t), l(a);
      }
    );
  }
  function Vs(t) {
    var e = t.memoizedState;
    if (e !== null) return e;
    e = {
      memoizedState: B,
      baseState: B,
      baseQueue: null,
      queue: {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: Bl,
        lastRenderedState: B
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
    return se(Nu);
  }
  function Ks() {
    return Qt().memoizedState;
  }
  function Js() {
    return Qt().memoizedState;
  }
  function Vm(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = we();
          t = Il(l);
          var a = Pl(e, t, l);
          a !== null && (De(a, e, l), du(a, e, l)), e = { cache: Lf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function Zm(t, e, l) {
    var a = we();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Ei(t) ? Fs(e, l) : (l = Uf(t, e, l, a), l !== null && (De(l, t, a), Ws(l, e, a)));
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
    if (Ei(t)) Fs(e, n);
    else {
      var u = t.alternate;
      if (t.lanes === 0 && (u === null || u.lanes === 0) && (u = e.lastRenderedReducer, u !== null))
        try {
          var i = e.lastRenderedState, f = u(i, l);
          if (n.hasEagerState = !0, n.eagerState = f, Be(f, i))
            return ui(t, e, n, 0), Et === null && ni(), !1;
        } catch {
        }
      if (l = Uf(t, e, n, a), l !== null)
        return De(l, t, a), Ws(l, e, a), !0;
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
    }, Ei(t)) {
      if (e) throw Error(p(479));
    } else
      e = Uf(
        t,
        l,
        a,
        2
      ), e !== null && De(e, t, 2);
  }
  function Ei(t) {
    var e = t.alternate;
    return t === P || e !== null && e === P;
  }
  function Fs(t, e) {
    xn = pi = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function Ws(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, Ku(t, l);
    }
  }
  var pu = {
    readContext: se,
    use: xi,
    useCallback: Yt,
    useContext: Yt,
    useEffect: Yt,
    useImperativeHandle: Yt,
    useLayoutEffect: Yt,
    useInsertionEffect: Yt,
    useMemo: Yt,
    useReducer: Yt,
    useRef: Yt,
    useState: Yt,
    useDebugValue: Yt,
    useDeferredValue: Yt,
    useTransition: Yt,
    useSyncExternalStore: Yt,
    useId: Yt,
    useHostTransitionStatus: Yt,
    useFormState: Yt,
    useActionState: Yt,
    useOptimistic: Yt,
    useMemoCache: Yt,
    useCacheRefresh: Yt
  };
  pu.useEffectEvent = Yt;
  var $s = {
    readContext: se,
    use: xi,
    useCallback: function(t, e) {
      return Te().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: se,
    useEffect: Ns,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, zi(
        4194308,
        4,
        ws.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return zi(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      zi(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = Te();
      e = e === void 0 ? null : e;
      var a = t();
      if (Xa) {
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
      var a = Te();
      if (l !== void 0) {
        var n = l(e);
        if (Xa) {
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
      }, a.queue = t, t = t.dispatch = Zm.bind(
        null,
        P,
        t
      ), [a.memoizedState, t];
    },
    useRef: function(t) {
      var e = Te();
      return t = { current: t }, e.memoizedState = t;
    },
    useState: function(t) {
      t = ic(t);
      var e = t.queue, l = ks.bind(null, P, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Te();
      return sc(l, t, e);
    },
    useTransition: function() {
      var t = ic(!1);
      return t = Qs.bind(
        null,
        P,
        t.queue,
        !0,
        !1
      ), Te().memoizedState = t, [!1, t];
    },
    useSyncExternalStore: function(t, e, l) {
      var a = P, n = Te();
      if (ot) {
        if (l === void 0)
          throw Error(p(407));
        l = l();
      } else {
        if (l = e(), Et === null)
          throw Error(p(349));
        (it & 127) !== 0 || ps(a, e, l);
      }
      n.memoizedState = l;
      var u = { value: l, getSnapshot: e };
      return n.queue = u, Ns(Ss.bind(null, a, u, t), [
        t
      ]), a.flags |= 2048, zn(
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
      var t = Te(), e = Et.identifierPrefix;
      if (ot) {
        var l = ml, a = dl;
        l = (a & ~(1 << 32 - Se(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = bi++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = wm++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: dc,
    useFormState: Os,
    useActionState: Os,
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
      return e.queue = l, e = mc.bind(
        null,
        P,
        !0,
        l
      ), l.dispatch = e, [t, e];
    },
    useMemoCache: ac,
    useCacheRefresh: function() {
      return Te().memoizedState = Vm.bind(
        null,
        P
      );
    },
    useEffectEvent: function(t) {
      var e = Te(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((pt & 2) !== 0)
          throw Error(p(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, hc = {
    readContext: se,
    use: xi,
    useCallback: Gs,
    useContext: se,
    useEffect: cc,
    useImperativeHandle: Ys,
    useInsertionEffect: qs,
    useLayoutEffect: js,
    useMemo: Ls,
    useReducer: Ti,
    useRef: Rs,
    useState: function() {
      return Ti(Bl);
    },
    useDebugValue: oc,
    useDeferredValue: function(t, e) {
      var l = Qt();
      return Xs(
        l,
        Tt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = Ti(Bl)[0], e = Qt().memoizedState;
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
      var l = Qt();
      return zs(l, Tt, t, e);
    },
    useMemoCache: ac,
    useCacheRefresh: Js
  };
  hc.useEffectEvent = Hs;
  var Is = {
    readContext: se,
    use: xi,
    useCallback: Gs,
    useContext: se,
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
      var l = Qt();
      return Tt === null ? sc(l, t, e) : Xs(
        l,
        Tt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = uc(Bl)[0], e = Qt().memoizedState;
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
      var l = Qt();
      return Tt !== null ? zs(l, Tt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ac,
    useCacheRefresh: Js
  };
  Is.useEffectEvent = Hs;
  function yc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : V({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var gc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = we(), n = Il(a);
      n.payload = e, l != null && (n.callback = l), e = Pl(t, n, a), e !== null && (De(e, t, a), du(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = we(), n = Il(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = Pl(t, n, a), e !== null && (De(e, t, a), du(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = we(), a = Il(l);
      a.tag = 2, e != null && (a.callback = e), e = Pl(t, a, l), e !== null && (De(e, t, l), du(e, t, l));
    }
  };
  function Ps(t, e, l, a, n, u, i) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, u, i) : e.prototype && e.prototype.isPureReactComponent ? !nu(l, a) || !nu(n, u) : !0;
  }
  function tr(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && gc.enqueueReplaceState(e, e.state, null);
  }
  function Qa(t, e) {
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
  function er(t) {
    ai(t);
  }
  function lr(t) {
    console.error(t);
  }
  function ar(t) {
    ai(t);
  }
  function Ai(t, e) {
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
    return l = Il(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Ai(t, e);
    }, l;
  }
  function ur(t) {
    return t = Il(t), t.tag = 3, t;
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
      nr(e, l, a), typeof n != "function" && (ua === null ? ua = /* @__PURE__ */ new Set([this]) : ua.add(this));
      var f = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: f !== null ? f : ""
      });
    });
  }
  function Km(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && yn(
        e,
        l,
        n,
        !0
      ), l = Ne.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return ke === null ? wi() : l.alternate === null && Gt === 0 && (Gt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === mi ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Xc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === mi ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Xc(t, a, n)), !1;
        }
        throw Error(p(435, l.tag));
      }
      return Xc(t, a, n), wi(), !1;
    }
    if (ot)
      return e = Ne.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== qf && (t = Error(p(422), { cause: a }), fu(Ve(t, l)))) : (a !== qf && (e = Error(p(423), {
        cause: a
      }), fu(
        Ve(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ve(a, l), n = vc(
        t.stateNode,
        a,
        n
      ), Jf(t, n), Gt !== 4 && (Gt = 2)), !1;
    var u = Error(p(520), { cause: a });
    if (u = Ve(u, l), Au === null ? Au = [u] : Au.push(u), Gt !== 4 && (Gt = 2), e === null) return !0;
    a = Ve(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = vc(l.stateNode, a, t), Jf(l, t), !1;
        case 1:
          if (e = l.type, u = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || u !== null && typeof u.componentDidCatch == "function" && (ua === null || !ua.has(u))))
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
  var pc = Error(p(461)), Kt = !1;
  function re(t, e, l, a) {
    e.child = t === null ? ss(e, null, l, a) : La(
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
    return ja(e), a = Pf(
      t,
      e,
      l,
      i,
      u,
      n
    ), f = tc(), t !== null && !Kt ? (ec(t, e, n), Rl(t, e, n)) : (ot && f && Nf(e), e.flags |= 1, re(t, e, a, n), e.child);
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
      )) : (t = fi(
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
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && ri(
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
      u !== null ? (ri(e, u.cachePool), ms(e, u), ea(), e.memoizedState = null) : (t !== null && ri(e, null), Ff(), ea());
    return re(t, e, n, l), e.child;
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
    }, t !== null && ri(e, null), Ff(), hs(e), t !== null && yn(t, e, a, !0), e.childLanes = n, null;
  }
  function _i(t, e) {
    return e = Oi(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function dr(t, e, l) {
    return La(e, t.child, null, l), t = _i(e, e.pendingProps), t.flags |= 2, He(e), e.memoizedState = null, t;
  }
  function Jm(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (ot) {
        if (a.mode === "hidden")
          return t = _i(e, a), e.lanes = 536870912, bu(null, t);
        if ($f(e), (t = Ot) ? (t = Md(
          t,
          Je
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Jl !== null ? { id: dl, overflow: ml } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, oe = e, Ot = null)) : t = null, t === null) throw Fl(e);
        return e.lanes = 536870912, null;
      }
      return _i(e, a);
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
        else throw Error(p(558));
      else if (Kt || yn(t, e, l, !1), n = (l & t.childLanes) !== 0, Kt || n) {
        if (a = Et, a !== null && (i = xe(a, l), i !== 0 && i !== u.retryLane))
          throw u.retryLane = i, Ra(t, i), De(a, t, i), pc;
        wi(), e = dr(
          t,
          e,
          l
        );
      } else
        t = u.treeContext, Ot = Fe(i.nextSibling), oe = e, ot = !0, kl = null, Je = !1, t !== null && Io(e, t), e = _i(e, a), e.flags |= 4096;
      return e;
    }
    return t = _l(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Di(t, e) {
    var l = e.ref;
    if (l === null)
      t !== null && t.ref !== null && (e.flags |= 4194816);
    else {
      if (typeof l != "function" && typeof l != "object")
        throw Error(p(284));
      (t === null || t.ref !== l) && (e.flags |= 4194816);
    }
  }
  function bc(t, e, l, a, n) {
    return ja(e), l = Pf(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = tc(), t !== null && !Kt ? (ec(t, e, n), Rl(t, e, n)) : (ot && a && Nf(e), e.flags |= 1, re(t, e, l, n), e.child);
  }
  function mr(t, e, l, a, n, u) {
    return ja(e), e.updateQueue = null, l = gs(
      e,
      a,
      l,
      n
    ), ys(t), a = tc(), t !== null && !Kt ? (ec(t, e, u), Rl(t, e, u)) : (ot && a && Nf(e), e.flags |= 1, re(t, e, l, u), e.child);
  }
  function hr(t, e, l, a, n) {
    if (ja(e), e.stateNode === null) {
      var u = rn, i = l.contextType;
      typeof i == "object" && i !== null && (u = se(i)), u = new l(a, u), e.memoizedState = u.state !== null && u.state !== void 0 ? u.state : null, u.updater = gc, e.stateNode = u, u._reactInternals = e, u = e.stateNode, u.props = a, u.state = e.memoizedState, u.refs = {}, Zf(e), i = l.contextType, u.context = typeof i == "object" && i !== null ? se(i) : rn, u.state = e.memoizedState, i = l.getDerivedStateFromProps, typeof i == "function" && (yc(
        e,
        l,
        i,
        a
      ), u.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof u.getSnapshotBeforeUpdate == "function" || typeof u.UNSAFE_componentWillMount != "function" && typeof u.componentWillMount != "function" || (i = u.state, typeof u.componentWillMount == "function" && u.componentWillMount(), typeof u.UNSAFE_componentWillMount == "function" && u.UNSAFE_componentWillMount(), i !== u.state && gc.enqueueReplaceState(u, u.state, null), hu(e, a, u, n), mu(), u.state = e.memoizedState), typeof u.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      u = e.stateNode;
      var f = e.memoizedProps, o = Qa(l, f);
      u.props = o;
      var y = u.context, x = l.contextType;
      i = rn, typeof x == "object" && x !== null && (i = se(x));
      var E = l.getDerivedStateFromProps;
      x = typeof E == "function" || typeof u.getSnapshotBeforeUpdate == "function", f = e.pendingProps !== f, x || typeof u.UNSAFE_componentWillReceiveProps != "function" && typeof u.componentWillReceiveProps != "function" || (f || y !== i) && tr(
        e,
        u,
        a,
        i
      ), $l = !1;
      var v = e.memoizedState;
      u.state = v, hu(e, a, u, n), mu(), y = e.memoizedState, f || v !== y || $l ? (typeof E == "function" && (yc(
        e,
        l,
        E,
        a
      ), y = e.memoizedState), (o = $l || Ps(
        e,
        l,
        o,
        a,
        v,
        y,
        i
      )) ? (x || typeof u.UNSAFE_componentWillMount != "function" && typeof u.componentWillMount != "function" || (typeof u.componentWillMount == "function" && u.componentWillMount(), typeof u.UNSAFE_componentWillMount == "function" && u.UNSAFE_componentWillMount()), typeof u.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof u.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = y), u.props = a, u.state = y, u.context = i, a = o) : (typeof u.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      u = e.stateNode, Kf(t, e), i = e.memoizedProps, x = Qa(l, i), u.props = x, E = e.pendingProps, v = u.context, y = l.contextType, o = rn, typeof y == "object" && y !== null && (o = se(y)), f = l.getDerivedStateFromProps, (y = typeof f == "function" || typeof u.getSnapshotBeforeUpdate == "function") || typeof u.UNSAFE_componentWillReceiveProps != "function" && typeof u.componentWillReceiveProps != "function" || (i !== E || v !== o) && tr(
        e,
        u,
        a,
        o
      ), $l = !1, v = e.memoizedState, u.state = v, hu(e, a, u, n), mu();
      var S = e.memoizedState;
      i !== E || v !== S || $l || t !== null && t.dependencies !== null && oi(t.dependencies) ? (typeof f == "function" && (yc(
        e,
        l,
        f,
        a
      ), S = e.memoizedState), (x = $l || Ps(
        e,
        l,
        x,
        a,
        v,
        S,
        o
      ) || t !== null && t.dependencies !== null && oi(t.dependencies)) ? (y || typeof u.UNSAFE_componentWillUpdate != "function" && typeof u.componentWillUpdate != "function" || (typeof u.componentWillUpdate == "function" && u.componentWillUpdate(a, S, o), typeof u.UNSAFE_componentWillUpdate == "function" && u.UNSAFE_componentWillUpdate(
        a,
        S,
        o
      )), typeof u.componentDidUpdate == "function" && (e.flags |= 4), typeof u.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof u.componentDidUpdate != "function" || i === t.memoizedProps && v === t.memoizedState || (e.flags |= 4), typeof u.getSnapshotBeforeUpdate != "function" || i === t.memoizedProps && v === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = S), u.props = a, u.state = S, u.context = o, a = x) : (typeof u.componentDidUpdate != "function" || i === t.memoizedProps && v === t.memoizedState || (e.flags |= 4), typeof u.getSnapshotBeforeUpdate != "function" || i === t.memoizedProps && v === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return u = a, Di(t, e), a = (e.flags & 128) !== 0, u || a ? (u = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : u.render(), e.flags |= 1, t !== null && a ? (e.child = La(
      e,
      t.child,
      null,
      n
    ), e.child = La(
      e,
      null,
      l,
      n
    )) : re(t, e, l, n), e.memoizedState = u.state, t = e.child) : t = Rl(
      t,
      e,
      n
    ), t;
  }
  function yr(t, e, l, a) {
    return Ha(), e.flags |= 256, re(t, e, l, a), e.child;
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
    if ((i = u) || (i = t !== null && t.memoizedState === null ? !1 : (Xt.current & 2) !== 0), i && (n = !0, e.flags &= -129), i = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (ot) {
        if (n ? ta(e) : ea(), (t = Ot) ? (t = Md(
          t,
          Je
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: Jl !== null ? { id: dl, overflow: ml } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = Fo(t), l.return = e, e.child = l, oe = e, Ot = null)) : t = null, t === null) throw Fl(e);
        return no(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var f = a.children;
      return a = a.fallback, n ? (ea(), n = e.mode, f = Oi(
        { mode: "hidden", children: f },
        n
      ), a = Na(
        a,
        n,
        l,
        null
      ), f.return = e, a.return = e, f.sibling = a, e.child = f, a = e.child, a.memoizedState = xc(l), a.childLanes = Tc(
        t,
        i,
        l
      ), e.memoizedState = Sc, bu(null, a)) : (ta(e), zc(e, f));
    }
    var o = t.memoizedState;
    if (o !== null && (f = o.dehydrated, f !== null)) {
      if (u)
        e.flags & 256 ? (ta(e), e.flags &= -257, e = Mc(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (ea(), e.child = t.child, e.flags |= 128, e = null) : (ea(), f = a.fallback, n = e.mode, a = Oi(
          { mode: "visible", children: a.children },
          n
        ), f = Na(
          f,
          n,
          l,
          null
        ), f.flags |= 2, a.return = e, f.return = e, a.sibling = f, e.child = a, La(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = xc(l), a.childLanes = Tc(
          t,
          i,
          l
        ), e.memoizedState = Sc, e = bu(null, a));
      else if (ta(e), no(f)) {
        if (i = f.nextSibling && f.nextSibling.dataset, i) var y = i.dgst;
        i = y, a = Error(p(419)), a.stack = "", a.digest = i, fu({ value: a, source: null, stack: null }), e = Mc(
          t,
          e,
          l
        );
      } else if (Kt || yn(t, e, l, !1), i = (l & t.childLanes) !== 0, Kt || i) {
        if (i = Et, i !== null && (a = xe(i, l), a !== 0 && a !== o.retryLane))
          throw o.retryLane = a, Ra(t, a), De(i, t, a), pc;
        ao(f) || wi(), e = Mc(
          t,
          e,
          l
        );
      } else
        ao(f) ? (e.flags |= 192, e.child = t.child, e = null) : (t = o.treeContext, Ot = Fe(
          f.nextSibling
        ), oe = e, ot = !0, kl = null, Je = !1, t !== null && Io(e, t), e = zc(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (ea(), f = a.fallback, n = e.mode, o = t.child, y = o.sibling, a = _l(o, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = o.subtreeFlags & 65011712, y !== null ? f = _l(
      y,
      f
    ) : (f = Na(
      f,
      n,
      l,
      null
    ), f.flags |= 2), f.return = e, a.return = e, a.sibling = f, e.child = a, bu(null, a), a = e.child, f = t.child.memoizedState, f === null ? f = xc(l) : (n = f.cachePool, n !== null ? (o = Vt._currentValue, n = n.parent !== o ? { parent: o, pool: o } : n) : n = ns(), f = {
      baseLanes: f.baseLanes | l,
      cachePool: n
    }), a.memoizedState = f, a.childLanes = Tc(
      t,
      i,
      l
    ), e.memoizedState = Sc, bu(t.child, a)) : (ta(e), l = t.child, t = l.sibling, l = _l(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (i = e.deletions, i === null ? (e.deletions = [t], e.flags |= 16) : i.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function zc(t, e) {
    return e = Oi(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Oi(t, e) {
    return t = Re(22, t, null, e), t.lanes = 0, t;
  }
  function Mc(t, e, l) {
    return La(e, t.child, null, l), t = zc(
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
    var i = Xt.current, f = (i & 2) !== 0;
    if (f ? (i = i & 1 | 2, e.flags |= 128) : i &= 1, C(Xt, i), re(t, e, a, l), a = ot ? iu : 0, !f && t !== null && (t.flags & 128) !== 0)
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
          t = l.alternate, t !== null && vi(t) === null && (n = l), l = l.sibling;
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
          if (t = n.alternate, t !== null && vi(t) === null) {
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
    if (t !== null && (e.dependencies = t.dependencies), na |= e.lanes, (l & e.childLanes) === 0)
      if (t !== null) {
        if (yn(
          t,
          e,
          l,
          !1
        ), (l & e.childLanes) === 0)
          return null;
      } else return null;
    if (t !== null && e.child !== t.child)
      throw Error(p(153));
    if (e.child !== null) {
      for (t = e.child, l = _l(t, t.pendingProps), e.child = l, l.return = e; t.sibling !== null; )
        t = t.sibling, l = l.sibling = _l(t, t.pendingProps), l.return = e;
      l.sibling = null;
    }
    return e.child;
  }
  function Ac(t, e) {
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && oi(t)));
  }
  function km(t, e, l) {
    switch (e.tag) {
      case 3:
        qt(e, e.stateNode.containerInfo), Wl(e, Vt, t.memoizedState.cache), Ha();
        break;
      case 27:
      case 5:
        Ue(e);
        break;
      case 4:
        qt(e, e.stateNode.containerInfo);
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
          return e.flags |= 128, $f(e), null;
        break;
      case 13:
        var a = e.memoizedState;
        if (a !== null)
          return a.dehydrated !== null ? (ta(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? gr(t, e, l) : (ta(e), t = Rl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        ta(e);
        break;
      case 19:
        var n = (t.flags & 128) !== 0;
        if (a = (l & e.childLanes) !== 0, a || (yn(
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
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), C(Xt, Xt.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, sr(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        Wl(e, Vt, t.memoizedState.cache);
    }
    return Rl(t, e, l);
  }
  function br(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        Kt = !0;
      else {
        if (!Ac(t, l) && (e.flags & 128) === 0)
          return Kt = !1, km(
            t,
            e,
            l
          );
        Kt = (t.flags & 131072) !== 0;
      }
    else
      Kt = !1, ot && (e.flags & 1048576) !== 0 && $o(e, iu, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = Ya(e.elementType), e.type = t, typeof t == "function")
            Cf(t) ? (a = Qa(t, a), e.tag = 1, e = hr(
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
              if (n === Pt) {
                e.tag = 11, e = fr(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === F) {
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
            throw e = G(t) || t, Error(p(306, e, ""));
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
        return a = e.type, n = Qa(
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
          if (qt(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(p(387));
          a = e.pendingProps;
          var u = e.memoizedState;
          n = u.element, Kf(t, e), hu(e, a, null, l);
          var i = e.memoizedState;
          if (a = i.cache, Wl(e, Vt, a), a !== u.cache && Gf(
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
              n = Ve(
                Error(p(424)),
                e
              ), fu(n), e = yr(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Ot = Fe(t.firstChild), oe = e, ot = !0, kl = null, Je = !0, l = ss(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (Ha(), a === n) {
              e = Rl(
                t,
                e,
                l
              );
              break t;
            }
            re(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Di(t, e), t === null ? (l = Ud(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : ot || (l = e.type, t = e.pendingProps, a = Zi(
          tt.current
        ).createElement(l), a[Wt] = e, a[fe] = t, de(a, l, t), jt(a), e.stateNode = a) : e.memoizedState = Ud(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return Ue(e), t === null && ot && (a = e.stateNode = _d(
          e.type,
          e.pendingProps,
          tt.current
        ), oe = e, Je = !0, n = Ot, oa(e.type) ? (uo = n, Ot = Fe(a.firstChild)) : Ot = n), re(
          t,
          e,
          e.pendingProps.children,
          l
        ), Di(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && ot && ((n = a = Ot) && (a = Mh(
          a,
          e.type,
          e.pendingProps,
          Je
        ), a !== null ? (e.stateNode = a, oe = e, Ot = Fe(a.firstChild), Je = !1, n = !0) : n = !1), n || Fl(e)), Ue(e), n = e.type, u = e.pendingProps, i = t !== null ? t.memoizedProps : null, a = u.children, to(n, u) ? a = null : i !== null && to(n, i) && (e.flags |= 32), e.memoizedState !== null && (n = Pf(
          t,
          e,
          Ym,
          null,
          null,
          l
        ), Nu._currentValue = n), Di(t, e), re(t, e, a, l), e.child;
      case 6:
        return t === null && ot && ((t = l = Ot) && (l = Eh(
          l,
          e.pendingProps,
          Je
        ), l !== null ? (e.stateNode = l, oe = e, Ot = null, t = !0) : t = !1), t || Fl(e)), null;
      case 13:
        return gr(t, e, l);
      case 4:
        return qt(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = La(
          e,
          null,
          a,
          l
        ) : re(t, e, a, l), e.child;
      case 11:
        return fr(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return re(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return re(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return re(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, Wl(e, e.type, a.value), re(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, ja(e), n = se(n), a = a(n), e.flags |= 1, re(t, e, a, l), e.child;
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
        return Jm(t, e, l);
      case 22:
        return sr(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return ja(e), a = se(Vt), t === null ? (n = Qf(), n === null && (n = Et, u = Lf(), n.pooledCache = u, u.refCount++, u !== null && (n.pooledCacheLanes |= l), n = u), e.memoizedState = { parent: a, cache: n }, Zf(e), Wl(e, Vt, n)) : ((t.lanes & l) !== 0 && (Kf(t, e), hu(e, null, null, l), mu()), n = t.memoizedState, u = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), Wl(e, Vt, a)) : (a = u.cache, Wl(e, Vt, a), a !== n.cache && Gf(
          e,
          [Vt],
          l,
          !0
        ))), re(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 29:
        throw e.pendingProps;
    }
    throw Error(p(156, e.tag));
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
          throw Ga = mi, Vf;
    } else t.flags &= -16777217;
  }
  function Sr(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !Hd(e))
      if (Kr()) t.flags |= 8192;
      else
        throw Ga = mi, Vf;
  }
  function Ui(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? cl() : 536870912, t.lanes |= e, _n |= e);
  }
  function Su(t, e) {
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
  function Fm(t, e, l) {
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
        return Ut(e), null;
      case 1:
        return Ut(e), null;
      case 3:
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), Ul(Vt), _t(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (hn(e) ? Nl(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, jf())), Ut(e), null;
      case 26:
        var n = e.type, u = e.memoizedState;
        return t === null ? (Nl(e), u !== null ? (Ut(e), Sr(e, u)) : (Ut(e), _c(
          e,
          n,
          null,
          a,
          l
        ))) : u ? u !== t.memoizedState ? (Nl(e), Ut(e), Sr(e, u)) : (Ut(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Nl(e), Ut(e), _c(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if ($e(e), l = tt.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Nl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(p(166));
            return Ut(e), null;
          }
          t = q.current, hn(e) ? Po(e) : (t = _d(n, a, l), e.stateNode = t, Nl(e));
        }
        return Ut(e), null;
      case 5:
        if ($e(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Nl(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(p(166));
            return Ut(e), null;
          }
          if (u = q.current, hn(e))
            Po(e);
          else {
            var i = Zi(
              tt.current
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
            u[Wt] = e, u[fe] = a;
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
            t: switch (de(u, n, a), n) {
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
        return Ut(e), _c(
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
            throw Error(p(166));
          if (t = tt.current, hn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = oe, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[Wt] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || gd(t.nodeValue, l)), t || Fl(e, !0);
          } else
            t = Zi(t).createTextNode(
              a
            ), t[Wt] = e, e.stateNode = t;
        }
        return Ut(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = hn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(p(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(p(557));
              t[Wt] = e;
            } else
              Ha(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ut(e), t = !1;
          } else
            l = jf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (He(e), e) : (He(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(p(558));
        }
        return Ut(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = hn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(p(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(p(317));
              n[Wt] = e;
            } else
              Ha(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Ut(e), n = !1;
          } else
            n = jf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (He(e), e) : (He(e), null);
        }
        return He(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), u = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (u = a.memoizedState.cachePool.pool), u !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Ui(e, e.updateQueue), Ut(e), null);
      case 4:
        return _t(), t === null && Fc(e.stateNode.containerInfo), Ut(e), null;
      case 10:
        return Ul(e.type), Ut(e), null;
      case 19:
        if (z(Xt), a = e.memoizedState, a === null) return Ut(e), null;
        if (n = (e.flags & 128) !== 0, u = a.rendering, u === null)
          if (n) Su(a, !1);
          else {
            if (Gt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (u = vi(t), u !== null) {
                  for (e.flags |= 128, Su(a, !1), t = u.updateQueue, e.updateQueue = t, Ui(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    ko(l, t), l = l.sibling;
                  return C(
                    Xt,
                    Xt.current & 1 | 2
                  ), ot && Dl(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && he() > Hi && (e.flags |= 128, n = !0, Su(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = vi(u), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Ui(e, t), Su(a, !0), a.tail === null && a.tailMode === "hidden" && !u.alternate && !ot)
                return Ut(e), null;
            } else
              2 * he() - a.renderingStartTime > Hi && l !== 536870912 && (e.flags |= 128, n = !0, Su(a, !1), e.lanes = 4194304);
          a.isBackwards ? (u.sibling = e.child, e.child = u) : (t = a.last, t !== null ? t.sibling = u : e.child = u, a.last = u);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = he(), t.sibling = null, l = Xt.current, C(
          Xt,
          n ? l & 1 | 2 : l & 1
        ), ot && Dl(e, a.treeForkCount), t) : (Ut(e), null);
      case 22:
      case 23:
        return He(e), Wf(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Ut(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Ut(e), l = e.updateQueue, l !== null && Ui(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && z(wa), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), Ul(Vt), Ut(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(p(156, e.tag));
  }
  function Wm(t, e) {
    switch (Hf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return Ul(Vt), _t(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return $e(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (He(e), e.alternate === null)
            throw Error(p(340));
          Ha();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (He(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(p(340));
          Ha();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return z(Xt), null;
      case 4:
        return _t(), null;
      case 10:
        return Ul(e.type), null;
      case 22:
      case 23:
        return He(e), Wf(), t !== null && z(wa), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
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
        Ul(Vt), _t();
        break;
      case 26:
      case 27:
      case 5:
        $e(e);
        break;
      case 4:
        _t();
        break;
      case 31:
        e.memoizedState !== null && He(e);
        break;
      case 13:
        He(e);
        break;
      case 19:
        z(Xt);
        break;
      case 10:
        Ul(e.type);
        break;
      case 22:
      case 23:
        He(e), Wf(), t !== null && z(wa);
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
  function la(t, e, l) {
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
              var o = l, y = f;
              try {
                y();
              } catch (x) {
                St(
                  n,
                  o,
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
    l.props = Qa(
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
  function hl(t, e) {
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
      ph(a, t.type, l, e), a[fe] = e;
    } catch (n) {
      St(t, t.return, n);
    }
  }
  function Er(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && oa(t.type) || t.tag === 4;
  }
  function Oc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || Er(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && oa(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function Uc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = tl));
    else if (a !== 4 && (a === 27 && oa(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (Uc(t, e, l), t = t.sibling; t !== null; )
        Uc(t, e, l), t = t.sibling;
  }
  function Ci(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && oa(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (Ci(t, e, l), t = t.sibling; t !== null; )
        Ci(t, e, l), t = t.sibling;
  }
  function Ar(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      de(e, a, l), e[Wt] = t, e[fe] = l;
    } catch (u) {
      St(t, t.return, u);
    }
  }
  var Hl = !1, Jt = !1, Cc = !1, _r = typeof WeakSet == "function" ? WeakSet : Set, le = null;
  function $m(t, e) {
    if (t = t.containerInfo, Ic = Ii, t = Yo(t), Mf(t)) {
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
            var i = 0, f = -1, o = -1, y = 0, x = 0, E = t, v = null;
            e: for (; ; ) {
              for (var S; E !== l || n !== 0 && E.nodeType !== 3 || (f = i + n), E !== u || a !== 0 && E.nodeType !== 3 || (o = i + a), E.nodeType === 3 && (i += E.nodeValue.length), (S = E.firstChild) !== null; )
                v = E, E = S;
              for (; ; ) {
                if (E === t) break e;
                if (v === l && ++y === n && (f = i), v === u && ++x === a && (o = i), (S = E.nextSibling) !== null) break;
                E = v, v = E.parentNode;
              }
              E = S;
            }
            l = f === -1 || o === -1 ? null : { start: f, end: o };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (Pc = { focusedElem: t, selectionRange: l }, Ii = !1, le = e; le !== null; )
      if (e = le, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, le = t;
      else
        for (; le !== null; ) {
          switch (e = le, u = e.alternate, t = e.flags, e.tag) {
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
                  var w = Qa(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    w,
                    u
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch (Q) {
                  St(
                    l,
                    l.return,
                    Q
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
              if ((t & 1024) !== 0) throw Error(p(163));
          }
          if (t = e.sibling, t !== null) {
            t.return = e.return, le = t;
            break;
          }
          le = e.return;
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
            var n = Qa(
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
        jl(t, l), a & 4 && Br(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = ih.bind(
          null,
          l
        ), Ah(t, l))));
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
    e !== null && (t.alternate = null, Or(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && tn(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Rt = null, Me = !1;
  function ql(t, e, l) {
    for (l = l.child; l !== null; )
      Ur(t, e, l), l = l.sibling;
  }
  function Ur(t, e, l) {
    if (be && typeof be.onCommitFiberUnmount == "function")
      try {
        be.onCommitFiberUnmount(va, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        Jt || hl(l, e), ql(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        Jt || hl(l, e);
        var a = Rt, n = Me;
        oa(l.type) && (Rt = l.stateNode, Me = !1), ql(
          t,
          e,
          l
        ), Cu(l.stateNode), Rt = a, Me = n;
        break;
      case 5:
        Jt || hl(l, e);
      case 6:
        if (a = Rt, n = Me, Rt = null, ql(
          t,
          e,
          l
        ), Rt = a, Me = n, Rt !== null)
          if (Me)
            try {
              (Rt.nodeType === 9 ? Rt.body : Rt.nodeName === "HTML" ? Rt.ownerDocument.body : Rt).removeChild(l.stateNode);
            } catch (u) {
              St(
                l,
                e,
                u
              );
            }
          else
            try {
              Rt.removeChild(l.stateNode);
            } catch (u) {
              St(
                l,
                e,
                u
              );
            }
        break;
      case 18:
        Rt !== null && (Me ? (t = Rt, Td(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), Hn(t)) : Td(Rt, l.stateNode));
        break;
      case 4:
        a = Rt, n = Me, Rt = l.stateNode.containerInfo, Me = !0, ql(
          t,
          e,
          l
        ), Rt = a, Me = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        la(2, l, e), Jt || la(4, l, e), ql(
          t,
          e,
          l
        );
        break;
      case 1:
        Jt || (hl(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && zr(
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
        Hn(t);
      } catch (l) {
        St(e, e.return, l);
      }
    }
  }
  function Br(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        Hn(t);
      } catch (l) {
        St(e, e.return, l);
      }
  }
  function Im(t) {
    switch (t.tag) {
      case 31:
      case 13:
      case 19:
        var e = t.stateNode;
        return e === null && (e = t.stateNode = new _r()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new _r()), e;
      default:
        throw Error(p(435, t.tag));
    }
  }
  function Bi(t, e) {
    var l = Im(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = fh.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function Ee(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], u = t, i = e, f = i;
        t: for (; f !== null; ) {
          switch (f.tag) {
            case 27:
              if (oa(f.type)) {
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
        if (Rt === null) throw Error(p(160));
        Ur(u, i, n), Rt = null, Me = !1, u = n.alternate, u !== null && (u.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        Rr(e, t), e = e.sibling;
  }
  var nl = null;
  function Rr(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Ee(e, t), Ae(t), a & 4 && (la(3, t, t.return), xu(3, t), la(5, t, t.return));
        break;
      case 1:
        Ee(e, t), Ae(t), a & 512 && (Jt || l === null || hl(l, l.return)), a & 64 && Hl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = nl;
        if (Ee(e, t), Ae(t), a & 512 && (Jt || l === null || hl(l, l.return)), a & 4) {
          var u = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      u = n.getElementsByTagName("title")[0], (!u || u[za] || u[Wt] || u.namespaceURI === "http://www.w3.org/2000/svg" || u.hasAttribute("itemprop")) && (u = n.createElement(a), n.head.insertBefore(
                        u,
                        n.querySelector("head > title")
                      )), de(u, a, l), u[Wt] = t, jt(u), a = u;
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
                      u = n.createElement(a), de(u, a, l), n.head.appendChild(u);
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
                      u = n.createElement(a), de(u, a, l), n.head.appendChild(u);
                      break;
                    default:
                      throw Error(p(468, a));
                  }
                  u[Wt] = t, jt(u), a = u;
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
        Ee(e, t), Ae(t), a & 512 && (Jt || l === null || hl(l, l.return)), l !== null && a & 4 && Dc(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (Ee(e, t), Ae(t), a & 512 && (Jt || l === null || hl(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            D(n, "");
          } catch (w) {
            St(t, t.return, w);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Dc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Cc = !0);
        break;
      case 6:
        if (Ee(e, t), Ae(t), a & 4) {
          if (t.stateNode === null)
            throw Error(p(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (w) {
            St(t, t.return, w);
          }
        }
        break;
      case 3:
        if (ki = null, n = nl, nl = Ki(e.containerInfo), Ee(e, t), nl = n, Ae(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            Hn(e.containerInfo);
          } catch (w) {
            St(t, t.return, w);
          }
        Cc && (Cc = !1, Nr(t));
        break;
      case 4:
        a = nl, nl = Ki(
          t.stateNode.containerInfo
        ), Ee(e, t), Ae(t), nl = a;
        break;
      case 12:
        Ee(e, t), Ae(t);
        break;
      case 31:
        Ee(e, t), Ae(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Bi(t, a)));
        break;
      case 13:
        Ee(e, t), Ae(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Ni = he()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Bi(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var o = l !== null && l.memoizedState !== null, y = Hl, x = Jt;
        if (Hl = y || n, Jt = x || o, Ee(e, t), Jt = x, Hl = y, Ae(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || o || Hl || Jt || Va(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                o = l = e;
                try {
                  if (u = o.stateNode, n)
                    i = u.style, typeof i.setProperty == "function" ? i.setProperty("display", "none", "important") : i.display = "none";
                  else {
                    f = o.stateNode;
                    var E = o.memoizedProps.style, v = E != null && E.hasOwnProperty("display") ? E.display : null;
                    f.style.display = v == null || typeof v == "boolean" ? "" : ("" + v).trim();
                  }
                } catch (w) {
                  St(o, o.return, w);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                o = e;
                try {
                  o.stateNode.nodeValue = n ? "" : o.memoizedProps;
                } catch (w) {
                  St(o, o.return, w);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                o = e;
                try {
                  var S = o.stateNode;
                  n ? zd(S, !0) : zd(o.stateNode, !1);
                } catch (w) {
                  St(o, o.return, w);
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
        a & 4 && (a = t.updateQueue, a !== null && (l = a.retryQueue, l !== null && (a.retryQueue = null, Bi(t, l))));
        break;
      case 19:
        Ee(e, t), Ae(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, Bi(t, a)));
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
          if (Er(a)) {
            l = a;
            break;
          }
          a = a.return;
        }
        if (l == null) throw Error(p(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, u = Oc(t);
            Ci(t, u, n);
            break;
          case 5:
            var i = l.stateNode;
            l.flags & 32 && (D(i, ""), l.flags &= -33);
            var f = Oc(t);
            Ci(t, f, i);
            break;
          case 3:
          case 4:
            var o = l.stateNode.containerInfo, y = Oc(t);
            Uc(
              t,
              y,
              o
            );
            break;
          default:
            throw Error(p(161));
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
  function Va(t) {
    for (t = t.child; t !== null; ) {
      var e = t;
      switch (e.tag) {
        case 0:
        case 11:
        case 14:
        case 15:
          la(4, e, e.return), Va(e);
          break;
        case 1:
          hl(e, e.return);
          var l = e.stateNode;
          typeof l.componentWillUnmount == "function" && zr(
            e,
            e.return,
            l
          ), Va(e);
          break;
        case 27:
          Cu(e.stateNode);
        case 26:
        case 5:
          hl(e, e.return), Va(e);
          break;
        case 22:
          e.memoizedState === null && Va(e);
          break;
        case 30:
          Va(e);
          break;
        default:
          Va(e);
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
            } catch (y) {
              St(a, a.return, y);
            }
          if (a = u, n = a.updateQueue, n !== null) {
            var f = a.stateNode;
            try {
              var o = n.shared.hiddenCallbacks;
              if (o !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < o.length; n++)
                  rs(o[n], f);
            } catch (y) {
              St(a, a.return, y);
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
  function ul(t, e, l, a) {
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
        ul(
          t,
          e,
          l,
          a
        ), n & 2048 && xu(9, e);
        break;
      case 1:
        ul(
          t,
          e,
          l,
          a
        );
        break;
      case 3:
        ul(
          t,
          e,
          l,
          a
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && cu(t)));
        break;
      case 12:
        if (n & 2048) {
          ul(
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
          } catch (o) {
            St(e, e.return, o);
          }
        } else
          ul(
            t,
            e,
            l,
            a
          );
        break;
      case 31:
        ul(
          t,
          e,
          l,
          a
        );
        break;
      case 13:
        ul(
          t,
          e,
          l,
          a
        );
        break;
      case 23:
        break;
      case 22:
        u = e.stateNode, i = e.alternate, e.memoizedState !== null ? u._visibility & 2 ? ul(
          t,
          e,
          l,
          a
        ) : zu(t, e) : u._visibility & 2 ? ul(
          t,
          e,
          l,
          a
        ) : (u._visibility |= 2, Mn(
          t,
          e,
          l,
          a,
          (e.subtreeFlags & 10256) !== 0 || !1
        )), n & 2048 && Bc(i, e);
        break;
      case 24:
        ul(
          t,
          e,
          l,
          a
        ), n & 2048 && Rc(e.alternate, e);
        break;
      default:
        ul(
          t,
          e,
          l,
          a
        );
    }
  }
  function Mn(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var u = t, i = e, f = l, o = a, y = i.flags;
      switch (i.tag) {
        case 0:
        case 11:
        case 15:
          Mn(
            u,
            i,
            f,
            o,
            n
          ), xu(8, i);
          break;
        case 23:
          break;
        case 22:
          var x = i.stateNode;
          i.memoizedState !== null ? x._visibility & 2 ? Mn(
            u,
            i,
            f,
            o,
            n
          ) : zu(
            u,
            i
          ) : (x._visibility |= 2, Mn(
            u,
            i,
            f,
            o,
            n
          )), n && y & 2048 && Bc(
            i.alternate,
            i
          );
          break;
        case 24:
          Mn(
            u,
            i,
            f,
            o,
            n
          ), n && y & 2048 && Rc(i.alternate, i);
          break;
        default:
          Mn(
            u,
            i,
            f,
            o,
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
  function En(t, e, l) {
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
        En(
          t,
          e,
          l
        ), t.flags & Mu && t.memoizedState !== null && wh(
          l,
          nl,
          t.memoizedState,
          t.memoizedProps
        );
        break;
      case 5:
        En(
          t,
          e,
          l
        );
        break;
      case 3:
      case 4:
        var a = nl;
        nl = Ki(t.stateNode.containerInfo), En(
          t,
          e,
          l
        ), nl = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = Mu, Mu = 16777216, En(
          t,
          e,
          l
        ), Mu = a) : En(
          t,
          e,
          l
        ));
        break;
      default:
        En(
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
          le = a, Yr(
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
        Eu(t), t.flags & 2048 && la(9, t, t.return);
        break;
      case 3:
        Eu(t);
        break;
      case 12:
        Eu(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, Ri(t)) : Eu(t);
        break;
      default:
        Eu(t);
    }
  }
  function Ri(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          le = a, Yr(
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
          la(8, e, e.return), Ri(e);
          break;
        case 22:
          l = e.stateNode, l._visibility & 2 && (l._visibility &= -3, Ri(e));
          break;
        default:
          Ri(e);
      }
      t = t.sibling;
    }
  }
  function Yr(t, e) {
    for (; le !== null; ) {
      var l = le;
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
          cu(l.memoizedState.cache);
      }
      if (a = l.child, a !== null) a.return = l, le = a;
      else
        t: for (l = t; le !== null; ) {
          a = le;
          var n = a.sibling, u = a.return;
          if (Or(a), a === l) {
            le = null;
            break t;
          }
          if (n !== null) {
            n.return = u, le = n;
            break t;
          }
          le = u;
        }
    }
  }
  var Pm = {
    getCacheForType: function(t) {
      var e = se(Vt), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return se(Vt).controller.signal;
    }
  }, th = typeof WeakMap == "function" ? WeakMap : Map, pt = 0, Et = null, nt = null, it = 0, bt = 0, qe = null, aa = !1, An = !1, Nc = !1, Yl = 0, Gt = 0, na = 0, Za = 0, Hc = 0, je = 0, _n = 0, Au = null, _e = null, qc = !1, Ni = 0, Gr = 0, Hi = 1 / 0, qi = null, ua = null, $t = 0, ia = null, Dn = null, Gl = 0, jc = 0, wc = null, Lr = null, _u = 0, Yc = null;
  function we() {
    return (pt & 2) !== 0 && it !== 0 ? it & -it : b.T !== null ? Zc() : Ju();
  }
  function Xr() {
    if (je === 0)
      if ((it & 536870912) === 0 || ot) {
        var t = gl;
        gl <<= 1, (gl & 3932160) === 0 && (gl = 262144), je = t;
      } else je = 536870912;
    return t = Ne.current, t !== null && (t.flags |= 32), je;
  }
  function De(t, e, l) {
    (t === Et && (bt === 2 || bt === 9) || t.cancelPendingCommit !== null) && (On(t, 0), fa(
      t,
      it,
      je,
      !1
    )), Sa(t, l), ((pt & 2) === 0 || t !== Et) && (t === Et && ((pt & 2) === 0 && (Za |= l), Gt === 4 && fa(
      t,
      it,
      je,
      !1
    )), yl(t));
  }
  function Qr(t, e, l) {
    if ((pt & 6) !== 0) throw Error(p(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Xl(t, e), n = a ? ah(t, e) : Lc(t, e, !0), u = a;
    do {
      if (n === 0) {
        An && !a && fa(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, u && !eh(l)) {
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
              var o = f.current.memoizedState.isDehydrated;
              if (o && (On(f, i).flags |= 256), i = Lc(
                f,
                i,
                !1
              ), i !== 2) {
                if (Nc && !o) {
                  f.errorRecoveryDisabledLanes |= u, Za |= u, n = 4;
                  break t;
                }
                u = _e, _e = n, u !== null && (_e === null ? _e = u : _e.push.apply(
                  _e,
                  u
                ));
              }
              n = i;
            }
            if (u = !1, n !== 2) continue;
          }
        }
        if (n === 1) {
          On(t, 0), fa(t, e, 0, !0);
          break;
        }
        t: {
          switch (a = t, u = n, u) {
            case 0:
            case 1:
              throw Error(p(345));
            case 4:
              if ((e & 4194048) !== e) break;
            case 6:
              fa(
                a,
                e,
                je,
                !aa
              );
              break t;
            case 2:
              _e = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(p(329));
          }
          if ((e & 62914560) === e && (n = Ni + 300 - he(), 10 < n)) {
            if (fa(
              a,
              e,
              je,
              !aa
            ), ba(a, 0, !0) !== 0) break t;
            Gl = e, a.timeoutHandle = Sd(
              Vr.bind(
                null,
                a,
                l,
                _e,
                qi,
                qc,
                e,
                je,
                Za,
                _n,
                aa,
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
            _e,
            qi,
            qc,
            e,
            je,
            Za,
            _n,
            aa,
            u,
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
  function Vr(t, e, l, a, n, u, i, f, o, y, x, E, v, S) {
    if (t.timeoutHandle = -1, E = e.subtreeFlags, E & 8192 || (E & 16785408) === 16785408) {
      E = {
        stylesheets: null,
        count: 0,
        imgCount: 0,
        imgBytes: 0,
        suspenseyImages: [],
        waitingForImages: !0,
        waitingForViewTransition: !1,
        unsuspend: tl
      }, qr(
        e,
        u,
        E
      );
      var w = (u & 62914560) === u ? Ni - he() : (u & 4194048) === u ? Gr - he() : 0;
      if (w = Yh(
        E,
        w
      ), w !== null) {
        Gl = u, t.cancelPendingCommit = w(
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
            o,
            x,
            E,
            null,
            v,
            S
          )
        ), fa(t, u, i, !y);
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
      o
    );
  }
  function eh(t) {
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
  function fa(t, e, l, a) {
    e &= ~Hc, e &= ~Za, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var u = 31 - Se(n), i = 1 << u;
      a[u] = -1, n &= ~i;
    }
    l !== 0 && Ln(t, l, e);
  }
  function ji() {
    return (pt & 6) === 0 ? (Du(0), !1) : !0;
  }
  function Gc() {
    if (nt !== null) {
      if (bt === 0)
        var t = nt.return;
      else
        t = nt, Ol = qa = null, lc(t), bn = null, su = 0, t = nt;
      for (; t !== null; )
        xr(t.alternate, t), t = t.return;
      nt = null;
    }
  }
  function On(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, xh(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), Gl = 0, Gc(), Et = t, nt = l = _l(t.current, null), it = e, bt = 0, qe = null, aa = !1, An = Xl(t, e), Nc = !1, _n = je = Hc = Za = na = Gt = 0, _e = Au = null, qc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - Se(a), u = 1 << n;
        e |= t[n], a &= ~u;
      }
    return Yl = e, ni(), l;
  }
  function Zr(t, e) {
    P = null, b.H = pu, e === pn || e === di ? (e = fs(), bt = 3) : e === Vf ? (e = fs(), bt = 4) : bt = e === pc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, qe = e, nt === null && (Gt = 1, Ai(
      t,
      Ve(e, t.current)
    ));
  }
  function Kr() {
    var t = Ne.current;
    return t === null ? !0 : (it & 4194048) === it ? ke === null : (it & 62914560) === it || (it & 536870912) !== 0 ? t === ke : !1;
  }
  function Jr() {
    var t = b.H;
    return b.H = pu, t === null ? pu : t;
  }
  function kr() {
    var t = b.A;
    return b.A = Pm, t;
  }
  function wi() {
    Gt = 4, aa || (it & 4194048) !== it && Ne.current !== null || (An = !0), (na & 134217727) === 0 && (Za & 134217727) === 0 || Et === null || fa(
      Et,
      it,
      je,
      !1
    );
  }
  function Lc(t, e, l) {
    var a = pt;
    pt |= 2;
    var n = Jr(), u = kr();
    (Et !== t || it !== e) && (qi = null, On(t, e)), e = !1;
    var i = Gt;
    t: do
      try {
        if (bt !== 0 && nt !== null) {
          var f = nt, o = qe;
          switch (bt) {
            case 8:
              Gc(), i = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              Ne.current === null && (e = !0);
              var y = bt;
              if (bt = 0, qe = null, Un(t, f, o, y), l && An) {
                i = 0;
                break t;
              }
              break;
            default:
              y = bt, bt = 0, qe = null, Un(t, f, o, y);
          }
        }
        lh(), i = Gt;
        break;
      } catch (x) {
        Zr(t, x);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Ol = qa = null, pt = a, b.H = n, b.A = u, nt === null && (Et = null, it = 0, ni()), i;
  }
  function lh() {
    for (; nt !== null; ) Fr(nt);
  }
  function ah(t, e) {
    var l = pt;
    pt |= 2;
    var a = Jr(), n = kr();
    Et !== t || it !== e ? (qi = null, Hi = he() + 500, On(t, e)) : An = Xl(
      t,
      e
    );
    t: do
      try {
        if (bt !== 0 && nt !== null) {
          e = nt;
          var u = qe;
          e: switch (bt) {
            case 1:
              bt = 0, qe = null, Un(t, e, u, 1);
              break;
            case 2:
            case 9:
              if (us(u)) {
                bt = 0, qe = null, Wr(e);
                break;
              }
              e = function() {
                bt !== 2 && bt !== 9 || Et !== t || (bt = 7), yl(t);
              }, u.then(e, e);
              break t;
            case 3:
              bt = 7;
              break t;
            case 4:
              bt = 5;
              break t;
            case 7:
              us(u) ? (bt = 0, qe = null, Wr(e)) : (bt = 0, qe = null, Un(t, e, u, 7));
              break;
            case 5:
              var i = null;
              switch (nt.tag) {
                case 26:
                  i = nt.memoizedState;
                case 5:
                case 27:
                  var f = nt;
                  if (i ? Hd(i) : f.stateNode.complete) {
                    bt = 0, qe = null;
                    var o = f.sibling;
                    if (o !== null) nt = o;
                    else {
                      var y = f.return;
                      y !== null ? (nt = y, Yi(y)) : nt = null;
                    }
                    break e;
                  }
              }
              bt = 0, qe = null, Un(t, e, u, 5);
              break;
            case 6:
              bt = 0, qe = null, Un(t, e, u, 6);
              break;
            case 8:
              Gc(), Gt = 6;
              break t;
            default:
              throw Error(p(462));
          }
        }
        nh();
        break;
      } catch (x) {
        Zr(t, x);
      }
    while (!0);
    return Ol = qa = null, b.H = a, b.A = n, pt = l, nt !== null ? 0 : (Et = null, it = 0, ni(), Gt);
  }
  function nh() {
    for (; nt !== null && !Xu(); )
      Fr(nt);
  }
  function Fr(t) {
    var e = br(t.alternate, t, Yl);
    t.memoizedProps = t.pendingProps, e === null ? Yi(t) : nt = e;
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
          it
        );
        break;
      case 11:
        e = mr(
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
        xr(l, e), e = nt = ko(e, Yl), e = br(l, e, Yl);
    }
    t.memoizedProps = t.pendingProps, e === null ? Yi(t) : nt = e;
  }
  function Un(t, e, l, a) {
    Ol = qa = null, lc(e), bn = null, su = 0;
    var n = e.return;
    try {
      if (Km(
        t,
        n,
        e,
        l,
        it
      )) {
        Gt = 1, Ai(
          t,
          Ve(l, t.current)
        ), nt = null;
        return;
      }
    } catch (u) {
      if (n !== null) throw nt = n, u;
      Gt = 1, Ai(
        t,
        Ve(l, t.current)
      ), nt = null;
      return;
    }
    e.flags & 32768 ? (ot || a === 1 ? t = !0 : An || (it & 536870912) !== 0 ? t = !1 : (aa = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = Ne.current, a !== null && a.tag === 13 && (a.flags |= 16384))), $r(e, t)) : Yi(e);
  }
  function Yi(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        $r(
          e,
          aa
        );
        return;
      }
      t = e.return;
      var l = Fm(
        e.alternate,
        e,
        Yl
      );
      if (l !== null) {
        nt = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        nt = e;
        return;
      }
      nt = e = t;
    } while (e !== null);
    Gt === 0 && (Gt = 5);
  }
  function $r(t, e) {
    do {
      var l = Wm(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, nt = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        nt = t;
        return;
      }
      nt = t = l;
    } while (t !== null);
    Gt = 6, nt = null;
  }
  function Ir(t, e, l, a, n, u, i, f, o) {
    t.cancelPendingCommit = null;
    do
      Gi();
    while ($t !== 0);
    if ((pt & 6) !== 0) throw Error(p(327));
    if (e !== null) {
      if (e === t.current) throw Error(p(177));
      if (u = e.lanes | e.childLanes, u |= Of, Pa(
        t,
        l,
        u,
        i,
        f,
        o
      ), t === Et && (nt = Et = null, it = 0), Dn = e, ia = t, Gl = l, jc = u, wc = n, Lr = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, ch(ka, function() {
        return ad(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = b.T, b.T = null, n = U.p, U.p = 2, i = pt, pt |= 4;
        try {
          $m(t, e, l);
        } finally {
          pt = i, U.p = n, b.T = a;
        }
      }
      $t = 1, Pr(), td(), ed();
    }
  }
  function Pr() {
    if ($t === 1) {
      $t = 0;
      var t = ia, e = Dn, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = b.T, b.T = null;
        var a = U.p;
        U.p = 2;
        var n = pt;
        pt |= 4;
        try {
          Rr(e, t);
          var u = Pc, i = Yo(t.containerInfo), f = u.focusedElem, o = u.selectionRange;
          if (i !== f && f && f.ownerDocument && wo(
            f.ownerDocument.documentElement,
            f
          )) {
            if (o !== null && Mf(f)) {
              var y = o.start, x = o.end;
              if (x === void 0 && (x = y), "selectionStart" in f)
                f.selectionStart = y, f.selectionEnd = Math.min(
                  x,
                  f.value.length
                );
              else {
                var E = f.ownerDocument || document, v = E && E.defaultView || window;
                if (v.getSelection) {
                  var S = v.getSelection(), w = f.textContent.length, Q = Math.min(o.start, w), Mt = o.end === void 0 ? Q : Math.min(o.end, w);
                  !S.extend && Q > Mt && (i = Mt, Mt = Q, Q = i);
                  var m = jo(
                    f,
                    Q
                  ), r = jo(
                    f,
                    Mt
                  );
                  if (m && r && (S.rangeCount !== 1 || S.anchorNode !== m.node || S.anchorOffset !== m.offset || S.focusNode !== r.node || S.focusOffset !== r.offset)) {
                    var h = E.createRange();
                    h.setStart(m.node, m.offset), S.removeAllRanges(), Q > Mt ? (S.addRange(h), S.extend(r.node, r.offset)) : (h.setEnd(r.node, r.offset), S.addRange(h));
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
              var T = E[f];
              T.element.scrollLeft = T.left, T.element.scrollTop = T.top;
            }
          }
          Ii = !!Ic, Pc = Ic = null;
        } finally {
          pt = n, U.p = a, b.T = l;
        }
      }
      t.current = e, $t = 2;
    }
  }
  function td() {
    if ($t === 2) {
      $t = 0;
      var t = ia, e = Dn, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = b.T, b.T = null;
        var a = U.p;
        U.p = 2;
        var n = pt;
        pt |= 4;
        try {
          Dr(t, e.alternate, e);
        } finally {
          pt = n, U.p = a, b.T = l;
        }
      }
      $t = 3;
    }
  }
  function ed() {
    if ($t === 4 || $t === 3) {
      $t = 0, Yn();
      var t = ia, e = Dn, l = Gl, a = Lr;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? $t = 5 : ($t = 0, Dn = ia = null, ld(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (ua = null), Ta(l), e = e.stateNode, be && typeof be.onCommitFiberRoot == "function")
        try {
          be.onCommitFiberRoot(
            va,
            e,
            void 0,
            (e.current.flags & 128) === 128
          );
        } catch {
        }
      if (a !== null) {
        e = b.T, n = U.p, U.p = 2, b.T = null;
        try {
          for (var u = t.onRecoverableError, i = 0; i < a.length; i++) {
            var f = a[i];
            u(f.value, {
              componentStack: f.stack
            });
          }
        } finally {
          b.T = e, U.p = n;
        }
      }
      (Gl & 3) !== 0 && Gi(), yl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Yc ? _u++ : (_u = 0, Yc = t) : _u = 0, Du(0);
    }
  }
  function ld(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, cu(e)));
  }
  function Gi() {
    return Pr(), td(), ed(), ad();
  }
  function ad() {
    if ($t !== 5) return !1;
    var t = ia, e = jc;
    jc = 0;
    var l = Ta(Gl), a = b.T, n = U.p;
    try {
      U.p = 32 > l ? 32 : l, b.T = null, l = wc, wc = null;
      var u = ia, i = Gl;
      if ($t = 0, Dn = ia = null, Gl = 0, (pt & 6) !== 0) throw Error(p(331));
      var f = pt;
      if (pt |= 4, wr(u.current), Hr(
        u,
        u.current,
        i,
        l
      ), pt = f, Du(0, !1), be && typeof be.onPostCommitFiberRoot == "function")
        try {
          be.onPostCommitFiberRoot(va, u);
        } catch {
        }
      return !0;
    } finally {
      U.p = n, b.T = a, ld(t, e);
    }
  }
  function nd(t, e, l) {
    e = Ve(l, e), e = vc(t.stateNode, e, 2), t = Pl(t, e, 2), t !== null && (Sa(t, 2), yl(t));
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
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (ua === null || !ua.has(a))) {
            t = Ve(l, t), l = ur(2), a = Pl(e, l, 2), a !== null && (ir(
              l,
              a,
              e,
              t
            ), Sa(a, 2), yl(a));
            break;
          }
        }
        e = e.return;
      }
  }
  function Xc(t, e, l) {
    var a = t.pingCache;
    if (a === null) {
      a = t.pingCache = new th();
      var n = /* @__PURE__ */ new Set();
      a.set(e, n);
    } else
      n = a.get(e), n === void 0 && (n = /* @__PURE__ */ new Set(), a.set(e, n));
    n.has(l) || (Nc = !0, n.add(l), t = uh.bind(null, t, e, l), e.then(t, t));
  }
  function uh(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, Et === t && (it & l) === l && (Gt === 4 || Gt === 3 && (it & 62914560) === it && 300 > he() - Ni ? (pt & 2) === 0 && On(t, 0) : Hc |= l, _n === it && (_n = 0)), yl(t);
  }
  function ud(t, e) {
    e === 0 && (e = cl()), t = Ra(t, e), t !== null && (Sa(t, e), yl(t));
  }
  function ih(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), ud(t, l);
  }
  function fh(t, e) {
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
        throw Error(p(314));
    }
    a !== null && a.delete(e), ud(t, l);
  }
  function ch(t, e) {
    return ya(t, e);
  }
  var Li = null, Cn = null, Qc = !1, Xi = !1, Vc = !1, ca = 0;
  function yl(t) {
    t !== Cn && t.next === null && (Cn === null ? Li = Cn = t : Cn = Cn.next = t), Xi = !0, Qc || (Qc = !0, sh());
  }
  function Du(t, e) {
    if (!Vc && Xi) {
      Vc = !0;
      do
        for (var l = !1, a = Li; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var u = 0;
            else {
              var i = a.suspendedLanes, f = a.pingedLanes;
              u = (1 << 31 - Se(42 | t) + 1) - 1, u &= n & ~(i & ~f), u = u & 201326741 ? u & 201326741 | 1 : u ? u | 2 : 0;
            }
            u !== 0 && (l = !0, od(a, u));
          } else
            u = it, u = ba(
              a,
              a === Et ? u : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (u & 3) === 0 || Xl(a, u) || (l = !0, od(a, u));
          a = a.next;
        }
      while (l);
      Vc = !1;
    }
  }
  function oh() {
    id();
  }
  function id() {
    Xi = Qc = !1;
    var t = 0;
    ca !== 0 && Sh() && (t = ca);
    for (var e = he(), l = null, a = Li; a !== null; ) {
      var n = a.next, u = fd(a, e);
      u === 0 ? (a.next = null, l === null ? Li = n : l.next = n, n === null && (Cn = l)) : (l = a, (t !== 0 || (u & 3) !== 0) && (Xi = !0)), a = n;
    }
    $t !== 0 && $t !== 5 || Du(t), ca !== 0 && (ca = 0);
  }
  function fd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, u = t.pendingLanes & -62914561; 0 < u; ) {
      var i = 31 - Se(u), f = 1 << i, o = n[i];
      o === -1 ? ((f & l) === 0 || (f & a) !== 0) && (n[i] = rf(f, e)) : o <= e && (t.expiredLanes |= f), u &= ~f;
    }
    if (e = Et, l = it, l = ba(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (bt === 2 || bt === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && ga(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Xl(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && ga(a), Ta(l)) {
        case 2:
        case 8:
          l = Gn;
          break;
        case 32:
          l = ka;
          break;
        case 268435456:
          l = Qu;
          break;
        default:
          l = ka;
      }
      return a = cd.bind(null, t), l = ya(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && ga(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function cd(t, e) {
    if ($t !== 0 && $t !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Gi() && t.callbackNode !== l)
      return null;
    var a = it;
    return a = ba(
      t,
      t === Et ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (Qr(t, a, e), fd(t, he()), t.callbackNode != null && t.callbackNode === l ? cd.bind(null, t) : null);
  }
  function od(t, e) {
    if (Gi()) return null;
    Qr(t, e, !0);
  }
  function sh() {
    Th(function() {
      (pt & 6) !== 0 ? ya(
        Ja,
        oh
      ) : id();
    });
  }
  function Zc() {
    if (ca === 0) {
      var t = gn;
      t === 0 && (t = Wa, Wa <<= 1, (Wa & 261888) === 0 && (Wa = 256)), ca = t;
    }
    return ca;
  }
  function sd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : Pe("" + t);
  }
  function rd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function rh(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var u = sd(
        (n[fe] || null).action
      ), i = a.submitter;
      i && (e = (e = i[fe] || null) ? sd(e.formAction) : i.getAttribute("formAction"), e !== null && (u = e, i = null));
      var f = new Da(
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
                if (ca !== 0) {
                  var o = i ? rd(n, i) : new FormData(n);
                  rc(
                    l,
                    {
                      pending: !0,
                      data: o,
                      method: n.method,
                      action: u
                    },
                    null,
                    o
                  );
                }
              } else
                typeof u == "function" && (f.preventDefault(), o = i ? rd(n, i) : new FormData(n), rc(
                  l,
                  {
                    pending: !0,
                    data: o,
                    method: n.method,
                    action: u
                  },
                  u,
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
    var Jc = Df[Kc], dh = Jc.toLowerCase(), mh = Jc[0].toUpperCase() + Jc.slice(1);
    al(
      dh,
      "on" + mh
    );
  }
  al(Xo, "onAnimationEnd"), al(Qo, "onAnimationIteration"), al(Vo, "onAnimationStart"), al("dblclick", "onDoubleClick"), al("focusin", "onFocus"), al("focusout", "onBlur"), al(Om, "onTransitionRun"), al(Um, "onTransitionStart"), al(Cm, "onTransitionCancel"), al(Zo, "onTransitionEnd"), xl("onMouseEnter", ["mouseout", "mouseover"]), xl("onMouseLeave", ["mouseout", "mouseover"]), xl("onPointerEnter", ["pointerout", "pointerover"]), xl("onPointerLeave", ["pointerout", "pointerover"]), Sl(
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
  var Ou = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), hh = new Set(
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
            var f = a[i], o = f.instance, y = f.currentTarget;
            if (f = f.listener, o !== u && n.isPropagationStopped())
              break t;
            u = f, n.currentTarget = y;
            try {
              u(n);
            } catch (x) {
              ai(x);
            }
            n.currentTarget = null, u = o;
          }
        else
          for (i = 0; i < a.length; i++) {
            if (f = a[i], o = f.instance, y = f.currentTarget, f = f.listener, o !== u && n.isPropagationStopped())
              break t;
            u = f, n.currentTarget = y;
            try {
              u(n);
            } catch (x) {
              ai(x);
            }
            n.currentTarget = null, u = o;
          }
      }
    }
  }
  function ut(t, e) {
    var l = e[Xn];
    l === void 0 && (l = e[Xn] = /* @__PURE__ */ new Set());
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
  var Qi = "_reactListening" + Math.random().toString(36).slice(2);
  function Fc(t) {
    if (!t[Qi]) {
      t[Qi] = !0, Qn.forEach(function(l) {
        l !== "selectionchange" && (hh.has(l) || kc(l, !1, t), kc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[Qi] || (e[Qi] = !0, kc("selectionchange", !1, e));
    }
  }
  function md(t, e, l, a) {
    switch (Xd(e)) {
      case 2:
        var n = Xh;
        break;
      case 8:
        n = Qh;
        break;
      default:
        n = so;
    }
    l = n.bind(
      null,
      e,
      l,
      t
    ), n = void 0, !an || e !== "touchstart" && e !== "touchmove" && e !== "wheel" || (n = !0), a ? n !== void 0 ? t.addEventListener(e, l, {
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
              var o = i.tag;
              if ((o === 3 || o === 4) && i.stateNode.containerInfo === n)
                return;
              i = i.return;
            }
          for (; f !== null; ) {
            if (i = ol(f), i === null) return;
            if (o = i.tag, o === 5 || o === 6 || o === 26 || o === 27) {
              a = u = i;
              continue t;
            }
            f = f.parentNode;
          }
        }
        a = a.return;
      }
    ln(function() {
      var y = u, x = Wn(l), E = [];
      t: {
        var v = Ko.get(t);
        if (v !== void 0) {
          var S = Da, w = t;
          switch (t) {
            case "keypress":
              if (Aa(l) === 0) break t;
            case "keydown":
            case "keyup":
              S = fm;
              break;
            case "focusin":
              w = "focus", S = O;
              break;
            case "focusout":
              w = "blur", S = O;
              break;
            case "beforeblur":
            case "afterblur":
              S = O;
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
              S = tu;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              S = un;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              S = sm;
              break;
            case Xo:
            case Qo:
            case Vo:
              S = I;
              break;
            case Zo:
              S = dm;
              break;
            case "scroll":
            case "scrollend":
              S = pf;
              break;
            case "wheel":
              S = hm;
              break;
            case "copy":
            case "cut":
            case "paste":
              S = mt;
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
              S = gm;
          }
          var Q = (e & 4) !== 0, Mt = !Q && (t === "scroll" || t === "scrollend"), m = Q ? v !== null ? v + "Capture" : null : v;
          Q = [];
          for (var r = y, h; r !== null; ) {
            var T = r;
            if (h = T.stateNode, T = T.tag, T !== 5 && T !== 26 && T !== 27 || h === null || m === null || (T = zl(r, m), T != null && Q.push(
              Uu(r, T, h)
            )), Mt) break;
            r = r.return;
          }
          0 < Q.length && (v = new S(
            v,
            w,
            null,
            l,
            x
          ), E.push({ event: v, listeners: Q }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (v = t === "mouseover" || t === "pointerover", S = t === "mouseout" || t === "pointerout", v && l !== Fn && (w = l.relatedTarget || l.fromElement) && (ol(w) || w[pl]))
            break t;
          if ((S || v) && (v = x.window === x ? x : (v = x.ownerDocument) ? v.defaultView || v.parentWindow : window, S ? (w = l.relatedTarget || l.toElement, S = y, w = w ? ol(w) : null, w !== null && (Mt = Lt(w), Q = w.tag, w !== Mt || Q !== 5 && Q !== 27 && Q !== 6) && (w = null)) : (S = null, w = y), S !== w)) {
            if (Q = tu, T = "onMouseLeave", m = "onMouseEnter", r = "mouse", (t === "pointerout" || t === "pointerover") && (Q = zo, T = "onPointerLeave", m = "onPointerEnter", r = "pointer"), Mt = S == null ? v : Ma(S), h = w == null ? v : Ma(w), v = new Q(
              T,
              r + "leave",
              S,
              l,
              x
            ), v.target = Mt, v.relatedTarget = h, T = null, ol(x) === y && (Q = new Q(
              m,
              r + "enter",
              w,
              l,
              x
            ), Q.target = h, Q.relatedTarget = Mt, T = Q), Mt = T, S && w)
              e: {
                for (Q = yh, m = S, r = w, h = 0, T = m; T; T = Q(T))
                  h++;
                T = 0;
                for (var X = r; X; X = Q(X))
                  T++;
                for (; 0 < h - T; )
                  m = Q(m), h--;
                for (; 0 < T - h; )
                  r = Q(r), T--;
                for (; h--; ) {
                  if (m === r || r !== null && m === r.alternate) {
                    Q = m;
                    break e;
                  }
                  m = Q(m), r = Q(r);
                }
                Q = null;
              }
            else Q = null;
            S !== null && hd(
              E,
              v,
              S,
              Q,
              !1
            ), w !== null && Mt !== null && hd(
              E,
              Mt,
              w,
              Q,
              !0
            );
          }
        }
        t: {
          if (v = y ? Ma(y) : window, S = v.nodeName && v.nodeName.toLowerCase(), S === "select" || S === "input" && v.type === "file")
            var ht = Co;
          else if (Oo(v))
            if (Bo)
              ht = Am;
            else {
              ht = Mm;
              var Y = zm;
            }
          else
            S = v.nodeName, !S || S.toLowerCase() !== "input" || v.type !== "checkbox" && v.type !== "radio" ? y && ct(y.elementType) && (ht = Co) : ht = Em;
          if (ht && (ht = ht(t, y))) {
            Uo(
              E,
              ht,
              l,
              x
            );
            break t;
          }
          Y && Y(t, v, y), t === "focusout" && y && v.type === "number" && y.memoizedProps.value != null && kn(v, "number", v.value);
        }
        switch (Y = y ? Ma(y) : window, t) {
          case "focusin":
            (Oo(Y) || Y.contentEditable === "true") && (cn = Y, Ef = y, uu = null);
            break;
          case "focusout":
            uu = Ef = cn = null;
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
            if (Dm) break;
          case "keydown":
          case "keyup":
            Go(E, l, x);
        }
        var et;
        if (xf)
          t: {
            switch (t) {
              case "compositionstart":
                var ft = "onCompositionStart";
                break t;
              case "compositionend":
                ft = "onCompositionEnd";
                break t;
              case "compositionupdate":
                ft = "onCompositionUpdate";
                break t;
            }
            ft = void 0;
          }
        else
          fn ? _o(t, l) && (ft = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (ft = "onCompositionStart");
        ft && (Mo && l.locale !== "ko" && (fn || ft !== "onCompositionStart" ? ft === "onCompositionEnd" && fn && (et = Iu()) : (Le = x, El = "value" in Le ? Le.value : Le.textContent, fn = !0)), Y = Vi(y, ft), 0 < Y.length && (ft = new ye(
          ft,
          t,
          null,
          l,
          x
        ), E.push({ event: ft, listeners: Y }), et ? ft.data = et : (et = Do(l), et !== null && (ft.data = et)))), (et = pm ? bm(t, l) : Sm(t, l)) && (ft = Vi(y, "onBeforeInput"), 0 < ft.length && (Y = new ye(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          x
        ), E.push({
          event: Y,
          listeners: ft
        }), Y.data = et)), rh(
          E,
          t,
          y,
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
  function Vi(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, u = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || u === null || (n = zl(t, l), n != null && a.unshift(
        Uu(t, n, u)
      ), n = zl(t, e), n != null && a.push(
        Uu(t, n, u)
      )), t.tag === 3) return a;
      t = t.return;
    }
    return [];
  }
  function yh(t) {
    if (t === null) return null;
    do
      t = t.return;
    while (t && t.tag !== 5 && t.tag !== 27);
    return t || null;
  }
  function hd(t, e, l, a, n) {
    for (var u = e._reactName, i = []; l !== null && l !== a; ) {
      var f = l, o = f.alternate, y = f.stateNode;
      if (f = f.tag, o !== null && o === a) break;
      f !== 5 && f !== 26 && f !== 27 || y === null || (o = y, n ? (y = zl(l, u), y != null && i.unshift(
        Uu(l, y, o)
      )) : n || (y = zl(l, u), y != null && i.push(
        Uu(l, y, o)
      ))), l = l.return;
    }
    i.length !== 0 && t.push({ event: e, listeners: i });
  }
  var gh = /\r\n?/g, vh = /\u0000|\uFFFD/g;
  function yd(t) {
    return (typeof t == "string" ? t : "" + t).replace(gh, `
`).replace(vh, "");
  }
  function gd(t, e) {
    return e = yd(e), yd(t) === e;
  }
  function zt(t, e, l, a, n, u) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || D(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && D(t, "" + a);
        break;
      case "className":
        en(t, "class", a);
        break;
      case "tabIndex":
        en(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        en(t, l, a);
        break;
      case "style":
        H(t, a, u);
        break;
      case "data":
        if (e !== "object") {
          en(t, "data", a);
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
        a = Pe("" + a), t.setAttribute(l, a);
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
          typeof u == "function" && (l === "formAction" ? (e !== "input" && zt(t, e, "name", n.name, n, null), zt(
            t,
            e,
            "formEncType",
            n.formEncType,
            n,
            null
          ), zt(
            t,
            e,
            "formMethod",
            n.formMethod,
            n,
            null
          ), zt(
            t,
            e,
            "formTarget",
            n.formTarget,
            n,
            null
          )) : (zt(t, e, "encType", n.encType, n, null), zt(t, e, "method", n.method, n, null), zt(t, e, "target", n.target, n, null)));
        if (a == null || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = Pe("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = tl);
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
            throw Error(p(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(p(60));
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
        l = Pe("" + a), t.setAttributeNS(
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
        ut("beforetoggle", t), ut("toggle", t), Ql(t, "popover", a);
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
        Ql(t, "is", a);
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = Dt.get(l) || l, Ql(t, l, a));
    }
  }
  function $c(t, e, l, a, n, u) {
    switch (l) {
      case "style":
        H(t, a, u);
        break;
      case "dangerouslySetInnerHTML":
        if (a != null) {
          if (typeof a != "object" || !("__html" in a))
            throw Error(p(61));
          if (l = a.__html, l != null) {
            if (n.children != null) throw Error(p(60));
            t.innerHTML = l;
          }
        }
        break;
      case "children":
        typeof a == "string" ? D(t, a) : (typeof a == "number" || typeof a == "bigint") && D(t, "" + a);
        break;
      case "onScroll":
        a != null && ut("scroll", t);
        break;
      case "onScrollEnd":
        a != null && ut("scrollend", t);
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
        if (!Vn.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), u = t[fe] || null, u = u != null ? u[l] : null, typeof u == "function" && t.removeEventListener(e, u, n), typeof a == "function")) {
              typeof u != "function" && u !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : Ql(t, l, a);
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
        ut("error", t), ut("load", t);
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
                  throw Error(p(137, e));
                default:
                  zt(t, e, u, i, l, null);
              }
          }
        n && zt(t, e, "srcSet", l.srcSet, l, null), a && zt(t, e, "src", l.src, l, null);
        return;
      case "input":
        ut("invalid", t);
        var f = u = i = n = null, o = null, y = null;
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
                  o = x;
                  break;
                case "defaultChecked":
                  y = x;
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
                    throw Error(p(137, e));
                  break;
                default:
                  zt(t, e, a, x, l, null);
              }
          }
        $u(
          t,
          u,
          f,
          o,
          y,
          i,
          n,
          !1
        );
        return;
      case "select":
        ut("invalid", t), a = i = u = null;
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
                zt(t, e, n, f, l, null);
            }
        e = u, l = i, t.multiple = !!a, e != null ? c(t, !!a, e, !1) : l != null && c(t, !!a, l, !0);
        return;
      case "textarea":
        ut("invalid", t), u = n = a = null;
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
                if (f != null) throw Error(p(91));
                break;
              default:
                zt(t, e, i, f, l, null);
            }
        g(t, a, n, u);
        return;
      case "option":
        for (o in l)
          l.hasOwnProperty(o) && (a = l[o], a != null) && (o === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : zt(t, e, o, a, l, null));
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
        for (a = 0; a < Ou.length; a++)
          ut(Ou[a], t);
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
        for (y in l)
          if (l.hasOwnProperty(y) && (a = l[y], a != null))
            switch (y) {
              case "children":
              case "dangerouslySetInnerHTML":
                throw Error(p(137, e));
              default:
                zt(t, e, y, a, l, null);
            }
        return;
      default:
        if (ct(e)) {
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
      l.hasOwnProperty(f) && (a = l[f], a != null && zt(t, e, f, a, l, null));
  }
  function ph(t, e, l, a) {
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
        var n = null, u = null, i = null, f = null, o = null, y = null, x = null;
        for (S in l) {
          var E = l[S];
          if (l.hasOwnProperty(S) && E != null)
            switch (S) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                o = E;
              default:
                a.hasOwnProperty(S) || zt(t, e, S, null, a, E);
            }
        }
        for (var v in a) {
          var S = a[v];
          if (E = l[v], a.hasOwnProperty(v) && (S != null || E != null))
            switch (v) {
              case "type":
                u = S;
                break;
              case "name":
                n = S;
                break;
              case "checked":
                y = S;
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
                  throw Error(p(137, e));
                break;
              default:
                S !== E && zt(
                  t,
                  e,
                  v,
                  S,
                  a,
                  E
                );
            }
        }
        Zl(
          t,
          i,
          f,
          o,
          y,
          x,
          u,
          n
        );
        return;
      case "select":
        S = i = f = v = null;
        for (u in l)
          if (o = l[u], l.hasOwnProperty(u) && o != null)
            switch (u) {
              case "value":
                break;
              case "multiple":
                S = o;
              default:
                a.hasOwnProperty(u) || zt(
                  t,
                  e,
                  u,
                  null,
                  a,
                  o
                );
            }
        for (n in a)
          if (u = a[n], o = l[n], a.hasOwnProperty(n) && (u != null || o != null))
            switch (n) {
              case "value":
                v = u;
                break;
              case "defaultValue":
                f = u;
                break;
              case "multiple":
                i = u;
              default:
                u !== o && zt(
                  t,
                  e,
                  n,
                  u,
                  a,
                  o
                );
            }
        e = f, l = i, a = S, v != null ? c(t, !!l, v, !1) : !!a != !!l && (e != null ? c(t, !!l, e, !0) : c(t, !!l, l ? [] : "", !1));
        return;
      case "textarea":
        S = v = null;
        for (f in l)
          if (n = l[f], l.hasOwnProperty(f) && n != null && !a.hasOwnProperty(f))
            switch (f) {
              case "value":
                break;
              case "children":
                break;
              default:
                zt(t, e, f, null, a, n);
            }
        for (i in a)
          if (n = a[i], u = l[i], a.hasOwnProperty(i) && (n != null || u != null))
            switch (i) {
              case "value":
                v = n;
                break;
              case "defaultValue":
                S = n;
                break;
              case "children":
                break;
              case "dangerouslySetInnerHTML":
                if (n != null) throw Error(p(91));
                break;
              default:
                n !== u && zt(t, e, i, n, a, u);
            }
        s(t, v, S);
        return;
      case "option":
        for (var w in l)
          v = l[w], l.hasOwnProperty(w) && v != null && !a.hasOwnProperty(w) && (w === "selected" ? t.selected = !1 : zt(
            t,
            e,
            w,
            null,
            a,
            v
          ));
        for (o in a)
          v = a[o], S = l[o], a.hasOwnProperty(o) && v !== S && (v != null || S != null) && (o === "selected" ? t.selected = v && typeof v != "function" && typeof v != "symbol" : zt(
            t,
            e,
            o,
            v,
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
        for (var Q in l)
          v = l[Q], l.hasOwnProperty(Q) && v != null && !a.hasOwnProperty(Q) && zt(t, e, Q, null, a, v);
        for (y in a)
          if (v = a[y], S = l[y], a.hasOwnProperty(y) && v !== S && (v != null || S != null))
            switch (y) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (v != null)
                  throw Error(p(137, e));
                break;
              default:
                zt(
                  t,
                  e,
                  y,
                  v,
                  a,
                  S
                );
            }
        return;
      default:
        if (ct(e)) {
          for (var Mt in l)
            v = l[Mt], l.hasOwnProperty(Mt) && v !== void 0 && !a.hasOwnProperty(Mt) && $c(
              t,
              e,
              Mt,
              void 0,
              a,
              v
            );
          for (x in a)
            v = a[x], S = l[x], !a.hasOwnProperty(x) || v === S || v === void 0 && S === void 0 || $c(
              t,
              e,
              x,
              v,
              a,
              S
            );
          return;
        }
    }
    for (var m in l)
      v = l[m], l.hasOwnProperty(m) && v != null && !a.hasOwnProperty(m) && zt(t, e, m, null, a, v);
    for (E in a)
      v = a[E], S = l[E], !a.hasOwnProperty(E) || v === S || v == null && S == null || zt(t, e, E, v, a, S);
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
  function bh() {
    if (typeof performance.getEntriesByType == "function") {
      for (var t = 0, e = 0, l = performance.getEntriesByType("resource"), a = 0; a < l.length; a++) {
        var n = l[a], u = n.transferSize, i = n.initiatorType, f = n.duration;
        if (u && f && vd(i)) {
          for (i = 0, f = n.responseEnd, a += 1; a < l.length; a++) {
            var o = l[a], y = o.startTime;
            if (y > f) break;
            var x = o.transferSize, E = o.initiatorType;
            x && vd(E) && (o = o.responseEnd, i += x * (o < f ? 1 : (f - y) / (o - y)));
          }
          if (--a, e += 8 * (u + i) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var Ic = null, Pc = null;
  function Zi(t) {
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
  function Sh() {
    var t = window.event;
    return t && t.type === "popstate" ? t === eo ? !1 : (eo = t, !0) : (eo = null, !1);
  }
  var Sd = typeof setTimeout == "function" ? setTimeout : void 0, xh = typeof clearTimeout == "function" ? clearTimeout : void 0, xd = typeof Promise == "function" ? Promise : void 0, Th = typeof queueMicrotask == "function" ? queueMicrotask : typeof xd < "u" ? function(t) {
    return xd.resolve(null).then(t).catch(zh);
  } : Sd;
  function zh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function oa(t) {
    return t === "head";
  }
  function Td(t, e) {
    var l = e, a = 0;
    do {
      var n = l.nextSibling;
      if (t.removeChild(l), n && n.nodeType === 8)
        if (l = n.data, l === "/$" || l === "/&") {
          if (a === 0) {
            t.removeChild(n), Hn(e);
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
            u[za] || f === "SCRIPT" || f === "STYLE" || f === "LINK" && u.rel.toLowerCase() === "stylesheet" || l.removeChild(u), u = i;
          }
        } else
          l === "body" && Cu(t.ownerDocument.body);
      l = n;
    } while (l);
    Hn(e);
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
          lo(l), tn(l);
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
  function Mh(t, e, l, a) {
    for (; t.nodeType === 1; ) {
      var n = l;
      if (t.nodeName.toLowerCase() !== e.toLowerCase()) {
        if (!a && (t.nodeName !== "INPUT" || t.type !== "hidden"))
          break;
      } else if (a) {
        if (!t[za])
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
      if (t = Fe(t.nextSibling), t === null) break;
    }
    return null;
  }
  function Eh(t, e, l) {
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
  function Ah(t, e) {
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
    switch (e = Zi(l), t) {
      case "html":
        if (t = e.documentElement, !t) throw Error(p(452));
        return t;
      case "head":
        if (t = e.head, !t) throw Error(p(453));
        return t;
      case "body":
        if (t = e.body, !t) throw Error(p(454));
        return t;
      default:
        throw Error(p(451));
    }
  }
  function Cu(t) {
    for (var e = t.attributes; e.length; )
      t.removeAttributeNode(e[0]);
    tn(t);
  }
  var We = /* @__PURE__ */ new Map(), Dd = /* @__PURE__ */ new Set();
  function Ki(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var Ll = U.d;
  U.d = {
    f: _h,
    r: Dh,
    D: Oh,
    C: Uh,
    L: Ch,
    m: Bh,
    X: Nh,
    S: Rh,
    M: Hh
  };
  function _h() {
    var t = Ll.f(), e = ji();
    return t || e;
  }
  function Dh(t) {
    var e = sl(t);
    e !== null && e.tag === 5 && e.type === "form" ? Zs(e) : Ll.r(t);
  }
  var Bn = typeof document > "u" ? null : document;
  function Od(t, e, l) {
    var a = Bn;
    if (a && typeof e == "string" && e) {
      var n = Bt(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Dd.has(n) || (Dd.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), de(e, "link", t), jt(e), a.head.appendChild(e)));
    }
  }
  function Oh(t) {
    Ll.D(t), Od("dns-prefetch", t, null);
  }
  function Uh(t, e) {
    Ll.C(t, e), Od("preconnect", t, e);
  }
  function Ch(t, e, l) {
    Ll.L(t, e, l);
    var a = Bn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + Bt(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + Bt(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + Bt(
        l.imageSizes
      ) + '"]')) : n += '[href="' + Bt(t) + '"]';
      var u = n;
      switch (e) {
        case "style":
          u = Rn(t);
          break;
        case "script":
          u = Nn(t);
      }
      We.has(u) || (t = V(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), We.set(u, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Bu(u)) || e === "script" && a.querySelector(Ru(u)) || (e = a.createElement("link"), de(e, "link", t), jt(e), a.head.appendChild(e)));
    }
  }
  function Bh(t, e) {
    Ll.m(t, e);
    var l = Bn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + Bt(a) + '"][href="' + Bt(t) + '"]', u = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          u = Nn(t);
      }
      if (!We.has(u) && (t = V({ rel: "modulepreload", href: t }, e), We.set(u, t), l.querySelector(n) === null)) {
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
        a = l.createElement("link"), de(a, "link", t), jt(a), l.head.appendChild(a);
      }
    }
  }
  function Rh(t, e, l) {
    Ll.S(t, e, l);
    var a = Bn;
    if (a && t) {
      var n = bl(a).hoistableStyles, u = Rn(t);
      e = e || "default";
      var i = n.get(u);
      if (!i) {
        var f = { loading: 0, preload: null };
        if (i = a.querySelector(
          Bu(u)
        ))
          f.loading = 5;
        else {
          t = V(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = We.get(u)) && io(t, l);
          var o = i = a.createElement("link");
          jt(o), de(o, "link", t), o._p = new Promise(function(y, x) {
            o.onload = y, o.onerror = x;
          }), o.addEventListener("load", function() {
            f.loading |= 1;
          }), o.addEventListener("error", function() {
            f.loading |= 2;
          }), f.loading |= 4, Ji(i, e, a);
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
  function Nh(t, e) {
    Ll.X(t, e);
    var l = Bn;
    if (l && t) {
      var a = bl(l).hoistableScripts, n = Nn(t), u = a.get(n);
      u || (u = l.querySelector(Ru(n)), u || (t = V({ src: t, async: !0 }, e), (e = We.get(n)) && fo(t, e), u = l.createElement("script"), jt(u), de(u, "link", t), l.head.appendChild(u)), u = {
        type: "script",
        instance: u,
        count: 1,
        state: null
      }, a.set(n, u));
    }
  }
  function Hh(t, e) {
    Ll.M(t, e);
    var l = Bn;
    if (l && t) {
      var a = bl(l).hoistableScripts, n = Nn(t), u = a.get(n);
      u || (u = l.querySelector(Ru(n)), u || (t = V({ src: t, async: !0, type: "module" }, e), (e = We.get(n)) && fo(t, e), u = l.createElement("script"), jt(u), de(u, "link", t), l.head.appendChild(u)), u = {
        type: "script",
        instance: u,
        count: 1,
        state: null
      }, a.set(n, u));
    }
  }
  function Ud(t, e, l, a) {
    var n = (n = tt.current) ? Ki(n) : null;
    if (!n) throw Error(p(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = Rn(l.href), l = bl(
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
          var u = bl(
            n
          ).hoistableStyles, i = u.get(t);
          if (i || (n = n.ownerDocument || n, i = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, u.set(t, i), (u = n.querySelector(
            Bu(t)
          )) && !u._p && (i.instance = u, i.state.loading = 5), We.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, We.set(t, l), u || qh(
            n,
            t,
            l,
            i.state
          ))), e && a === null)
            throw Error(p(528, ""));
          return i;
        }
        if (e && a !== null)
          throw Error(p(529, ""));
        return null;
      case "script":
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = Nn(l), l = bl(
          n
        ).hoistableScripts, a = l.get(e), a || (a = {
          type: "script",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      default:
        throw Error(p(444, t));
    }
  }
  function Rn(t) {
    return 'href="' + Bt(t) + '"';
  }
  function Bu(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Cd(t) {
    return V({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function qh(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), de(e, "link", l), jt(e), t.head.appendChild(e));
  }
  function Nn(t) {
    return '[src="' + Bt(t) + '"]';
  }
  function Ru(t) {
    return "script[async]" + t;
  }
  function Bd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + Bt(l.href) + '"]'
          );
          if (a)
            return e.instance = a, jt(a), a;
          var n = V({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), jt(a), de(a, "style", n), Ji(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = Rn(l.href);
          var u = t.querySelector(
            Bu(n)
          );
          if (u)
            return e.state.loading |= 4, e.instance = u, jt(u), u;
          a = Cd(l), (n = We.get(n)) && io(a, n), u = (t.ownerDocument || t).createElement("link"), jt(u);
          var i = u;
          return i._p = new Promise(function(f, o) {
            i.onload = f, i.onerror = o;
          }), de(u, "link", a), e.state.loading |= 4, Ji(u, l.precedence, t), e.instance = u;
        case "script":
          return u = Nn(l.src), (n = t.querySelector(
            Ru(u)
          )) ? (e.instance = n, jt(n), n) : (a = l, (n = We.get(u)) && (a = V({}, l), fo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), jt(n), de(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(p(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, Ji(a, l.precedence, t));
    return e.instance;
  }
  function Ji(t, e, l) {
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
  var ki = null;
  function Rd(t, e, l) {
    if (ki === null) {
      var a = /* @__PURE__ */ new Map(), n = ki = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = ki, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var u = l[n];
      if (!(u[za] || u[Wt] || t === "link" && u.getAttribute("rel") === "stylesheet") && u.namespaceURI !== "http://www.w3.org/2000/svg") {
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
  function jh(t, e, l) {
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
  function wh(t, e, l, a) {
    if (l.type === "stylesheet" && (typeof a.media != "string" || matchMedia(a.media).matches !== !1) && (l.state.loading & 4) === 0) {
      if (l.instance === null) {
        var n = Rn(a.href), u = e.querySelector(
          Bu(n)
        );
        if (u) {
          e = u._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = Fi.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = u, jt(u);
          return;
        }
        u = e.ownerDocument || e, a = Cd(a), (n = We.get(n)) && io(a, n), u = u.createElement("link"), jt(u);
        var i = u;
        i._p = new Promise(function(f, o) {
          i.onload = f, i.onerror = o;
        }), de(u, "link", a), l.instance = u;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = Fi.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var co = 0;
  function Yh(t, e) {
    return t.stylesheets && t.count === 0 && $i(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && $i(t, t.stylesheets), t.unsuspend) {
          var u = t.unsuspend;
          t.unsuspend = null, u();
        }
      }, 6e4 + e);
      0 < t.imgBytes && co === 0 && (co = 62500 * bh());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && $i(t, t.stylesheets), t.unsuspend)) {
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
  function Fi() {
    if (this.count--, this.count === 0 && (this.imgCount === 0 || !this.waitingForImages)) {
      if (this.stylesheets) $i(this, this.stylesheets);
      else if (this.unsuspend) {
        var t = this.unsuspend;
        this.unsuspend = null, t();
      }
    }
  }
  var Wi = null;
  function $i(t, e) {
    t.stylesheets = null, t.unsuspend !== null && (t.count++, Wi = /* @__PURE__ */ new Map(), e.forEach(Gh, t), Wi = null, Fi.call(t));
  }
  function Gh(t, e) {
    if (!(e.state.loading & 4)) {
      var l = Wi.get(t);
      if (l) var a = l.get(null);
      else {
        l = /* @__PURE__ */ new Map(), Wi.set(t, l);
        for (var n = t.querySelectorAll(
          "link[data-precedence],style[data-precedence]"
        ), u = 0; u < n.length; u++) {
          var i = n[u];
          (i.nodeName === "LINK" || i.getAttribute("media") !== "not all") && (l.set(i.dataset.precedence, i), a = i);
        }
        a && l.set(null, a);
      }
      n = e.instance, i = n.getAttribute("data-precedence"), u = l.get(i) || a, u === a && l.set(null, n), l.set(i, n), this.count++, a = Fi.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), u ? u.parentNode.insertBefore(n, u.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Nu = {
    $$typeof: Ht,
    Provider: null,
    Consumer: null,
    _currentValue: B,
    _currentValue2: B,
    _threadCount: 0
  };
  function Lh(t, e, l, a, n, u, i, f, o) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Ia(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Ia(0), this.hiddenUpdates = Ia(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = u, this.onRecoverableError = i, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = o, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function qd(t, e, l, a, n, u, i, f, o, y, x, E) {
    return t = new Lh(
      t,
      e,
      l,
      i,
      o,
      y,
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
    return t ? (t = rn, t) : rn;
  }
  function wd(t, e, l, a, n, u) {
    n = jd(n), a.context === null ? a.context = n : a.pendingContext = n, a = Il(e), a.payload = { element: l }, u = u === void 0 ? null : u, u !== null && (a.callback = u), l = Pl(t, a, e), l !== null && (De(l, t, e), du(l, t, e));
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
      var e = Ra(t, 67108864);
      e !== null && De(e, t, 67108864), oo(t, 67108864);
    }
  }
  function Ld(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = we();
      e = xa(e);
      var l = Ra(t, e);
      l !== null && De(l, t, e), oo(t, e);
    }
  }
  var Ii = !0;
  function Xh(t, e, l, a) {
    var n = b.T;
    b.T = null;
    var u = U.p;
    try {
      U.p = 2, so(t, e, l, a);
    } finally {
      U.p = u, b.T = n;
    }
  }
  function Qh(t, e, l, a) {
    var n = b.T;
    b.T = null;
    var u = U.p;
    try {
      U.p = 8, so(t, e, l, a);
    } finally {
      U.p = u, b.T = n;
    }
  }
  function so(t, e, l, a) {
    if (Ii) {
      var n = ro(a);
      if (n === null)
        Wc(
          t,
          e,
          a,
          Pi,
          l
        ), Qd(t, a);
      else if (Zh(
        n,
        t,
        e,
        l,
        a
      ))
        a.stopPropagation();
      else if (Qd(t, a), e & 4 && -1 < Vh.indexOf(t)) {
        for (; n !== null; ) {
          var u = sl(n);
          if (u !== null)
            switch (u.tag) {
              case 3:
                if (u = u.stateNode, u.current.memoizedState.isDehydrated) {
                  var i = vl(u.pendingLanes);
                  if (i !== 0) {
                    var f = u;
                    for (f.pendingLanes |= 2, f.entangledLanes |= 2; i; ) {
                      var o = 1 << 31 - Se(i);
                      f.entanglements[1] |= o, i &= ~o;
                    }
                    yl(u), (pt & 6) === 0 && (Hi = he() + 500, Du(0));
                  }
                }
                break;
              case 31:
              case 13:
                f = Ra(u, 2), f !== null && De(f, u, 2), ji(), oo(u, 2);
            }
          if (u = ro(a), u === null && Wc(
            t,
            e,
            a,
            Pi,
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
    return t = Wn(t), mo(t);
  }
  var Pi = null;
  function mo(t) {
    if (Pi = null, t = ol(t), t !== null) {
      var e = Lt(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = kt(e), t !== null) return t;
          t = null;
        } else if (l === 31) {
          if (t = K(e), t !== null) return t;
          t = null;
        } else if (l === 3) {
          if (e.stateNode.current.memoizedState.isDehydrated)
            return e.tag === 3 ? e.stateNode.containerInfo : null;
          t = null;
        } else e !== t && (t = null);
      }
    }
    return Pi = t, null;
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
        switch (cf()) {
          case Ja:
            return 2;
          case Gn:
            return 8;
          case ka:
          case of:
            return 32;
          case Qu:
            return 268435456;
          default:
            return 32;
        }
      default:
        return 32;
    }
  }
  var ho = !1, sa = null, ra = null, da = null, Hu = /* @__PURE__ */ new Map(), qu = /* @__PURE__ */ new Map(), ma = [], Vh = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function Qd(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        sa = null;
        break;
      case "dragenter":
      case "dragleave":
        ra = null;
        break;
      case "mouseover":
      case "mouseout":
        da = null;
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
    }, e !== null && (e = sl(e), e !== null && Gd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function Zh(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return sa = ju(
          sa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return ra = ju(
          ra,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return da = ju(
          da,
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
    var e = ol(t.target);
    if (e !== null) {
      var l = Lt(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = kt(l), e !== null) {
            t.blockedOn = e, ku(t.priority, function() {
              Ld(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = K(l), e !== null) {
            t.blockedOn = e, ku(t.priority, function() {
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
  function tf(t) {
    if (t.blockedOn !== null) return !1;
    for (var e = t.targetContainers; 0 < e.length; ) {
      var l = ro(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        Fn = a, l.target.dispatchEvent(a), Fn = null;
      } else
        return e = sl(l), e !== null && Gd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function Zd(t, e, l) {
    tf(t) && l.delete(e);
  }
  function Kh() {
    ho = !1, sa !== null && tf(sa) && (sa = null), ra !== null && tf(ra) && (ra = null), da !== null && tf(da) && (da = null), Hu.forEach(Zd), qu.forEach(Zd);
  }
  function ef(t, e) {
    t.blockedOn === e && (t.blockedOn = null, ho || (ho = !0, _.unstable_scheduleCallback(
      _.unstable_NormalPriority,
      Kh
    )));
  }
  var lf = null;
  function Kd(t) {
    lf !== t && (lf = t, _.unstable_scheduleCallback(
      _.unstable_NormalPriority,
      function() {
        lf === t && (lf = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (mo(a || l) === null)
              continue;
            break;
          }
          var u = sl(l);
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
  function Hn(t) {
    function e(o) {
      return ef(o, t);
    }
    sa !== null && ef(sa, t), ra !== null && ef(ra, t), da !== null && ef(da, t), Hu.forEach(e), qu.forEach(e);
    for (var l = 0; l < ma.length; l++) {
      var a = ma[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < ma.length && (l = ma[0], l.blockedOn === null); )
      Vd(l), l.blockedOn === null && ma.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], u = l[a + 1], i = n[fe] || null;
        if (typeof u == "function")
          i || Kd(l);
        else if (i) {
          var f = null;
          if (u && u.hasAttribute("formAction")) {
            if (n = u, i = u[fe] || null)
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
  af.prototype.render = yo.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(p(409));
    var l = e.current, a = we();
    wd(l, a, t, e, null, null);
  }, af.prototype.unmount = yo.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      wd(t.current, 2, null, t, null, null), ji(), e[pl] = null;
    }
  };
  function af(t) {
    this._internalRoot = t;
  }
  af.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = Ju();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < ma.length && e !== 0 && e < ma[l].priority; l++) ;
      ma.splice(l, 0, t), l === 0 && Vd(t);
    }
  };
  var kd = xt.version;
  if (kd !== "19.2.3")
    throw Error(
      p(
        527,
        kd,
        "19.2.3"
      )
    );
  U.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(p(188)) : (t = Object.keys(t).join(","), Error(p(268, t)));
    return t = A(e), t = t !== null ? at(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var Jh = {
    bundleType: 0,
    version: "19.2.3",
    rendererPackageName: "react-dom",
    currentDispatcherRef: b,
    reconcilerVersion: "19.2.3"
  };
  if (typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ < "u") {
    var nf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!nf.isDisabled && nf.supportsFiber)
      try {
        va = nf.inject(
          Jh
        ), be = nf;
      } catch {
      }
  }
  return Yu.createRoot = function(t, e) {
    if (!Nt(t)) throw Error(p(299));
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
    ), t[pl] = e.current, Fc(t), new yo(e);
  }, Yu.hydrateRoot = function(t, e, l) {
    if (!Nt(t)) throw Error(p(299));
    var a = !1, n = "", u = er, i = lr, f = ar, o = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (u = l.onUncaughtError), l.onCaughtError !== void 0 && (i = l.onCaughtError), l.onRecoverableError !== void 0 && (f = l.onRecoverableError), l.formState !== void 0 && (o = l.formState)), e = qd(
      t,
      1,
      !0,
      e,
      l ?? null,
      a,
      n,
      o,
      u,
      i,
      f,
      Jd
    ), e.context = jd(null), l = e.current, a = we(), a = xa(a), n = Il(a), n.callback = null, Pl(l, n, a), l = a, e.current.lanes = l, Sa(e, l), yl(e), t[pl] = e.current, Fc(t), new af(e);
  }, Yu.version = "19.2.3", Yu;
}
var nm;
function a0() {
  if (nm) return vo.exports;
  nm = 1;
  function _() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(_);
      } catch (xt) {
        console.error(xt);
      }
  }
  return _(), vo.exports = l0(), vo.exports;
}
var n0 = a0(), um = To();
function u0(_) {
  const xt = _.assets ?? {}, st = (c, s) => {
    if (typeof c != "string" || c.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${s}`);
    return new URL(c, window.location.href).href;
  }, p = st(xt.diffsModuleURL, "diffsModuleURL"), Nt = st(xt.treesModuleURL, "treesModuleURL"), Lt = st(xt.workerPoolModuleURL, "workerPoolModuleURL"), kt = st(xt.workerModuleURL, "workerModuleURL"), K = _.payload ?? {}, L = K.labels ?? {}, A = document.getElementById("viewer"), at = document.getElementById("status"), V = document.getElementById("toolbar"), gt = document.getElementById("source-select"), ve = document.getElementById("repo-select"), me = document.getElementById("base-select"), It = document.getElementById("source-detail"), At = document.getElementById("jump-select"), ae = document.getElementById("external-link"), pe = document.getElementById("files-toggle"), Ht = document.getElementById("layout-toggle"), Pt = document.getElementById("options-button"), Ft = document.getElementById("options-menu"), te = document.getElementById("files-sidebar"), F = document.getElementById("file-list"), ne = document.getElementById("files-count"), ee = document.getElementById("file-search-toggle"), Ye = document.getElementById("file-collapse-toggle"), Oe = document.getElementById("stats-files"), ue = document.getElementById("stats-added"), il = document.getElementById("stats-deleted"), G = (c) => L[c] ?? c, N = {
    layout: K.layout === "unified" ? "unified" : "split",
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
  let b, U, B;
  const J = [], $ = [], d = /* @__PURE__ */ new Map();
  let z = /* @__PURE__ */ new Set(), C = null, q = null, k = /* @__PURE__ */ new Map(), tt = { value: null }, rt = "", qt = "", _t = !1, Ue = /* @__PURE__ */ new Map(), $e = /* @__PURE__ */ new Map();
  document.title = K.title, va(K.appearance), fl(), Wt(K.sourceOptions ?? []), pl(ve, K.repoOptions ?? [], K.repoRoot ?? "", G("repoPath")), pl(me, K.baseOptions ?? [], K.branchBaseRef ?? "", G("branchBase"));
  const Ka = globalThis.queueMicrotask ?? ((c) => setTimeout(c, 0));
  K.pendingReplacement === !0 ? (ie(K.statusMessage ?? G("loadingDiff"), { pending: !0 }), ff()) : typeof K.statusMessage == "string" && K.statusMessage.length > 0 ? ie(K.statusMessage, { error: K.statusIsError === !0 }) : Ka(() => {
    Gu().catch((c) => {
      console.error("cmux diff viewer render failed", c), ie(G("renderFailed"), { error: !0 });
    });
  });
  async function Gu() {
    ie(G("loadingRenderer"));
    const [
      {
        CodeView: c,
        getFiletypeFromFileName: s,
        parsePatchFiles: g,
        preloadHighlighter: D,
        processFile: j,
        registerCustomTheme: R
      },
      H
    ] = await Promise.all([
      import(p),
      import(Nt).catch((Dt) => (console.warn("cmux diff file tree import failed", Dt), null))
    ]);
    if (Zl(R, K.appearance.themes.light), Zl(R, K.appearance.themes.dark), ie(G("parsingDiff")), ya("loading"), U = await Lu(), Zn(J), xe(), window.__cmuxDiffViewer = { codeView: b, items: J, state: N, workerPool: U }, wn(U), U?.initialize?.()?.then?.(() => ga(U?.getStats?.()))?.catch?.((Dt) => console.warn("cmux diff worker pool initialization failed", Dt)), window.addEventListener("pagehide", () => U?.terminate?.(), { once: !0 }), await cf({
      CodeView: c,
      parsePatchFiles: g,
      processFile: j,
      treesModule: H
    }), J.length === 0)
      throw new Error(G("noFileDiffs"));
    U || $u(K.appearance, $.length > 0 ? $ : J, s, D).catch((Dt) => console.warn("cmux diff highlighter preload failed", Dt));
  }
  function ie(c, s = {}) {
    at.isConnected || A.replaceChildren(at), document.body.dataset.statusOnly = s.pending === !0 || s.error === !0 ? "true" : "false", at.dataset.error = s.error === !0 ? "true" : "false", at.dataset.pending = s.pending === !0 ? "true" : "false", at.textContent = c;
  }
  function qn(c) {
    document.open(), document.write(c), document.close();
  }
  async function jn(c) {
    if (!c.ok)
      return ie(G("renderFailed"), { error: !0 }), !1;
    const s = await c.text();
    return s.includes('data-cmux-diff-pending="true"') ? !1 : (qn(s), !0);
  }
  async function ff() {
    try {
      const c = await fetch("/__cmux_diff_viewer_wait" + location.pathname, { cache: "no-store" });
      await jn(c);
    } catch (c) {
      document.documentElement.dataset.cmuxDiffWait = "failed", ie(G("renderFailed"), { error: !0 }), console.warn("cmux diff viewer deferred load failed", c);
    }
  }
  async function Lu() {
    if (typeof Worker > "u")
      return null;
    try {
      const c = await import(Lt);
      Zl(c.registerCustomTheme, K.appearance.themes.light), Zl(c.registerCustomTheme, K.appearance.themes.dark);
      const s = new URL(kt, window.location.href).href;
      return c.createDiffWorkerPool({
        workerURL: s,
        highlighterOptions: Xu()
      }) ?? null;
    } catch (c) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", c), null;
    }
  }
  function wn(c) {
    if (!c) {
      ya("fallback");
      return;
    }
    ya("enabled"), ga(c.getStats?.());
    const s = c.subscribeToStatChanges?.((g) => {
      ga(g);
    });
    typeof s == "function" && window.addEventListener("pagehide", s, { once: !0 });
  }
  function ya(c) {
    document.body.dataset.workerPool = c;
  }
  function ga(c) {
    !c || typeof c != "object" || (typeof c.managerState == "string" && (document.body.dataset.workerPoolState = c.managerState), Number.isFinite(c.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(c.totalWorkers)), typeof c.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(c.workersFailed)));
  }
  function Xu() {
    return {
      theme: K.appearance.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: N.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const Yn = /^From\s+([a-f0-9]+)\s/im;
  function he(c, s) {
    const g = c?.match(Yn);
    return g?.[1] ? new TextDecoder().decode(new TextEncoder().encode(g[1].slice(0, 5))) : `Commit ${s + 1}`;
  }
  async function cf({ CodeView: c, parsePatchFiles: s, processFile: g, treesModule: D }) {
    const j = ka(), R = {
      dirtyCount: 0,
      lastRefreshAt: 0,
      timeout: 0,
      treesModule: null
    }, H = {
      startedAt: performance.now(),
      completedAt: 0,
      flushCount: 0,
      maxBatchSize: 0,
      treeRefreshCount: 0
    };
    let ct = performance.now(), Dt = performance.now(), vt = !0;
    const Pe = {
      initialBatchSize: Vn(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function tl(M, O) {
      const Z = Fn(j, M, O);
      return Z?.renamedItem && In(Z.renamedItem), Z?.item;
    }
    function Fn(M, O, Z) {
      if (!O)
        return null;
      const I = Vl(O), dt = Z == null ? I : `${Z}/${I}`, mt = I.length === 0 ? void 0 : M.pathStateByTreePath.get(dt), wt = mt == null ? void 0 : Wn(M, dt, mt), ye = rl(O), Ce = {
        id: M.itemIdToFile.has(dt) ? Tl(M, `${dt}?2`) : dt,
        type: "diff",
        fileDiff: O,
        version: 0
      }, ei = M.items.length;
      M.fileIndex += 1, M.items.push(Ce), M.pendingItems.push(Ce), M.pendingItemById.set(Ce.id, Ce), M.itemIdToFile.set(Ce.id, { fileOrder: ei, path: I }), M.itemIdByTreePath.set(dt, Ce.id), M.treePathByItemId.set(Ce.id, dt), M.diffStats.addedLines += ye.added, M.diffStats.deletedLines += ye.deleted, M.diffStats.fileCount += 1, M.diffStats.totalLinesOfCode += O.unifiedLineCount ?? O.splitLineCount ?? 0;
      const bf = M.statsByPath.get(dt);
      return M.statsByPath.set(dt, ye), mt != null && !vf(bf, ye) && (M.pendingStatsChanged = !0), I.length > 0 && (mt == null && M.paths.push(dt), M.pathToItemId.set(dt, Ce.id), Kl(M, dt, O.type, mt?.sawDeleted === !0), M.pathStateByTreePath.set(dt, {
        currentItem: Ce,
        currentItemId: Ce.id,
        currentType: O.type,
        fileOrder: ei,
        sawDeleted: mt?.sawDeleted === !0 || O.type === "deleted"
      })), { item: Ce, renamedItem: wt };
    }
    function Wn(M, O, Z) {
      const I = Z.currentItemId, dt = Z.currentType === "deleted" ? "?deleted" : "?previous", mt = Tl(M, `${O}${dt}`);
      if (Z.currentItem.id = mt, Z.currentItemId = mt, M.itemIdToFile.has(I)) {
        const wt = M.itemIdToFile.get(I);
        M.itemIdToFile.delete(I), M.itemIdToFile.set(mt, wt);
      }
      if (M.treePathByItemId.has(I) && (M.treePathByItemId.delete(I), M.treePathByItemId.set(mt, O)), M.pendingItemById.has(I)) {
        const wt = M.pendingItemById.get(I);
        M.pendingItemById.delete(I), M.pendingItemById.set(mt, wt);
        return;
      }
      return { oldId: I, newId: mt };
    }
    function Tl(M, O) {
      if (!M.itemIdToFile.has(O))
        return O;
      let Z = M.nextCollisionSuffixByBase.get(O) ?? 2, I = `${O}-${Z}`;
      for (; M.itemIdToFile.has(I); )
        Z += 1, I = `${O}-${Z}`;
      return M.nextCollisionSuffixByBase.set(O, Z + 1), I;
    }
    function Kl(M, O, Z, I) {
      if (I && Z !== "deleted") {
        M.gitStatusByPath.delete(O) && $n(M, O);
        return;
      }
      const dt = Jn(Z);
      if (dt === "modified") {
        M.gitStatusByPath.delete(O) && $n(M, O);
        return;
      }
      if (M.gitStatusByPath.get(O)?.status === dt)
        return;
      const wt = { path: O, status: dt };
      M.gitStatusByPath.set(O, wt), M.pendingGitStatusRemovePaths.delete(O), M.pendingGitStatusSetByPath.set(O, wt);
    }
    function $n(M, O) {
      M.pendingGitStatusSetByPath.delete(O), M.pendingGitStatusRemovePaths.add(O);
    }
    function In(M) {
      if (z.delete(M.oldId) && z.add(M.newId), d.has(M.oldId)) {
        const O = d.get(M.oldId);
        d.delete(M.oldId), d.set(M.newId, O);
      }
      yf(M.oldId, M.newId), b?.updateItemId?.(M.oldId, M.newId);
    }
    async function ln(M, O) {
      tl(M, O) && await zl(!1);
    }
    async function zl(M) {
      if (j.pendingItems.length === 0)
        return;
      const O = performance.now();
      if (!M && vt && O - ct >= 8 && j.pendingItems.length < Pe.initialBatchSize && O - Dt < Pe.initialMaxWait) {
        await Vu(), ct = performance.now();
        return;
      }
      const Z = vt ? Pe.initialBatchSize : Pe.incrementalBatchSize, I = vt ? Pe.initialMaxWait : Pe.incrementalMaxWait;
      if (M || j.pendingItems.length >= Z || O - Dt >= I) {
        el(), await Vu(), ct = performance.now();
        return;
      }
    }
    function el() {
      if (j.pendingItems.length === 0)
        return;
      const M = j.pendingItems.splice(0, j.pendingItems.length);
      j.pendingItemById.clear();
      const O = M, Z = $.length > 0;
      J.push(...M);
      for (const I of M)
        d.set(I.id, I);
      if (O.length > 0) {
        $.push(...O);
        for (const I of O)
          z.add(I.id);
        b ? b.addItems(O) : (b = new c(Xl(), U ?? void 0), b.setup(A), b.setItems($), b.render(!0), window.__cmuxDiffViewer.codeView = b);
      }
      Wu(M), Ml(D, !1, M.length), H.flushCount += 1, H.maxBatchSize = Math.max(H.maxBatchSize, M.length), H.fileCount = J.length, H.renderableFileCount = $.length, Ja(H), Dt = performance.now(), vt && (vt = !1, at.remove()), Z || Ge($[0]?.id ?? J[0]?.id ?? ""), window.__cmuxDiffViewer.items = J, window.__cmuxDiffViewer.codeViewItems = $, window.__cmuxDiffViewer.streamMetrics = H;
    }
    function an() {
      b && (b.syncContainerHeight?.(), b.render(!0));
    }
    function Ml(M, O, Z = 1) {
      if (R.treesModule = M, R.dirtyCount += Z, O || R.lastRefreshAt === 0) {
        Le(R.treesModule);
        return;
      }
      const I = performance.now() - R.lastRefreshAt;
      if (R.dirtyCount >= 1e3 || I >= 1e3) {
        Le(R.treesModule);
        return;
      }
      if (R.timeout !== 0)
        return;
      const dt = Math.max(0, 1e3 - I);
      R.timeout = window.setTimeout(() => {
        R.timeout = 0, Le(R.treesModule);
      }, dt);
    }
    function Le(M) {
      R.timeout !== 0 && (window.clearTimeout(R.timeout), R.timeout = 0), R.dirtyCount = 0, R.lastRefreshAt = performance.now(), H.treeRefreshCount += 1, q = of(j), df(q, M), xe(), Ja(H);
    }
    const El = await fetch(K.patchURL, { cache: "no-store" });
    if (!El.ok)
      throw new Error(`${G("loadingDiff")} (${El.status})`);
    if (!El.body?.getReader) {
      const M = await El.text();
      await Gn(M, s, ln), await zl(!0), an(), Ml(D, !0), H.completedAt = performance.now();
      return;
    }
    const Ea = new TextDecoder(), Iu = El.body.getReader(), Aa = "diff --git ", _a = `
` + Aa, Pu = _a.length - 1, ce = /\S/;
    function Xe(M, O) {
      const Z = Math.max(O, 0);
      if (Z === 0 && M.startsWith(Aa))
        return 0;
      const I = M.indexOf(_a, Z);
      return I === -1 ? void 0 : I + 1;
    }
    function Da(M, O) {
      return Math.max(O, M.length - Pu);
    }
    function Oa(M, O, Z) {
      const I = Math.max(O, 0), dt = Math.min(Z, M.length);
      if (I >= dt)
        return;
      let mt = M.lastIndexOf(`
From `, dt - 1);
      for (; mt !== -1; ) {
        const wt = mt + 1;
        if (wt < I)
          return;
        if (wt >= dt) {
          mt = M.lastIndexOf(`
From `, mt - 1);
          continue;
        }
        const ye = M.indexOf(`
`, wt + 1), Ua = M.slice(wt, ye === -1 || ye > dt ? dt : ye);
        if (Yn.test(Ua))
          return wt;
        mt = M.lastIndexOf(`
From `, mt - 1);
      }
    }
    function pf(M) {
      const O = Xe(M, 0);
      if (O == null || O <= 0)
        return;
      const Z = M.slice(0, O);
      return Yn.test(Z) ? Z : void 0;
    }
    async function nn(M) {
      if (M.trim() === "")
        return;
      const O = pf(M);
      O != null && (tu = he(O, ti), ti += 1);
      const Z = `cmux-diff-file-${j.fileIndex}`;
      await ln(g(M, {
        cacheKey: Z,
        isGitDiff: !0
      }), tu);
    }
    function Pn() {
      let M, O = "", Z = 0, I = !1;
      function dt() {
        if (M == null) {
          if (M = Xe(O, Z), M == null)
            return Z = Da(O, 0), null;
          I = !0, Z = M + 1;
        }
        for (; ; ) {
          const mt = M;
          if (mt == null)
            return null;
          const wt = Xe(O, Z);
          if (wt == null)
            return Z = Da(O, mt + 1), null;
          const ye = Oa(O, mt + 1, wt) ?? wt, Ua = O.slice(0, ye);
          if (O = O.slice(ye), M = Xe(O, 0), Z = M == null ? 0 : M + 1, ce.test(Ua))
            return Ua;
        }
      }
      return {
        push(mt) {
          mt.length > 0 && (O += mt);
        },
        takeAvailableFile: dt,
        finish() {
          const mt = dt();
          if (mt != null)
            return { fileText: mt };
          if (!ce.test(O))
            return O = "", {};
          if (!I) {
            const ye = O;
            return O = "", { fallbackPatchContent: ye };
          }
          const wt = O;
          return O = "", { fileText: wt };
        }
      };
    }
    async function Al(M) {
      let O;
      for (; (O = M.takeAvailableFile()) != null; )
        await nn(O);
    }
    const ll = Pn();
    let tu, ti = 0;
    for (; ; ) {
      const { done: M, value: O } = await Iu.read();
      if (M) {
        const Z = Ea.decode();
        Z.length > 0 && (ll.push(Z), await Al(ll));
        break;
      }
      ll.push(Ea.decode(O, { stream: !0 })), await Al(ll);
    }
    const un = ll.finish();
    un.fileText != null ? (await nn(un.fileText), await Al(ll)) : un.fallbackPatchContent != null && await Gn(un.fallbackPatchContent, s, ln), await zl(!0), an(), Ml(D, !0), H.completedAt = performance.now(), Ja(H);
  }
  function Ja(c) {
    document.body.dataset.streamFileCount = String(c.fileCount ?? J.length), document.body.dataset.streamRenderableFileCount = String(c.renderableFileCount ?? $.length), document.body.dataset.streamFlushCount = String(c.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(c.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(c.treeRefreshCount ?? 0), Number.isFinite(c.completedAt) && c.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(c.completedAt - c.startedAt)));
  }
  async function Gn(c, s, g) {
    const D = s(c, "cmux-diff"), j = D.length > 1;
    for (const [R, H] of D.entries()) {
      const ct = j ? he(H.patchMetadata, R) : void 0;
      for (const Dt of H.files ?? [])
        await g(Dt, ct);
    }
  }
  function ka() {
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
  function of(c) {
    const s = c.lastTreeSource, g = Qu(c), D = {
      diffStats: { ...c.diffStats },
      gitStatus: Array.from(c.gitStatusByPath.values()),
      gitStatusPatch: g,
      pathCount: c.paths.length,
      paths: c.paths,
      pathToItemId: c.pathToItemId,
      previousSource: s,
      statsChanged: c.pendingStatsChanged,
      statsByPath: c.statsByPath,
      treePathByItemId: c.treePathByItemId
    };
    return c.pendingStatsChanged = !1, c.lastTreeSource = D, D;
  }
  function Qu(c) {
    if (c.pendingGitStatusRemovePaths.size === 0 && c.pendingGitStatusSetByPath.size === 0)
      return;
    const s = {};
    return c.pendingGitStatusRemovePaths.size > 0 && (s.remove = Array.from(c.pendingGitStatusRemovePaths), c.pendingGitStatusRemovePaths.clear()), c.pendingGitStatusSetByPath.size > 0 && (s.set = Array.from(c.pendingGitStatusSetByPath.values()), c.pendingGitStatusSetByPath.clear()), s;
  }
  function Vu() {
    return new Promise((c) => {
      let s = !1, g = 0;
      const D = () => {
        s || (s = !0, g !== 0 && window.clearTimeout(g), c());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        g = window.setTimeout(D, 50), window.requestAnimationFrame(D);
      else if (typeof MessageChannel < "u") {
        const j = new MessageChannel();
        j.port1.onmessage = D, j.port2.postMessage(void 0);
      } else
        queueMicrotask(D);
    });
  }
  async function sf() {
    return tt.value == null && (tt.value = fetch(K.patchURL, { cache: "no-store" }).then(async (c) => {
      if (!c.ok)
        throw new Error(`${G("loadingDiff")} (${c.status})`);
      return c.text();
    })), tt.value;
  }
  function va(c) {
    const s = document.documentElement.style;
    s.setProperty("--cmux-diff-bg-light", c.themes.light.background), s.setProperty("--cmux-diff-bg-dark", c.themes.dark.background), s.setProperty("--cmux-diff-fg-light", c.themes.light.foreground), s.setProperty("--cmux-diff-fg-dark", c.themes.dark.foreground), s.setProperty("--cmux-diff-selection-bg-light", c.themes.light.selectionBackground), s.setProperty("--cmux-diff-selection-bg-dark", c.themes.dark.selectionBackground), s.setProperty("--cmux-diff-code-font-family", be(c.fontFamily)), s.setProperty("--cmux-diff-font-size", `${c.fontSize}px`), s.setProperty("--cmux-diff-line-height", `${c.lineHeight}px`);
  }
  function be(c) {
    const s = typeof c == "string" && c.trim() !== "" ? c.trim() : "Menlo";
    return `${JSON.stringify(s)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
  }
  function fl() {
    pe.innerHTML = Bt("files"), ee.innerHTML = Bt("search"), Ye.innerHTML = Bt("sidebarCollapse"), Ht.innerHTML = Bt(N.layout), Pt.innerHTML = Bt("dots"), typeof K.externalURL == "string" && K.externalURL.length > 0 && (ae.href = K.externalURL, ae.innerHTML = Bt("external"), ae.hidden = !1), pe.addEventListener("click", () => Pa(!N.filesVisible)), Ye.addEventListener("click", () => Pa(!1)), ee.addEventListener("click", () => Ln(!N.fileSearchOpen)), Ht.addEventListener("click", () => Sa(N.layout === "split" ? "unified" : "split")), Pt.addEventListener("click", () => xa(Ft.hidden)), document.addEventListener("click", (c) => {
      Ft.hidden || V.contains(c.target) || xa(!1);
    }), document.addEventListener("keydown", (c) => {
      c.key === "Escape" && xa(!1);
    }), Se(), xe();
  }
  function Se() {
    const c = K.shortcuts ?? {}, s = pa(c.diffViewerScrollDown), g = pa(c.diffViewerScrollUp), D = pa(c.diffViewerScrollToBottom), j = pa(c.diffViewerScrollToTop), R = pa(c.diffViewerOpenFileSearch);
    let H = null, ct = 0;
    document.addEventListener("keydown", (vt) => {
      if (!(vt.defaultPrevented || vl(vt.target))) {
        if (H && !gl(H.shortcut.second, vt) && Dt(), H && gl(H.shortcut.second, vt)) {
          vt.preventDefault(), H.action(), Dt();
          return;
        }
        if (Fa(s, vt)) {
          vt.preventDefault(), ba(1);
          return;
        }
        if (Fa(g, vt)) {
          vt.preventDefault(), ba(-1);
          return;
        }
        if (Fa(D, vt)) {
          vt.preventDefault(), A.scrollTo({ top: A.scrollHeight, behavior: "auto" });
          return;
        }
        if (Fa(R, vt) && B) {
          vt.preventDefault(), Pa(!0), Ln(!0);
          return;
        }
        Wa(j, vt) && (vt.preventDefault(), H = {
          shortcut: j,
          action: () => A.scrollTo({ top: 0, behavior: "auto" })
        }, ct = setTimeout(Dt, 700));
      }
    });
    function Dt() {
      H = null, ct !== 0 && (clearTimeout(ct), ct = 0);
    }
  }
  function pa(c) {
    return !c || c.unbound === !0 || !c.first ? null : {
      first: Zu(c.first),
      second: c.second ? Zu(c.second) : null
    };
  }
  function Zu(c) {
    return {
      key: String(c?.key ?? "").toLowerCase(),
      command: c?.command === !0,
      shift: c?.shift === !0,
      option: c?.option === !0,
      control: c?.control === !0
    };
  }
  function Fa(c, s) {
    return c && !c.second && gl(c.first, s);
  }
  function Wa(c, s) {
    return c && c.second && gl(c.first, s);
  }
  function gl(c, s) {
    return !c || s.metaKey !== c.command || s.ctrlKey !== c.control || s.altKey !== c.option || s.shiftKey !== c.shift ? !1 : $a(s) === c.key;
  }
  function $a(c) {
    return c.code === "Space" ? "space" : typeof c.key != "string" || c.key.length === 0 ? "" : (c.key.length === 1, c.key.toLowerCase());
  }
  function vl(c) {
    const s = c instanceof Element ? c : null;
    return s ? !!s.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function ba(c) {
    const s = Math.max(80, Math.floor(A.clientHeight * 0.38));
    A.scrollBy({ top: c * s, behavior: "auto" });
  }
  function Xl() {
    return {
      layout: { paddingTop: 0, gap: 1, paddingBottom: 0 },
      diffStyle: N.layout,
      diffIndicators: N.diffIndicators,
      overflow: N.wordWrap ? "wrap" : "scroll",
      expandUnchanged: N.expandUnchanged,
      disableBackground: !N.showBackgrounds,
      disableLineNumbers: !N.lineNumbers,
      lineHoverHighlight: "number",
      enableLineSelection: !0,
      enableGutterUtility: !0,
      lineDiffType: N.wordDiffs ? "word" : "none",
      stickyHeaders: !0,
      unsafeCSS: rf(),
      theme: K.appearance.theme,
      themeType: "system"
    };
  }
  function rf() {
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
  function cl() {
    const c = Xl();
    if (!b) {
      Ia();
      return;
    }
    b.setOptions(c), Ia(), b.render(!0);
  }
  function Ia() {
    U?.setRenderOptions && U.setRenderOptions(Xu()).then(() => b?.render(!0)).catch((c) => console.warn("cmux diff worker render options update failed", c));
  }
  function Sa(c) {
    N.layout = c === "unified" ? "unified" : "split", xe(), cl();
  }
  function Pa(c) {
    N.filesVisible = c, document.body.dataset.filesHidden = c ? "false" : "true", te.setAttribute("aria-hidden", String(!c)), c ? te.removeAttribute("inert") : te.setAttribute("inert", ""), xe();
  }
  function Ln(c) {
    N.fileSearchOpen = !!c, B && (N.fileSearchOpen ? B.openSearch("") : B.closeSearch()), xe();
  }
  function Ku(c) {
    N.collapsed = c;
    const s = $.map((j) => ({
      ...j,
      collapsed: c,
      version: (j.version ?? 0) + 1
    })), g = new Map(s.map((j) => [j.id, j])), D = J.map((j) => g.get(j.id) ?? {
      ...j,
      collapsed: c,
      version: (j.version ?? 0) + 1
    });
    $.splice(0, $.length, ...s), J.splice(0, J.length, ...D), b && (b.setItems($), b.render(!0)), xe();
  }
  function xe() {
    pe.setAttribute("aria-pressed", String(N.filesVisible)), pe.title = N.filesVisible ? G("hideFiles") : G("showFiles"), pe.setAttribute("aria-label", pe.title), Ye.title = G("hideFiles"), Ye.setAttribute("aria-label", Ye.title), Ht.innerHTML = Bt(N.layout), Ht.title = N.layout === "split" ? G("switchToUnifiedDiff") : G("switchToSplitDiff"), Ht.setAttribute("aria-label", Ht.title), Pt.setAttribute("aria-expanded", String(!Ft.hidden)), document.documentElement.dataset.layout = N.layout, document.documentElement.dataset.wordWrap = String(N.wordWrap), document.documentElement.dataset.diffIndicators = N.diffIndicators, ee.disabled = !B, ee.setAttribute("aria-pressed", String(N.fileSearchOpen)), ee.title = N.fileSearchOpen ? G("hideFileSearch") : G("showFileSearch"), ee.setAttribute("aria-label", ee.title);
  }
  function xa(c) {
    c && Ta(), Ft.hidden = !c, xe();
  }
  function Ta() {
    Ft.textContent = "";
    const c = [
      { label: G("refresh"), icon: "refresh", action: () => window.location.reload() },
      { label: N.wordWrap ? G("disableWordWrap") : G("enableWordWrap"), icon: "wrap", checked: N.wordWrap, action: () => {
        N.wordWrap = !N.wordWrap, cl();
      } },
      { label: N.collapsed ? G("expandAllDiffs") : G("collapseAllDiffs"), icon: "collapse", checked: N.collapsed, action: () => Ku(!N.collapsed) },
      "separator",
      { label: N.filesVisible ? G("hideFiles") : G("showFiles"), icon: "files", checked: N.filesVisible, action: () => Pa(!N.filesVisible) },
      { label: N.expandUnchanged ? G("collapseUnchangedContext") : G("expandUnchangedContext"), icon: "document", checked: N.expandUnchanged, action: () => {
        N.expandUnchanged = !N.expandUnchanged, cl();
      } },
      { label: N.showBackgrounds ? G("hideBackgrounds") : G("showBackgrounds"), icon: "background", checked: N.showBackgrounds, action: () => {
        N.showBackgrounds = !N.showBackgrounds, cl();
      } },
      { label: N.lineNumbers ? G("hideLineNumbers") : G("showLineNumbers"), icon: "numbers", checked: N.lineNumbers, action: () => {
        N.lineNumbers = !N.lineNumbers, cl();
      } },
      { label: N.wordDiffs ? G("disableWordDiffs") : G("enableWordDiffs"), icon: "word", checked: N.wordDiffs, action: () => {
        N.wordDiffs = !N.wordDiffs, cl();
      } },
      { kind: "segment", label: G("indicatorStyle"), icon: "bars", options: [
        { value: "bars", icon: "bars", label: G("bars") },
        { value: "classic", icon: "classic", label: G("classic") },
        { value: "none", icon: "eye", label: G("none") }
      ] },
      "separator",
      { label: G("copyGitApplyCommand"), icon: "clipboard", action: ku }
    ];
    for (const s of c) {
      if (s === "separator") {
        const D = document.createElement("div");
        D.className = "menu-separator", Ft.append(D);
        continue;
      }
      if (s.kind === "segment") {
        const D = document.createElement("div");
        D.className = "menu-item menu-segment", D.setAttribute("role", "presentation"), D.innerHTML = `${Bt(s.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`, D.querySelector(".menu-label").textContent = s.label;
        const j = D.querySelector(".menu-segment-controls");
        for (const R of s.options) {
          const H = document.createElement("button");
          H.type = "button", H.className = "segment-button", H.title = R.label, H.setAttribute("aria-label", R.label), H.setAttribute("aria-pressed", String(N.diffIndicators === R.value)), H.innerHTML = Bt(R.icon), H.addEventListener("click", () => {
            N.diffIndicators = R.value, cl(), Ta(), xe();
          }), j.append(H);
        }
        Ft.append(D);
        continue;
      }
      const g = document.createElement("button");
      g.type = "button", g.className = "menu-item", g.setAttribute("role", s.checked == null ? "menuitem" : "menuitemcheckbox"), s.checked != null && g.setAttribute("aria-checked", String(!!s.checked)), g.disabled = !!s.disabled, g.innerHTML = `${Bt(s.icon)}<span class="menu-label"></span><span class="menu-check">${s.checked ? Bt("check") : ""}</span>`, g.querySelector(".menu-label").textContent = s.label, g.addEventListener("click", () => {
        g.disabled || (s.action?.(), Ta(), xe());
      }), Ft.append(g);
    }
  }
  function Ju(c) {
    const s = new Set(c.split(/\r?\n/));
    let g = "CMUX_DIFF_PATCH", D = 0;
    for (; s.has(g); )
      D += 1, g = `CMUX_DIFF_PATCH_${D}`;
    return g;
  }
  async function ku() {
    const s = await sf(), g = s.endsWith(`
`) ? s : `${s}
`, D = Ju(g), j = `git apply <<'${D}'
${g}${D}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(j);
      } catch {
        Ie(j);
      }
    else
      Ie(j);
    Pt.title = G("copiedGitApplyCommand"), Pt.setAttribute("aria-label", G("copiedGitApplyCommand"));
  }
  function Ie(c) {
    const s = document.createElement("textarea");
    s.value = c, s.setAttribute("readonly", ""), s.style.position = "fixed", s.style.left = "-9999px", document.body.append(s), s.select(), document.execCommand("copy"), s.remove();
  }
  function Wt(c) {
    if (It.textContent = fe(), !Array.isArray(c) || c.length < 2)
      return;
    gt.textContent = "";
    const s = c.find((g) => g.selected) ?? c.find((g) => !g.disabled);
    for (const g of c) {
      const D = document.createElement("option");
      D.value = g.value, D.textContent = g.label, D.disabled = g.disabled || !g.url, D.selected = g.value === s?.value, g.message && (D.title = g.message), gt.append(D);
    }
    It.textContent = s?.sourceLabel ?? fe(), gt.hidden = !1, gt.addEventListener("change", () => {
      const g = c.find((D) => D.value === gt.value);
      if (!g?.url) {
        gt.value = s?.value ?? "";
        return;
      }
      ie(G("loadingDiff"), { pending: !0 }), window.location.href = g.url;
    });
  }
  function fe() {
    return [K.sourceLabel, K.repoRoot, K.branchBaseRef].filter((s) => typeof s == "string" && s.trim() !== "").join(" | ");
  }
  function pl(c, s, g, D) {
    if (!c || !Array.isArray(s) || s.length < 2)
      return;
    c.textContent = "";
    const j = s.find((R) => R.selected) ?? s.find((R) => !R.disabled);
    for (const R of s) {
      const H = document.createElement("option");
      H.value = R.value, H.textContent = R.label, H.disabled = R.disabled || !R.url, H.selected = R.value === j?.value, R.message && (H.title = R.message), c.append(H);
    }
    c.hidden = !1, c.title = D, c.addEventListener("change", () => {
      const R = s.find((H) => H.value === c.value);
      if (!R?.url) {
        c.value = j?.value ?? g ?? "";
        return;
      }
      ie(G("loadingDiff"), { pending: !0 }), window.location.href = R.url;
    });
  }
  function Xn(c, s) {
    const g = tn(c), D = za(s);
    if (jt(c, []), B && (B.cleanUp?.(), B = null), C = null, N.fileSearchOpen = !1, F.textContent = "", ne.textContent = `${g}`, xl(c), D)
      try {
        mf(c, s), xe();
        return;
      } catch (R) {
        console.warn("cmux diff file tree setup failed", R);
      }
    const j = ol(c);
    jt(c, j), Qn(j), xe();
  }
  function df(c, s) {
    const g = tn(c);
    if (jt(c, []), ne.textContent = `${g}`, xl(c), B && F.dataset.treeMode === "pierre" && s?.preparePresortedFileTreeInput) {
      Fu(c, s);
      return;
    }
    if (B || F.childElementCount === 0) {
      Xn(c, s);
      return;
    }
    const D = ol(c);
    jt(c, D), F.textContent = "", Qn(D);
  }
  function mf(c, s) {
    const { FileTree: g, preparePresortedFileTreeInput: D } = s, j = sl(c);
    C = c;
    const R = j[0];
    bl(c), F.dataset.treeMode = "pierre", B = new g({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: R ? [R] : [],
      initialVisibleRowCount: Vn(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: D(j),
      presorted: !0,
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: c.gitStatus,
      renderRowDecoration(H) {
        if (H.item.kind !== "file")
          return null;
        const ct = k.get(H.item.path);
        return ct == null || ct.added === 0 && ct.deleted === 0 ? null : {
          text: `+${ct.added} -${ct.deleted}`,
          title: `${ct.added} ${G("additions")}, ${ct.deleted} ${G("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Sl(),
      onSelectionChange(H) {
        if (_t)
          return;
        const ct = H[H.length - 1], Dt = Ue.get(ct);
        Dt && Ql(Dt);
      }
    }), B.render({ containerWrapper: F });
  }
  function Fu(c, s) {
    const g = C, D = sl(c);
    C = c, bl(c);
    let j = !1;
    if (g && (c.previousSource === g || Ma(g, c)) && c.pathCount >= g.pathCount) {
      const R = c.paths.slice(g.pathCount, c.pathCount);
      if (R.length > 0)
        try {
          B.batch(R.map((H) => ({ type: "add", path: H })));
        } catch (H) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", H), B.resetPaths(D, {
            preparedInput: s.preparePresortedFileTreeInput(D)
          }), j = !0;
        }
    } else
      B.resetPaths(D, {
        preparedInput: s.preparePresortedFileTreeInput(D)
      }), j = !0;
    c.gitStatusPatch ? typeof B.applyGitStatusPatch == "function" ? B.applyGitStatusPatch(c.gitStatusPatch) : B.setGitStatus(c.gitStatus) : (j || c.statsChanged === !0) && B.setGitStatus(c.gitStatus);
  }
  function za(c) {
    return !!(c?.FileTree && c?.preparePresortedFileTreeInput);
  }
  function tn(c) {
    return c?.pathCount ?? c?.entries?.length ?? 0;
  }
  function ol(c) {
    const s = c?.pathCount ?? c?.entries?.length ?? 0, g = c?.entries ?? [];
    if (g.length > 0)
      return g.length === s ? g : g.slice(0, s);
    const D = sl(c), j = c?.pathToItemId, R = c?.statsByPath;
    return D.map((H) => {
      const ct = j instanceof Map ? j.get(H) : void 0, Dt = ct ? d.get(ct) : void 0, vt = Dt?.fileDiff ?? {};
      return {
        item: Dt ?? { id: ct ?? H, fileDiff: vt },
        path: H,
        status: Kn(vt),
        stats: R instanceof Map ? R.get(H) ?? rl(vt) : rl(vt)
      };
    });
  }
  function sl(c) {
    const s = c?.pathCount ?? c?.paths?.length ?? 0, g = c?.paths ?? [];
    return g.length === s ? g : g.slice(0, s);
  }
  function Ma(c, s) {
    const g = c?.paths, D = s?.paths, j = c?.pathCount ?? g?.length ?? 0, R = s?.pathCount ?? D?.length ?? 0;
    if (!Array.isArray(g) || !Array.isArray(D) || j > R)
      return !1;
    for (let H = 0; H < j; H += 1)
      if (g[H] !== D[H])
        return !1;
    return !0;
  }
  function bl(c) {
    if (c?.statsByPath instanceof Map) {
      k = c.statsByPath;
      return;
    }
    k = /* @__PURE__ */ new Map();
    const s = ol(c);
    for (const g of s)
      k.set(g.path, g.stats);
  }
  function jt(c, s) {
    if (c?.pathToItemId instanceof Map && c?.treePathByItemId instanceof Map)
      Ue = c.pathToItemId, $e = c.treePathByItemId;
    else if (c?.pathToItemId instanceof Map) {
      Ue = c.pathToItemId, $e = /* @__PURE__ */ new Map();
      for (const [g, D] of Ue)
        $e.set(D, g);
    } else {
      Ue = /* @__PURE__ */ new Map(), $e = /* @__PURE__ */ new Map();
      for (const g of s) {
        const D = g.item?.id;
        D && (Ue.set(g.path, D), $e.set(D, g.path));
      }
    }
    qt && !Ue.has(qt) && (qt = "");
  }
  function Qn(c) {
    delete F.dataset.treeMode;
    for (const s of c) {
      const g = s.item, D = g.fileDiff ?? {}, j = s.stats ?? rl(D), R = document.createElement("button");
      R.type = "button", R.className = "file-entry", R.dataset.itemId = g.id, R.title = Vl(D), R.innerHTML = `
      <span class="file-status">${gf(D)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${j.added}</span>
        <span class="stat-del">-${j.deleted}</span>
      </span>
    `, R.querySelector(".file-name").textContent = Vl(D), R.addEventListener("click", () => Ql(g.id)), F.append(R);
    }
  }
  function Vn() {
    const c = window.visualViewport?.height ?? window.innerHeight;
    return !Number.isFinite(c) || c <= 0 ? 25 : Math.min(96, Math.max(25, Math.ceil(c / 24)));
  }
  function Sl() {
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
  function xl(c) {
    const s = c?.diffStats;
    if (s && Number.isFinite(s.addedLines) && Number.isFinite(s.deletedLines) && Number.isFinite(s.fileCount)) {
      Oe.textContent = `${s.fileCount}`, ue.textContent = `+${s.addedLines}`, il.textContent = `-${s.deletedLines}`;
      return;
    }
    hf(c?.entries ?? []);
  }
  function hf(c) {
    const s = c.reduce((g, D) => {
      const j = D.stats ?? rl(D.item?.fileDiff ?? {});
      return g.added += j.added, g.deleted += j.deleted, g;
    }, { added: 0, deleted: 0 });
    Oe.textContent = `${c.length}`, ue.textContent = `+${s.added}`, il.textContent = `-${s.deleted}`;
  }
  function Zn(c) {
    At.textContent = "";
    const s = document.createElement("option");
    s.value = "", s.textContent = G("jumpToFile"), At.append(s), At.dataset.initialized = "true";
    for (const g of c) {
      const D = document.createElement("option");
      D.value = g.id, D.textContent = Vl(g.fileDiff ?? {}), At.append(D);
    }
    At.hidden = c.length === 0, At.onchange = () => {
      At.value && Ql(At.value);
    };
  }
  function Wu(c) {
    if (c.length === 0)
      return;
    At.dataset.initialized !== "true" && Zn([]);
    const s = document.createDocumentFragment();
    for (const g of c) {
      const D = document.createElement("option");
      D.value = g.id, D.textContent = Vl(g.fileDiff ?? {}), s.append(D);
    }
    At.append(s), At.hidden = !1;
  }
  function yf(c, s) {
    if (At.dataset.initialized === "true") {
      for (const g of At.options)
        if (g.value === c) {
          g.value = s;
          return;
        }
    }
  }
  function Ql(c) {
    if (!b)
      return;
    const s = en(c);
    s && (b.scrollTo({ type: "item", id: s, align: "start", behavior: "smooth-auto" }), Ge(s));
  }
  function en(c) {
    if (z.has(c))
      return c;
    const s = J.findIndex((g) => g.id === c);
    if (s === -1)
      return $[0]?.id ?? "";
    for (let g = s + 1; g < J.length; g += 1)
      if (z.has(J[g].id))
        return J[g].id;
    for (let g = s - 1; g >= 0; g -= 1)
      if (z.has(J[g].id))
        return J[g].id;
    return "";
  }
  function Ge(c) {
    if (!(!c || rt === c)) {
      rt = c, ze(c);
      for (const s of F.querySelectorAll(".file-entry"))
        s.setAttribute("aria-current", s.dataset.itemId === c ? "true" : "false");
      At.value !== c && (At.value = c);
    }
  }
  function ze(c) {
    if (!B)
      return;
    const s = $e.get(c);
    if (!(!s || s === qt)) {
      _t = !0;
      try {
        qt && B.getItem(qt)?.deselect(), B.getItem(s)?.select(), B.scrollToPath(s, { focus: !1, offset: "nearest" }), qt = s;
      } finally {
        Ka(() => {
          _t = !1;
        });
      }
    }
  }
  function Vl(c) {
    return c.name ?? c.newName ?? c.oldName ?? c.prevName ?? G("untitled");
  }
  function gf(c) {
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
  function Kn(c) {
    return Jn(c.type);
  }
  function Jn(c) {
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
    const s = { added: 0, deleted: 0 };
    for (const g of c.hunks ?? [])
      s.added += g.additionLines ?? 0, s.deleted += g.deletionLines ?? 0;
    return s;
  }
  function vf(c, s) {
    return c?.added === s.added && c?.deleted === s.deleted;
  }
  function Bt(c) {
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
  function Zl(c, s) {
    c(s.name, () => Promise.resolve(kn(s)));
  }
  function $u(c, s, g, D) {
    const j = Array.from(new Set([
      c.theme?.light,
      c.theme?.dark
    ].filter(Boolean))), R = Array.from(new Set(s.flatMap((H) => {
      const ct = H.fileDiff ?? {}, Dt = ct.name ?? ct.newName ?? ct.oldName ?? ct.prevName ?? "", vt = ct.lang ?? g(Dt) ?? "text";
      return vt ? [vt] : [];
    })));
    return D({
      themes: j,
      langs: R.length > 0 ? R : ["text"]
    });
  }
  function kn(c) {
    const s = c.palette ?? {}, g = c.foreground, D = c.background;
    return {
      name: c.name,
      displayName: c.ghosttyName,
      type: c.type,
      colors: {
        "editor.background": D,
        "editor.foreground": g,
        "terminal.background": D,
        "terminal.foreground": g,
        "terminal.ansiBlack": s[0] ?? g,
        "terminal.ansiRed": s[1] ?? g,
        "terminal.ansiGreen": s[2] ?? g,
        "terminal.ansiYellow": s[3] ?? g,
        "terminal.ansiBlue": s[4] ?? g,
        "terminal.ansiMagenta": s[5] ?? g,
        "terminal.ansiCyan": s[6] ?? g,
        "terminal.ansiWhite": s[7] ?? g,
        "terminal.ansiBrightBlack": s[8] ?? g,
        "terminal.ansiBrightRed": s[9] ?? s[1] ?? g,
        "terminal.ansiBrightGreen": s[10] ?? s[2] ?? g,
        "terminal.ansiBrightYellow": s[11] ?? s[3] ?? g,
        "terminal.ansiBrightBlue": s[12] ?? s[4] ?? g,
        "terminal.ansiBrightMagenta": s[13] ?? s[5] ?? g,
        "terminal.ansiBrightCyan": s[14] ?? s[6] ?? g,
        "terminal.ansiBrightWhite": s[15] ?? g,
        "gitDecoration.addedResourceForeground": s[10] ?? s[2] ?? "#32d74b",
        "gitDecoration.deletedResourceForeground": s[9] ?? s[1] ?? "#ff453a",
        "gitDecoration.modifiedResourceForeground": s[12] ?? s[4] ?? "#0a84ff",
        "editor.selectionBackground": c.selectionBackground,
        "editor.selectionForeground": c.selectionForeground
      },
      tokenColors: [
        { settings: { foreground: g, background: D } },
        { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: s[8] ?? g, fontStyle: "italic" } },
        { scope: ["string", "constant.other.symbol"], settings: { foreground: s[2] ?? g } },
        { scope: ["constant.numeric", "constant.language", "support.constant"], settings: { foreground: s[3] ?? g } },
        { scope: ["keyword", "storage", "storage.type"], settings: { foreground: s[5] ?? g } },
        { scope: ["entity.name.function", "support.function"], settings: { foreground: s[4] ?? g } },
        { scope: ["entity.name.type", "entity.name.class", "support.type"], settings: { foreground: s[6] ?? g } },
        { scope: ["variable", "meta.definition.variable"], settings: { foreground: g } },
        { scope: ["invalid", "message.error"], settings: { foreground: s[9] ?? s[1] ?? g } }
      ]
    };
  }
}
function Ct(_, xt) {
  return _.payload?.labels?.[xt] ?? xt;
}
function i0({ config: _ }) {
  return /* @__PURE__ */ lt.jsxs("div", { className: "toolbar-left", children: [
    /* @__PURE__ */ lt.jsx("select", { id: "source-select", "aria-label": Ct(_, "diffTarget"), hidden: !0 }),
    /* @__PURE__ */ lt.jsx("select", { id: "repo-select", "aria-label": Ct(_, "repoPath"), hidden: !0 }),
    /* @__PURE__ */ lt.jsx("select", { id: "base-select", "aria-label": Ct(_, "branchBase"), hidden: !0 }),
    /* @__PURE__ */ lt.jsx("span", { id: "source-detail" })
  ] });
}
function f0({ config: _ }) {
  return /* @__PURE__ */ lt.jsxs("header", { id: "toolbar", children: [
    /* @__PURE__ */ lt.jsx(i0, { config: _ }),
    /* @__PURE__ */ lt.jsx("div", { className: "toolbar-middle", children: /* @__PURE__ */ lt.jsx("select", { id: "jump-select", "aria-label": Ct(_, "jumpToFile"), hidden: !0 }) }),
    /* @__PURE__ */ lt.jsxs("div", { className: "toolbar-actions", children: [
      /* @__PURE__ */ lt.jsx(
        "a",
        {
          id: "external-link",
          className: "toolbar-icon",
          href: _.payload?.externalURL ?? "#",
          target: "_blank",
          rel: "noreferrer",
          title: Ct(_, "openSourceURL"),
          "aria-label": Ct(_, "openSourceURL"),
          hidden: !0
        }
      ),
      /* @__PURE__ */ lt.jsx(
        "button",
        {
          id: "files-toggle",
          className: "toolbar-icon",
          type: "button",
          title: Ct(_, "hideFiles"),
          "aria-label": Ct(_, "hideFiles"),
          "aria-pressed": "true"
        }
      ),
      /* @__PURE__ */ lt.jsx(
        "button",
        {
          id: "layout-toggle",
          className: "toolbar-icon",
          type: "button",
          title: Ct(_, "switchToUnifiedDiff"),
          "aria-label": Ct(_, "switchToUnifiedDiff")
        }
      ),
      /* @__PURE__ */ lt.jsx(
        "button",
        {
          id: "options-button",
          className: "toolbar-icon",
          type: "button",
          title: Ct(_, "options"),
          "aria-label": Ct(_, "options"),
          "aria-expanded": "false",
          "aria-haspopup": "menu"
        }
      )
    ] }),
    /* @__PURE__ */ lt.jsx("div", { id: "options-menu", role: "menu", "aria-label": Ct(_, "options"), hidden: !0 })
  ] });
}
function c0({ config: _ }) {
  return /* @__PURE__ */ lt.jsxs("aside", { id: "files-sidebar", "aria-label": Ct(_, "changedFiles"), children: [
    /* @__PURE__ */ lt.jsxs("div", { id: "files-header", children: [
      /* @__PURE__ */ lt.jsxs("span", { id: "files-title", children: [
        /* @__PURE__ */ lt.jsx("span", { children: Ct(_, "files") }),
        /* @__PURE__ */ lt.jsx("span", { id: "files-count" })
      ] }),
      /* @__PURE__ */ lt.jsxs("span", { id: "files-header-actions", children: [
        /* @__PURE__ */ lt.jsx(
          "button",
          {
            id: "file-search-toggle",
            type: "button",
            title: Ct(_, "showFileSearch"),
            "aria-label": Ct(_, "showFileSearch"),
            "aria-pressed": "false"
          }
        ),
        /* @__PURE__ */ lt.jsx(
          "button",
          {
            id: "file-collapse-toggle",
            type: "button",
            title: Ct(_, "hideFiles"),
            "aria-label": Ct(_, "hideFiles")
          }
        )
      ] })
    ] }),
    /* @__PURE__ */ lt.jsx("div", { id: "file-list" }),
    /* @__PURE__ */ lt.jsxs("div", { id: "files-footer", "aria-label": Ct(_, "diffStats"), children: [
      /* @__PURE__ */ lt.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ lt.jsx("span", { children: Ct(_, "files") }),
        /* @__PURE__ */ lt.jsx("strong", { id: "stats-files", children: "0" })
      ] }),
      /* @__PURE__ */ lt.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ lt.jsx("span", { children: Ct(_, "additions") }),
        /* @__PURE__ */ lt.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" })
      ] }),
      /* @__PURE__ */ lt.jsxs("div", { className: "stats-row", children: [
        /* @__PURE__ */ lt.jsx("span", { children: Ct(_, "deletions") }),
        /* @__PURE__ */ lt.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" })
      ] })
    ] })
  ] });
}
function o0({ config: _ }) {
  const xt = um.useRef(!1), st = um.useCallback((p) => {
    !p || xt.current || (xt.current = !0, queueMicrotask(() => u0(_)));
  }, [_]);
  return /* @__PURE__ */ lt.jsxs("div", { id: "app", ref: st, children: [
    /* @__PURE__ */ lt.jsx(f0, { config: _ }),
    /* @__PURE__ */ lt.jsxs("section", { id: "content", children: [
      /* @__PURE__ */ lt.jsx(c0, { config: _ }),
      /* @__PURE__ */ lt.jsx("main", { id: "viewer", "aria-label": Ct(_, "diffViewer"), children: /* @__PURE__ */ lt.jsx("div", { id: "status", children: _.payload?.statusMessage ?? Ct(_, "loadingDiff") }) })
    ] })
  ] });
}
const s0 = ':root{color-scheme:light dark;--cmux-diff-bg-light: #fff;--cmux-diff-bg-dark: #000;--cmux-diff-fg-light: #000;--cmux-diff-fg-dark: #fff;--cmux-diff-selection-bg-light: #abd8ff;--cmux-diff-selection-bg-dark: #3f638b;--cmux-diff-ui-font-family: system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size: 12px;--cmux-diff-ui-line-height: 16px;--cmux-diff-code-font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size: 10px;--cmux-diff-line-height: 20px;--cmux-diff-bg: var(--cmux-diff-bg-light);--cmux-diff-fg: var(--cmux-diff-fg-light);--cmux-diff-border: color-mix(in lab, var(--cmux-diff-fg) 12%, transparent);--cmux-diff-sidebar-bg: color-mix(in lab, var(--cmux-diff-bg) 98%, var(--cmux-diff-fg));--cmux-diff-muted-bg: color-mix(in lab, var(--cmux-diff-fg) 8%, transparent);--cmux-diff-hover-bg: color-mix(in lab, var(--cmux-diff-fg) 10%, transparent);--cmux-diff-accent: light-dark(#0a84ff, #7ab7ff);background:var(--cmux-diff-bg);color:var(--cmux-diff-fg)}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg: var(--cmux-diff-bg-dark);--cmux-diff-fg: var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{height:100%;overflow:hidden}body{margin:0;height:100vh;min-height:0;background:var(--cmux-diff-bg);color:var(--cmux-diff-fg);display:flex;flex-direction:column;overflow:hidden;font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height)}#app{height:100vh;min-height:0;display:grid;grid-template-rows:auto minmax(0,1fr);overflow:hidden;overscroll-behavior:contain;contain:strict;background:inherit;color:inherit}#toolbar{position:relative;flex:0 0 auto;display:flex;align-items:center;gap:7px;min-height:32px;padding:3px 8px;border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent);background:color-mix(in lab,var(--cmux-diff-bg) 98%,var(--cmux-diff-fg));color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg));z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{display:flex;align-items:center;gap:6px;min-width:0}.toolbar-left{flex:0 1 36%}.toolbar-middle{flex:1 1 auto;justify-content:center}.toolbar-actions{flex:0 0 auto}#source-select,#repo-select,#base-select,#jump-select{appearance:none;height:24px;min-width:118px;max-width:min(30vw,320px);padding:0 24px 0 9px;border:1px solid transparent;border-radius:6px;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent);color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent);background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent);outline-offset:1px}#source-detail{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}.toolbar-icon{width:28px;height:26px;display:inline-flex;align-items:center;justify-content:center;border:1px solid transparent;border-radius:6px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg));padding:0;cursor:pointer}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent);background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent);color:var(--cmux-diff-fg)}.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{width:16px;height:16px;display:block;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{position:absolute;top:calc(100% + 7px);right:10px;min-width:246px;padding:8px;border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent);border-radius:8px;background:color-mix(in lab,var(--cmux-diff-bg) 94%,var(--cmux-diff-fg));box-shadow:0 16px 34px color-mix(in lab,#000 28%,transparent);z-index:100}#options-menu[hidden]{display:none}.menu-separator{height:1px;margin:7px 6px;background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}.menu-item{width:100%;min-height:31px;display:grid;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;border:0;border-radius:6px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg));font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent);color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:transparent}.menu-segment-controls{display:inline-flex;align-items:center;gap:2px;justify-self:end;padding:2px;border-radius:7px;background:color-mix(in lab,var(--cmux-diff-bg) 82%,var(--cmux-diff-fg))}.segment-button{width:27px;height:24px;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:5px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg));padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent);color:var(--cmux-diff-fg)}.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}.menu-label{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.menu-check{justify-self:end}#content{--cmux-diff-files-width: clamp(190px, 22vw, 252px);position:relative;flex:1 1 auto;min-height:0;min-width:0;display:grid;grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";overflow:hidden;overscroll-behavior:contain;contain:strict;background:inherit}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}#files-sidebar{grid-area:files;position:relative;width:100%;height:100%;min-height:0;min-width:0;display:flex;flex-direction:column;overflow:hidden;border-left:1px solid var(--cmux-diff-border);background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg));contain:strict;opacity:1;transition:opacity .1s ease,visibility 0s linear 0s}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s ease,visibility 0s linear .1s}#files-header{position:relative;z-index:1;display:flex;align-items:center;justify-content:space-between;min-height:30px;gap:8px;padding:0 7px 0 10px;border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent);background:color-mix(in lab,var(--cmux-diff-bg) 99%,var(--cmux-diff-fg));color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}#files-title{display:inline-flex;align-items:center;gap:6px;min-width:0}#files-header-actions{display:inline-flex;align-items:center;gap:2px;flex:0 0 auto}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;flex:0 0 auto;display:inline-flex;align-items:center;justify-content:center;border:0;border-radius:5px;background:transparent;color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg));padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{width:15px;height:15px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round}#file-list{flex:1 1 auto;min-height:0;overflow:hidden;padding:6px 4px 6px 6px;--trees-bg-override: var(--cmux-diff-sidebar-bg);--trees-fg-override: color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg));--trees-fg-muted-override: color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg));--trees-bg-muted-override: var(--cmux-diff-hover-bg);--trees-selected-bg-override: color-mix(in lab, var(--cmux-diff-fg) 11%, transparent);--trees-selected-fg-override: var(--cmux-diff-fg);--trees-selected-focused-border-color-override: transparent;--trees-border-color-override: var(--cmux-diff-border);--trees-focus-ring-color-override: color-mix(in lab, var(--cmux-diff-accent) 72%, transparent);--trees-font-family-override: var(--cmux-diff-ui-font-family);--trees-font-size-override: var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override: 500;--trees-density-override: .78;--trees-border-radius-override: 5px;--trees-item-padding-x-override: 7px;--trees-item-margin-x-override: 0;--trees-padding-inline-override: 0;--trees-search-bg-override: color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg));--trees-status-added-override: light-dark(#257a3e, #8fd88f);--trees-status-modified-override: var(--cmux-diff-accent);--trees-status-renamed-override: light-dark(#a26300, #ffd166);--trees-status-deleted-override: light-dark(#b42318, #ff8a80)}#file-list file-tree-container{width:100%;height:100%}#files-footer{flex:0 0 auto;padding:7px 10px 8px;border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent);background:color-mix(in lab,var(--cmux-diff-bg) 97%,var(--cmux-diff-fg))}.stats-row{display:flex;align-items:center;justify-content:space-between;gap:10px;min-height:19px;color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg));font-weight:600}.file-entry{width:100%;min-height:30px;display:grid;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;border:0;border-radius:6px;background:transparent;color:inherit;font:inherit;text-align:left;padding:3px 7px}.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}.file-status{width:17px;height:17px;border:1px solid currentColor;border-radius:5px;display:inline-flex;align-items:center;justify-content:center;font-size:9px;line-height:1;color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}.file-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-stats{display:inline-flex;gap:5px;color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family: var(--cmux-diff-code-font-family);--diffs-header-font-family: var(--cmux-diff-ui-font-family);--diffs-font-size: var(--cmux-diff-font-size);--diffs-line-height: var(--cmux-diff-line-height);--diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));grid-area:viewer;width:100%;height:100%;min-height:0;min-width:0;position:relative;overflow-y:auto;overflow-x:clip;overscroll-behavior:contain;overflow-anchor:none;contain:strict;will-change:scroll-position;border-bottom:1px solid var(--cmux-diff-border);background:inherit}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}body[data-status-only=true] #files-sidebar{display:none}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family: var(--cmux-diff-code-font-family);--diffs-header-font-family: var(--cmux-diff-ui-font-family);--diffs-font-size: var(--cmux-diff-font-size);--diffs-line-height: var(--cmux-diff-line-height);--diffs-bg-selection-override: light-dark(var(--cmux-diff-selection-bg-light), var(--cmux-diff-selection-bg-dark));display:block;overflow:clip;contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border)}#status{padding:16px;font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}#status[data-pending=true]{display:inline-flex;align-items:center;gap:10px}#status[data-pending=true]:before{content:"";width:16px;height:16px;flex:0 0 auto;border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent);border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg));border-radius:50%;animation:cmuxDiffPendingSpin .8s linear infinite}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before{animation:none}}';
function r0() {
  const _ = document.getElementById("cmux-diff-viewer-config");
  if (!_?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(_.textContent);
}
function d0() {
  const _ = document.createElement("style");
  _.dataset.cmuxDiffViewerStyle = "true", _.textContent = s0, document.head.append(_);
}
const uf = r0();
d0();
document.title = uf.payload?.title ?? document.title;
document.body.dataset.filesHidden = "false";
document.body.dataset.statusOnly = uf.payload?.statusMessage || uf.payload?.pendingReplacement ? "true" : "false";
n0.createRoot(document.getElementById("root")).render(/* @__PURE__ */ lt.jsx(o0, { config: uf }));
