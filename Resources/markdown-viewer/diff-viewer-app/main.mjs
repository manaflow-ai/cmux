var vo = { exports: {} }, Gi = {};
var tm;
function rg() {
  if (tm) return Gi;
  tm = 1;
  var T = /* @__PURE__ */ Symbol.for("react.transitional.element"), f = /* @__PURE__ */ Symbol.for("react.fragment");
  function z(s, L, k) {
    var I = null;
    if (k !== void 0 && (I = "" + k), L.key !== void 0 && (I = "" + L.key), "key" in L) {
      k = {};
      for (var lt in L)
        lt !== "key" && (k[lt] = L[lt]);
    } else k = L;
    return L = k.ref, {
      $$typeof: T,
      type: s,
      key: I,
      ref: L !== void 0 ? L : null,
      props: k
    };
  }
  return Gi.Fragment = f, Gi.jsx = z, Gi.jsxs = z, Gi;
}
var em;
function sg() {
  return em || (em = 1, vo.exports = rg()), vo.exports;
}
var V = sg(), bo = { exports: {} }, Yi = {}, xo = { exports: {} }, So = {};
var lm;
function dg() {
  return lm || (lm = 1, (function(T) {
    function f(g, C) {
      var Z = g.length;
      g.push(C);
      t: for (; 0 < Z; ) {
        var F = Z - 1 >>> 1, at = g[F];
        if (0 < L(at, C))
          g[F] = C, g[Z] = at, Z = F;
        else break t;
      }
    }
    function z(g) {
      return g.length === 0 ? null : g[0];
    }
    function s(g) {
      if (g.length === 0) return null;
      var C = g[0], Z = g.pop();
      if (Z !== C) {
        g[0] = Z;
        t: for (var F = 0, at = g.length, m = at >>> 1; F < m; ) {
          var _ = 2 * (F + 1) - 1, B = g[_], G = _ + 1, nt = g[G];
          if (0 > L(B, Z))
            G < at && 0 > L(nt, B) ? (g[F] = nt, g[G] = Z, F = G) : (g[F] = B, g[_] = Z, F = _);
          else if (G < at && 0 > L(nt, Z))
            g[F] = nt, g[G] = Z, F = G;
          else break t;
        }
      }
      return C;
    }
    function L(g, C) {
      var Z = g.sortIndex - C.sortIndex;
      return Z !== 0 ? Z : g.id - C.id;
    }
    if (T.unstable_now = void 0, typeof performance == "object" && typeof performance.now == "function") {
      var k = performance;
      T.unstable_now = function() {
        return k.now();
      };
    } else {
      var I = Date, lt = I.now();
      T.unstable_now = function() {
        return I.now() - lt;
      };
    }
    var U = [], y = [], q = 1, N = null, et = 3, rt = !1, ht = !1, mt = !1, Dt = !1, P = typeof setTimeout == "function" ? setTimeout : null, Ot = typeof clearTimeout == "function" ? clearTimeout : null, dt = typeof setImmediate < "u" ? setImmediate : null;
    function Ct(g) {
      for (var C = z(y); C !== null; ) {
        if (C.callback === null) s(y);
        else if (C.startTime <= g)
          s(y), C.sortIndex = C.expirationTime, f(U, C);
        else break;
        C = z(y);
      }
    }
    function wt(g) {
      if (mt = !1, Ct(g), !ht)
        if (z(U) !== null)
          ht = !0, gt || (gt = !0, Zt());
        else {
          var C = z(y);
          C !== null && X(wt, C.startTime - g);
        }
    }
    var gt = !1, W = -1, Rt = 5, Pt = -1;
    function Ft() {
      return Dt ? !0 : !(T.unstable_now() - Pt < Rt);
    }
    function Vt() {
      if (Dt = !1, gt) {
        var g = T.unstable_now();
        Pt = g;
        var C = !0;
        try {
          t: {
            ht = !1, mt && (mt = !1, Ot(W), W = -1), rt = !0;
            var Z = et;
            try {
              e: {
                for (Ct(g), N = z(U); N !== null && !(N.expirationTime > g && Ft()); ) {
                  var F = N.callback;
                  if (typeof F == "function") {
                    N.callback = null, et = N.priorityLevel;
                    var at = F(
                      N.expirationTime <= g
                    );
                    if (g = T.unstable_now(), typeof at == "function") {
                      N.callback = at, Ct(g), C = !0;
                      break e;
                    }
                    N === z(U) && s(U), Ct(g);
                  } else s(U);
                  N = z(U);
                }
                if (N !== null) C = !0;
                else {
                  var m = z(y);
                  m !== null && X(
                    wt,
                    m.startTime - g
                  ), C = !1;
                }
              }
              break t;
            } finally {
              N = null, et = Z, rt = !1;
            }
            C = void 0;
          }
        } finally {
          C ? Zt() : gt = !1;
        }
      }
    }
    var Zt;
    if (typeof dt == "function")
      Zt = function() {
        dt(Vt);
      };
    else if (typeof MessageChannel < "u") {
      var oe = new MessageChannel(), ie = oe.port2;
      oe.port1.onmessage = Vt, Zt = function() {
        ie.postMessage(null);
      };
    } else
      Zt = function() {
        P(Vt, 0);
      };
    function X(g, C) {
      W = P(function() {
        g(T.unstable_now());
      }, C);
    }
    T.unstable_IdlePriority = 5, T.unstable_ImmediatePriority = 1, T.unstable_LowPriority = 4, T.unstable_NormalPriority = 3, T.unstable_Profiling = null, T.unstable_UserBlockingPriority = 2, T.unstable_cancelCallback = function(g) {
      g.callback = null;
    }, T.unstable_forceFrameRate = function(g) {
      0 > g || 125 < g ? console.error(
        "forceFrameRate takes a positive int between 0 and 125, forcing frame rates higher than 125 fps is not supported"
      ) : Rt = 0 < g ? Math.floor(1e3 / g) : 5;
    }, T.unstable_getCurrentPriorityLevel = function() {
      return et;
    }, T.unstable_next = function(g) {
      switch (et) {
        case 1:
        case 2:
        case 3:
          var C = 3;
          break;
        default:
          C = et;
      }
      var Z = et;
      et = C;
      try {
        return g();
      } finally {
        et = Z;
      }
    }, T.unstable_requestPaint = function() {
      Dt = !0;
    }, T.unstable_runWithPriority = function(g, C) {
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
      var Z = et;
      et = g;
      try {
        return C();
      } finally {
        et = Z;
      }
    }, T.unstable_scheduleCallback = function(g, C, Z) {
      var F = T.unstable_now();
      switch (typeof Z == "object" && Z !== null ? (Z = Z.delay, Z = typeof Z == "number" && 0 < Z ? F + Z : F) : Z = F, g) {
        case 1:
          var at = -1;
          break;
        case 2:
          at = 250;
          break;
        case 5:
          at = 1073741823;
          break;
        case 4:
          at = 1e4;
          break;
        default:
          at = 5e3;
      }
      return at = Z + at, g = {
        id: q++,
        callback: C,
        priorityLevel: g,
        startTime: Z,
        expirationTime: at,
        sortIndex: -1
      }, Z > F ? (g.sortIndex = Z, f(y, g), z(U) === null && g === z(y) && (mt ? (Ot(W), W = -1) : mt = !0, X(wt, Z - F))) : (g.sortIndex = at, f(U, g), ht || rt || (ht = !0, gt || (gt = !0, Zt()))), g;
    }, T.unstable_shouldYield = Ft, T.unstable_wrapCallback = function(g) {
      var C = et;
      return function() {
        var Z = et;
        et = C;
        try {
          return g.apply(this, arguments);
        } finally {
          et = Z;
        }
      };
    };
  })(So)), So;
}
var am;
function mg() {
  return am || (am = 1, xo.exports = dg()), xo.exports;
}
var To = { exports: {} }, ft = {};
var nm;
function hg() {
  if (nm) return ft;
  nm = 1;
  var T = /* @__PURE__ */ Symbol.for("react.transitional.element"), f = /* @__PURE__ */ Symbol.for("react.portal"), z = /* @__PURE__ */ Symbol.for("react.fragment"), s = /* @__PURE__ */ Symbol.for("react.strict_mode"), L = /* @__PURE__ */ Symbol.for("react.profiler"), k = /* @__PURE__ */ Symbol.for("react.consumer"), I = /* @__PURE__ */ Symbol.for("react.context"), lt = /* @__PURE__ */ Symbol.for("react.forward_ref"), U = /* @__PURE__ */ Symbol.for("react.suspense"), y = /* @__PURE__ */ Symbol.for("react.memo"), q = /* @__PURE__ */ Symbol.for("react.lazy"), N = /* @__PURE__ */ Symbol.for("react.activity"), et = Symbol.iterator;
  function rt(m) {
    return m === null || typeof m != "object" ? null : (m = et && m[et] || m["@@iterator"], typeof m == "function" ? m : null);
  }
  var ht = {
    isMounted: function() {
      return !1;
    },
    enqueueForceUpdate: function() {
    },
    enqueueReplaceState: function() {
    },
    enqueueSetState: function() {
    }
  }, mt = Object.assign, Dt = {};
  function P(m, _, B) {
    this.props = m, this.context = _, this.refs = Dt, this.updater = B || ht;
  }
  P.prototype.isReactComponent = {}, P.prototype.setState = function(m, _) {
    if (typeof m != "object" && typeof m != "function" && m != null)
      throw Error(
        "takes an object of state variables to update or a function which returns an object of state variables."
      );
    this.updater.enqueueSetState(this, m, _, "setState");
  }, P.prototype.forceUpdate = function(m) {
    this.updater.enqueueForceUpdate(this, m, "forceUpdate");
  };
  function Ot() {
  }
  Ot.prototype = P.prototype;
  function dt(m, _, B) {
    this.props = m, this.context = _, this.refs = Dt, this.updater = B || ht;
  }
  var Ct = dt.prototype = new Ot();
  Ct.constructor = dt, mt(Ct, P.prototype), Ct.isPureReactComponent = !0;
  var wt = Array.isArray;
  function gt() {
  }
  var W = { H: null, A: null, T: null, S: null }, Rt = Object.prototype.hasOwnProperty;
  function Pt(m, _, B) {
    var G = B.ref;
    return {
      $$typeof: T,
      type: m,
      key: _,
      ref: G !== void 0 ? G : null,
      props: B
    };
  }
  function Ft(m, _) {
    return Pt(m.type, _, m.props);
  }
  function Vt(m) {
    return typeof m == "object" && m !== null && m.$$typeof === T;
  }
  function Zt(m) {
    var _ = { "=": "=0", ":": "=2" };
    return "$" + m.replace(/[=:]/g, function(B) {
      return _[B];
    });
  }
  var oe = /\/+/g;
  function ie(m, _) {
    return typeof m == "object" && m !== null && m.key != null ? Zt("" + m.key) : _.toString(36);
  }
  function X(m) {
    switch (m.status) {
      case "fulfilled":
        return m.value;
      case "rejected":
        throw m.reason;
      default:
        switch (typeof m.status == "string" ? m.then(gt, gt) : (m.status = "pending", m.then(
          function(_) {
            m.status === "pending" && (m.status = "fulfilled", m.value = _);
          },
          function(_) {
            m.status === "pending" && (m.status = "rejected", m.reason = _);
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
  function g(m, _, B, G, nt) {
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
            case T:
            case f:
              Tt = !0;
              break;
            case q:
              return Tt = m._init, g(
                Tt(m._payload),
                _,
                B,
                G,
                nt
              );
          }
      }
    if (Tt)
      return nt = nt(m), Tt = G === "" ? "." + ie(m, 0) : G, wt(nt) ? (B = "", Tt != null && (B = Tt.replace(oe, "$&/") + "/"), g(nt, _, B, "", function(gl) {
        return gl;
      })) : nt != null && (Vt(nt) && (nt = Ft(
        nt,
        B + (nt.key == null || m && m.key === nt.key ? "" : ("" + nt.key).replace(
          oe,
          "$&/"
        ) + "/") + Tt
      )), _.push(nt)), 1;
    Tt = 0;
    var fe = G === "" ? "." : G + ":";
    if (wt(m))
      for (var Bt = 0; Bt < m.length; Bt++)
        G = m[Bt], ct = fe + ie(G, Bt), Tt += g(
          G,
          _,
          B,
          ct,
          nt
        );
    else if (Bt = rt(m), typeof Bt == "function")
      for (m = Bt.call(m), Bt = 0; !(G = m.next()).done; )
        G = G.value, ct = fe + ie(G, Bt++), Tt += g(
          G,
          _,
          B,
          ct,
          nt
        );
    else if (ct === "object") {
      if (typeof m.then == "function")
        return g(
          X(m),
          _,
          B,
          G,
          nt
        );
      throw _ = String(m), Error(
        "Objects are not valid as a React child (found: " + (_ === "[object Object]" ? "object with keys {" + Object.keys(m).join(", ") + "}" : _) + "). If you meant to render a collection of children, use an array instead."
      );
    }
    return Tt;
  }
  function C(m, _, B) {
    if (m == null) return m;
    var G = [], nt = 0;
    return g(m, G, "", "", function(ct) {
      return _.call(B, ct, nt++);
    }), G;
  }
  function Z(m) {
    if (m._status === -1) {
      var _ = m._result;
      _ = _(), _.then(
        function(B) {
          (m._status === 0 || m._status === -1) && (m._status = 1, m._result = B);
        },
        function(B) {
          (m._status === 0 || m._status === -1) && (m._status = 2, m._result = B);
        }
      ), m._status === -1 && (m._status = 0, m._result = _);
    }
    if (m._status === 1) return m._result.default;
    throw m._result;
  }
  var F = typeof reportError == "function" ? reportError : function(m) {
    if (typeof window == "object" && typeof window.ErrorEvent == "function") {
      var _ = new window.ErrorEvent("error", {
        bubbles: !0,
        cancelable: !0,
        message: typeof m == "object" && m !== null && typeof m.message == "string" ? String(m.message) : String(m),
        error: m
      });
      if (!window.dispatchEvent(_)) return;
    } else if (typeof process == "object" && typeof process.emit == "function") {
      process.emit("uncaughtException", m);
      return;
    }
    console.error(m);
  }, at = {
    map: C,
    forEach: function(m, _, B) {
      C(
        m,
        function() {
          _.apply(this, arguments);
        },
        B
      );
    },
    count: function(m) {
      var _ = 0;
      return C(m, function() {
        _++;
      }), _;
    },
    toArray: function(m) {
      return C(m, function(_) {
        return _;
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
  return ft.Activity = N, ft.Children = at, ft.Component = P, ft.Fragment = z, ft.Profiler = L, ft.PureComponent = dt, ft.StrictMode = s, ft.Suspense = U, ft.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = W, ft.__COMPILER_RUNTIME = {
    __proto__: null,
    c: function(m) {
      return W.H.useMemoCache(m);
    }
  }, ft.cache = function(m) {
    return function() {
      return m.apply(null, arguments);
    };
  }, ft.cacheSignal = function() {
    return null;
  }, ft.cloneElement = function(m, _, B) {
    if (m == null)
      throw Error(
        "The argument must be a React element, but you passed " + m + "."
      );
    var G = mt({}, m.props), nt = m.key;
    if (_ != null)
      for (ct in _.key !== void 0 && (nt = "" + _.key), _)
        !Rt.call(_, ct) || ct === "key" || ct === "__self" || ct === "__source" || ct === "ref" && _.ref === void 0 || (G[ct] = _[ct]);
    var ct = arguments.length - 2;
    if (ct === 1) G.children = B;
    else if (1 < ct) {
      for (var Tt = Array(ct), fe = 0; fe < ct; fe++)
        Tt[fe] = arguments[fe + 2];
      G.children = Tt;
    }
    return Pt(m.type, nt, G);
  }, ft.createContext = function(m) {
    return m = {
      $$typeof: I,
      _currentValue: m,
      _currentValue2: m,
      _threadCount: 0,
      Provider: null,
      Consumer: null
    }, m.Provider = m, m.Consumer = {
      $$typeof: k,
      _context: m
    }, m;
  }, ft.createElement = function(m, _, B) {
    var G, nt = {}, ct = null;
    if (_ != null)
      for (G in _.key !== void 0 && (ct = "" + _.key), _)
        Rt.call(_, G) && G !== "key" && G !== "__self" && G !== "__source" && (nt[G] = _[G]);
    var Tt = arguments.length - 2;
    if (Tt === 1) nt.children = B;
    else if (1 < Tt) {
      for (var fe = Array(Tt), Bt = 0; Bt < Tt; Bt++)
        fe[Bt] = arguments[Bt + 2];
      nt.children = fe;
    }
    if (m && m.defaultProps)
      for (G in Tt = m.defaultProps, Tt)
        nt[G] === void 0 && (nt[G] = Tt[G]);
    return Pt(m, ct, nt);
  }, ft.createRef = function() {
    return { current: null };
  }, ft.forwardRef = function(m) {
    return { $$typeof: lt, render: m };
  }, ft.isValidElement = Vt, ft.lazy = function(m) {
    return {
      $$typeof: q,
      _payload: { _status: -1, _result: m },
      _init: Z
    };
  }, ft.memo = function(m, _) {
    return {
      $$typeof: y,
      type: m,
      compare: _ === void 0 ? null : _
    };
  }, ft.startTransition = function(m) {
    var _ = W.T, B = {};
    W.T = B;
    try {
      var G = m(), nt = W.S;
      nt !== null && nt(B, G), typeof G == "object" && G !== null && typeof G.then == "function" && G.then(gt, F);
    } catch (ct) {
      F(ct);
    } finally {
      _ !== null && B.types !== null && (_.types = B.types), W.T = _;
    }
  }, ft.unstable_useCacheRefresh = function() {
    return W.H.useCacheRefresh();
  }, ft.use = function(m) {
    return W.H.use(m);
  }, ft.useActionState = function(m, _, B) {
    return W.H.useActionState(m, _, B);
  }, ft.useCallback = function(m, _) {
    return W.H.useCallback(m, _);
  }, ft.useContext = function(m) {
    return W.H.useContext(m);
  }, ft.useDebugValue = function() {
  }, ft.useDeferredValue = function(m, _) {
    return W.H.useDeferredValue(m, _);
  }, ft.useEffect = function(m, _) {
    return W.H.useEffect(m, _);
  }, ft.useEffectEvent = function(m) {
    return W.H.useEffectEvent(m);
  }, ft.useId = function() {
    return W.H.useId();
  }, ft.useImperativeHandle = function(m, _, B) {
    return W.H.useImperativeHandle(m, _, B);
  }, ft.useInsertionEffect = function(m, _) {
    return W.H.useInsertionEffect(m, _);
  }, ft.useLayoutEffect = function(m, _) {
    return W.H.useLayoutEffect(m, _);
  }, ft.useMemo = function(m, _) {
    return W.H.useMemo(m, _);
  }, ft.useOptimistic = function(m, _) {
    return W.H.useOptimistic(m, _);
  }, ft.useReducer = function(m, _, B) {
    return W.H.useReducer(m, _, B);
  }, ft.useRef = function(m) {
    return W.H.useRef(m);
  }, ft.useState = function(m) {
    return W.H.useState(m);
  }, ft.useSyncExternalStore = function(m, _, B) {
    return W.H.useSyncExternalStore(
      m,
      _,
      B
    );
  }, ft.useTransition = function() {
    return W.H.useTransition();
  }, ft.version = "19.2.3", ft;
}
var im;
function cf() {
  return im || (im = 1, To.exports = hg()), To.exports;
}
var zo = { exports: {} }, be = {};
var um;
function gg() {
  if (um) return be;
  um = 1;
  var T = cf();
  function f(U) {
    var y = "https://react.dev/errors/" + U;
    if (1 < arguments.length) {
      y += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var q = 2; q < arguments.length; q++)
        y += "&args[]=" + encodeURIComponent(arguments[q]);
    }
    return "Minified React error #" + U + "; visit " + y + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function z() {
  }
  var s = {
    d: {
      f: z,
      r: function() {
        throw Error(f(522));
      },
      D: z,
      C: z,
      L: z,
      m: z,
      X: z,
      S: z,
      M: z
    },
    p: 0,
    findDOMNode: null
  }, L = /* @__PURE__ */ Symbol.for("react.portal");
  function k(U, y, q) {
    var N = 3 < arguments.length && arguments[3] !== void 0 ? arguments[3] : null;
    return {
      $$typeof: L,
      key: N == null ? null : "" + N,
      children: U,
      containerInfo: y,
      implementation: q
    };
  }
  var I = T.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  function lt(U, y) {
    if (U === "font") return "";
    if (typeof y == "string")
      return y === "use-credentials" ? y : "";
  }
  return be.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE = s, be.createPortal = function(U, y) {
    var q = 2 < arguments.length && arguments[2] !== void 0 ? arguments[2] : null;
    if (!y || y.nodeType !== 1 && y.nodeType !== 9 && y.nodeType !== 11)
      throw Error(f(299));
    return k(U, y, null, q);
  }, be.flushSync = function(U) {
    var y = I.T, q = s.p;
    try {
      if (I.T = null, s.p = 2, U) return U();
    } finally {
      I.T = y, s.p = q, s.d.f();
    }
  }, be.preconnect = function(U, y) {
    typeof U == "string" && (y ? (y = y.crossOrigin, y = typeof y == "string" ? y === "use-credentials" ? y : "" : void 0) : y = null, s.d.C(U, y));
  }, be.prefetchDNS = function(U) {
    typeof U == "string" && s.d.D(U);
  }, be.preinit = function(U, y) {
    if (typeof U == "string" && y && typeof y.as == "string") {
      var q = y.as, N = lt(q, y.crossOrigin), et = typeof y.integrity == "string" ? y.integrity : void 0, rt = typeof y.fetchPriority == "string" ? y.fetchPriority : void 0;
      q === "style" ? s.d.S(
        U,
        typeof y.precedence == "string" ? y.precedence : void 0,
        {
          crossOrigin: N,
          integrity: et,
          fetchPriority: rt
        }
      ) : q === "script" && s.d.X(U, {
        crossOrigin: N,
        integrity: et,
        fetchPriority: rt,
        nonce: typeof y.nonce == "string" ? y.nonce : void 0
      });
    }
  }, be.preinitModule = function(U, y) {
    if (typeof U == "string")
      if (typeof y == "object" && y !== null) {
        if (y.as == null || y.as === "script") {
          var q = lt(
            y.as,
            y.crossOrigin
          );
          s.d.M(U, {
            crossOrigin: q,
            integrity: typeof y.integrity == "string" ? y.integrity : void 0,
            nonce: typeof y.nonce == "string" ? y.nonce : void 0
          });
        }
      } else y == null && s.d.M(U);
  }, be.preload = function(U, y) {
    if (typeof U == "string" && typeof y == "object" && y !== null && typeof y.as == "string") {
      var q = y.as, N = lt(q, y.crossOrigin);
      s.d.L(U, q, {
        crossOrigin: N,
        integrity: typeof y.integrity == "string" ? y.integrity : void 0,
        nonce: typeof y.nonce == "string" ? y.nonce : void 0,
        type: typeof y.type == "string" ? y.type : void 0,
        fetchPriority: typeof y.fetchPriority == "string" ? y.fetchPriority : void 0,
        referrerPolicy: typeof y.referrerPolicy == "string" ? y.referrerPolicy : void 0,
        imageSrcSet: typeof y.imageSrcSet == "string" ? y.imageSrcSet : void 0,
        imageSizes: typeof y.imageSizes == "string" ? y.imageSizes : void 0,
        media: typeof y.media == "string" ? y.media : void 0
      });
    }
  }, be.preloadModule = function(U, y) {
    if (typeof U == "string")
      if (y) {
        var q = lt(y.as, y.crossOrigin);
        s.d.m(U, {
          as: typeof y.as == "string" && y.as !== "script" ? y.as : void 0,
          crossOrigin: q,
          integrity: typeof y.integrity == "string" ? y.integrity : void 0
        });
      } else s.d.m(U);
  }, be.requestFormReset = function(U) {
    s.d.r(U);
  }, be.unstable_batchedUpdates = function(U, y) {
    return U(y);
  }, be.useFormState = function(U, y, q) {
    return I.H.useFormState(U, y, q);
  }, be.useFormStatus = function() {
    return I.H.useHostTransitionStatus();
  }, be.version = "19.2.3", be;
}
var fm;
function pg() {
  if (fm) return zo.exports;
  fm = 1;
  function T() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(T);
      } catch (f) {
        console.error(f);
      }
  }
  return T(), zo.exports = gg(), zo.exports;
}
var cm;
function yg() {
  if (cm) return Yi;
  cm = 1;
  var T = mg(), f = cf(), z = pg();
  function s(t) {
    var e = "https://react.dev/errors/" + t;
    if (1 < arguments.length) {
      e += "?args[]=" + encodeURIComponent(arguments[1]);
      for (var l = 2; l < arguments.length; l++)
        e += "&args[]=" + encodeURIComponent(arguments[l]);
    }
    return "Minified React error #" + t + "; visit " + e + " for the full message or use the non-minified dev environment for full errors and additional helpful warnings.";
  }
  function L(t) {
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
  function I(t) {
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
  function U(t) {
    if (k(t) !== t)
      throw Error(s(188));
  }
  function y(t) {
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
  function q(t) {
    var e = t.tag;
    if (e === 5 || e === 26 || e === 27 || e === 6) return t;
    for (t = t.child; t !== null; ) {
      if (e = q(t), e !== null) return e;
      t = t.sibling;
    }
    return null;
  }
  var N = Object.assign, et = /* @__PURE__ */ Symbol.for("react.element"), rt = /* @__PURE__ */ Symbol.for("react.transitional.element"), ht = /* @__PURE__ */ Symbol.for("react.portal"), mt = /* @__PURE__ */ Symbol.for("react.fragment"), Dt = /* @__PURE__ */ Symbol.for("react.strict_mode"), P = /* @__PURE__ */ Symbol.for("react.profiler"), Ot = /* @__PURE__ */ Symbol.for("react.consumer"), dt = /* @__PURE__ */ Symbol.for("react.context"), Ct = /* @__PURE__ */ Symbol.for("react.forward_ref"), wt = /* @__PURE__ */ Symbol.for("react.suspense"), gt = /* @__PURE__ */ Symbol.for("react.suspense_list"), W = /* @__PURE__ */ Symbol.for("react.memo"), Rt = /* @__PURE__ */ Symbol.for("react.lazy"), Pt = /* @__PURE__ */ Symbol.for("react.activity"), Ft = /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel"), Vt = Symbol.iterator;
  function Zt(t) {
    return t === null || typeof t != "object" ? null : (t = Vt && t[Vt] || t["@@iterator"], typeof t == "function" ? t : null);
  }
  var oe = /* @__PURE__ */ Symbol.for("react.client.reference");
  function ie(t) {
    if (t == null) return null;
    if (typeof t == "function")
      return t.$$typeof === oe ? null : t.displayName || t.name || null;
    if (typeof t == "string") return t;
    switch (t) {
      case mt:
        return "Fragment";
      case P:
        return "Profiler";
      case Dt:
        return "StrictMode";
      case wt:
        return "Suspense";
      case gt:
        return "SuspenseList";
      case Pt:
        return "Activity";
    }
    if (typeof t == "object")
      switch (t.$$typeof) {
        case ht:
          return "Portal";
        case dt:
          return t.displayName || "Context";
        case Ot:
          return (t._context.displayName || "Context") + ".Consumer";
        case Ct:
          var e = t.render;
          return t = t.displayName, t || (t = e.displayName || e.name || "", t = t !== "" ? "ForwardRef(" + t + ")" : "ForwardRef"), t;
        case W:
          return e = t.displayName || null, e !== null ? e : ie(t.type) || "Memo";
        case Rt:
          e = t._payload, t = t._init;
          try {
            return ie(t(e));
          } catch {
          }
      }
    return null;
  }
  var X = Array.isArray, g = f.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, C = z.__DOM_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE, Z = {
    pending: !1,
    data: null,
    method: null,
    action: null
  }, F = [], at = -1;
  function m(t) {
    return { current: t };
  }
  function _(t) {
    0 > at || (t.current = F[at], F[at] = null, at--);
  }
  function B(t, e) {
    at++, F[at] = t.current, t.current = e;
  }
  var G = m(null), nt = m(null), ct = m(null), Tt = m(null);
  function fe(t, e) {
    switch (B(ct, e), B(nt, t), B(G, null), e.nodeType) {
      case 9:
      case 11:
        t = (t = e.documentElement) && (t = t.namespaceURI) ? zd(t) : 0;
        break;
      default:
        if (t = e.tagName, e = e.namespaceURI)
          e = zd(e), t = Md(e, t);
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
    _(G), B(G, t);
  }
  function Bt() {
    _(G), _(nt), _(ct);
  }
  function gl(t) {
    t.memoizedState !== null && B(Tt, t);
    var e = G.current, l = Md(e, t.type);
    e !== l && (B(nt, t), B(G, l));
  }
  function Ve(t) {
    nt.current === t && (_(G), _(nt)), Tt.current === t && (_(Tt), Ni._currentValue = Z);
  }
  var ul, Xn;
  function pl(t) {
    if (ul === void 0)
      try {
        throw Error();
      } catch (l) {
        var e = l.stack.trim().match(/\n( *(at )?)/);
        ul = e && e[1] || "", Xn = -1 < l.stack.indexOf(`
    at`) ? " (<anonymous>)" : -1 < l.stack.indexOf("@") ? "@unknown:0:0" : "";
      }
    return `
` + ul + t + Xn;
  }
  var Be = !1;
  function Qn(t, e) {
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
                } catch (M) {
                  var S = M;
                }
                Reflect.construct(t, [], O);
              } else {
                try {
                  O.call();
                } catch (M) {
                  S = M;
                }
                t.call(O.prototype);
              }
            } else {
              try {
                throw Error();
              } catch (M) {
                S = M;
              }
              (O = t()) && typeof O.catch == "function" && O.catch(function() {
              });
            }
          } catch (M) {
            if (M && S && typeof M.stack == "string")
              return [M.stack, S.stack];
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
`), b = c.split(`
`);
        for (n = a = 0; a < r.length && !r[a].includes("DetermineComponentFrameRoot"); )
          a++;
        for (; n < b.length && !b[n].includes(
          "DetermineComponentFrameRoot"
        ); )
          n++;
        if (a === r.length || n === b.length)
          for (a = r.length - 1, n = b.length - 1; 1 <= a && 0 <= n && r[a] !== b[n]; )
            n--;
        for (; 1 <= a && 0 <= n; a--, n--)
          if (r[a] !== b[n]) {
            if (a !== 1 || n !== 1)
              do
                if (a--, n--, 0 > n || r[a] !== b[n]) {
                  var E = `
` + r[a].replace(" at new ", " at ");
                  return t.displayName && E.includes("<anonymous>") && (E = E.replace("<anonymous>", t.displayName)), E;
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
  function of(t, e) {
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
        return Qn(t.type, !1);
      case 11:
        return Qn(t.type.render, !1);
      case 1:
        return Qn(t.type, !0);
      case 31:
        return pl("Activity");
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
  var Vn = Object.prototype.hasOwnProperty, pa = T.unstable_scheduleCallback, ya = T.unstable_cancelCallback, Xi = T.unstable_shouldYield, Zn = T.unstable_requestPaint, pe = T.unstable_now, rf = T.unstable_getCurrentPriorityLevel, Fa = T.unstable_ImmediatePriority, Kn = T.unstable_UserBlockingPriority, Wa = T.unstable_NormalPriority, sf = T.unstable_LowPriority, Qi = T.unstable_IdlePriority, Vi = T.log, df = T.unstable_setDisableYieldValue, va = null, xe = null;
  function Ee(t) {
    if (typeof Vi == "function" && df(t), xe && typeof xe.setStrictMode == "function")
      try {
        xe.setStrictMode(va, t);
      } catch {
      }
  }
  var ye = Math.clz32 ? Math.clz32 : Ia, $a = Math.log, mf = Math.LN2;
  function Ia(t) {
    return t >>>= 0, t === 0 ? 32 : 31 - ($a(t) / mf | 0) | 0;
  }
  var Pa = 256, tn = 262144, ba = 4194304;
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
  function en(t, e, l) {
    var a = t.pendingLanes;
    if (a === 0) return 0;
    var n = 0, i = t.suspendedLanes, u = t.pingedLanes;
    t = t.warmLanes;
    var c = a & 134217727;
    return c !== 0 ? (a = c & ~i, a !== 0 ? n = fl(a) : (u &= c, u !== 0 ? n = fl(u) : l || (l = c & ~t, l !== 0 && (n = fl(l))))) : (c = a & ~i, c !== 0 ? n = fl(c) : u !== 0 ? n = fl(u) : l || (l = a & ~t, l !== 0 && (n = fl(l)))), n === 0 ? 0 : e !== 0 && e !== n && (e & i) === 0 && (i = n & -n, l = e & -e, i >= l || i === 32 && (l & 4194048) !== 0) ? e : n;
  }
  function Ne(t, e) {
    return (t.pendingLanes & ~(t.suspendedLanes & ~t.pingedLanes) & e) === 0;
  }
  function Zi(t, e) {
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
  function Ki() {
    var t = ba;
    return ba <<= 1, (ba & 62914560) === 0 && (ba = 4194304), t;
  }
  function Gl(t) {
    for (var e = [], l = 0; 31 > l; l++) e.push(t);
    return e;
  }
  function Yl(t, e) {
    t.pendingLanes |= e, e !== 268435456 && (t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0);
  }
  function hf(t, e, l, a, n, i) {
    var u = t.pendingLanes;
    t.pendingLanes = l, t.suspendedLanes = 0, t.pingedLanes = 0, t.warmLanes = 0, t.expiredLanes &= l, t.entangledLanes &= l, t.errorRecoveryDisabledLanes &= l, t.shellSuspendCounter = 0;
    var c = t.entanglements, r = t.expirationTimes, b = t.hiddenUpdates;
    for (l = u & ~l; 0 < l; ) {
      var E = 31 - ye(l), O = 1 << E;
      c[E] = 0, r[E] = -1;
      var S = b[E];
      if (S !== null)
        for (b[E] = null, E = 0; E < S.length; E++) {
          var M = S[E];
          M !== null && (M.lane &= -536870913);
        }
      l &= ~O;
    }
    a !== 0 && Se(t, a, 0), i !== 0 && n === 0 && t.tag !== 0 && (t.suspendedLanes |= i & ~(u & ~e));
  }
  function Se(t, e, l) {
    t.pendingLanes |= e, t.suspendedLanes &= ~e;
    var a = 31 - ye(e);
    t.entangledLanes |= e, t.entanglements[a] = t.entanglements[a] | 1073741824 | l & 261930;
  }
  function ln(t, e) {
    var l = t.entangledLanes |= e;
    for (t = t.entanglements; l; ) {
      var a = 31 - ye(l), n = 1 << a;
      n & e | t[a] & e && (t[a] |= e), l &= ~n;
    }
  }
  function an(t, e) {
    var l = e & -e;
    return l = (l & 42) !== 0 ? 1 : Jn(l), (l & (t.suspendedLanes | e)) !== 0 ? 0 : l;
  }
  function Jn(t) {
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
  function kn(t) {
    return t &= -t, 2 < t ? 8 < t ? (t & 134217727) !== 0 ? 32 : 268435456 : 8 : 2;
  }
  function Fn() {
    var t = C.p;
    return t !== 0 ? t : (t = window.event, t === void 0 ? 32 : Jd(t.type));
  }
  function Ji(t, e) {
    var l = C.p;
    try {
      return C.p = t, e();
    } finally {
      C.p = l;
    }
  }
  var Pe = Math.random().toString(36).slice(2), te = "__reactFiber$" + Pe, re = "__reactProps$" + Pe, Ll = "__reactContainer$" + Pe, Wn = "__reactEvents$" + Pe, gf = "__reactListeners$" + Pe, pf = "__reactHandles$" + Pe, ki = "__reactResources$" + Pe, Xl = "__reactMarker$" + Pe;
  function xa(t) {
    delete t[te], delete t[re], delete t[Wn], delete t[gf], delete t[pf];
  }
  function cl(t) {
    var e = t[te];
    if (e) return e;
    for (var l = t.parentNode; l; ) {
      if (e = l[Ll] || l[te]) {
        if (l = e.alternate, e.child !== null || l !== null && l.child !== null)
          for (t = Ud(t); t !== null; ) {
            if (l = t[te]) return l;
            t = Ud(t);
          }
        return e;
      }
      t = l, l = t.parentNode;
    }
    return null;
  }
  function yl(t) {
    if (t = t[te] || t[Ll]) {
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
  function vl(t) {
    var e = t[ki];
    return e || (e = t[ki] = { hoistableStyles: /* @__PURE__ */ new Map(), hoistableScripts: /* @__PURE__ */ new Map() }), e;
  }
  function Wt(t) {
    t[Xl] = !0;
  }
  var Fi = /* @__PURE__ */ new Set(), $n = {};
  function bl(t, e) {
    xl(t, e), xl(t + "Capture", e);
  }
  function xl(t, e) {
    for ($n[t] = e, t = 0; t < e.length; t++)
      Fi.add(e[t]);
  }
  var yf = RegExp(
    "^[:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD][:A-Z_a-z\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040]*$"
  ), Wi = {}, nn = {};
  function vf(t) {
    return Vn.call(nn, t) ? !0 : Vn.call(Wi, t) ? !1 : yf.test(t) ? nn[t] = !0 : (Wi[t] = !0, !1);
  }
  function Sa(t, e, l) {
    if (vf(e))
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
  function un(t, e, l) {
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
  function Ae(t) {
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
  function $i(t) {
    var e = t.type;
    return (t = t.nodeName) && t.toLowerCase() === "input" && (e === "checkbox" || e === "radio");
  }
  function Ii(t, e, l) {
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
  function Sl(t) {
    if (!t._valueTracker) {
      var e = $i(t) ? "checked" : "value";
      t._valueTracker = Ii(
        t,
        e,
        "" + t[e]
      );
    }
  }
  function Pi(t) {
    if (!t) return !1;
    var e = t._valueTracker;
    if (!e) return !0;
    var l = e.getValue(), a = "";
    return t && (a = $i(t) ? t.checked ? "true" : "false" : t.value), t = a, t !== l ? (e.setValue(t), !0) : !1;
  }
  function ve(t) {
    if (t = t || (typeof document < "u" ? document : void 0), typeof t > "u") return null;
    try {
      return t.activeElement || t.body;
    } catch {
      return t.body;
    }
  }
  var fn = /[\n"\\]/g;
  function _e(t) {
    return t.replace(
      fn,
      function(e) {
        return "\\" + e.charCodeAt(0).toString(16) + " ";
      }
    );
  }
  function In(t, e, l, a, n, i, u, c) {
    t.name = "", u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" ? t.type = u : t.removeAttribute("type"), e != null ? u === "number" ? (e === 0 && t.value === "" || t.value != e) && (t.value = "" + Ae(e)) : t.value !== "" + Ae(e) && (t.value = "" + Ae(e)) : u !== "submit" && u !== "reset" || t.removeAttribute("value"), e != null ? d(t, u, Ae(e)) : l != null ? d(t, u, Ae(l)) : a != null && t.removeAttribute("value"), n == null && i != null && (t.defaultChecked = !!i), n != null && (t.checked = n && typeof n != "function" && typeof n != "symbol"), c != null && typeof c != "function" && typeof c != "symbol" && typeof c != "boolean" ? t.name = "" + Ae(c) : t.removeAttribute("name");
  }
  function o(t, e, l, a, n, i, u, c) {
    if (i != null && typeof i != "function" && typeof i != "symbol" && typeof i != "boolean" && (t.type = i), e != null || l != null) {
      if (!(i !== "submit" && i !== "reset" || e != null)) {
        Sl(t);
        return;
      }
      l = l != null ? "" + Ae(l) : "", e = e != null ? "" + Ae(e) : l, c || e === t.value || (t.value = e), t.defaultValue = e;
    }
    a = a ?? n, a = typeof a != "function" && typeof a != "symbol" && !!a, t.checked = c ? t.checked : !!a, t.defaultChecked = !!a, u != null && typeof u != "function" && typeof u != "symbol" && typeof u != "boolean" && (t.name = u), Sl(t);
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
      for (l = "" + Ae(l), e = null, n = 0; n < t.length; n++) {
        if (t[n].value === l) {
          t[n].selected = !0, a && (t[n].defaultSelected = !0);
          return;
        }
        e !== null || t[n].disabled || (e = t[n]);
      }
      e !== null && (e.selected = !0);
    }
  }
  function R(t, e, l) {
    if (e != null && (e = "" + Ae(e), e !== t.value && (t.value = e), l == null)) {
      t.defaultValue !== e && (t.defaultValue = e);
      return;
    }
    t.defaultValue = l != null ? "" + Ae(l) : "";
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
    l = Ae(e), t.defaultValue = l, a = t.textContent, a === l && a !== "" && a !== null && (t.value = a), Sl(t);
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
  var K = new Set(
    "animationIterationCount aspectRatio borderImageOutset borderImageSlice borderImageWidth boxFlex boxFlexGroup boxOrdinalGroup columnCount columns flex flexGrow flexPositive flexShrink flexNegative flexOrder gridArea gridRow gridRowEnd gridRowSpan gridRowStart gridColumn gridColumnEnd gridColumnSpan gridColumnStart fontWeight lineClamp lineHeight opacity order orphans scale tabSize widows zIndex zoom fillOpacity floodOpacity stopOpacity strokeDasharray strokeDashoffset strokeMiterlimit strokeOpacity strokeWidth MozAnimationIterationCount MozBoxFlex MozBoxFlexGroup MozLineClamp msAnimationIterationCount msFlex msZoom msFlexGrow msFlexNegative msFlexOrder msFlexPositive msFlexShrink msGridColumn msGridColumnSpan msGridRow msGridRowSpan WebkitAnimationIterationCount WebkitBoxFlex WebKitBoxFlexGroup WebkitBoxOrdinalGroup WebkitColumnCount WebkitColumns WebkitFlex WebkitFlexGrow WebkitFlexPositive WebkitFlexShrink WebkitLineClamp".split(
      " "
    )
  );
  function it(t, e, l) {
    var a = e.indexOf("--") === 0;
    l == null || typeof l == "boolean" || l === "" ? a ? t.setProperty(e, "") : e === "float" ? t.cssFloat = "" : t[e] = "" : a ? t.setProperty(e, l) : typeof l != "number" || l === 0 || K.has(e) ? e === "float" ? t.cssFloat = l : t[e] = ("" + l).trim() : t[e] = l + "px";
  }
  function xt(t, e, l) {
    if (e != null && typeof e != "object")
      throw Error(s(62));
    if (t = t.style, l != null) {
      for (var a in l)
        !l.hasOwnProperty(a) || e != null && e.hasOwnProperty(a) || (a.indexOf("--") === 0 ? t.setProperty(a, "") : a === "float" ? t.cssFloat = "" : t[a] = "");
      for (var n in e)
        a = e[n], e.hasOwnProperty(n) && l[n] !== a && it(t, n, a);
    } else
      for (var i in e)
        e.hasOwnProperty(i) && it(t, i, e[i]);
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
  var Ql = /* @__PURE__ */ new Map([
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
  ]), bf = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i;
  function cn(t) {
    return bf.test("" + t) ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')" : t;
  }
  function tl() {
  }
  var on = null;
  function Pn(t) {
    return t = t.target || t.srcElement || window, t.correspondingUseElement && (t = t.correspondingUseElement), t.nodeType === 3 ? t.parentNode : t;
  }
  var Tl = null, Vl = null;
  function rn(t) {
    var e = yl(t);
    if (e && (t = e.stateNode)) {
      var l = t[re] || null;
      t: switch (t = e.stateNode, e.type) {
        case "input":
          if (In(
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
              'input[name="' + _e(
                "" + e
              ) + '"][type="radio"]'
            ), e = 0; e < l.length; e++) {
              var a = l[e];
              if (a !== t && a.form === t.form) {
                var n = a[re] || null;
                if (!n) throw Error(s(90));
                In(
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
              a = l[e], a.form === t.form && Pi(a);
          }
          break t;
        case "textarea":
          R(t, l.value, l.defaultValue);
          break t;
        case "select":
          e = l.value, e != null && x(t, !!l.multiple, e, !1);
      }
    }
  }
  var Ta = !1;
  function tu(t, e, l) {
    if (Ta) return t(e, l);
    Ta = !0;
    try {
      var a = t(e);
      return a;
    } finally {
      if (Ta = !1, (Tl !== null || Vl !== null) && (ju(), Tl && (e = Tl, t = Vl, Vl = Tl = null, rn(e), t)))
        for (e = 0; e < t.length; e++) rn(t[e]);
    }
  }
  function Zl(t, e) {
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
        s(231, e, typeof l)
      );
    return l;
  }
  var He = !(typeof window > "u" || typeof window.document > "u" || typeof window.document.createElement > "u"), za = !1;
  if (He)
    try {
      var el = {};
      Object.defineProperty(el, "passive", {
        get: function() {
          za = !0;
        }
      }), window.addEventListener("test", el, el), window.removeEventListener("test", el, el);
    } catch {
      za = !1;
    }
  var ll = null, ti = null, Ma = null;
  function ei() {
    if (Ma) return Ma;
    var t, e = ti, l = e.length, a, n = "value" in ll ? ll.value : ll.textContent, i = n.length;
    for (t = 0; t < l && e[t] === n[t]; t++) ;
    var u = l - t;
    for (a = 1; a <= u && e[l - a] === n[i - a]; a++) ;
    return Ma = n.slice(t, 1 < a ? 1 - a : void 0);
  }
  function sn(t) {
    var e = t.keyCode;
    return "charCode" in t ? (t = t.charCode, t === 0 && e === 13 && (t = 13)) : t = e, t === 10 && (t = 13), 32 <= t || t === 13 ? t : 0;
  }
  function Ea() {
    return !0;
  }
  function Aa() {
    return !1;
  }
  function se(t) {
    function e(l, a, n, i, u) {
      this._reactName = l, this._targetInst = n, this.type = a, this.nativeEvent = i, this.target = u, this.currentTarget = null;
      for (var c in t)
        t.hasOwnProperty(c) && (l = t[c], this[c] = l ? l(i) : i[c]);
      return this.isDefaultPrevented = (i.defaultPrevented != null ? i.defaultPrevented : i.returnValue === !1) ? Ea : Aa, this.isPropagationStopped = Aa, this;
    }
    return N(e.prototype, {
      preventDefault: function() {
        this.defaultPrevented = !0;
        var l = this.nativeEvent;
        l && (l.preventDefault ? l.preventDefault() : typeof l.returnValue != "unknown" && (l.returnValue = !1), this.isDefaultPrevented = Ea);
      },
      stopPropagation: function() {
        var l = this.nativeEvent;
        l && (l.stopPropagation ? l.stopPropagation() : typeof l.cancelBubble != "unknown" && (l.cancelBubble = !0), this.isPropagationStopped = Ea);
      },
      persist: function() {
      },
      isPersistent: Ea
    }), e;
  }
  var zl = {
    eventPhase: 0,
    bubbles: 0,
    cancelable: 0,
    timeStamp: function(t) {
      return t.timeStamp || Date.now();
    },
    defaultPrevented: 0,
    isTrusted: 0
  }, dn = se(zl), Kl = N({}, zl, { view: 0, detail: 0 }), xf = se(Kl), _a, rl, Jl, Da = N({}, Kl, {
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
      return "movementX" in t ? t.movementX : (t !== Jl && (Jl && t.type === "mousemove" ? (_a = t.screenX - Jl.screenX, rl = t.screenY - Jl.screenY) : rl = _a = 0, Jl = t), _a);
    },
    movementY: function(t) {
      return "movementY" in t ? t.movementY : rl;
    }
  }), Oa = se(Da), D = N({}, Da, { dataTransfer: 0 }), w = se(D), tt = N({}, Kl, { relatedTarget: 0 }), ut = se(tt), Mt = N({}, zl, {
    animationName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), Et = se(Mt), Kt = N({}, zl, {
    clipboardData: function(t) {
      return "clipboardData" in t ? t.clipboardData : window.clipboardData;
    }
  }), ze = se(Kt), Ca = N({}, zl, { data: 0 }), De = se(Ca), eu = {
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
  }, Sf = {
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
  }, bm = {
    Alt: "altKey",
    Control: "ctrlKey",
    Meta: "metaKey",
    Shift: "shiftKey"
  };
  function xm(t) {
    var e = this.nativeEvent;
    return e.getModifierState ? e.getModifierState(t) : (t = bm[t]) ? !!e[t] : !1;
  }
  function Tf() {
    return xm;
  }
  var Sm = N({}, Kl, {
    key: function(t) {
      if (t.key) {
        var e = eu[t.key] || t.key;
        if (e !== "Unidentified") return e;
      }
      return t.type === "keypress" ? (t = sn(t), t === 13 ? "Enter" : String.fromCharCode(t)) : t.type === "keydown" || t.type === "keyup" ? Sf[t.keyCode] || "Unidentified" : "";
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
      return t.type === "keypress" ? sn(t) : 0;
    },
    keyCode: function(t) {
      return t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    },
    which: function(t) {
      return t.type === "keypress" ? sn(t) : t.type === "keydown" || t.type === "keyup" ? t.keyCode : 0;
    }
  }), Tm = se(Sm), zm = N({}, Da, {
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
  }), Do = se(zm), Mm = N({}, Kl, {
    touches: 0,
    targetTouches: 0,
    changedTouches: 0,
    altKey: 0,
    metaKey: 0,
    ctrlKey: 0,
    shiftKey: 0,
    getModifierState: Tf
  }), Em = se(Mm), Am = N({}, zl, {
    propertyName: 0,
    elapsedTime: 0,
    pseudoElement: 0
  }), _m = se(Am), Dm = N({}, Da, {
    deltaX: function(t) {
      return "deltaX" in t ? t.deltaX : "wheelDeltaX" in t ? -t.wheelDeltaX : 0;
    },
    deltaY: function(t) {
      return "deltaY" in t ? t.deltaY : "wheelDeltaY" in t ? -t.wheelDeltaY : "wheelDelta" in t ? -t.wheelDelta : 0;
    },
    deltaZ: 0,
    deltaMode: 0
  }), Om = se(Dm), Cm = N({}, zl, {
    newState: 0,
    oldState: 0
  }), Um = se(Cm), wm = [9, 13, 27, 32], zf = He && "CompositionEvent" in window, li = null;
  He && "documentMode" in document && (li = document.documentMode);
  var Rm = He && "TextEvent" in window && !li, Oo = He && (!zf || li && 8 < li && 11 >= li), Co = " ", Uo = !1;
  function wo(t, e) {
    switch (t) {
      case "keyup":
        return wm.indexOf(e.keyCode) !== -1;
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
  function Ro(t) {
    return t = t.detail, typeof t == "object" && "data" in t ? t.data : null;
  }
  var mn = !1;
  function Bm(t, e) {
    switch (t) {
      case "compositionend":
        return Ro(e);
      case "keypress":
        return e.which !== 32 ? null : (Uo = !0, Co);
      case "textInput":
        return t = e.data, t === Co && Uo ? null : t;
      default:
        return null;
    }
  }
  function Nm(t, e) {
    if (mn)
      return t === "compositionend" || !zf && wo(t, e) ? (t = ei(), Ma = ti = ll = null, mn = !1, t) : null;
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
        return Oo && e.locale !== "ko" ? null : e.data;
      default:
        return null;
    }
  }
  var Hm = {
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
  function Bo(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e === "input" ? !!Hm[t.type] : e === "textarea";
  }
  function No(t, e, l, a) {
    Tl ? Vl ? Vl.push(a) : Vl = [a] : Tl = a, e = Vu(e, "onChange"), 0 < e.length && (l = new dn(
      "onChange",
      "change",
      null,
      l,
      a
    ), t.push({ event: l, listeners: e }));
  }
  var ai = null, ni = null;
  function jm(t) {
    yd(t, 0);
  }
  function lu(t) {
    var e = ol(t);
    if (Pi(e)) return t;
  }
  function Ho(t, e) {
    if (t === "change") return e;
  }
  var jo = !1;
  if (He) {
    var Mf;
    if (He) {
      var Ef = "oninput" in document;
      if (!Ef) {
        var qo = document.createElement("div");
        qo.setAttribute("oninput", "return;"), Ef = typeof qo.oninput == "function";
      }
      Mf = Ef;
    } else Mf = !1;
    jo = Mf && (!document.documentMode || 9 < document.documentMode);
  }
  function Go() {
    ai && (ai.detachEvent("onpropertychange", Yo), ni = ai = null);
  }
  function Yo(t) {
    if (t.propertyName === "value" && lu(ni)) {
      var e = [];
      No(
        e,
        ni,
        t,
        Pn(t)
      ), tu(jm, e);
    }
  }
  function qm(t, e, l) {
    t === "focusin" ? (Go(), ai = e, ni = l, ai.attachEvent("onpropertychange", Yo)) : t === "focusout" && Go();
  }
  function Gm(t) {
    if (t === "selectionchange" || t === "keyup" || t === "keydown")
      return lu(ni);
  }
  function Ym(t, e) {
    if (t === "click") return lu(e);
  }
  function Lm(t, e) {
    if (t === "input" || t === "change")
      return lu(e);
  }
  function Xm(t, e) {
    return t === e && (t !== 0 || 1 / t === 1 / e) || t !== t && e !== e;
  }
  var je = typeof Object.is == "function" ? Object.is : Xm;
  function ii(t, e) {
    if (je(t, e)) return !0;
    if (typeof t != "object" || t === null || typeof e != "object" || e === null)
      return !1;
    var l = Object.keys(t), a = Object.keys(e);
    if (l.length !== a.length) return !1;
    for (a = 0; a < l.length; a++) {
      var n = l[a];
      if (!Vn.call(e, n) || !je(t[n], e[n]))
        return !1;
    }
    return !0;
  }
  function Lo(t) {
    for (; t && t.firstChild; ) t = t.firstChild;
    return t;
  }
  function Xo(t, e) {
    var l = Lo(t);
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
      l = Lo(l);
    }
  }
  function Qo(t, e) {
    return t && e ? t === e ? !0 : t && t.nodeType === 3 ? !1 : e && e.nodeType === 3 ? Qo(t, e.parentNode) : "contains" in t ? t.contains(e) : t.compareDocumentPosition ? !!(t.compareDocumentPosition(e) & 16) : !1 : !1;
  }
  function Vo(t) {
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
  function Af(t) {
    var e = t && t.nodeName && t.nodeName.toLowerCase();
    return e && (e === "input" && (t.type === "text" || t.type === "search" || t.type === "tel" || t.type === "url" || t.type === "password") || e === "textarea" || t.contentEditable === "true");
  }
  var Qm = He && "documentMode" in document && 11 >= document.documentMode, hn = null, _f = null, ui = null, Df = !1;
  function Zo(t, e, l) {
    var a = l.window === l ? l.document : l.nodeType === 9 ? l : l.ownerDocument;
    Df || hn == null || hn !== ve(a) || (a = hn, "selectionStart" in a && Af(a) ? a = { start: a.selectionStart, end: a.selectionEnd } : (a = (a.ownerDocument && a.ownerDocument.defaultView || window).getSelection(), a = {
      anchorNode: a.anchorNode,
      anchorOffset: a.anchorOffset,
      focusNode: a.focusNode,
      focusOffset: a.focusOffset
    }), ui && ii(ui, a) || (ui = a, a = Vu(_f, "onSelect"), 0 < a.length && (e = new dn(
      "onSelect",
      "select",
      null,
      e,
      l
    ), t.push({ event: e, listeners: a }), e.target = hn)));
  }
  function Ua(t, e) {
    var l = {};
    return l[t.toLowerCase()] = e.toLowerCase(), l["Webkit" + t] = "webkit" + e, l["Moz" + t] = "moz" + e, l;
  }
  var gn = {
    animationend: Ua("Animation", "AnimationEnd"),
    animationiteration: Ua("Animation", "AnimationIteration"),
    animationstart: Ua("Animation", "AnimationStart"),
    transitionrun: Ua("Transition", "TransitionRun"),
    transitionstart: Ua("Transition", "TransitionStart"),
    transitioncancel: Ua("Transition", "TransitionCancel"),
    transitionend: Ua("Transition", "TransitionEnd")
  }, Of = {}, Ko = {};
  He && (Ko = document.createElement("div").style, "AnimationEvent" in window || (delete gn.animationend.animation, delete gn.animationiteration.animation, delete gn.animationstart.animation), "TransitionEvent" in window || delete gn.transitionend.transition);
  function wa(t) {
    if (Of[t]) return Of[t];
    if (!gn[t]) return t;
    var e = gn[t], l;
    for (l in e)
      if (e.hasOwnProperty(l) && l in Ko)
        return Of[t] = e[l];
    return t;
  }
  var Jo = wa("animationend"), ko = wa("animationiteration"), Fo = wa("animationstart"), Vm = wa("transitionrun"), Zm = wa("transitionstart"), Km = wa("transitioncancel"), Wo = wa("transitionend"), $o = /* @__PURE__ */ new Map(), Cf = "abort auxClick beforeToggle cancel canPlay canPlayThrough click close contextMenu copy cut drag dragEnd dragEnter dragExit dragLeave dragOver dragStart drop durationChange emptied encrypted ended error gotPointerCapture input invalid keyDown keyPress keyUp load loadedData loadedMetadata loadStart lostPointerCapture mouseDown mouseMove mouseOut mouseOver mouseUp paste pause play playing pointerCancel pointerDown pointerMove pointerOut pointerOver pointerUp progress rateChange reset resize seeked seeking stalled submit suspend timeUpdate touchCancel touchEnd touchStart volumeChange scroll toggle touchMove waiting wheel".split(
    " "
  );
  Cf.push("scrollEnd");
  function al(t, e) {
    $o.set(t, e), bl(e, [t]);
  }
  var au = typeof reportError == "function" ? reportError : function(t) {
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
  }, Ze = [], pn = 0, Uf = 0;
  function nu() {
    for (var t = pn, e = Uf = pn = 0; e < t; ) {
      var l = Ze[e];
      Ze[e++] = null;
      var a = Ze[e];
      Ze[e++] = null;
      var n = Ze[e];
      Ze[e++] = null;
      var i = Ze[e];
      if (Ze[e++] = null, a !== null && n !== null) {
        var u = a.pending;
        u === null ? n.next = n : (n.next = u.next, u.next = n), a.pending = n;
      }
      i !== 0 && Io(l, n, i);
    }
  }
  function iu(t, e, l, a) {
    Ze[pn++] = t, Ze[pn++] = e, Ze[pn++] = l, Ze[pn++] = a, Uf |= a, t.lanes |= a, t = t.alternate, t !== null && (t.lanes |= a);
  }
  function wf(t, e, l, a) {
    return iu(t, e, l, a), uu(t);
  }
  function Ra(t, e) {
    return iu(t, null, null, e), uu(t);
  }
  function Io(t, e, l) {
    t.lanes |= l;
    var a = t.alternate;
    a !== null && (a.lanes |= l);
    for (var n = !1, i = t.return; i !== null; )
      i.childLanes |= l, a = i.alternate, a !== null && (a.childLanes |= l), i.tag === 22 && (t = i.stateNode, t === null || t._visibility & 1 || (n = !0)), t = i, i = i.return;
    return t.tag === 3 ? (i = t.stateNode, n && e !== null && (n = 31 - ye(l), t = i.hiddenUpdates, a = t[n], a === null ? t[n] = [e] : a.push(e), e.lane = l | 536870912), i) : null;
  }
  function uu(t) {
    if (50 < Di)
      throw Di = 0, Lc = null, Error(s(185));
    for (var e = t.return; e !== null; )
      t = e, e = t.return;
    return t.tag === 3 ? t.stateNode : null;
  }
  var yn = {};
  function Jm(t, e, l, a) {
    this.tag = t, this.key = l, this.sibling = this.child = this.return = this.stateNode = this.type = this.elementType = null, this.index = 0, this.refCleanup = this.ref = null, this.pendingProps = e, this.dependencies = this.memoizedState = this.updateQueue = this.memoizedProps = null, this.mode = a, this.subtreeFlags = this.flags = 0, this.deletions = null, this.childLanes = this.lanes = 0, this.alternate = null;
  }
  function qe(t, e, l, a) {
    return new Jm(t, e, l, a);
  }
  function Rf(t) {
    return t = t.prototype, !(!t || !t.isReactComponent);
  }
  function Ml(t, e) {
    var l = t.alternate;
    return l === null ? (l = qe(
      t.tag,
      e,
      t.key,
      t.mode
    ), l.elementType = t.elementType, l.type = t.type, l.stateNode = t.stateNode, l.alternate = t, t.alternate = l) : (l.pendingProps = e, l.type = t.type, l.flags = 0, l.subtreeFlags = 0, l.deletions = null), l.flags = t.flags & 65011712, l.childLanes = t.childLanes, l.lanes = t.lanes, l.child = t.child, l.memoizedProps = t.memoizedProps, l.memoizedState = t.memoizedState, l.updateQueue = t.updateQueue, e = t.dependencies, l.dependencies = e === null ? null : { lanes: e.lanes, firstContext: e.firstContext }, l.sibling = t.sibling, l.index = t.index, l.ref = t.ref, l.refCleanup = t.refCleanup, l;
  }
  function Po(t, e) {
    t.flags &= 65011714;
    var l = t.alternate;
    return l === null ? (t.childLanes = 0, t.lanes = e, t.child = null, t.subtreeFlags = 0, t.memoizedProps = null, t.memoizedState = null, t.updateQueue = null, t.dependencies = null, t.stateNode = null) : (t.childLanes = l.childLanes, t.lanes = l.lanes, t.child = l.child, t.subtreeFlags = 0, t.deletions = null, t.memoizedProps = l.memoizedProps, t.memoizedState = l.memoizedState, t.updateQueue = l.updateQueue, t.type = l.type, e = l.dependencies, t.dependencies = e === null ? null : {
      lanes: e.lanes,
      firstContext: e.firstContext
    }), t;
  }
  function fu(t, e, l, a, n, i) {
    var u = 0;
    if (a = t, typeof t == "function") Rf(t) && (u = 1);
    else if (typeof t == "string")
      u = Ih(
        t,
        l,
        G.current
      ) ? 26 : t === "html" || t === "head" || t === "body" ? 27 : 5;
    else
      t: switch (t) {
        case Pt:
          return t = qe(31, l, e, n), t.elementType = Pt, t.lanes = i, t;
        case mt:
          return Ba(l.children, n, i, e);
        case Dt:
          u = 8, n |= 24;
          break;
        case P:
          return t = qe(12, l, e, n | 2), t.elementType = P, t.lanes = i, t;
        case wt:
          return t = qe(13, l, e, n), t.elementType = wt, t.lanes = i, t;
        case gt:
          return t = qe(19, l, e, n), t.elementType = gt, t.lanes = i, t;
        default:
          if (typeof t == "object" && t !== null)
            switch (t.$$typeof) {
              case dt:
                u = 10;
                break t;
              case Ot:
                u = 9;
                break t;
              case Ct:
                u = 11;
                break t;
              case W:
                u = 14;
                break t;
              case Rt:
                u = 16, a = null;
                break t;
            }
          u = 29, l = Error(
            s(130, t === null ? "null" : typeof t, "")
          ), a = null;
      }
    return e = qe(u, l, e, n), e.elementType = t, e.type = a, e.lanes = i, e;
  }
  function Ba(t, e, l, a) {
    return t = qe(7, t, a, e), t.lanes = l, t;
  }
  function Bf(t, e, l) {
    return t = qe(6, t, null, e), t.lanes = l, t;
  }
  function tr(t) {
    var e = qe(18, null, null, 0);
    return e.stateNode = t, e;
  }
  function Nf(t, e, l) {
    return e = qe(
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
  var er = /* @__PURE__ */ new WeakMap();
  function Ke(t, e) {
    if (typeof t == "object" && t !== null) {
      var l = er.get(t);
      return l !== void 0 ? l : (e = {
        value: t,
        source: e,
        stack: Li(e)
      }, er.set(t, e), e);
    }
    return {
      value: t,
      source: e,
      stack: Li(e)
    };
  }
  var vn = [], bn = 0, cu = null, fi = 0, Je = [], ke = 0, kl = null, sl = 1, dl = "";
  function El(t, e) {
    vn[bn++] = fi, vn[bn++] = cu, cu = t, fi = e;
  }
  function lr(t, e, l) {
    Je[ke++] = sl, Je[ke++] = dl, Je[ke++] = kl, kl = t;
    var a = sl;
    t = dl;
    var n = 32 - ye(a) - 1;
    a &= ~(1 << n), l += 1;
    var i = 32 - ye(e) + n;
    if (30 < i) {
      var u = n - n % 5;
      i = (a & (1 << u) - 1).toString(32), a >>= u, n -= u, sl = 1 << 32 - ye(e) + n | l << n | a, dl = i + t;
    } else
      sl = 1 << i | l << n | a, dl = t;
  }
  function Hf(t) {
    t.return !== null && (El(t, 1), lr(t, 1, 0));
  }
  function jf(t) {
    for (; t === cu; )
      cu = vn[--bn], vn[bn] = null, fi = vn[--bn], vn[bn] = null;
    for (; t === kl; )
      kl = Je[--ke], Je[ke] = null, dl = Je[--ke], Je[ke] = null, sl = Je[--ke], Je[ke] = null;
  }
  function ar(t, e) {
    Je[ke++] = sl, Je[ke++] = dl, Je[ke++] = kl, sl = e.id, dl = e.overflow, kl = t;
  }
  var de = null, Lt = null, St = !1, Fl = null, Fe = !1, qf = Error(s(519));
  function Wl(t) {
    var e = Error(
      s(
        418,
        1 < arguments.length && arguments[1] !== void 0 && arguments[1] ? "text" : "HTML",
        ""
      )
    );
    throw ci(Ke(e, t)), qf;
  }
  function nr(t) {
    var e = t.stateNode, l = t.type, a = t.memoizedProps;
    switch (e[te] = t, e[re] = a, l) {
      case "dialog":
        yt("cancel", e), yt("close", e);
        break;
      case "iframe":
      case "object":
      case "embed":
        yt("load", e);
        break;
      case "video":
      case "audio":
        for (l = 0; l < Ci.length; l++)
          yt(Ci[l], e);
        break;
      case "source":
        yt("error", e);
        break;
      case "img":
      case "image":
      case "link":
        yt("error", e), yt("load", e);
        break;
      case "details":
        yt("toggle", e);
        break;
      case "input":
        yt("invalid", e), o(
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
        yt("invalid", e);
        break;
      case "textarea":
        yt("invalid", e), H(e, a.value, a.defaultValue, a.children);
    }
    l = a.children, typeof l != "string" && typeof l != "number" && typeof l != "bigint" || e.textContent === "" + l || a.suppressHydrationWarning === !0 || Sd(e.textContent, l) ? (a.popover != null && (yt("beforetoggle", e), yt("toggle", e)), a.onScroll != null && yt("scroll", e), a.onScrollEnd != null && yt("scrollend", e), a.onClick != null && (e.onclick = tl), e = !0) : e = !1, e || Wl(t, !0);
  }
  function ir(t) {
    for (de = t.return; de; )
      switch (de.tag) {
        case 5:
        case 31:
        case 13:
          Fe = !1;
          return;
        case 27:
        case 3:
          Fe = !0;
          return;
        default:
          de = de.return;
      }
  }
  function xn(t) {
    if (t !== de) return !1;
    if (!St) return ir(t), St = !0, !1;
    var e = t.tag, l;
    if ((l = e !== 3 && e !== 27) && ((l = e === 5) && (l = t.type, l = !(l !== "form" && l !== "button") || lo(t.type, t.memoizedProps)), l = !l), l && Lt && Wl(t), ir(t), e === 13) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = Cd(t);
    } else if (e === 31) {
      if (t = t.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(317));
      Lt = Cd(t);
    } else
      e === 27 ? (e = Lt, ra(t.type) ? (t = fo, fo = null, Lt = t) : Lt = e) : Lt = de ? $e(t.stateNode.nextSibling) : null;
    return !0;
  }
  function Na() {
    Lt = de = null, St = !1;
  }
  function Gf() {
    var t = Fl;
    return t !== null && (we === null ? we = t : we.push.apply(
      we,
      t
    ), Fl = null), t;
  }
  function ci(t) {
    Fl === null ? Fl = [t] : Fl.push(t);
  }
  var Yf = m(null), Ha = null, Al = null;
  function $l(t, e, l) {
    B(Yf, e._currentValue), e._currentValue = l;
  }
  function _l(t) {
    t._currentValue = Yf.current, _(Yf);
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
  function Sn(t, e, l, a) {
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
          je(n.pendingProps.value, u.value) || (t !== null ? t.push(c) : t = [c]);
        }
      } else if (n === Tt.current) {
        if (u = n.alternate, u === null) throw Error(s(387));
        u.memoizedState.memoizedState !== n.memoizedState.memoizedState && (t !== null ? t.push(Ni) : t = [Ni]);
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
  function ou(t) {
    for (t = t.firstContext; t !== null; ) {
      if (!je(
        t.context._currentValue,
        t.memoizedValue
      ))
        return !0;
      t = t.next;
    }
    return !1;
  }
  function ja(t) {
    Ha = t, Al = null, t = t.dependencies, t !== null && (t.firstContext = null);
  }
  function me(t) {
    return ur(Ha, t);
  }
  function ru(t, e) {
    return Ha === null && ja(t), ur(t, e);
  }
  function ur(t, e) {
    var l = e._currentValue;
    if (e = { context: e, memoizedValue: l, next: null }, Al === null) {
      if (t === null) throw Error(s(308));
      Al = e, t.dependencies = { lanes: 0, firstContext: e }, t.flags |= 524288;
    } else Al = Al.next = e;
    return l;
  }
  var km = typeof AbortController < "u" ? AbortController : function() {
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
  }, Fm = T.unstable_scheduleCallback, Wm = T.unstable_NormalPriority, ee = {
    $$typeof: dt,
    Consumer: null,
    Provider: null,
    _currentValue: null,
    _currentValue2: null,
    _threadCount: 0
  };
  function Qf() {
    return {
      controller: new km(),
      data: /* @__PURE__ */ new Map(),
      refCount: 0
    };
  }
  function oi(t) {
    t.refCount--, t.refCount === 0 && Fm(Wm, function() {
      t.controller.abort();
    });
  }
  var ri = null, Vf = 0, Tn = 0, zn = null;
  function $m(t, e) {
    if (ri === null) {
      var l = ri = [];
      Vf = 0, Tn = Jc(), zn = {
        status: "pending",
        value: void 0,
        then: function(a) {
          l.push(a);
        }
      };
    }
    return Vf++, e.then(fr, fr), e;
  }
  function fr() {
    if (--Vf === 0 && ri !== null) {
      zn !== null && (zn.status = "fulfilled");
      var t = ri;
      ri = null, Tn = 0, zn = null;
      for (var e = 0; e < t.length; e++) (0, t[e])();
    }
  }
  function Im(t, e) {
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
  var cr = g.S;
  g.S = function(t, e) {
    Zs = pe(), typeof e == "object" && e !== null && typeof e.then == "function" && $m(t, e), cr !== null && cr(t, e);
  };
  var qa = m(null);
  function Zf() {
    var t = qa.current;
    return t !== null ? t : Yt.pooledCache;
  }
  function su(t, e) {
    e === null ? B(qa, qa.current) : B(qa, e.pool);
  }
  function or() {
    var t = Zf();
    return t === null ? null : { parent: ee._currentValue, pool: t };
  }
  var Mn = Error(s(460)), Kf = Error(s(474)), du = Error(s(542)), mu = { then: function() {
  } };
  function rr(t) {
    return t = t.status, t === "fulfilled" || t === "rejected";
  }
  function sr(t, e, l) {
    switch (l = t[l], l === void 0 ? t.push(e) : l !== e && (e.then(tl, tl), e = l), e.status) {
      case "fulfilled":
        return e.value;
      case "rejected":
        throw t = e.reason, mr(t), t;
      default:
        if (typeof e.status == "string") e.then(tl, tl);
        else {
          if (t = Yt, t !== null && 100 < t.shellSuspendCounter)
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
            throw t = e.reason, mr(t), t;
        }
        throw Ya = e, Mn;
    }
  }
  function Ga(t) {
    try {
      var e = t._init;
      return e(t._payload);
    } catch (l) {
      throw l !== null && typeof l == "object" && typeof l.then == "function" ? (Ya = l, Mn) : l;
    }
  }
  var Ya = null;
  function dr() {
    if (Ya === null) throw Error(s(459));
    var t = Ya;
    return Ya = null, t;
  }
  function mr(t) {
    if (t === Mn || t === du)
      throw Error(s(483));
  }
  var En = null, si = 0;
  function hu(t) {
    var e = si;
    return si += 1, En === null && (En = []), sr(En, t, e);
  }
  function di(t, e) {
    e = e.props.ref, t.ref = e !== void 0 ? e : null;
  }
  function gu(t, e) {
    throw e.$$typeof === et ? Error(s(525)) : (t = Object.prototype.toString.call(e), Error(
      s(
        31,
        t === "[object Object]" ? "object with keys {" + Object.keys(e).join(", ") + "}" : t
      )
    ));
  }
  function hr(t) {
    function e(p, h) {
      if (t) {
        var v = p.deletions;
        v === null ? (p.deletions = [h], p.flags |= 16) : v.push(h);
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
    function i(p, h, v) {
      return p.index = v, t ? (v = p.alternate, v !== null ? (v = v.index, v < h ? (p.flags |= 67108866, h) : v) : (p.flags |= 67108866, h)) : (p.flags |= 1048576, h);
    }
    function u(p) {
      return t && p.alternate === null && (p.flags |= 67108866), p;
    }
    function c(p, h, v, A) {
      return h === null || h.tag !== 6 ? (h = Bf(v, p.mode, A), h.return = p, h) : (h = n(h, v), h.return = p, h);
    }
    function r(p, h, v, A) {
      var J = v.type;
      return J === mt ? E(
        p,
        h,
        v.props.children,
        A,
        v.key
      ) : h !== null && (h.elementType === J || typeof J == "object" && J !== null && J.$$typeof === Rt && Ga(J) === h.type) ? (h = n(h, v.props), di(h, v), h.return = p, h) : (h = fu(
        v.type,
        v.key,
        v.props,
        null,
        p.mode,
        A
      ), di(h, v), h.return = p, h);
    }
    function b(p, h, v, A) {
      return h === null || h.tag !== 4 || h.stateNode.containerInfo !== v.containerInfo || h.stateNode.implementation !== v.implementation ? (h = Nf(v, p.mode, A), h.return = p, h) : (h = n(h, v.children || []), h.return = p, h);
    }
    function E(p, h, v, A, J) {
      return h === null || h.tag !== 7 ? (h = Ba(
        v,
        p.mode,
        A,
        J
      ), h.return = p, h) : (h = n(h, v), h.return = p, h);
    }
    function O(p, h, v) {
      if (typeof h == "string" && h !== "" || typeof h == "number" || typeof h == "bigint")
        return h = Bf(
          "" + h,
          p.mode,
          v
        ), h.return = p, h;
      if (typeof h == "object" && h !== null) {
        switch (h.$$typeof) {
          case rt:
            return v = fu(
              h.type,
              h.key,
              h.props,
              null,
              p.mode,
              v
            ), di(v, h), v.return = p, v;
          case ht:
            return h = Nf(
              h,
              p.mode,
              v
            ), h.return = p, h;
          case Rt:
            return h = Ga(h), O(p, h, v);
        }
        if (X(h) || Zt(h))
          return h = Ba(
            h,
            p.mode,
            v,
            null
          ), h.return = p, h;
        if (typeof h.then == "function")
          return O(p, hu(h), v);
        if (h.$$typeof === dt)
          return O(
            p,
            ru(p, h),
            v
          );
        gu(p, h);
      }
      return null;
    }
    function S(p, h, v, A) {
      var J = h !== null ? h.key : null;
      if (typeof v == "string" && v !== "" || typeof v == "number" || typeof v == "bigint")
        return J !== null ? null : c(p, h, "" + v, A);
      if (typeof v == "object" && v !== null) {
        switch (v.$$typeof) {
          case rt:
            return v.key === J ? r(p, h, v, A) : null;
          case ht:
            return v.key === J ? b(p, h, v, A) : null;
          case Rt:
            return v = Ga(v), S(p, h, v, A);
        }
        if (X(v) || Zt(v))
          return J !== null ? null : E(p, h, v, A, null);
        if (typeof v.then == "function")
          return S(
            p,
            h,
            hu(v),
            A
          );
        if (v.$$typeof === dt)
          return S(
            p,
            h,
            ru(p, v),
            A
          );
        gu(p, v);
      }
      return null;
    }
    function M(p, h, v, A, J) {
      if (typeof A == "string" && A !== "" || typeof A == "number" || typeof A == "bigint")
        return p = p.get(v) || null, c(h, p, "" + A, J);
      if (typeof A == "object" && A !== null) {
        switch (A.$$typeof) {
          case rt:
            return p = p.get(
              A.key === null ? v : A.key
            ) || null, r(h, p, A, J);
          case ht:
            return p = p.get(
              A.key === null ? v : A.key
            ) || null, b(h, p, A, J);
          case Rt:
            return A = Ga(A), M(
              p,
              h,
              v,
              A,
              J
            );
        }
        if (X(A) || Zt(A))
          return p = p.get(v) || null, E(h, p, A, J, null);
        if (typeof A.then == "function")
          return M(
            p,
            h,
            v,
            hu(A),
            J
          );
        if (A.$$typeof === dt)
          return M(
            p,
            h,
            v,
            ru(h, A),
            J
          );
        gu(h, A);
      }
      return null;
    }
    function Y(p, h, v, A) {
      for (var J = null, At = null, Q = h, st = h = 0, bt = null; Q !== null && st < v.length; st++) {
        Q.index > st ? (bt = Q, Q = null) : bt = Q.sibling;
        var _t = S(
          p,
          Q,
          v[st],
          A
        );
        if (_t === null) {
          Q === null && (Q = bt);
          break;
        }
        t && Q && _t.alternate === null && e(p, Q), h = i(_t, h, st), At === null ? J = _t : At.sibling = _t, At = _t, Q = bt;
      }
      if (st === v.length)
        return l(p, Q), St && El(p, st), J;
      if (Q === null) {
        for (; st < v.length; st++)
          Q = O(p, v[st], A), Q !== null && (h = i(
            Q,
            h,
            st
          ), At === null ? J = Q : At.sibling = Q, At = Q);
        return St && El(p, st), J;
      }
      for (Q = a(Q); st < v.length; st++)
        bt = M(
          Q,
          p,
          st,
          v[st],
          A
        ), bt !== null && (t && bt.alternate !== null && Q.delete(
          bt.key === null ? st : bt.key
        ), h = i(
          bt,
          h,
          st
        ), At === null ? J = bt : At.sibling = bt, At = bt);
      return t && Q.forEach(function(ga) {
        return e(p, ga);
      }), St && El(p, st), J;
    }
    function $(p, h, v, A) {
      if (v == null) throw Error(s(151));
      for (var J = null, At = null, Q = h, st = h = 0, bt = null, _t = v.next(); Q !== null && !_t.done; st++, _t = v.next()) {
        Q.index > st ? (bt = Q, Q = null) : bt = Q.sibling;
        var ga = S(p, Q, _t.value, A);
        if (ga === null) {
          Q === null && (Q = bt);
          break;
        }
        t && Q && ga.alternate === null && e(p, Q), h = i(ga, h, st), At === null ? J = ga : At.sibling = ga, At = ga, Q = bt;
      }
      if (_t.done)
        return l(p, Q), St && El(p, st), J;
      if (Q === null) {
        for (; !_t.done; st++, _t = v.next())
          _t = O(p, _t.value, A), _t !== null && (h = i(_t, h, st), At === null ? J = _t : At.sibling = _t, At = _t);
        return St && El(p, st), J;
      }
      for (Q = a(Q); !_t.done; st++, _t = v.next())
        _t = M(Q, p, st, _t.value, A), _t !== null && (t && _t.alternate !== null && Q.delete(_t.key === null ? st : _t.key), h = i(_t, h, st), At === null ? J = _t : At.sibling = _t, At = _t);
      return t && Q.forEach(function(og) {
        return e(p, og);
      }), St && El(p, st), J;
    }
    function Gt(p, h, v, A) {
      if (typeof v == "object" && v !== null && v.type === mt && v.key === null && (v = v.props.children), typeof v == "object" && v !== null) {
        switch (v.$$typeof) {
          case rt:
            t: {
              for (var J = v.key; h !== null; ) {
                if (h.key === J) {
                  if (J = v.type, J === mt) {
                    if (h.tag === 7) {
                      l(
                        p,
                        h.sibling
                      ), A = n(
                        h,
                        v.props.children
                      ), A.return = p, p = A;
                      break t;
                    }
                  } else if (h.elementType === J || typeof J == "object" && J !== null && J.$$typeof === Rt && Ga(J) === h.type) {
                    l(
                      p,
                      h.sibling
                    ), A = n(h, v.props), di(A, v), A.return = p, p = A;
                    break t;
                  }
                  l(p, h);
                  break;
                } else e(p, h);
                h = h.sibling;
              }
              v.type === mt ? (A = Ba(
                v.props.children,
                p.mode,
                A,
                v.key
              ), A.return = p, p = A) : (A = fu(
                v.type,
                v.key,
                v.props,
                null,
                p.mode,
                A
              ), di(A, v), A.return = p, p = A);
            }
            return u(p);
          case ht:
            t: {
              for (J = v.key; h !== null; ) {
                if (h.key === J)
                  if (h.tag === 4 && h.stateNode.containerInfo === v.containerInfo && h.stateNode.implementation === v.implementation) {
                    l(
                      p,
                      h.sibling
                    ), A = n(h, v.children || []), A.return = p, p = A;
                    break t;
                  } else {
                    l(p, h);
                    break;
                  }
                else e(p, h);
                h = h.sibling;
              }
              A = Nf(v, p.mode, A), A.return = p, p = A;
            }
            return u(p);
          case Rt:
            return v = Ga(v), Gt(
              p,
              h,
              v,
              A
            );
        }
        if (X(v))
          return Y(
            p,
            h,
            v,
            A
          );
        if (Zt(v)) {
          if (J = Zt(v), typeof J != "function") throw Error(s(150));
          return v = J.call(v), $(
            p,
            h,
            v,
            A
          );
        }
        if (typeof v.then == "function")
          return Gt(
            p,
            h,
            hu(v),
            A
          );
        if (v.$$typeof === dt)
          return Gt(
            p,
            h,
            ru(p, v),
            A
          );
        gu(p, v);
      }
      return typeof v == "string" && v !== "" || typeof v == "number" || typeof v == "bigint" ? (v = "" + v, h !== null && h.tag === 6 ? (l(p, h.sibling), A = n(h, v), A.return = p, p = A) : (l(p, h), A = Bf(v, p.mode, A), A.return = p, p = A), u(p)) : l(p, h);
    }
    return function(p, h, v, A) {
      try {
        si = 0;
        var J = Gt(
          p,
          h,
          v,
          A
        );
        return En = null, J;
      } catch (Q) {
        if (Q === Mn || Q === du) throw Q;
        var At = qe(29, Q, null, p.mode);
        return At.lanes = A, At.return = p, At;
      }
    };
  }
  var La = hr(!0), gr = hr(!1), Il = !1;
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
  function Pl(t) {
    return { lane: t, tag: 0, payload: null, callback: null, next: null };
  }
  function ta(t, e, l) {
    var a = t.updateQueue;
    if (a === null) return null;
    if (a = a.shared, (Ut & 2) !== 0) {
      var n = a.pending;
      return n === null ? e.next = e : (e.next = n.next, n.next = e), a.pending = e, e = uu(t), Io(t, null, l), e;
    }
    return iu(t, a, e, l), uu(t);
  }
  function mi(t, e, l) {
    if (e = e.updateQueue, e !== null && (e = e.shared, (l & 4194048) !== 0)) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, ln(t, l);
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
  function hi() {
    if (Wf) {
      var t = zn;
      if (t !== null) throw t;
    }
  }
  function gi(t, e, l, a) {
    Wf = !1;
    var n = t.updateQueue;
    Il = !1;
    var i = n.firstBaseUpdate, u = n.lastBaseUpdate, c = n.shared.pending;
    if (c !== null) {
      n.shared.pending = null;
      var r = c, b = r.next;
      r.next = null, u === null ? i = b : u.next = b, u = r;
      var E = t.alternate;
      E !== null && (E = E.updateQueue, c = E.lastBaseUpdate, c !== u && (c === null ? E.firstBaseUpdate = b : c.next = b, E.lastBaseUpdate = r));
    }
    if (i !== null) {
      var O = n.baseState;
      u = 0, E = b = r = null, c = i;
      do {
        var S = c.lane & -536870913, M = S !== c.lane;
        if (M ? (vt & S) === S : (a & S) === S) {
          S !== 0 && S === Tn && (Wf = !0), E !== null && (E = E.next = {
            lane: 0,
            tag: c.tag,
            payload: c.payload,
            callback: null,
            next: null
          });
          t: {
            var Y = t, $ = c;
            S = e;
            var Gt = l;
            switch ($.tag) {
              case 1:
                if (Y = $.payload, typeof Y == "function") {
                  O = Y.call(Gt, O, S);
                  break t;
                }
                O = Y;
                break t;
              case 3:
                Y.flags = Y.flags & -65537 | 128;
              case 0:
                if (Y = $.payload, S = typeof Y == "function" ? Y.call(Gt, O, S) : Y, S == null) break t;
                O = N({}, O, S);
                break t;
              case 2:
                Il = !0;
            }
          }
          S = c.callback, S !== null && (t.flags |= 64, M && (t.flags |= 8192), M = n.callbacks, M === null ? n.callbacks = [S] : M.push(S));
        } else
          M = {
            lane: S,
            tag: c.tag,
            payload: c.payload,
            callback: c.callback,
            next: null
          }, E === null ? (b = E = M, r = O) : E = E.next = M, u |= S;
        if (c = c.next, c === null) {
          if (c = n.shared.pending, c === null)
            break;
          M = c, c = M.next, M.next = null, n.lastBaseUpdate = M, n.shared.pending = null;
        }
      } while (!0);
      E === null && (r = O), n.baseState = r, n.firstBaseUpdate = b, n.lastBaseUpdate = E, i === null && (n.shared.lanes = 0), ia |= u, t.lanes = u, t.memoizedState = O;
    }
  }
  function pr(t, e) {
    if (typeof t != "function")
      throw Error(s(191, t));
    t.call(e);
  }
  function yr(t, e) {
    var l = t.callbacks;
    if (l !== null)
      for (t.callbacks = null, t = 0; t < l.length; t++)
        pr(l[t], e);
  }
  var An = m(null), pu = m(0);
  function vr(t, e) {
    t = Hl, B(pu, t), B(An, e), Hl = t | e.baseLanes;
  }
  function $f() {
    B(pu, Hl), B(An, An.current);
  }
  function If() {
    Hl = pu.current, _(An), _(pu);
  }
  var Ge = m(null), We = null;
  function ea(t) {
    var e = t.alternate;
    B($t, $t.current & 1), B(Ge, t), We === null && (e === null || An.current !== null || e.memoizedState !== null) && (We = t);
  }
  function Pf(t) {
    B($t, $t.current), B(Ge, t), We === null && (We = t);
  }
  function br(t) {
    t.tag === 22 ? (B($t, $t.current), B(Ge, t), We === null && (We = t)) : la();
  }
  function la() {
    B($t, $t.current), B(Ge, Ge.current);
  }
  function Ye(t) {
    _(Ge), We === t && (We = null), _($t);
  }
  var $t = m(0);
  function yu(t) {
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
  var Dl = 0, ot = null, jt = null, le = null, vu = !1, _n = !1, Xa = !1, bu = 0, pi = 0, Dn = null, Pm = 0;
  function Jt() {
    throw Error(s(321));
  }
  function tc(t, e) {
    if (e === null) return !1;
    for (var l = 0; l < e.length && l < t.length; l++)
      if (!je(t[l], e[l])) return !1;
    return !0;
  }
  function ec(t, e, l, a, n, i) {
    return Dl = i, ot = e, e.memoizedState = null, e.updateQueue = null, e.lanes = 0, g.H = t === null || t.memoizedState === null ? ls : pc, Xa = !1, i = l(a, n), Xa = !1, _n && (i = Sr(
      e,
      l,
      a,
      n
    )), xr(t), i;
  }
  function xr(t) {
    g.H = bi;
    var e = jt !== null && jt.next !== null;
    if (Dl = 0, le = jt = ot = null, vu = !1, pi = 0, Dn = null, e) throw Error(s(300));
    t === null || ae || (t = t.dependencies, t !== null && ou(t) && (ae = !0));
  }
  function Sr(t, e, l, a) {
    ot = t;
    var n = 0;
    do {
      if (_n && (Dn = null), pi = 0, _n = !1, 25 <= n) throw Error(s(301));
      if (n += 1, le = jt = null, t.updateQueue != null) {
        var i = t.updateQueue;
        i.lastEffect = null, i.events = null, i.stores = null, i.memoCache != null && (i.memoCache.index = 0);
      }
      g.H = as, i = e(l, a);
    } while (_n);
    return i;
  }
  function th() {
    var t = g.H, e = t.useState()[0];
    return e = typeof e.then == "function" ? yi(e) : e, t = t.useState()[0], (jt !== null ? jt.memoizedState : null) !== t && (ot.flags |= 1024), e;
  }
  function lc() {
    var t = bu !== 0;
    return bu = 0, t;
  }
  function ac(t, e, l) {
    e.updateQueue = t.updateQueue, e.flags &= -2053, t.lanes &= ~l;
  }
  function nc(t) {
    if (vu) {
      for (t = t.memoizedState; t !== null; ) {
        var e = t.queue;
        e !== null && (e.pending = null), t = t.next;
      }
      vu = !1;
    }
    Dl = 0, le = jt = ot = null, _n = !1, pi = bu = 0, Dn = null;
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
    if (jt === null) {
      var t = ot.alternate;
      t = t !== null ? t.memoizedState : null;
    } else t = jt.next;
    var e = le === null ? ot.memoizedState : le.next;
    if (e !== null)
      le = e, jt = t;
    else {
      if (t === null)
        throw ot.alternate === null ? Error(s(467)) : Error(s(310));
      jt = t, t = {
        memoizedState: jt.memoizedState,
        baseState: jt.baseState,
        baseQueue: jt.baseQueue,
        queue: jt.queue,
        next: null
      }, le === null ? ot.memoizedState = le = t : le = le.next = t;
    }
    return le;
  }
  function xu() {
    return { lastEffect: null, events: null, stores: null, memoCache: null };
  }
  function yi(t) {
    var e = pi;
    return pi += 1, Dn === null && (Dn = []), t = sr(Dn, t, e), e = ot, (le === null ? e.memoizedState : le.next) === null && (e = e.alternate, g.H = e === null || e.memoizedState === null ? ls : pc), t;
  }
  function Su(t) {
    if (t !== null && typeof t == "object") {
      if (typeof t.then == "function") return yi(t);
      if (t.$$typeof === dt) return me(t);
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
    if (e == null && (e = { data: [], index: 0 }), l === null && (l = xu(), ot.updateQueue = l), l.memoCache = e, l = e.data[e.index], l === void 0)
      for (l = e.data[e.index] = Array(t), a = 0; a < t; a++)
        l[a] = Ft;
    return e.index++, l;
  }
  function Ol(t, e) {
    return typeof e == "function" ? e(t) : e;
  }
  function Tu(t) {
    var e = It();
    return uc(e, jt, t);
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
      var c = u = null, r = null, b = e, E = !1;
      do {
        var O = b.lane & -536870913;
        if (O !== b.lane ? (vt & O) === O : (Dl & O) === O) {
          var S = b.revertLane;
          if (S === 0)
            r !== null && (r = r.next = {
              lane: 0,
              revertLane: 0,
              gesture: null,
              action: b.action,
              hasEagerState: b.hasEagerState,
              eagerState: b.eagerState,
              next: null
            }), O === Tn && (E = !0);
          else if ((Dl & S) === S) {
            b = b.next, S === Tn && (E = !0);
            continue;
          } else
            O = {
              lane: 0,
              revertLane: b.revertLane,
              gesture: null,
              action: b.action,
              hasEagerState: b.hasEagerState,
              eagerState: b.eagerState,
              next: null
            }, r === null ? (c = r = O, u = i) : r = r.next = O, ot.lanes |= S, ia |= S;
          O = b.action, Xa && l(i, O), i = b.hasEagerState ? b.eagerState : l(i, O);
        } else
          S = {
            lane: O,
            revertLane: b.revertLane,
            gesture: b.gesture,
            action: b.action,
            hasEagerState: b.hasEagerState,
            eagerState: b.eagerState,
            next: null
          }, r === null ? (c = r = S, u = i) : r = r.next = S, ot.lanes |= O, ia |= O;
        b = b.next;
      } while (b !== null && b !== e);
      if (r === null ? u = i : r.next = c, !je(i, t.memoizedState) && (ae = !0, E && (l = zn, l !== null)))
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
      je(i, e.memoizedState) || (ae = !0), e.memoizedState = i, e.baseQueue === null && (e.baseState = i), l.lastRenderedState = i;
    }
    return [i, a];
  }
  function Tr(t, e, l) {
    var a = ot, n = It(), i = St;
    if (i) {
      if (l === void 0) throw Error(s(407));
      l = l();
    } else l = e();
    var u = !je(
      (jt || n).memoizedState,
      l
    );
    if (u && (n.memoizedState = l, ae = !0), n = n.queue, rc(Er.bind(null, a, n, t), [
      t
    ]), n.getSnapshot !== e || u || le !== null && le.memoizedState.tag & 1) {
      if (a.flags |= 2048, On(
        9,
        { destroy: void 0 },
        Mr.bind(
          null,
          a,
          n,
          l,
          e
        ),
        null
      ), Yt === null) throw Error(s(349));
      i || (Dl & 127) !== 0 || zr(a, e, l);
    }
    return l;
  }
  function zr(t, e, l) {
    t.flags |= 16384, t = { getSnapshot: e, value: l }, e = ot.updateQueue, e === null ? (e = xu(), ot.updateQueue = e, e.stores = [t]) : (l = e.stores, l === null ? e.stores = [t] : l.push(t));
  }
  function Mr(t, e, l, a) {
    e.value = l, e.getSnapshot = a, Ar(e) && _r(t);
  }
  function Er(t, e, l) {
    return l(function() {
      Ar(e) && _r(t);
    });
  }
  function Ar(t) {
    var e = t.getSnapshot;
    t = t.value;
    try {
      var l = e();
      return !je(t, l);
    } catch {
      return !0;
    }
  }
  function _r(t) {
    var e = Ra(t, 2);
    e !== null && Re(e, t, 2);
  }
  function cc(t) {
    var e = Me();
    if (typeof t == "function") {
      var l = t;
      if (t = l(), Xa) {
        Ee(!0);
        try {
          l();
        } finally {
          Ee(!1);
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
  function Dr(t, e, l, a) {
    return t.baseState = l, uc(
      t,
      jt,
      typeof a == "function" ? a : Ol
    );
  }
  function eh(t, e, l, a, n) {
    if (Eu(t)) throw Error(s(485));
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
      g.T !== null ? l(!0) : i.isTransition = !1, a(i), l = e.pending, l === null ? (i.next = e.pending = i, Or(e, i)) : (i.next = l.next, e.pending = l.next = i);
    }
  }
  function Or(t, e) {
    var l = e.action, a = e.payload, n = t.state;
    if (e.isTransition) {
      var i = g.T, u = {};
      g.T = u;
      try {
        var c = l(n, a), r = g.S;
        r !== null && r(u, c), Cr(t, e, c);
      } catch (b) {
        oc(t, e, b);
      } finally {
        i !== null && u.types !== null && (i.types = u.types), g.T = i;
      }
    } else
      try {
        i = l(n, a), Cr(t, e, i);
      } catch (b) {
        oc(t, e, b);
      }
  }
  function Cr(t, e, l) {
    l !== null && typeof l == "object" && typeof l.then == "function" ? l.then(
      function(a) {
        Ur(t, e, a);
      },
      function(a) {
        return oc(t, e, a);
      }
    ) : Ur(t, e, l);
  }
  function Ur(t, e, l) {
    e.status = "fulfilled", e.value = l, wr(e), t.state = l, e = t.pending, e !== null && (l = e.next, l === e ? t.pending = null : (l = l.next, e.next = l, Or(t, l)));
  }
  function oc(t, e, l) {
    var a = t.pending;
    if (t.pending = null, a !== null) {
      a = a.next;
      do
        e.status = "rejected", e.reason = l, wr(e), e = e.next;
      while (e !== a);
    }
    t.action = null;
  }
  function wr(t) {
    t = t.listeners;
    for (var e = 0; e < t.length; e++) (0, t[e])();
  }
  function Rr(t, e) {
    return e;
  }
  function Br(t, e) {
    if (St) {
      var l = Yt.formState;
      if (l !== null) {
        t: {
          var a = ot;
          if (St) {
            if (Lt) {
              e: {
                for (var n = Lt, i = Fe; n.nodeType !== 8; ) {
                  if (!i) {
                    n = null;
                    break e;
                  }
                  if (n = $e(
                    n.nextSibling
                  ), n === null) {
                    n = null;
                    break e;
                  }
                }
                i = n.data, n = i === "F!" || i === "F" ? n : null;
              }
              if (n) {
                Lt = $e(
                  n.nextSibling
                ), a = n.data === "F!";
                break t;
              }
            }
            Wl(a);
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
      lastRenderedReducer: Rr,
      lastRenderedState: e
    }, l.queue = a, l = Pr.bind(
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
    }, a.queue = n, l = eh.bind(
      null,
      ot,
      n,
      i,
      l
    ), n.dispatch = l, a.memoizedState = t, [e, l, !1];
  }
  function Nr(t) {
    var e = It();
    return Hr(e, jt, t);
  }
  function Hr(t, e, l) {
    if (e = uc(
      t,
      e,
      Rr
    )[0], t = Tu(Ol)[0], typeof e == "object" && e !== null && typeof e.then == "function")
      try {
        var a = yi(e);
      } catch (u) {
        throw u === Mn ? du : u;
      }
    else a = e;
    e = It();
    var n = e.queue, i = n.dispatch;
    return l !== e.memoizedState && (ot.flags |= 2048, On(
      9,
      { destroy: void 0 },
      lh.bind(null, n, l),
      null
    )), [a, i, t];
  }
  function lh(t, e) {
    t.action = e;
  }
  function jr(t) {
    var e = It(), l = jt;
    if (l !== null)
      return Hr(e, l, t);
    It(), e = e.memoizedState, l = It();
    var a = l.queue.dispatch;
    return l.memoizedState = t, [e, a, !1];
  }
  function On(t, e, l, a) {
    return t = { tag: t, create: l, deps: a, inst: e, next: null }, e = ot.updateQueue, e === null && (e = xu(), ot.updateQueue = e), l = e.lastEffect, l === null ? e.lastEffect = t.next = t : (a = l.next, l.next = t, t.next = a, e.lastEffect = t), t;
  }
  function qr() {
    return It().memoizedState;
  }
  function zu(t, e, l, a) {
    var n = Me();
    ot.flags |= t, n.memoizedState = On(
      1 | e,
      { destroy: void 0 },
      l,
      a === void 0 ? null : a
    );
  }
  function Mu(t, e, l, a) {
    var n = It();
    a = a === void 0 ? null : a;
    var i = n.memoizedState.inst;
    jt !== null && a !== null && tc(a, jt.memoizedState.deps) ? n.memoizedState = On(e, i, l, a) : (ot.flags |= t, n.memoizedState = On(
      1 | e,
      i,
      l,
      a
    ));
  }
  function Gr(t, e) {
    zu(8390656, 8, t, e);
  }
  function rc(t, e) {
    Mu(2048, 8, t, e);
  }
  function ah(t) {
    ot.flags |= 4;
    var e = ot.updateQueue;
    if (e === null)
      e = xu(), ot.updateQueue = e, e.events = [t];
    else {
      var l = e.events;
      l === null ? e.events = [t] : l.push(t);
    }
  }
  function Yr(t) {
    var e = It().memoizedState;
    return ah({ ref: e, nextImpl: t }), function() {
      if ((Ut & 2) !== 0) throw Error(s(440));
      return e.impl.apply(void 0, arguments);
    };
  }
  function Lr(t, e) {
    return Mu(4, 2, t, e);
  }
  function Xr(t, e) {
    return Mu(4, 4, t, e);
  }
  function Qr(t, e) {
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
  function Vr(t, e, l) {
    l = l != null ? l.concat([t]) : null, Mu(4, 4, Qr.bind(null, e, t), l);
  }
  function sc() {
  }
  function Zr(t, e) {
    var l = It();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    return e !== null && tc(e, a[1]) ? a[0] : (l.memoizedState = [t, e], t);
  }
  function Kr(t, e) {
    var l = It();
    e = e === void 0 ? null : e;
    var a = l.memoizedState;
    if (e !== null && tc(e, a[1]))
      return a[0];
    if (a = t(), Xa) {
      Ee(!0);
      try {
        t();
      } finally {
        Ee(!1);
      }
    }
    return l.memoizedState = [a, e], a;
  }
  function dc(t, e, l) {
    return l === void 0 || (Dl & 1073741824) !== 0 && (vt & 261930) === 0 ? t.memoizedState = e : (t.memoizedState = l, t = Js(), ot.lanes |= t, ia |= t, l);
  }
  function Jr(t, e, l, a) {
    return je(l, e) ? l : An.current !== null ? (t = dc(t, l, a), je(t, e) || (ae = !0), t) : (Dl & 42) === 0 || (Dl & 1073741824) !== 0 && (vt & 261930) === 0 ? (ae = !0, t.memoizedState = l) : (t = Js(), ot.lanes |= t, ia |= t, e);
  }
  function kr(t, e, l, a, n) {
    var i = C.p;
    C.p = i !== 0 && 8 > i ? i : 8;
    var u = g.T, c = {};
    g.T = c, gc(t, !1, e, l);
    try {
      var r = n(), b = g.S;
      if (b !== null && b(c, r), r !== null && typeof r == "object" && typeof r.then == "function") {
        var E = Im(
          r,
          a
        );
        vi(
          t,
          e,
          E,
          Qe(t)
        );
      } else
        vi(
          t,
          e,
          a,
          Qe(t)
        );
    } catch (O) {
      vi(
        t,
        e,
        { then: function() {
        }, status: "rejected", reason: O },
        Qe()
      );
    } finally {
      C.p = i, u !== null && c.types !== null && (u.types = c.types), g.T = u;
    }
  }
  function nh() {
  }
  function mc(t, e, l, a) {
    if (t.tag !== 5) throw Error(s(476));
    var n = Fr(t).queue;
    kr(
      t,
      n,
      e,
      Z,
      l === null ? nh : function() {
        return Wr(t), l(a);
      }
    );
  }
  function Fr(t) {
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
  function Wr(t) {
    var e = Fr(t);
    e.next === null && (e = t.alternate.memoizedState), vi(
      t,
      e.next.queue,
      {},
      Qe()
    );
  }
  function hc() {
    return me(Ni);
  }
  function $r() {
    return It().memoizedState;
  }
  function Ir() {
    return It().memoizedState;
  }
  function ih(t) {
    for (var e = t.return; e !== null; ) {
      switch (e.tag) {
        case 24:
        case 3:
          var l = Qe();
          t = Pl(l);
          var a = ta(e, t, l);
          a !== null && (Re(a, e, l), mi(a, e, l)), e = { cache: Qf() }, t.payload = e;
          return;
      }
      e = e.return;
    }
  }
  function uh(t, e, l) {
    var a = Qe();
    l = {
      lane: a,
      revertLane: 0,
      gesture: null,
      action: l,
      hasEagerState: !1,
      eagerState: null,
      next: null
    }, Eu(t) ? ts(e, l) : (l = wf(t, e, l, a), l !== null && (Re(l, t, a), es(l, e, a)));
  }
  function Pr(t, e, l) {
    var a = Qe();
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
    if (Eu(t)) ts(e, n);
    else {
      var i = t.alternate;
      if (t.lanes === 0 && (i === null || i.lanes === 0) && (i = e.lastRenderedReducer, i !== null))
        try {
          var u = e.lastRenderedState, c = i(u, l);
          if (n.hasEagerState = !0, n.eagerState = c, je(c, u))
            return iu(t, e, n, 0), Yt === null && nu(), !1;
        } catch {
        }
      if (l = wf(t, e, n, a), l !== null)
        return Re(l, t, a), es(l, e, a), !0;
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
    }, Eu(t)) {
      if (e) throw Error(s(479));
    } else
      e = wf(
        t,
        l,
        a,
        2
      ), e !== null && Re(e, t, 2);
  }
  function Eu(t) {
    var e = t.alternate;
    return t === ot || e !== null && e === ot;
  }
  function ts(t, e) {
    _n = vu = !0;
    var l = t.pending;
    l === null ? e.next = e : (e.next = l.next, l.next = e), t.pending = e;
  }
  function es(t, e, l) {
    if ((l & 4194048) !== 0) {
      var a = e.lanes;
      a &= t.pendingLanes, l |= a, e.lanes = l, ln(t, l);
    }
  }
  var bi = {
    readContext: me,
    use: Su,
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
  bi.useEffectEvent = Jt;
  var ls = {
    readContext: me,
    use: Su,
    useCallback: function(t, e) {
      return Me().memoizedState = [
        t,
        e === void 0 ? null : e
      ], t;
    },
    useContext: me,
    useEffect: Gr,
    useImperativeHandle: function(t, e, l) {
      l = l != null ? l.concat([t]) : null, zu(
        4194308,
        4,
        Qr.bind(null, e, t),
        l
      );
    },
    useLayoutEffect: function(t, e) {
      return zu(4194308, 4, t, e);
    },
    useInsertionEffect: function(t, e) {
      zu(4, 2, t, e);
    },
    useMemo: function(t, e) {
      var l = Me();
      e = e === void 0 ? null : e;
      var a = t();
      if (Xa) {
        Ee(!0);
        try {
          t();
        } finally {
          Ee(!1);
        }
      }
      return l.memoizedState = [a, e], a;
    },
    useReducer: function(t, e, l) {
      var a = Me();
      if (l !== void 0) {
        var n = l(e);
        if (Xa) {
          Ee(!0);
          try {
            l(e);
          } finally {
            Ee(!1);
          }
        }
      } else n = e;
      return a.memoizedState = a.baseState = n, t = {
        pending: null,
        lanes: 0,
        dispatch: null,
        lastRenderedReducer: t,
        lastRenderedState: n
      }, a.queue = t, t = t.dispatch = uh.bind(
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
      var e = t.queue, l = Pr.bind(null, ot, e);
      return e.dispatch = l, [t.memoizedState, l];
    },
    useDebugValue: sc,
    useDeferredValue: function(t, e) {
      var l = Me();
      return dc(l, t, e);
    },
    useTransition: function() {
      var t = cc(!1);
      return t = kr.bind(
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
        if (l = e(), Yt === null)
          throw Error(s(349));
        (vt & 127) !== 0 || zr(a, e, l);
      }
      n.memoizedState = l;
      var i = { value: l, getSnapshot: e };
      return n.queue = i, Gr(Er.bind(null, a, i, t), [
        t
      ]), a.flags |= 2048, On(
        9,
        { destroy: void 0 },
        Mr.bind(
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
      var t = Me(), e = Yt.identifierPrefix;
      if (St) {
        var l = dl, a = sl;
        l = (a & ~(1 << 32 - ye(a) - 1)).toString(32) + l, e = "_" + e + "R_" + l, l = bu++, 0 < l && (e += "H" + l.toString(32)), e += "_";
      } else
        l = Pm++, e = "_" + e + "r_" + l.toString(32) + "_";
      return t.memoizedState = e;
    },
    useHostTransitionStatus: hc,
    useFormState: Br,
    useActionState: Br,
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
      return Me().memoizedState = ih.bind(
        null,
        ot
      );
    },
    useEffectEvent: function(t) {
      var e = Me(), l = { impl: t };
      return e.memoizedState = l, function() {
        if ((Ut & 2) !== 0)
          throw Error(s(440));
        return l.impl.apply(void 0, arguments);
      };
    }
  }, pc = {
    readContext: me,
    use: Su,
    useCallback: Zr,
    useContext: me,
    useEffect: rc,
    useImperativeHandle: Vr,
    useInsertionEffect: Lr,
    useLayoutEffect: Xr,
    useMemo: Kr,
    useReducer: Tu,
    useRef: qr,
    useState: function() {
      return Tu(Ol);
    },
    useDebugValue: sc,
    useDeferredValue: function(t, e) {
      var l = It();
      return Jr(
        l,
        jt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = Tu(Ol)[0], e = It().memoizedState;
      return [
        typeof t == "boolean" ? t : yi(t),
        e
      ];
    },
    useSyncExternalStore: Tr,
    useId: $r,
    useHostTransitionStatus: hc,
    useFormState: Nr,
    useActionState: Nr,
    useOptimistic: function(t, e) {
      var l = It();
      return Dr(l, jt, t, e);
    },
    useMemoCache: ic,
    useCacheRefresh: Ir
  };
  pc.useEffectEvent = Yr;
  var as = {
    readContext: me,
    use: Su,
    useCallback: Zr,
    useContext: me,
    useEffect: rc,
    useImperativeHandle: Vr,
    useInsertionEffect: Lr,
    useLayoutEffect: Xr,
    useMemo: Kr,
    useReducer: fc,
    useRef: qr,
    useState: function() {
      return fc(Ol);
    },
    useDebugValue: sc,
    useDeferredValue: function(t, e) {
      var l = It();
      return jt === null ? dc(l, t, e) : Jr(
        l,
        jt.memoizedState,
        t,
        e
      );
    },
    useTransition: function() {
      var t = fc(Ol)[0], e = It().memoizedState;
      return [
        typeof t == "boolean" ? t : yi(t),
        e
      ];
    },
    useSyncExternalStore: Tr,
    useId: $r,
    useHostTransitionStatus: hc,
    useFormState: jr,
    useActionState: jr,
    useOptimistic: function(t, e) {
      var l = It();
      return jt !== null ? Dr(l, jt, t, e) : (l.baseState = t, [t, l.queue.dispatch]);
    },
    useMemoCache: ic,
    useCacheRefresh: Ir
  };
  as.useEffectEvent = Yr;
  function yc(t, e, l, a) {
    e = t.memoizedState, l = l(a, e), l = l == null ? e : N({}, e, l), t.memoizedState = l, t.lanes === 0 && (t.updateQueue.baseState = l);
  }
  var vc = {
    enqueueSetState: function(t, e, l) {
      t = t._reactInternals;
      var a = Qe(), n = Pl(a);
      n.payload = e, l != null && (n.callback = l), e = ta(t, n, a), e !== null && (Re(e, t, a), mi(e, t, a));
    },
    enqueueReplaceState: function(t, e, l) {
      t = t._reactInternals;
      var a = Qe(), n = Pl(a);
      n.tag = 1, n.payload = e, l != null && (n.callback = l), e = ta(t, n, a), e !== null && (Re(e, t, a), mi(e, t, a));
    },
    enqueueForceUpdate: function(t, e) {
      t = t._reactInternals;
      var l = Qe(), a = Pl(l);
      a.tag = 2, e != null && (a.callback = e), e = ta(t, a, l), e !== null && (Re(e, t, l), mi(e, t, l));
    }
  };
  function ns(t, e, l, a, n, i, u) {
    return t = t.stateNode, typeof t.shouldComponentUpdate == "function" ? t.shouldComponentUpdate(a, i, u) : e.prototype && e.prototype.isPureReactComponent ? !ii(l, a) || !ii(n, i) : !0;
  }
  function is(t, e, l, a) {
    t = e.state, typeof e.componentWillReceiveProps == "function" && e.componentWillReceiveProps(l, a), typeof e.UNSAFE_componentWillReceiveProps == "function" && e.UNSAFE_componentWillReceiveProps(l, a), e.state !== t && vc.enqueueReplaceState(e, e.state, null);
  }
  function Qa(t, e) {
    var l = e;
    if ("ref" in e) {
      l = {};
      for (var a in e)
        a !== "ref" && (l[a] = e[a]);
    }
    if (t = t.defaultProps) {
      l === e && (l = N({}, l));
      for (var n in t)
        l[n] === void 0 && (l[n] = t[n]);
    }
    return l;
  }
  function us(t) {
    au(t);
  }
  function fs(t) {
    console.error(t);
  }
  function cs(t) {
    au(t);
  }
  function Au(t, e) {
    try {
      var l = t.onUncaughtError;
      l(e.value, { componentStack: e.stack });
    } catch (a) {
      setTimeout(function() {
        throw a;
      });
    }
  }
  function os(t, e, l) {
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
    return l = Pl(l), l.tag = 3, l.payload = { element: null }, l.callback = function() {
      Au(t, e);
    }, l;
  }
  function rs(t) {
    return t = Pl(t), t.tag = 3, t;
  }
  function ss(t, e, l, a) {
    var n = l.type.getDerivedStateFromError;
    if (typeof n == "function") {
      var i = a.value;
      t.payload = function() {
        return n(i);
      }, t.callback = function() {
        os(e, l, a);
      };
    }
    var u = l.stateNode;
    u !== null && typeof u.componentDidCatch == "function" && (t.callback = function() {
      os(e, l, a), typeof n != "function" && (ua === null ? ua = /* @__PURE__ */ new Set([this]) : ua.add(this));
      var c = a.stack;
      this.componentDidCatch(a.value, {
        componentStack: c !== null ? c : ""
      });
    });
  }
  function fh(t, e, l, a, n) {
    if (l.flags |= 32768, a !== null && typeof a == "object" && typeof a.then == "function") {
      if (e = l.alternate, e !== null && Sn(
        e,
        l,
        n,
        !0
      ), l = Ge.current, l !== null) {
        switch (l.tag) {
          case 31:
          case 13:
            return We === null ? qu() : l.alternate === null && kt === 0 && (kt = 3), l.flags &= -257, l.flags |= 65536, l.lanes = n, a === mu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? l.updateQueue = /* @__PURE__ */ new Set([a]) : e.add(a), Vc(t, a, n)), !1;
          case 22:
            return l.flags |= 65536, a === mu ? l.flags |= 16384 : (e = l.updateQueue, e === null ? (e = {
              transitions: null,
              markerInstances: null,
              retryQueue: /* @__PURE__ */ new Set([a])
            }, l.updateQueue = e) : (l = e.retryQueue, l === null ? e.retryQueue = /* @__PURE__ */ new Set([a]) : l.add(a)), Vc(t, a, n)), !1;
        }
        throw Error(s(435, l.tag));
      }
      return Vc(t, a, n), qu(), !1;
    }
    if (St)
      return e = Ge.current, e !== null ? ((e.flags & 65536) === 0 && (e.flags |= 256), e.flags |= 65536, e.lanes = n, a !== qf && (t = Error(s(422), { cause: a }), ci(Ke(t, l)))) : (a !== qf && (e = Error(s(423), {
        cause: a
      }), ci(
        Ke(e, l)
      )), t = t.current.alternate, t.flags |= 65536, n &= -n, t.lanes |= n, a = Ke(a, l), n = bc(
        t.stateNode,
        a,
        n
      ), Ff(t, n), kt !== 4 && (kt = 2)), !1;
    var i = Error(s(520), { cause: a });
    if (i = Ke(i, l), _i === null ? _i = [i] : _i.push(i), kt !== 4 && (kt = 2), e === null) return !0;
    a = Ke(a, l), l = e;
    do {
      switch (l.tag) {
        case 3:
          return l.flags |= 65536, t = n & -n, l.lanes |= t, t = bc(l.stateNode, a, t), Ff(l, t), !1;
        case 1:
          if (e = l.type, i = l.stateNode, (l.flags & 128) === 0 && (typeof e.getDerivedStateFromError == "function" || i !== null && typeof i.componentDidCatch == "function" && (ua === null || !ua.has(i))))
            return l.flags |= 65536, n &= -n, l.lanes |= n, n = rs(n), ss(
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
  function he(t, e, l, a) {
    e.child = t === null ? gr(e, null, l, a) : La(
      e,
      t.child,
      l,
      a
    );
  }
  function ds(t, e, l, a, n) {
    l = l.render;
    var i = e.ref;
    if ("ref" in a) {
      var u = {};
      for (var c in a)
        c !== "ref" && (u[c] = a[c]);
    } else u = a;
    return ja(e), a = ec(
      t,
      e,
      l,
      u,
      i,
      n
    ), c = lc(), t !== null && !ae ? (ac(t, e, n), Cl(t, e, n)) : (St && c && Hf(e), e.flags |= 1, he(t, e, a, n), e.child);
  }
  function ms(t, e, l, a, n) {
    if (t === null) {
      var i = l.type;
      return typeof i == "function" && !Rf(i) && i.defaultProps === void 0 && l.compare === null ? (e.tag = 15, e.type = i, hs(
        t,
        e,
        i,
        a,
        n
      )) : (t = fu(
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
      if (l = l.compare, l = l !== null ? l : ii, l(u, a) && t.ref === e.ref)
        return Cl(t, e, n);
    }
    return e.flags |= 1, t = Ml(i, a), t.ref = e.ref, t.return = e, e.child = t;
  }
  function hs(t, e, l, a, n) {
    if (t !== null) {
      var i = t.memoizedProps;
      if (ii(i, a) && t.ref === e.ref)
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
  function gs(t, e, l, a) {
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
        return ps(
          t,
          e,
          i,
          l,
          a
        );
      }
      if ((l & 536870912) !== 0)
        e.memoizedState = { baseLanes: 0, cachePool: null }, t !== null && su(
          e,
          i !== null ? i.cachePool : null
        ), i !== null ? vr(e, i) : $f(), br(e);
      else
        return a = e.lanes = 536870912, ps(
          t,
          e,
          i !== null ? i.baseLanes | l : l,
          l,
          a
        );
    } else
      i !== null ? (su(e, i.cachePool), vr(e, i), la(), e.memoizedState = null) : (t !== null && su(e, null), $f(), la());
    return he(t, e, n, l), e.child;
  }
  function xi(t, e) {
    return t !== null && t.tag === 22 || e.stateNode !== null || (e.stateNode = {
      _visibility: 1,
      _pendingMarkers: null,
      _retryCache: null,
      _transitions: null
    }), e.sibling;
  }
  function ps(t, e, l, a, n) {
    var i = Zf();
    return i = i === null ? null : { parent: ee._currentValue, pool: i }, e.memoizedState = {
      baseLanes: l,
      cachePool: i
    }, t !== null && su(e, null), $f(), br(e), t !== null && Sn(t, e, a, !0), e.childLanes = n, null;
  }
  function _u(t, e) {
    return e = Ou(
      { mode: e.mode, children: e.children },
      t.mode
    ), e.ref = t.ref, t.child = e, e.return = t, e;
  }
  function ys(t, e, l) {
    return La(e, t.child, null, l), t = _u(e, e.pendingProps), t.flags |= 2, Ye(e), e.memoizedState = null, t;
  }
  function ch(t, e, l) {
    var a = e.pendingProps, n = (e.flags & 128) !== 0;
    if (e.flags &= -129, t === null) {
      if (St) {
        if (a.mode === "hidden")
          return t = _u(e, a), e.lanes = 536870912, xi(null, t);
        if (Pf(e), (t = Lt) ? (t = Od(
          t,
          Fe
        ), t = t !== null && t.data === "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: kl !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = tr(t), l.return = e, e.child = l, de = e, Lt = null)) : t = null, t === null) throw Wl(e);
        return e.lanes = 536870912, null;
      }
      return _u(e, a);
    }
    var i = t.memoizedState;
    if (i !== null) {
      var u = i.dehydrated;
      if (Pf(e), n)
        if (e.flags & 256)
          e.flags &= -257, e = ys(
            t,
            e,
            l
          );
        else if (e.memoizedState !== null)
          e.child = t.child, e.flags |= 128, e = null;
        else throw Error(s(558));
      else if (ae || Sn(t, e, l, !1), n = (l & t.childLanes) !== 0, ae || n) {
        if (a = Yt, a !== null && (u = an(a, l), u !== 0 && u !== i.retryLane))
          throw i.retryLane = u, Ra(t, u), Re(a, t, u), xc;
        qu(), e = ys(
          t,
          e,
          l
        );
      } else
        t = i.treeContext, Lt = $e(u.nextSibling), de = e, St = !0, Fl = null, Fe = !1, t !== null && ar(e, t), e = _u(e, a), e.flags |= 4096;
      return e;
    }
    return t = Ml(t.child, {
      mode: a.mode,
      children: a.children
    }), t.ref = e.ref, e.child = t, t.return = e, t;
  }
  function Du(t, e) {
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
    return ja(e), l = ec(
      t,
      e,
      l,
      a,
      void 0,
      n
    ), a = lc(), t !== null && !ae ? (ac(t, e, n), Cl(t, e, n)) : (St && a && Hf(e), e.flags |= 1, he(t, e, l, n), e.child);
  }
  function vs(t, e, l, a, n, i) {
    return ja(e), e.updateQueue = null, l = Sr(
      e,
      a,
      l,
      n
    ), xr(t), a = lc(), t !== null && !ae ? (ac(t, e, i), Cl(t, e, i)) : (St && a && Hf(e), e.flags |= 1, he(t, e, l, i), e.child);
  }
  function bs(t, e, l, a, n) {
    if (ja(e), e.stateNode === null) {
      var i = yn, u = l.contextType;
      typeof u == "object" && u !== null && (i = me(u)), i = new l(a, i), e.memoizedState = i.state !== null && i.state !== void 0 ? i.state : null, i.updater = vc, e.stateNode = i, i._reactInternals = e, i = e.stateNode, i.props = a, i.state = e.memoizedState, i.refs = {}, Jf(e), u = l.contextType, i.context = typeof u == "object" && u !== null ? me(u) : yn, i.state = e.memoizedState, u = l.getDerivedStateFromProps, typeof u == "function" && (yc(
        e,
        l,
        u,
        a
      ), i.state = e.memoizedState), typeof l.getDerivedStateFromProps == "function" || typeof i.getSnapshotBeforeUpdate == "function" || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (u = i.state, typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount(), u !== i.state && vc.enqueueReplaceState(i, i.state, null), gi(e, a, i, n), hi(), i.state = e.memoizedState), typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !0;
    } else if (t === null) {
      i = e.stateNode;
      var c = e.memoizedProps, r = Qa(l, c);
      i.props = r;
      var b = i.context, E = l.contextType;
      u = yn, typeof E == "object" && E !== null && (u = me(E));
      var O = l.getDerivedStateFromProps;
      E = typeof O == "function" || typeof i.getSnapshotBeforeUpdate == "function", c = e.pendingProps !== c, E || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (c || b !== u) && is(
        e,
        i,
        a,
        u
      ), Il = !1;
      var S = e.memoizedState;
      i.state = S, gi(e, a, i, n), hi(), b = e.memoizedState, c || S !== b || Il ? (typeof O == "function" && (yc(
        e,
        l,
        O,
        a
      ), b = e.memoizedState), (r = Il || ns(
        e,
        l,
        r,
        a,
        S,
        b,
        u
      )) ? (E || typeof i.UNSAFE_componentWillMount != "function" && typeof i.componentWillMount != "function" || (typeof i.componentWillMount == "function" && i.componentWillMount(), typeof i.UNSAFE_componentWillMount == "function" && i.UNSAFE_componentWillMount()), typeof i.componentDidMount == "function" && (e.flags |= 4194308)) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), e.memoizedProps = a, e.memoizedState = b), i.props = a, i.state = b, i.context = u, a = r) : (typeof i.componentDidMount == "function" && (e.flags |= 4194308), a = !1);
    } else {
      i = e.stateNode, kf(t, e), u = e.memoizedProps, E = Qa(l, u), i.props = E, O = e.pendingProps, S = i.context, b = l.contextType, r = yn, typeof b == "object" && b !== null && (r = me(b)), c = l.getDerivedStateFromProps, (b = typeof c == "function" || typeof i.getSnapshotBeforeUpdate == "function") || typeof i.UNSAFE_componentWillReceiveProps != "function" && typeof i.componentWillReceiveProps != "function" || (u !== O || S !== r) && is(
        e,
        i,
        a,
        r
      ), Il = !1, S = e.memoizedState, i.state = S, gi(e, a, i, n), hi();
      var M = e.memoizedState;
      u !== O || S !== M || Il || t !== null && t.dependencies !== null && ou(t.dependencies) ? (typeof c == "function" && (yc(
        e,
        l,
        c,
        a
      ), M = e.memoizedState), (E = Il || ns(
        e,
        l,
        E,
        a,
        S,
        M,
        r
      ) || t !== null && t.dependencies !== null && ou(t.dependencies)) ? (b || typeof i.UNSAFE_componentWillUpdate != "function" && typeof i.componentWillUpdate != "function" || (typeof i.componentWillUpdate == "function" && i.componentWillUpdate(a, M, r), typeof i.UNSAFE_componentWillUpdate == "function" && i.UNSAFE_componentWillUpdate(
        a,
        M,
        r
      )), typeof i.componentDidUpdate == "function" && (e.flags |= 4), typeof i.getSnapshotBeforeUpdate == "function" && (e.flags |= 1024)) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && S === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && S === t.memoizedState || (e.flags |= 1024), e.memoizedProps = a, e.memoizedState = M), i.props = a, i.state = M, i.context = r, a = E) : (typeof i.componentDidUpdate != "function" || u === t.memoizedProps && S === t.memoizedState || (e.flags |= 4), typeof i.getSnapshotBeforeUpdate != "function" || u === t.memoizedProps && S === t.memoizedState || (e.flags |= 1024), a = !1);
    }
    return i = a, Du(t, e), a = (e.flags & 128) !== 0, i || a ? (i = e.stateNode, l = a && typeof l.getDerivedStateFromError != "function" ? null : i.render(), e.flags |= 1, t !== null && a ? (e.child = La(
      e,
      t.child,
      null,
      n
    ), e.child = La(
      e,
      null,
      l,
      n
    )) : he(t, e, l, n), e.memoizedState = i.state, t = e.child) : t = Cl(
      t,
      e,
      n
    ), t;
  }
  function xs(t, e, l, a) {
    return Na(), e.flags |= 256, he(t, e, l, a), e.child;
  }
  var Tc = {
    dehydrated: null,
    treeContext: null,
    retryLane: 0,
    hydrationErrors: null
  };
  function zc(t) {
    return { baseLanes: t, cachePool: or() };
  }
  function Mc(t, e, l) {
    return t = t !== null ? t.childLanes & ~l : 0, e && (t |= Xe), t;
  }
  function Ss(t, e, l) {
    var a = e.pendingProps, n = !1, i = (e.flags & 128) !== 0, u;
    if ((u = i) || (u = t !== null && t.memoizedState === null ? !1 : ($t.current & 2) !== 0), u && (n = !0, e.flags &= -129), u = (e.flags & 32) !== 0, e.flags &= -33, t === null) {
      if (St) {
        if (n ? ea(e) : la(), (t = Lt) ? (t = Od(
          t,
          Fe
        ), t = t !== null && t.data !== "&" ? t : null, t !== null && (e.memoizedState = {
          dehydrated: t,
          treeContext: kl !== null ? { id: sl, overflow: dl } : null,
          retryLane: 536870912,
          hydrationErrors: null
        }, l = tr(t), l.return = e, e.child = l, de = e, Lt = null)) : t = null, t === null) throw Wl(e);
        return uo(t) ? e.lanes = 32 : e.lanes = 536870912, null;
      }
      var c = a.children;
      return a = a.fallback, n ? (la(), n = e.mode, c = Ou(
        { mode: "hidden", children: c },
        n
      ), a = Ba(
        a,
        n,
        l,
        null
      ), c.return = e, a.return = e, c.sibling = a, e.child = c, a = e.child, a.memoizedState = zc(l), a.childLanes = Mc(
        t,
        u,
        l
      ), e.memoizedState = Tc, xi(null, a)) : (ea(e), Ec(e, c));
    }
    var r = t.memoizedState;
    if (r !== null && (c = r.dehydrated, c !== null)) {
      if (i)
        e.flags & 256 ? (ea(e), e.flags &= -257, e = Ac(
          t,
          e,
          l
        )) : e.memoizedState !== null ? (la(), e.child = t.child, e.flags |= 128, e = null) : (la(), c = a.fallback, n = e.mode, a = Ou(
          { mode: "visible", children: a.children },
          n
        ), c = Ba(
          c,
          n,
          l,
          null
        ), c.flags |= 2, a.return = e, c.return = e, a.sibling = c, e.child = a, La(
          e,
          t.child,
          null,
          l
        ), a = e.child, a.memoizedState = zc(l), a.childLanes = Mc(
          t,
          u,
          l
        ), e.memoizedState = Tc, e = xi(null, a));
      else if (ea(e), uo(c)) {
        if (u = c.nextSibling && c.nextSibling.dataset, u) var b = u.dgst;
        u = b, a = Error(s(419)), a.stack = "", a.digest = u, ci({ value: a, source: null, stack: null }), e = Ac(
          t,
          e,
          l
        );
      } else if (ae || Sn(t, e, l, !1), u = (l & t.childLanes) !== 0, ae || u) {
        if (u = Yt, u !== null && (a = an(u, l), a !== 0 && a !== r.retryLane))
          throw r.retryLane = a, Ra(t, a), Re(u, t, a), xc;
        io(c) || qu(), e = Ac(
          t,
          e,
          l
        );
      } else
        io(c) ? (e.flags |= 192, e.child = t.child, e = null) : (t = r.treeContext, Lt = $e(
          c.nextSibling
        ), de = e, St = !0, Fl = null, Fe = !1, t !== null && ar(e, t), e = Ec(
          e,
          a.children
        ), e.flags |= 4096);
      return e;
    }
    return n ? (la(), c = a.fallback, n = e.mode, r = t.child, b = r.sibling, a = Ml(r, {
      mode: "hidden",
      children: a.children
    }), a.subtreeFlags = r.subtreeFlags & 65011712, b !== null ? c = Ml(
      b,
      c
    ) : (c = Ba(
      c,
      n,
      l,
      null
    ), c.flags |= 2), c.return = e, a.return = e, a.sibling = c, e.child = a, xi(null, a), a = e.child, c = t.child.memoizedState, c === null ? c = zc(l) : (n = c.cachePool, n !== null ? (r = ee._currentValue, n = n.parent !== r ? { parent: r, pool: r } : n) : n = or(), c = {
      baseLanes: c.baseLanes | l,
      cachePool: n
    }), a.memoizedState = c, a.childLanes = Mc(
      t,
      u,
      l
    ), e.memoizedState = Tc, xi(t.child, a)) : (ea(e), l = t.child, t = l.sibling, l = Ml(l, {
      mode: "visible",
      children: a.children
    }), l.return = e, l.sibling = null, t !== null && (u = e.deletions, u === null ? (e.deletions = [t], e.flags |= 16) : u.push(t)), e.child = l, e.memoizedState = null, l);
  }
  function Ec(t, e) {
    return e = Ou(
      { mode: "visible", children: e },
      t.mode
    ), e.return = t, t.child = e;
  }
  function Ou(t, e) {
    return t = qe(22, t, null, e), t.lanes = 0, t;
  }
  function Ac(t, e, l) {
    return La(e, t.child, null, l), t = Ec(
      e,
      e.pendingProps.children
    ), t.flags |= 2, e.memoizedState = null, t;
  }
  function Ts(t, e, l) {
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
  function zs(t, e, l) {
    var a = e.pendingProps, n = a.revealOrder, i = a.tail;
    a = a.children;
    var u = $t.current, c = (u & 2) !== 0;
    if (c ? (u = u & 1 | 2, e.flags |= 128) : u &= 1, B($t, u), he(t, e, a, l), a = St ? fi : 0, !c && t !== null && (t.flags & 128) !== 0)
      t: for (t = e.child; t !== null; ) {
        if (t.tag === 13)
          t.memoizedState !== null && Ts(t, l, e);
        else if (t.tag === 19)
          Ts(t, l, e);
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
          if (t = n.alternate, t !== null && yu(t) === null) {
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
    if (t !== null && (e.dependencies = t.dependencies), ia |= e.lanes, (l & e.childLanes) === 0)
      if (t !== null) {
        if (Sn(
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
    return (t.lanes & e) !== 0 ? !0 : (t = t.dependencies, !!(t !== null && ou(t)));
  }
  function oh(t, e, l) {
    switch (e.tag) {
      case 3:
        fe(e, e.stateNode.containerInfo), $l(e, ee, t.memoizedState.cache), Na();
        break;
      case 27:
      case 5:
        gl(e);
        break;
      case 4:
        fe(e, e.stateNode.containerInfo);
        break;
      case 10:
        $l(
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
          return a.dehydrated !== null ? (ea(e), e.flags |= 128, null) : (l & e.child.childLanes) !== 0 ? Ss(t, e, l) : (ea(e), t = Cl(
            t,
            e,
            l
          ), t !== null ? t.sibling : null);
        ea(e);
        break;
      case 19:
        var n = (t.flags & 128) !== 0;
        if (a = (l & e.childLanes) !== 0, a || (Sn(
          t,
          e,
          l,
          !1
        ), a = (l & e.childLanes) !== 0), n) {
          if (a)
            return zs(
              t,
              e,
              l
            );
          e.flags |= 128;
        }
        if (n = e.memoizedState, n !== null && (n.rendering = null, n.tail = null, n.lastEffect = null), B($t, $t.current), a) break;
        return null;
      case 22:
        return e.lanes = 0, gs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        $l(e, ee, t.memoizedState.cache);
    }
    return Cl(t, e, l);
  }
  function Ms(t, e, l) {
    if (t !== null)
      if (t.memoizedProps !== e.pendingProps)
        ae = !0;
      else {
        if (!Dc(t, l) && (e.flags & 128) === 0)
          return ae = !1, oh(
            t,
            e,
            l
          );
        ae = (t.flags & 131072) !== 0;
      }
    else
      ae = !1, St && (e.flags & 1048576) !== 0 && lr(e, fi, e.index);
    switch (e.lanes = 0, e.tag) {
      case 16:
        t: {
          var a = e.pendingProps;
          if (t = Ga(e.elementType), e.type = t, typeof t == "function")
            Rf(t) ? (a = Qa(t, a), e.tag = 1, e = bs(
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
              if (n === Ct) {
                e.tag = 11, e = ds(
                  null,
                  e,
                  t,
                  a,
                  l
                );
                break t;
              } else if (n === W) {
                e.tag = 14, e = ms(
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
        return a = e.type, n = Qa(
          a,
          e.pendingProps
        ), bs(
          t,
          e,
          a,
          n,
          l
        );
      case 3:
        t: {
          if (fe(
            e,
            e.stateNode.containerInfo
          ), t === null) throw Error(s(387));
          a = e.pendingProps;
          var i = e.memoizedState;
          n = i.element, kf(t, e), gi(e, a, null, l);
          var u = e.memoizedState;
          if (a = u.cache, $l(e, ee, a), a !== i.cache && Xf(
            e,
            [ee],
            l,
            !0
          ), hi(), a = u.element, i.isDehydrated)
            if (i = {
              element: a,
              isDehydrated: !1,
              cache: u.cache
            }, e.updateQueue.baseState = i, e.memoizedState = i, e.flags & 256) {
              e = xs(
                t,
                e,
                a,
                l
              );
              break t;
            } else if (a !== n) {
              n = Ke(
                Error(s(424)),
                e
              ), ci(n), e = xs(
                t,
                e,
                a,
                l
              );
              break t;
            } else
              for (t = e.stateNode.containerInfo, t.nodeType === 9 ? t = t.body : t = t.nodeName === "HTML" ? t.ownerDocument.body : t, Lt = $e(t.firstChild), de = e, St = !0, Fl = null, Fe = !0, l = gr(
                e,
                null,
                a,
                l
              ), e.child = l; l; )
                l.flags = l.flags & -3 | 4096, l = l.sibling;
          else {
            if (Na(), a === n) {
              e = Cl(
                t,
                e,
                l
              );
              break t;
            }
            he(t, e, a, l);
          }
          e = e.child;
        }
        return e;
      case 26:
        return Du(t, e), t === null ? (l = Nd(
          e.type,
          null,
          e.pendingProps,
          null
        )) ? e.memoizedState = l : St || (l = e.type, t = e.pendingProps, a = Zu(
          ct.current
        ).createElement(l), a[te] = e, a[re] = t, ge(a, l, t), Wt(a), e.stateNode = a) : e.memoizedState = Nd(
          e.type,
          t.memoizedProps,
          e.pendingProps,
          t.memoizedState
        ), null;
      case 27:
        return gl(e), t === null && St && (a = e.stateNode = wd(
          e.type,
          e.pendingProps,
          ct.current
        ), de = e, Fe = !0, n = Lt, ra(e.type) ? (fo = n, Lt = $e(a.firstChild)) : Lt = n), he(
          t,
          e,
          e.pendingProps.children,
          l
        ), Du(t, e), t === null && (e.flags |= 4194304), e.child;
      case 5:
        return t === null && St && ((n = a = Lt) && (a = Gh(
          a,
          e.type,
          e.pendingProps,
          Fe
        ), a !== null ? (e.stateNode = a, de = e, Lt = $e(a.firstChild), Fe = !1, n = !0) : n = !1), n || Wl(e)), gl(e), n = e.type, i = e.pendingProps, u = t !== null ? t.memoizedProps : null, a = i.children, lo(n, i) ? a = null : u !== null && lo(n, u) && (e.flags |= 32), e.memoizedState !== null && (n = ec(
          t,
          e,
          th,
          null,
          null,
          l
        ), Ni._currentValue = n), Du(t, e), he(t, e, a, l), e.child;
      case 6:
        return t === null && St && ((t = l = Lt) && (l = Yh(
          l,
          e.pendingProps,
          Fe
        ), l !== null ? (e.stateNode = l, de = e, Lt = null, t = !0) : t = !1), t || Wl(e)), null;
      case 13:
        return Ss(t, e, l);
      case 4:
        return fe(
          e,
          e.stateNode.containerInfo
        ), a = e.pendingProps, t === null ? e.child = La(
          e,
          null,
          a,
          l
        ) : he(t, e, a, l), e.child;
      case 11:
        return ds(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 7:
        return he(
          t,
          e,
          e.pendingProps,
          l
        ), e.child;
      case 8:
        return he(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 12:
        return he(
          t,
          e,
          e.pendingProps.children,
          l
        ), e.child;
      case 10:
        return a = e.pendingProps, $l(e, e.type, a.value), he(t, e, a.children, l), e.child;
      case 9:
        return n = e.type._context, a = e.pendingProps.children, ja(e), n = me(n), a = a(n), e.flags |= 1, he(t, e, a, l), e.child;
      case 14:
        return ms(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 15:
        return hs(
          t,
          e,
          e.type,
          e.pendingProps,
          l
        );
      case 19:
        return zs(t, e, l);
      case 31:
        return ch(t, e, l);
      case 22:
        return gs(
          t,
          e,
          l,
          e.pendingProps
        );
      case 24:
        return ja(e), a = me(ee), t === null ? (n = Zf(), n === null && (n = Yt, i = Qf(), n.pooledCache = i, i.refCount++, i !== null && (n.pooledCacheLanes |= l), n = i), e.memoizedState = { parent: a, cache: n }, Jf(e), $l(e, ee, n)) : ((t.lanes & l) !== 0 && (kf(t, e), gi(e, null, null, l), hi()), n = t.memoizedState, i = e.memoizedState, n.parent !== a ? (n = { parent: a, cache: a }, e.memoizedState = n, e.lanes === 0 && (e.memoizedState = e.updateQueue.baseState = n), $l(e, ee, a)) : (a = i.cache, $l(e, ee, a), a !== n.cache && Xf(
          e,
          [ee],
          l,
          !0
        ))), he(
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
        else if ($s()) t.flags |= 8192;
        else
          throw Ya = mu, Kf;
    } else t.flags &= -16777217;
  }
  function Es(t, e) {
    if (e.type !== "stylesheet" || (e.state.loading & 4) !== 0)
      t.flags &= -16777217;
    else if (t.flags |= 16777216, !Yd(e))
      if ($s()) t.flags |= 8192;
      else
        throw Ya = mu, Kf;
  }
  function Cu(t, e) {
    e !== null && (t.flags |= 4), t.flags & 16384 && (e = t.tag !== 22 ? Ki() : 536870912, t.lanes |= e, Rn |= e);
  }
  function Si(t, e) {
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
  function rh(t, e, l) {
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
        return l = e.stateNode, a = null, t !== null && (a = t.memoizedState.cache), e.memoizedState.cache !== a && (e.flags |= 2048), _l(ee), Bt(), l.pendingContext && (l.context = l.pendingContext, l.pendingContext = null), (t === null || t.child === null) && (xn(e) ? Ul(e) : t === null || t.memoizedState.isDehydrated && (e.flags & 256) === 0 || (e.flags |= 1024, Gf())), Xt(e), null;
      case 26:
        var n = e.type, i = e.memoizedState;
        return t === null ? (Ul(e), i !== null ? (Xt(e), Es(e, i)) : (Xt(e), Oc(
          e,
          n,
          null,
          a,
          l
        ))) : i ? i !== t.memoizedState ? (Ul(e), Xt(e), Es(e, i)) : (Xt(e), e.flags &= -16777217) : (t = t.memoizedProps, t !== a && Ul(e), Xt(e), Oc(
          e,
          n,
          t,
          a,
          l
        )), null;
      case 27:
        if (Ve(e), l = ct.current, n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Ul(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          t = G.current, xn(e) ? nr(e) : (t = wd(n, a, l), e.stateNode = t, Ul(e));
        }
        return Xt(e), null;
      case 5:
        if (Ve(e), n = e.type, t !== null && e.stateNode != null)
          t.memoizedProps !== a && Ul(e);
        else {
          if (!a) {
            if (e.stateNode === null)
              throw Error(s(166));
            return Xt(e), null;
          }
          if (i = G.current, xn(e))
            nr(e);
          else {
            var u = Zu(
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
            i[te] = e, i[re] = a;
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
            t: switch (ge(i, n, a), n) {
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
          if (t = ct.current, xn(e)) {
            if (t = e.stateNode, l = e.memoizedProps, a = null, n = de, n !== null)
              switch (n.tag) {
                case 27:
                case 5:
                  a = n.memoizedProps;
              }
            t[te] = e, t = !!(t.nodeValue === l || a !== null && a.suppressHydrationWarning === !0 || Sd(t.nodeValue, l)), t || Wl(e, !0);
          } else
            t = Zu(t).createTextNode(
              a
            ), t[te] = e, e.stateNode = t;
        }
        return Xt(e), null;
      case 31:
        if (l = e.memoizedState, t === null || t.memoizedState !== null) {
          if (a = xn(e), l !== null) {
            if (t === null) {
              if (!a) throw Error(s(318));
              if (t = e.memoizedState, t = t !== null ? t.dehydrated : null, !t) throw Error(s(557));
              t[te] = e;
            } else
              Na(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), t = !1;
          } else
            l = Gf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = l), t = !0;
          if (!t)
            return e.flags & 256 ? (Ye(e), e) : (Ye(e), null);
          if ((e.flags & 128) !== 0)
            throw Error(s(558));
        }
        return Xt(e), null;
      case 13:
        if (a = e.memoizedState, t === null || t.memoizedState !== null && t.memoizedState.dehydrated !== null) {
          if (n = xn(e), a !== null && a.dehydrated !== null) {
            if (t === null) {
              if (!n) throw Error(s(318));
              if (n = e.memoizedState, n = n !== null ? n.dehydrated : null, !n) throw Error(s(317));
              n[te] = e;
            } else
              Na(), (e.flags & 128) === 0 && (e.memoizedState = null), e.flags |= 4;
            Xt(e), n = !1;
          } else
            n = Gf(), t !== null && t.memoizedState !== null && (t.memoizedState.hydrationErrors = n), n = !0;
          if (!n)
            return e.flags & 256 ? (Ye(e), e) : (Ye(e), null);
        }
        return Ye(e), (e.flags & 128) !== 0 ? (e.lanes = l, e) : (l = a !== null, t = t !== null && t.memoizedState !== null, l && (a = e.child, n = null, a.alternate !== null && a.alternate.memoizedState !== null && a.alternate.memoizedState.cachePool !== null && (n = a.alternate.memoizedState.cachePool.pool), i = null, a.memoizedState !== null && a.memoizedState.cachePool !== null && (i = a.memoizedState.cachePool.pool), i !== n && (a.flags |= 2048)), l !== t && l && (e.child.flags |= 8192), Cu(e, e.updateQueue), Xt(e), null);
      case 4:
        return Bt(), t === null && $c(e.stateNode.containerInfo), Xt(e), null;
      case 10:
        return _l(e.type), Xt(e), null;
      case 19:
        if (_($t), a = e.memoizedState, a === null) return Xt(e), null;
        if (n = (e.flags & 128) !== 0, i = a.rendering, i === null)
          if (n) Si(a, !1);
          else {
            if (kt !== 0 || t !== null && (t.flags & 128) !== 0)
              for (t = e.child; t !== null; ) {
                if (i = yu(t), i !== null) {
                  for (e.flags |= 128, Si(a, !1), t = i.updateQueue, e.updateQueue = t, Cu(e, t), e.subtreeFlags = 0, t = l, l = e.child; l !== null; )
                    Po(l, t), l = l.sibling;
                  return B(
                    $t,
                    $t.current & 1 | 2
                  ), St && El(e, a.treeForkCount), e.child;
                }
                t = t.sibling;
              }
            a.tail !== null && pe() > Nu && (e.flags |= 128, n = !0, Si(a, !1), e.lanes = 4194304);
          }
        else {
          if (!n)
            if (t = yu(i), t !== null) {
              if (e.flags |= 128, n = !0, t = t.updateQueue, e.updateQueue = t, Cu(e, t), Si(a, !0), a.tail === null && a.tailMode === "hidden" && !i.alternate && !St)
                return Xt(e), null;
            } else
              2 * pe() - a.renderingStartTime > Nu && l !== 536870912 && (e.flags |= 128, n = !0, Si(a, !1), e.lanes = 4194304);
          a.isBackwards ? (i.sibling = e.child, e.child = i) : (t = a.last, t !== null ? t.sibling = i : e.child = i, a.last = i);
        }
        return a.tail !== null ? (t = a.tail, a.rendering = t, a.tail = t.sibling, a.renderingStartTime = pe(), t.sibling = null, l = $t.current, B(
          $t,
          n ? l & 1 | 2 : l & 1
        ), St && El(e, a.treeForkCount), t) : (Xt(e), null);
      case 22:
      case 23:
        return Ye(e), If(), a = e.memoizedState !== null, t !== null ? t.memoizedState !== null !== a && (e.flags |= 8192) : a && (e.flags |= 8192), a ? (l & 536870912) !== 0 && (e.flags & 128) === 0 && (Xt(e), e.subtreeFlags & 6 && (e.flags |= 8192)) : Xt(e), l = e.updateQueue, l !== null && Cu(e, l.retryQueue), l = null, t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), a = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (a = e.memoizedState.cachePool.pool), a !== l && (e.flags |= 2048), t !== null && _(qa), null;
      case 24:
        return l = null, t !== null && (l = t.memoizedState.cache), e.memoizedState.cache !== l && (e.flags |= 2048), _l(ee), Xt(e), null;
      case 25:
        return null;
      case 30:
        return null;
    }
    throw Error(s(156, e.tag));
  }
  function sh(t, e) {
    switch (jf(e), e.tag) {
      case 1:
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 3:
        return _l(ee), Bt(), t = e.flags, (t & 65536) !== 0 && (t & 128) === 0 ? (e.flags = t & -65537 | 128, e) : null;
      case 26:
      case 27:
      case 5:
        return Ve(e), null;
      case 31:
        if (e.memoizedState !== null) {
          if (Ye(e), e.alternate === null)
            throw Error(s(340));
          Na();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 13:
        if (Ye(e), t = e.memoizedState, t !== null && t.dehydrated !== null) {
          if (e.alternate === null)
            throw Error(s(340));
          Na();
        }
        return t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 19:
        return _($t), null;
      case 4:
        return Bt(), null;
      case 10:
        return _l(e.type), null;
      case 22:
      case 23:
        return Ye(e), If(), t !== null && _(qa), t = e.flags, t & 65536 ? (e.flags = t & -65537 | 128, e) : null;
      case 24:
        return _l(ee), null;
      case 25:
        return null;
      default:
        return null;
    }
  }
  function As(t, e) {
    switch (jf(e), e.tag) {
      case 3:
        _l(ee), Bt();
        break;
      case 26:
      case 27:
      case 5:
        Ve(e);
        break;
      case 4:
        Bt();
        break;
      case 31:
        e.memoizedState !== null && Ye(e);
        break;
      case 13:
        Ye(e);
        break;
      case 19:
        _($t);
        break;
      case 10:
        _l(e.type);
        break;
      case 22:
      case 23:
        Ye(e), If(), t !== null && _(qa);
        break;
      case 24:
        _l(ee);
    }
  }
  function Ti(t, e) {
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
      Ht(e, e.return, c);
    }
  }
  function aa(t, e, l) {
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
              var r = l, b = c;
              try {
                b();
              } catch (E) {
                Ht(
                  n,
                  r,
                  E
                );
              }
            }
          }
          a = a.next;
        } while (a !== i);
      }
    } catch (E) {
      Ht(e, e.return, E);
    }
  }
  function _s(t) {
    var e = t.updateQueue;
    if (e !== null) {
      var l = t.stateNode;
      try {
        yr(e, l);
      } catch (a) {
        Ht(t, t.return, a);
      }
    }
  }
  function Ds(t, e, l) {
    l.props = Qa(
      t.type,
      t.memoizedProps
    ), l.state = t.memoizedState;
    try {
      l.componentWillUnmount();
    } catch (a) {
      Ht(t, e, a);
    }
  }
  function zi(t, e) {
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
      Ht(t, e, n);
    }
  }
  function ml(t, e) {
    var l = t.ref, a = t.refCleanup;
    if (l !== null)
      if (typeof a == "function")
        try {
          a();
        } catch (n) {
          Ht(t, e, n);
        } finally {
          t.refCleanup = null, t = t.alternate, t != null && (t.refCleanup = null);
        }
      else if (typeof l == "function")
        try {
          l(null);
        } catch (n) {
          Ht(t, e, n);
        }
      else l.current = null;
  }
  function Os(t) {
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
      Ht(t, t.return, n);
    }
  }
  function Cc(t, e, l) {
    try {
      var a = t.stateNode;
      Rh(a, t.type, l, e), a[re] = e;
    } catch (n) {
      Ht(t, t.return, n);
    }
  }
  function Cs(t) {
    return t.tag === 5 || t.tag === 3 || t.tag === 26 || t.tag === 27 && ra(t.type) || t.tag === 4;
  }
  function Uc(t) {
    t: for (; ; ) {
      for (; t.sibling === null; ) {
        if (t.return === null || Cs(t.return)) return null;
        t = t.return;
      }
      for (t.sibling.return = t.return, t = t.sibling; t.tag !== 5 && t.tag !== 6 && t.tag !== 18; ) {
        if (t.tag === 27 && ra(t.type) || t.flags & 2 || t.child === null || t.tag === 4) continue t;
        t.child.return = t, t = t.child;
      }
      if (!(t.flags & 2)) return t.stateNode;
    }
  }
  function wc(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? (l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l).insertBefore(t, e) : (e = l.nodeType === 9 ? l.body : l.nodeName === "HTML" ? l.ownerDocument.body : l, e.appendChild(t), l = l._reactRootContainer, l != null || e.onclick !== null || (e.onclick = tl));
    else if (a !== 4 && (a === 27 && ra(t.type) && (l = t.stateNode, e = null), t = t.child, t !== null))
      for (wc(t, e, l), t = t.sibling; t !== null; )
        wc(t, e, l), t = t.sibling;
  }
  function Uu(t, e, l) {
    var a = t.tag;
    if (a === 5 || a === 6)
      t = t.stateNode, e ? l.insertBefore(t, e) : l.appendChild(t);
    else if (a !== 4 && (a === 27 && ra(t.type) && (l = t.stateNode), t = t.child, t !== null))
      for (Uu(t, e, l), t = t.sibling; t !== null; )
        Uu(t, e, l), t = t.sibling;
  }
  function Us(t) {
    var e = t.stateNode, l = t.memoizedProps;
    try {
      for (var a = t.type, n = e.attributes; n.length; )
        e.removeAttributeNode(n[0]);
      ge(e, a, l), e[te] = t, e[re] = l;
    } catch (i) {
      Ht(t, t.return, i);
    }
  }
  var wl = !1, ne = !1, Rc = !1, ws = typeof WeakSet == "function" ? WeakSet : Set, ce = null;
  function dh(t, e) {
    if (t = t.containerInfo, to = Iu, t = Vo(t), Af(t)) {
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
            var u = 0, c = -1, r = -1, b = 0, E = 0, O = t, S = null;
            e: for (; ; ) {
              for (var M; O !== l || n !== 0 && O.nodeType !== 3 || (c = u + n), O !== i || a !== 0 && O.nodeType !== 3 || (r = u + a), O.nodeType === 3 && (u += O.nodeValue.length), (M = O.firstChild) !== null; )
                S = O, O = M;
              for (; ; ) {
                if (O === t) break e;
                if (S === l && ++b === n && (c = u), S === i && ++E === a && (r = u), (M = O.nextSibling) !== null) break;
                O = S, S = O.parentNode;
              }
              O = M;
            }
            l = c === -1 || r === -1 ? null : { start: c, end: r };
          } else l = null;
        }
      l = l || { start: 0, end: 0 };
    } else l = null;
    for (eo = { focusedElem: t, selectionRange: l }, Iu = !1, ce = e; ce !== null; )
      if (e = ce, t = e.child, (e.subtreeFlags & 1028) !== 0 && t !== null)
        t.return = e, ce = t;
      else
        for (; ce !== null; ) {
          switch (e = ce, i = e.alternate, t = e.flags, e.tag) {
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
                  var Y = Qa(
                    l.type,
                    n
                  );
                  t = a.getSnapshotBeforeUpdate(
                    Y,
                    i
                  ), a.__reactInternalSnapshotBeforeUpdate = t;
                } catch ($) {
                  Ht(
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
            t.return = e.return, ce = t;
            break;
          }
          ce = e.return;
        }
  }
  function Rs(t, e, l) {
    var a = l.flags;
    switch (l.tag) {
      case 0:
      case 11:
      case 15:
        Bl(t, l), a & 4 && Ti(5, l);
        break;
      case 1:
        if (Bl(t, l), a & 4)
          if (t = l.stateNode, e === null)
            try {
              t.componentDidMount();
            } catch (u) {
              Ht(l, l.return, u);
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
            } catch (u) {
              Ht(
                l,
                l.return,
                u
              );
            }
          }
        a & 64 && _s(l), a & 512 && zi(l, l.return);
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
            yr(t, e);
          } catch (u) {
            Ht(l, l.return, u);
          }
        }
        break;
      case 27:
        e === null && a & 4 && Us(l);
      case 26:
      case 5:
        Bl(t, l), e === null && a & 4 && Os(l), a & 512 && zi(l, l.return);
        break;
      case 12:
        Bl(t, l);
        break;
      case 31:
        Bl(t, l), a & 4 && Hs(t, l);
        break;
      case 13:
        Bl(t, l), a & 4 && js(t, l), a & 64 && (t = l.memoizedState, t !== null && (t = t.dehydrated, t !== null && (l = Sh.bind(
          null,
          l
        ), Lh(t, l))));
        break;
      case 22:
        if (a = l.memoizedState !== null || wl, !a) {
          e = e !== null && e.memoizedState !== null || ne, n = wl;
          var i = ne;
          wl = a, (ne = e) && !i ? Nl(
            t,
            l,
            (l.subtreeFlags & 8772) !== 0
          ) : Bl(t, l), wl = n, ne = i;
        }
        break;
      case 30:
        break;
      default:
        Bl(t, l);
    }
  }
  function Bs(t) {
    var e = t.alternate;
    e !== null && (t.alternate = null, Bs(e)), t.child = null, t.deletions = null, t.sibling = null, t.tag === 5 && (e = t.stateNode, e !== null && xa(e)), t.stateNode = null, t.return = null, t.dependencies = null, t.memoizedProps = null, t.memoizedState = null, t.pendingProps = null, t.stateNode = null, t.updateQueue = null;
  }
  var Qt = null, Oe = !1;
  function Rl(t, e, l) {
    for (l = l.child; l !== null; )
      Ns(t, e, l), l = l.sibling;
  }
  function Ns(t, e, l) {
    if (xe && typeof xe.onCommitFiberUnmount == "function")
      try {
        xe.onCommitFiberUnmount(va, l);
      } catch {
      }
    switch (l.tag) {
      case 26:
        ne || ml(l, e), Rl(
          t,
          e,
          l
        ), l.memoizedState ? l.memoizedState.count-- : l.stateNode && (l = l.stateNode, l.parentNode.removeChild(l));
        break;
      case 27:
        ne || ml(l, e);
        var a = Qt, n = Oe;
        ra(l.type) && (Qt = l.stateNode, Oe = !1), Rl(
          t,
          e,
          l
        ), wi(l.stateNode), Qt = a, Oe = n;
        break;
      case 5:
        ne || ml(l, e);
      case 6:
        if (a = Qt, n = Oe, Qt = null, Rl(
          t,
          e,
          l
        ), Qt = a, Oe = n, Qt !== null)
          if (Oe)
            try {
              (Qt.nodeType === 9 ? Qt.body : Qt.nodeName === "HTML" ? Qt.ownerDocument.body : Qt).removeChild(l.stateNode);
            } catch (i) {
              Ht(
                l,
                e,
                i
              );
            }
          else
            try {
              Qt.removeChild(l.stateNode);
            } catch (i) {
              Ht(
                l,
                e,
                i
              );
            }
        break;
      case 18:
        Qt !== null && (Oe ? (t = Qt, _d(
          t.nodeType === 9 ? t.body : t.nodeName === "HTML" ? t.ownerDocument.body : t,
          l.stateNode
        ), Ln(t)) : _d(Qt, l.stateNode));
        break;
      case 4:
        a = Qt, n = Oe, Qt = l.stateNode.containerInfo, Oe = !0, Rl(
          t,
          e,
          l
        ), Qt = a, Oe = n;
        break;
      case 0:
      case 11:
      case 14:
      case 15:
        aa(2, l, e), ne || aa(4, l, e), Rl(
          t,
          e,
          l
        );
        break;
      case 1:
        ne || (ml(l, e), a = l.stateNode, typeof a.componentWillUnmount == "function" && Ds(
          l,
          e,
          a
        )), Rl(
          t,
          e,
          l
        );
        break;
      case 21:
        Rl(
          t,
          e,
          l
        );
        break;
      case 22:
        ne = (a = ne) || l.memoizedState !== null, Rl(
          t,
          e,
          l
        ), ne = a;
        break;
      default:
        Rl(
          t,
          e,
          l
        );
    }
  }
  function Hs(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null))) {
      t = t.dehydrated;
      try {
        Ln(t);
      } catch (l) {
        Ht(e, e.return, l);
      }
    }
  }
  function js(t, e) {
    if (e.memoizedState === null && (t = e.alternate, t !== null && (t = t.memoizedState, t !== null && (t = t.dehydrated, t !== null))))
      try {
        Ln(t);
      } catch (l) {
        Ht(e, e.return, l);
      }
  }
  function mh(t) {
    switch (t.tag) {
      case 31:
      case 13:
      case 19:
        var e = t.stateNode;
        return e === null && (e = t.stateNode = new ws()), e;
      case 22:
        return t = t.stateNode, e = t._retryCache, e === null && (e = t._retryCache = new ws()), e;
      default:
        throw Error(s(435, t.tag));
    }
  }
  function wu(t, e) {
    var l = mh(t);
    e.forEach(function(a) {
      if (!l.has(a)) {
        l.add(a);
        var n = Th.bind(null, t, a);
        a.then(n, n);
      }
    });
  }
  function Ce(t, e) {
    var l = e.deletions;
    if (l !== null)
      for (var a = 0; a < l.length; a++) {
        var n = l[a], i = t, u = e, c = u;
        t: for (; c !== null; ) {
          switch (c.tag) {
            case 27:
              if (ra(c.type)) {
                Qt = c.stateNode, Oe = !1;
                break t;
              }
              break;
            case 5:
              Qt = c.stateNode, Oe = !1;
              break t;
            case 3:
            case 4:
              Qt = c.stateNode.containerInfo, Oe = !0;
              break t;
          }
          c = c.return;
        }
        if (Qt === null) throw Error(s(160));
        Ns(i, u, n), Qt = null, Oe = !1, i = n.alternate, i !== null && (i.return = null), n.return = null;
      }
    if (e.subtreeFlags & 13886)
      for (e = e.child; e !== null; )
        qs(e, t), e = e.sibling;
  }
  var nl = null;
  function qs(t, e) {
    var l = t.alternate, a = t.flags;
    switch (t.tag) {
      case 0:
      case 11:
      case 14:
      case 15:
        Ce(e, t), Ue(t), a & 4 && (aa(3, t, t.return), Ti(3, t), aa(5, t, t.return));
        break;
      case 1:
        Ce(e, t), Ue(t), a & 512 && (ne || l === null || ml(l, l.return)), a & 64 && wl && (t = t.updateQueue, t !== null && (a = t.callbacks, a !== null && (l = t.shared.hiddenCallbacks, t.shared.hiddenCallbacks = l === null ? a : l.concat(a))));
        break;
      case 26:
        var n = nl;
        if (Ce(e, t), Ue(t), a & 512 && (ne || l === null || ml(l, l.return)), a & 4) {
          var i = l !== null ? l.memoizedState : null;
          if (a = t.memoizedState, l === null)
            if (a === null)
              if (t.stateNode === null) {
                t: {
                  a = t.type, l = t.memoizedProps, n = n.ownerDocument || n;
                  e: switch (a) {
                    case "title":
                      i = n.getElementsByTagName("title")[0], (!i || i[Xl] || i[te] || i.namespaceURI === "http://www.w3.org/2000/svg" || i.hasAttribute("itemprop")) && (i = n.createElement(a), n.head.insertBefore(
                        i,
                        n.querySelector("head > title")
                      )), ge(i, a, l), i[te] = t, Wt(i), a = i;
                      break t;
                    case "link":
                      var u = qd(
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
                      i = n.createElement(a), ge(i, a, l), n.head.appendChild(i);
                      break;
                    case "meta":
                      if (u = qd(
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
                      i = n.createElement(a), ge(i, a, l), n.head.appendChild(i);
                      break;
                    default:
                      throw Error(s(468, a));
                  }
                  i[te] = t, Wt(i), a = i;
                }
                t.stateNode = a;
              } else
                Gd(
                  n,
                  t.type,
                  t.stateNode
                );
            else
              t.stateNode = jd(
                n,
                a,
                t.memoizedProps
              );
          else
            i !== a ? (i === null ? l.stateNode !== null && (l = l.stateNode, l.parentNode.removeChild(l)) : i.count--, a === null ? Gd(
              n,
              t.type,
              t.stateNode
            ) : jd(
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
        Ce(e, t), Ue(t), a & 512 && (ne || l === null || ml(l, l.return)), l !== null && a & 4 && Cc(
          t,
          t.memoizedProps,
          l.memoizedProps
        );
        break;
      case 5:
        if (Ce(e, t), Ue(t), a & 512 && (ne || l === null || ml(l, l.return)), t.flags & 32) {
          n = t.stateNode;
          try {
            j(n, "");
          } catch (Y) {
            Ht(t, t.return, Y);
          }
        }
        a & 4 && t.stateNode != null && (n = t.memoizedProps, Cc(
          t,
          n,
          l !== null ? l.memoizedProps : n
        )), a & 1024 && (Rc = !0);
        break;
      case 6:
        if (Ce(e, t), Ue(t), a & 4) {
          if (t.stateNode === null)
            throw Error(s(162));
          a = t.memoizedProps, l = t.stateNode;
          try {
            l.nodeValue = a;
          } catch (Y) {
            Ht(t, t.return, Y);
          }
        }
        break;
      case 3:
        if (ku = null, n = nl, nl = Ku(e.containerInfo), Ce(e, t), nl = n, Ue(t), a & 4 && l !== null && l.memoizedState.isDehydrated)
          try {
            Ln(e.containerInfo);
          } catch (Y) {
            Ht(t, t.return, Y);
          }
        Rc && (Rc = !1, Gs(t));
        break;
      case 4:
        a = nl, nl = Ku(
          t.stateNode.containerInfo
        ), Ce(e, t), Ue(t), nl = a;
        break;
      case 12:
        Ce(e, t), Ue(t);
        break;
      case 31:
        Ce(e, t), Ue(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, wu(t, a)));
        break;
      case 13:
        Ce(e, t), Ue(t), t.child.flags & 8192 && t.memoizedState !== null != (l !== null && l.memoizedState !== null) && (Bu = pe()), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, wu(t, a)));
        break;
      case 22:
        n = t.memoizedState !== null;
        var r = l !== null && l.memoizedState !== null, b = wl, E = ne;
        if (wl = b || n, ne = E || r, Ce(e, t), ne = E, wl = b, Ue(t), a & 8192)
          t: for (e = t.stateNode, e._visibility = n ? e._visibility & -2 : e._visibility | 1, n && (l === null || r || wl || ne || Va(t)), l = null, e = t; ; ) {
            if (e.tag === 5 || e.tag === 26) {
              if (l === null) {
                r = l = e;
                try {
                  if (i = r.stateNode, n)
                    u = i.style, typeof u.setProperty == "function" ? u.setProperty("display", "none", "important") : u.display = "none";
                  else {
                    c = r.stateNode;
                    var O = r.memoizedProps.style, S = O != null && O.hasOwnProperty("display") ? O.display : null;
                    c.style.display = S == null || typeof S == "boolean" ? "" : ("" + S).trim();
                  }
                } catch (Y) {
                  Ht(r, r.return, Y);
                }
              }
            } else if (e.tag === 6) {
              if (l === null) {
                r = e;
                try {
                  r.stateNode.nodeValue = n ? "" : r.memoizedProps;
                } catch (Y) {
                  Ht(r, r.return, Y);
                }
              }
            } else if (e.tag === 18) {
              if (l === null) {
                r = e;
                try {
                  var M = r.stateNode;
                  n ? Dd(M, !0) : Dd(r.stateNode, !1);
                } catch (Y) {
                  Ht(r, r.return, Y);
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
        Ce(e, t), Ue(t), a & 4 && (a = t.updateQueue, a !== null && (t.updateQueue = null, wu(t, a)));
        break;
      case 30:
        break;
      case 21:
        break;
      default:
        Ce(e, t), Ue(t);
    }
  }
  function Ue(t) {
    var e = t.flags;
    if (e & 2) {
      try {
        for (var l, a = t.return; a !== null; ) {
          if (Cs(a)) {
            l = a;
            break;
          }
          a = a.return;
        }
        if (l == null) throw Error(s(160));
        switch (l.tag) {
          case 27:
            var n = l.stateNode, i = Uc(t);
            Uu(t, i, n);
            break;
          case 5:
            var u = l.stateNode;
            l.flags & 32 && (j(u, ""), l.flags &= -33);
            var c = Uc(t);
            Uu(t, c, u);
            break;
          case 3:
          case 4:
            var r = l.stateNode.containerInfo, b = Uc(t);
            wc(
              t,
              b,
              r
            );
            break;
          default:
            throw Error(s(161));
        }
      } catch (E) {
        Ht(t, t.return, E);
      }
      t.flags &= -3;
    }
    e & 4096 && (t.flags &= -4097);
  }
  function Gs(t) {
    if (t.subtreeFlags & 1024)
      for (t = t.child; t !== null; ) {
        var e = t;
        Gs(e), e.tag === 5 && e.flags & 1024 && e.stateNode.reset(), t = t.sibling;
      }
  }
  function Bl(t, e) {
    if (e.subtreeFlags & 8772)
      for (e = e.child; e !== null; )
        Rs(t, e.alternate, e), e = e.sibling;
  }
  function Va(t) {
    for (t = t.child; t !== null; ) {
      var e = t;
      switch (e.tag) {
        case 0:
        case 11:
        case 14:
        case 15:
          aa(4, e, e.return), Va(e);
          break;
        case 1:
          ml(e, e.return);
          var l = e.stateNode;
          typeof l.componentWillUnmount == "function" && Ds(
            e,
            e.return,
            l
          ), Va(e);
          break;
        case 27:
          wi(e.stateNode);
        case 26:
        case 5:
          ml(e, e.return), Va(e);
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
          ), Ti(4, i);
          break;
        case 1:
          if (Nl(
            n,
            i,
            l
          ), a = i, n = a.stateNode, typeof n.componentDidMount == "function")
            try {
              n.componentDidMount();
            } catch (b) {
              Ht(a, a.return, b);
            }
          if (a = i, n = a.updateQueue, n !== null) {
            var c = a.stateNode;
            try {
              var r = n.shared.hiddenCallbacks;
              if (r !== null)
                for (n.shared.hiddenCallbacks = null, n = 0; n < r.length; n++)
                  pr(r[n], c);
            } catch (b) {
              Ht(a, a.return, b);
            }
          }
          l && u & 64 && _s(i), zi(i, i.return);
          break;
        case 27:
          Us(i);
        case 26:
        case 5:
          Nl(
            n,
            i,
            l
          ), l && a === null && u & 4 && Os(i), zi(i, i.return);
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
          ), l && u & 4 && Hs(n, i);
          break;
        case 13:
          Nl(
            n,
            i,
            l
          ), l && u & 4 && js(n, i);
          break;
        case 22:
          i.memoizedState === null && Nl(
            n,
            i,
            l
          ), zi(i, i.return);
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
    t !== null && t.memoizedState !== null && t.memoizedState.cachePool !== null && (l = t.memoizedState.cachePool.pool), t = null, e.memoizedState !== null && e.memoizedState.cachePool !== null && (t = e.memoizedState.cachePool.pool), t !== l && (t != null && t.refCount++, l != null && oi(l));
  }
  function Nc(t, e) {
    t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && oi(t));
  }
  function il(t, e, l, a) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; )
        Ys(
          t,
          e,
          l,
          a
        ), e = e.sibling;
  }
  function Ys(t, e, l, a) {
    var n = e.flags;
    switch (e.tag) {
      case 0:
      case 11:
      case 15:
        il(
          t,
          e,
          l,
          a
        ), n & 2048 && Ti(9, e);
        break;
      case 1:
        il(
          t,
          e,
          l,
          a
        );
        break;
      case 3:
        il(
          t,
          e,
          l,
          a
        ), n & 2048 && (t = null, e.alternate !== null && (t = e.alternate.memoizedState.cache), e = e.memoizedState.cache, e !== t && (e.refCount++, t != null && oi(t)));
        break;
      case 12:
        if (n & 2048) {
          il(
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
            Ht(e, e.return, r);
          }
        } else
          il(
            t,
            e,
            l,
            a
          );
        break;
      case 31:
        il(
          t,
          e,
          l,
          a
        );
        break;
      case 13:
        il(
          t,
          e,
          l,
          a
        );
        break;
      case 23:
        break;
      case 22:
        i = e.stateNode, u = e.alternate, e.memoizedState !== null ? i._visibility & 2 ? il(
          t,
          e,
          l,
          a
        ) : Mi(t, e) : i._visibility & 2 ? il(
          t,
          e,
          l,
          a
        ) : (i._visibility |= 2, Cn(
          t,
          e,
          l,
          a,
          (e.subtreeFlags & 10256) !== 0 || !1
        )), n & 2048 && Bc(u, e);
        break;
      case 24:
        il(
          t,
          e,
          l,
          a
        ), n & 2048 && Nc(e.alternate, e);
        break;
      default:
        il(
          t,
          e,
          l,
          a
        );
    }
  }
  function Cn(t, e, l, a, n) {
    for (n = n && ((e.subtreeFlags & 10256) !== 0 || !1), e = e.child; e !== null; ) {
      var i = t, u = e, c = l, r = a, b = u.flags;
      switch (u.tag) {
        case 0:
        case 11:
        case 15:
          Cn(
            i,
            u,
            c,
            r,
            n
          ), Ti(8, u);
          break;
        case 23:
          break;
        case 22:
          var E = u.stateNode;
          u.memoizedState !== null ? E._visibility & 2 ? Cn(
            i,
            u,
            c,
            r,
            n
          ) : Mi(
            i,
            u
          ) : (E._visibility |= 2, Cn(
            i,
            u,
            c,
            r,
            n
          )), n && b & 2048 && Bc(
            u.alternate,
            u
          );
          break;
        case 24:
          Cn(
            i,
            u,
            c,
            r,
            n
          ), n && b & 2048 && Nc(u.alternate, u);
          break;
        default:
          Cn(
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
  function Mi(t, e) {
    if (e.subtreeFlags & 10256)
      for (e = e.child; e !== null; ) {
        var l = t, a = e, n = a.flags;
        switch (a.tag) {
          case 22:
            Mi(l, a), n & 2048 && Bc(
              a.alternate,
              a
            );
            break;
          case 24:
            Mi(l, a), n & 2048 && Nc(a.alternate, a);
            break;
          default:
            Mi(l, a);
        }
        e = e.sibling;
      }
  }
  var Ei = 8192;
  function Un(t, e, l) {
    if (t.subtreeFlags & Ei)
      for (t = t.child; t !== null; )
        Ls(
          t,
          e,
          l
        ), t = t.sibling;
  }
  function Ls(t, e, l) {
    switch (t.tag) {
      case 26:
        Un(
          t,
          e,
          l
        ), t.flags & Ei && t.memoizedState !== null && Ph(
          l,
          nl,
          t.memoizedState,
          t.memoizedProps
        );
        break;
      case 5:
        Un(
          t,
          e,
          l
        );
        break;
      case 3:
      case 4:
        var a = nl;
        nl = Ku(t.stateNode.containerInfo), Un(
          t,
          e,
          l
        ), nl = a;
        break;
      case 22:
        t.memoizedState === null && (a = t.alternate, a !== null && a.memoizedState !== null ? (a = Ei, Ei = 16777216, Un(
          t,
          e,
          l
        ), Ei = a) : Un(
          t,
          e,
          l
        ));
        break;
      default:
        Un(
          t,
          e,
          l
        );
    }
  }
  function Xs(t) {
    var e = t.alternate;
    if (e !== null && (t = e.child, t !== null)) {
      e.child = null;
      do
        e = t.sibling, t.sibling = null, t = e;
      while (t !== null);
    }
  }
  function Ai(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          ce = a, Vs(
            a,
            t
          );
        }
      Xs(t);
    }
    if (t.subtreeFlags & 10256)
      for (t = t.child; t !== null; )
        Qs(t), t = t.sibling;
  }
  function Qs(t) {
    switch (t.tag) {
      case 0:
      case 11:
      case 15:
        Ai(t), t.flags & 2048 && aa(9, t, t.return);
        break;
      case 3:
        Ai(t);
        break;
      case 12:
        Ai(t);
        break;
      case 22:
        var e = t.stateNode;
        t.memoizedState !== null && e._visibility & 2 && (t.return === null || t.return.tag !== 13) ? (e._visibility &= -3, Ru(t)) : Ai(t);
        break;
      default:
        Ai(t);
    }
  }
  function Ru(t) {
    var e = t.deletions;
    if ((t.flags & 16) !== 0) {
      if (e !== null)
        for (var l = 0; l < e.length; l++) {
          var a = e[l];
          ce = a, Vs(
            a,
            t
          );
        }
      Xs(t);
    }
    for (t = t.child; t !== null; ) {
      switch (e = t, e.tag) {
        case 0:
        case 11:
        case 15:
          aa(8, e, e.return), Ru(e);
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
  function Vs(t, e) {
    for (; ce !== null; ) {
      var l = ce;
      switch (l.tag) {
        case 0:
        case 11:
        case 15:
          aa(8, l, e);
          break;
        case 23:
        case 22:
          if (l.memoizedState !== null && l.memoizedState.cachePool !== null) {
            var a = l.memoizedState.cachePool.pool;
            a != null && a.refCount++;
          }
          break;
        case 24:
          oi(l.memoizedState.cache);
      }
      if (a = l.child, a !== null) a.return = l, ce = a;
      else
        t: for (l = t; ce !== null; ) {
          a = ce;
          var n = a.sibling, i = a.return;
          if (Bs(a), a === l) {
            ce = null;
            break t;
          }
          if (n !== null) {
            n.return = i, ce = n;
            break t;
          }
          ce = i;
        }
    }
  }
  var hh = {
    getCacheForType: function(t) {
      var e = me(ee), l = e.data.get(t);
      return l === void 0 && (l = t(), e.data.set(t, l)), l;
    },
    cacheSignal: function() {
      return me(ee).controller.signal;
    }
  }, gh = typeof WeakMap == "function" ? WeakMap : Map, Ut = 0, Yt = null, pt = null, vt = 0, Nt = 0, Le = null, na = !1, wn = !1, Hc = !1, Hl = 0, kt = 0, ia = 0, Za = 0, jc = 0, Xe = 0, Rn = 0, _i = null, we = null, qc = !1, Bu = 0, Zs = 0, Nu = 1 / 0, Hu = null, ua = null, ue = 0, fa = null, Bn = null, jl = 0, Gc = 0, Yc = null, Ks = null, Di = 0, Lc = null;
  function Qe() {
    return (Ut & 2) !== 0 && vt !== 0 ? vt & -vt : g.T !== null ? Jc() : Fn();
  }
  function Js() {
    if (Xe === 0)
      if ((vt & 536870912) === 0 || St) {
        var t = tn;
        tn <<= 1, (tn & 3932160) === 0 && (tn = 262144), Xe = t;
      } else Xe = 536870912;
    return t = Ge.current, t !== null && (t.flags |= 32), Xe;
  }
  function Re(t, e, l) {
    (t === Yt && (Nt === 2 || Nt === 9) || t.cancelPendingCommit !== null) && (Nn(t, 0), ca(
      t,
      vt,
      Xe,
      !1
    )), Yl(t, l), ((Ut & 2) === 0 || t !== Yt) && (t === Yt && ((Ut & 2) === 0 && (Za |= l), kt === 4 && ca(
      t,
      vt,
      Xe,
      !1
    )), hl(t));
  }
  function ks(t, e, l) {
    if ((Ut & 6) !== 0) throw Error(s(327));
    var a = !l && (e & 127) === 0 && (e & t.expiredLanes) === 0 || Ne(t, e), n = a ? vh(t, e) : Qc(t, e, !0), i = a;
    do {
      if (n === 0) {
        wn && !a && ca(t, e, 0, !1);
        break;
      } else {
        if (l = t.current.alternate, i && !ph(l)) {
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
              n = _i;
              var r = c.current.memoizedState.isDehydrated;
              if (r && (Nn(c, u).flags |= 256), u = Qc(
                c,
                u,
                !1
              ), u !== 2) {
                if (Hc && !r) {
                  c.errorRecoveryDisabledLanes |= i, Za |= i, n = 4;
                  break t;
                }
                i = we, we = n, i !== null && (we === null ? we = i : we.push.apply(
                  we,
                  i
                ));
              }
              n = u;
            }
            if (i = !1, n !== 2) continue;
          }
        }
        if (n === 1) {
          Nn(t, 0), ca(t, e, 0, !0);
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
              ca(
                a,
                e,
                Xe,
                !na
              );
              break t;
            case 2:
              we = null;
              break;
            case 3:
            case 5:
              break;
            default:
              throw Error(s(329));
          }
          if ((e & 62914560) === e && (n = Bu + 300 - pe(), 10 < n)) {
            if (ca(
              a,
              e,
              Xe,
              !na
            ), en(a, 0, !0) !== 0) break t;
            jl = e, a.timeoutHandle = Ed(
              Fs.bind(
                null,
                a,
                l,
                we,
                Hu,
                qc,
                e,
                Xe,
                Za,
                Rn,
                na,
                i,
                "Throttled",
                -0,
                0
              ),
              n
            );
            break t;
          }
          Fs(
            a,
            l,
            we,
            Hu,
            qc,
            e,
            Xe,
            Za,
            Rn,
            na,
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
  function Fs(t, e, l, a, n, i, u, c, r, b, E, O, S, M) {
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
      }, Ls(
        e,
        i,
        O
      );
      var Y = (i & 62914560) === i ? Bu - pe() : (i & 4194048) === i ? Zs - pe() : 0;
      if (Y = tg(
        O,
        Y
      ), Y !== null) {
        jl = i, t.cancelPendingCommit = Y(
          ad.bind(
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
            E,
            O,
            null,
            S,
            M
          )
        ), ca(t, i, u, !b);
        return;
      }
    }
    ad(
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
  function ph(t) {
    for (var e = t; ; ) {
      var l = e.tag;
      if ((l === 0 || l === 11 || l === 15) && e.flags & 16384 && (l = e.updateQueue, l !== null && (l = l.stores, l !== null)))
        for (var a = 0; a < l.length; a++) {
          var n = l[a], i = n.getSnapshot;
          n = n.value;
          try {
            if (!je(i(), n)) return !1;
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
  function ca(t, e, l, a) {
    e &= ~jc, e &= ~Za, t.suspendedLanes |= e, t.pingedLanes &= ~e, a && (t.warmLanes |= e), a = t.expirationTimes;
    for (var n = e; 0 < n; ) {
      var i = 31 - ye(n), u = 1 << i;
      a[i] = -1, n &= ~u;
    }
    l !== 0 && Se(t, l, e);
  }
  function ju() {
    return (Ut & 6) === 0 ? (Oi(0), !1) : !0;
  }
  function Xc() {
    if (pt !== null) {
      if (Nt === 0)
        var t = pt.return;
      else
        t = pt, Al = Ha = null, nc(t), En = null, si = 0, t = pt;
      for (; t !== null; )
        As(t.alternate, t), t = t.return;
      pt = null;
    }
  }
  function Nn(t, e) {
    var l = t.timeoutHandle;
    l !== -1 && (t.timeoutHandle = -1, Hh(l)), l = t.cancelPendingCommit, l !== null && (t.cancelPendingCommit = null, l()), jl = 0, Xc(), Yt = t, pt = l = Ml(t.current, null), vt = e, Nt = 0, Le = null, na = !1, wn = Ne(t, e), Hc = !1, Rn = Xe = jc = Za = ia = kt = 0, we = _i = null, qc = !1, (e & 8) !== 0 && (e |= e & 32);
    var a = t.entangledLanes;
    if (a !== 0)
      for (t = t.entanglements, a &= e; 0 < a; ) {
        var n = 31 - ye(a), i = 1 << n;
        e |= t[n], a &= ~i;
      }
    return Hl = e, nu(), l;
  }
  function Ws(t, e) {
    ot = null, g.H = bi, e === Mn || e === du ? (e = dr(), Nt = 3) : e === Kf ? (e = dr(), Nt = 4) : Nt = e === xc ? 8 : e !== null && typeof e == "object" && typeof e.then == "function" ? 6 : 1, Le = e, pt === null && (kt = 1, Au(
      t,
      Ke(e, t.current)
    ));
  }
  function $s() {
    var t = Ge.current;
    return t === null ? !0 : (vt & 4194048) === vt ? We === null : (vt & 62914560) === vt || (vt & 536870912) !== 0 ? t === We : !1;
  }
  function Is() {
    var t = g.H;
    return g.H = bi, t === null ? bi : t;
  }
  function Ps() {
    var t = g.A;
    return g.A = hh, t;
  }
  function qu() {
    kt = 4, na || (vt & 4194048) !== vt && Ge.current !== null || (wn = !0), (ia & 134217727) === 0 && (Za & 134217727) === 0 || Yt === null || ca(
      Yt,
      vt,
      Xe,
      !1
    );
  }
  function Qc(t, e, l) {
    var a = Ut;
    Ut |= 2;
    var n = Is(), i = Ps();
    (Yt !== t || vt !== e) && (Hu = null, Nn(t, e)), e = !1;
    var u = kt;
    t: do
      try {
        if (Nt !== 0 && pt !== null) {
          var c = pt, r = Le;
          switch (Nt) {
            case 8:
              Xc(), u = 6;
              break t;
            case 3:
            case 2:
            case 9:
            case 6:
              Ge.current === null && (e = !0);
              var b = Nt;
              if (Nt = 0, Le = null, Hn(t, c, r, b), l && wn) {
                u = 0;
                break t;
              }
              break;
            default:
              b = Nt, Nt = 0, Le = null, Hn(t, c, r, b);
          }
        }
        yh(), u = kt;
        break;
      } catch (E) {
        Ws(t, E);
      }
    while (!0);
    return e && t.shellSuspendCounter++, Al = Ha = null, Ut = a, g.H = n, g.A = i, pt === null && (Yt = null, vt = 0, nu()), u;
  }
  function yh() {
    for (; pt !== null; ) td(pt);
  }
  function vh(t, e) {
    var l = Ut;
    Ut |= 2;
    var a = Is(), n = Ps();
    Yt !== t || vt !== e ? (Hu = null, Nu = pe() + 500, Nn(t, e)) : wn = Ne(
      t,
      e
    );
    t: do
      try {
        if (Nt !== 0 && pt !== null) {
          e = pt;
          var i = Le;
          e: switch (Nt) {
            case 1:
              Nt = 0, Le = null, Hn(t, e, i, 1);
              break;
            case 2:
            case 9:
              if (rr(i)) {
                Nt = 0, Le = null, ed(e);
                break;
              }
              e = function() {
                Nt !== 2 && Nt !== 9 || Yt !== t || (Nt = 7), hl(t);
              }, i.then(e, e);
              break t;
            case 3:
              Nt = 7;
              break t;
            case 4:
              Nt = 5;
              break t;
            case 7:
              rr(i) ? (Nt = 0, Le = null, ed(e)) : (Nt = 0, Le = null, Hn(t, e, i, 7));
              break;
            case 5:
              var u = null;
              switch (pt.tag) {
                case 26:
                  u = pt.memoizedState;
                case 5:
                case 27:
                  var c = pt;
                  if (u ? Yd(u) : c.stateNode.complete) {
                    Nt = 0, Le = null;
                    var r = c.sibling;
                    if (r !== null) pt = r;
                    else {
                      var b = c.return;
                      b !== null ? (pt = b, Gu(b)) : pt = null;
                    }
                    break e;
                  }
              }
              Nt = 0, Le = null, Hn(t, e, i, 5);
              break;
            case 6:
              Nt = 0, Le = null, Hn(t, e, i, 6);
              break;
            case 8:
              Xc(), kt = 6;
              break t;
            default:
              throw Error(s(462));
          }
        }
        bh();
        break;
      } catch (E) {
        Ws(t, E);
      }
    while (!0);
    return Al = Ha = null, g.H = a, g.A = n, Ut = l, pt !== null ? 0 : (Yt = null, vt = 0, nu(), kt);
  }
  function bh() {
    for (; pt !== null && !Xi(); )
      td(pt);
  }
  function td(t) {
    var e = Ms(t.alternate, t, Hl);
    t.memoizedProps = t.pendingProps, e === null ? Gu(t) : pt = e;
  }
  function ed(t) {
    var e = t, l = e.alternate;
    switch (e.tag) {
      case 15:
      case 0:
        e = vs(
          l,
          e,
          e.pendingProps,
          e.type,
          void 0,
          vt
        );
        break;
      case 11:
        e = vs(
          l,
          e,
          e.pendingProps,
          e.type.render,
          e.ref,
          vt
        );
        break;
      case 5:
        nc(e);
      default:
        As(l, e), e = pt = Po(e, Hl), e = Ms(l, e, Hl);
    }
    t.memoizedProps = t.pendingProps, e === null ? Gu(t) : pt = e;
  }
  function Hn(t, e, l, a) {
    Al = Ha = null, nc(e), En = null, si = 0;
    var n = e.return;
    try {
      if (fh(
        t,
        n,
        e,
        l,
        vt
      )) {
        kt = 1, Au(
          t,
          Ke(l, t.current)
        ), pt = null;
        return;
      }
    } catch (i) {
      if (n !== null) throw pt = n, i;
      kt = 1, Au(
        t,
        Ke(l, t.current)
      ), pt = null;
      return;
    }
    e.flags & 32768 ? (St || a === 1 ? t = !0 : wn || (vt & 536870912) !== 0 ? t = !1 : (na = t = !0, (a === 2 || a === 9 || a === 3 || a === 6) && (a = Ge.current, a !== null && a.tag === 13 && (a.flags |= 16384))), ld(e, t)) : Gu(e);
  }
  function Gu(t) {
    var e = t;
    do {
      if ((e.flags & 32768) !== 0) {
        ld(
          e,
          na
        );
        return;
      }
      t = e.return;
      var l = rh(
        e.alternate,
        e,
        Hl
      );
      if (l !== null) {
        pt = l;
        return;
      }
      if (e = e.sibling, e !== null) {
        pt = e;
        return;
      }
      pt = e = t;
    } while (e !== null);
    kt === 0 && (kt = 5);
  }
  function ld(t, e) {
    do {
      var l = sh(t.alternate, t);
      if (l !== null) {
        l.flags &= 32767, pt = l;
        return;
      }
      if (l = t.return, l !== null && (l.flags |= 32768, l.subtreeFlags = 0, l.deletions = null), !e && (t = t.sibling, t !== null)) {
        pt = t;
        return;
      }
      pt = t = l;
    } while (t !== null);
    kt = 6, pt = null;
  }
  function ad(t, e, l, a, n, i, u, c, r) {
    t.cancelPendingCommit = null;
    do
      Yu();
    while (ue !== 0);
    if ((Ut & 6) !== 0) throw Error(s(327));
    if (e !== null) {
      if (e === t.current) throw Error(s(177));
      if (i = e.lanes | e.childLanes, i |= Uf, hf(
        t,
        l,
        i,
        u,
        c,
        r
      ), t === Yt && (pt = Yt = null, vt = 0), Bn = e, fa = t, jl = l, Gc = i, Yc = n, Ks = a, (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? (t.callbackNode = null, t.callbackPriority = 0, zh(Wa, function() {
        return cd(), null;
      })) : (t.callbackNode = null, t.callbackPriority = 0), a = (e.flags & 13878) !== 0, (e.subtreeFlags & 13878) !== 0 || a) {
        a = g.T, g.T = null, n = C.p, C.p = 2, u = Ut, Ut |= 4;
        try {
          dh(t, e, l);
        } finally {
          Ut = u, C.p = n, g.T = a;
        }
      }
      ue = 1, nd(), id(), ud();
    }
  }
  function nd() {
    if (ue === 1) {
      ue = 0;
      var t = fa, e = Bn, l = (e.flags & 13878) !== 0;
      if ((e.subtreeFlags & 13878) !== 0 || l) {
        l = g.T, g.T = null;
        var a = C.p;
        C.p = 2;
        var n = Ut;
        Ut |= 4;
        try {
          qs(e, t);
          var i = eo, u = Vo(t.containerInfo), c = i.focusedElem, r = i.selectionRange;
          if (u !== c && c && c.ownerDocument && Qo(
            c.ownerDocument.documentElement,
            c
          )) {
            if (r !== null && Af(c)) {
              var b = r.start, E = r.end;
              if (E === void 0 && (E = b), "selectionStart" in c)
                c.selectionStart = b, c.selectionEnd = Math.min(
                  E,
                  c.value.length
                );
              else {
                var O = c.ownerDocument || document, S = O && O.defaultView || window;
                if (S.getSelection) {
                  var M = S.getSelection(), Y = c.textContent.length, $ = Math.min(r.start, Y), Gt = r.end === void 0 ? $ : Math.min(r.end, Y);
                  !M.extend && $ > Gt && (u = Gt, Gt = $, $ = u);
                  var p = Xo(
                    c,
                    $
                  ), h = Xo(
                    c,
                    Gt
                  );
                  if (p && h && (M.rangeCount !== 1 || M.anchorNode !== p.node || M.anchorOffset !== p.offset || M.focusNode !== h.node || M.focusOffset !== h.offset)) {
                    var v = O.createRange();
                    v.setStart(p.node, p.offset), M.removeAllRanges(), $ > Gt ? (M.addRange(v), M.extend(h.node, h.offset)) : (v.setEnd(h.node, h.offset), M.addRange(v));
                  }
                }
              }
            }
            for (O = [], M = c; M = M.parentNode; )
              M.nodeType === 1 && O.push({
                element: M,
                left: M.scrollLeft,
                top: M.scrollTop
              });
            for (typeof c.focus == "function" && c.focus(), c = 0; c < O.length; c++) {
              var A = O[c];
              A.element.scrollLeft = A.left, A.element.scrollTop = A.top;
            }
          }
          Iu = !!to, eo = to = null;
        } finally {
          Ut = n, C.p = a, g.T = l;
        }
      }
      t.current = e, ue = 2;
    }
  }
  function id() {
    if (ue === 2) {
      ue = 0;
      var t = fa, e = Bn, l = (e.flags & 8772) !== 0;
      if ((e.subtreeFlags & 8772) !== 0 || l) {
        l = g.T, g.T = null;
        var a = C.p;
        C.p = 2;
        var n = Ut;
        Ut |= 4;
        try {
          Rs(t, e.alternate, e);
        } finally {
          Ut = n, C.p = a, g.T = l;
        }
      }
      ue = 3;
    }
  }
  function ud() {
    if (ue === 4 || ue === 3) {
      ue = 0, Zn();
      var t = fa, e = Bn, l = jl, a = Ks;
      (e.subtreeFlags & 10256) !== 0 || (e.flags & 10256) !== 0 ? ue = 5 : (ue = 0, Bn = fa = null, fd(t, t.pendingLanes));
      var n = t.pendingLanes;
      if (n === 0 && (ua = null), kn(l), e = e.stateNode, xe && typeof xe.onCommitFiberRoot == "function")
        try {
          xe.onCommitFiberRoot(
            va,
            e,
            void 0,
            (e.current.flags & 128) === 128
          );
        } catch {
        }
      if (a !== null) {
        e = g.T, n = C.p, C.p = 2, g.T = null;
        try {
          for (var i = t.onRecoverableError, u = 0; u < a.length; u++) {
            var c = a[u];
            i(c.value, {
              componentStack: c.stack
            });
          }
        } finally {
          g.T = e, C.p = n;
        }
      }
      (jl & 3) !== 0 && Yu(), hl(t), n = t.pendingLanes, (l & 261930) !== 0 && (n & 42) !== 0 ? t === Lc ? Di++ : (Di = 0, Lc = t) : Di = 0, Oi(0);
    }
  }
  function fd(t, e) {
    (t.pooledCacheLanes &= e) === 0 && (e = t.pooledCache, e != null && (t.pooledCache = null, oi(e)));
  }
  function Yu() {
    return nd(), id(), ud(), cd();
  }
  function cd() {
    if (ue !== 5) return !1;
    var t = fa, e = Gc;
    Gc = 0;
    var l = kn(jl), a = g.T, n = C.p;
    try {
      C.p = 32 > l ? 32 : l, g.T = null, l = Yc, Yc = null;
      var i = fa, u = jl;
      if (ue = 0, Bn = fa = null, jl = 0, (Ut & 6) !== 0) throw Error(s(331));
      var c = Ut;
      if (Ut |= 4, Qs(i.current), Ys(
        i,
        i.current,
        u,
        l
      ), Ut = c, Oi(0, !1), xe && typeof xe.onPostCommitFiberRoot == "function")
        try {
          xe.onPostCommitFiberRoot(va, i);
        } catch {
        }
      return !0;
    } finally {
      C.p = n, g.T = a, fd(t, e);
    }
  }
  function od(t, e, l) {
    e = Ke(l, e), e = bc(t.stateNode, e, 2), t = ta(t, e, 2), t !== null && (Yl(t, 2), hl(t));
  }
  function Ht(t, e, l) {
    if (t.tag === 3)
      od(t, t, l);
    else
      for (; e !== null; ) {
        if (e.tag === 3) {
          od(
            e,
            t,
            l
          );
          break;
        } else if (e.tag === 1) {
          var a = e.stateNode;
          if (typeof e.type.getDerivedStateFromError == "function" || typeof a.componentDidCatch == "function" && (ua === null || !ua.has(a))) {
            t = Ke(l, t), l = rs(2), a = ta(e, l, 2), a !== null && (ss(
              l,
              a,
              e,
              t
            ), Yl(a, 2), hl(a));
            break;
          }
        }
        e = e.return;
      }
  }
  function Vc(t, e, l) {
    var a = t.pingCache;
    if (a === null) {
      a = t.pingCache = new gh();
      var n = /* @__PURE__ */ new Set();
      a.set(e, n);
    } else
      n = a.get(e), n === void 0 && (n = /* @__PURE__ */ new Set(), a.set(e, n));
    n.has(l) || (Hc = !0, n.add(l), t = xh.bind(null, t, e, l), e.then(t, t));
  }
  function xh(t, e, l) {
    var a = t.pingCache;
    a !== null && a.delete(e), t.pingedLanes |= t.suspendedLanes & l, t.warmLanes &= ~l, Yt === t && (vt & l) === l && (kt === 4 || kt === 3 && (vt & 62914560) === vt && 300 > pe() - Bu ? (Ut & 2) === 0 && Nn(t, 0) : jc |= l, Rn === vt && (Rn = 0)), hl(t);
  }
  function rd(t, e) {
    e === 0 && (e = Ki()), t = Ra(t, e), t !== null && (Yl(t, e), hl(t));
  }
  function Sh(t) {
    var e = t.memoizedState, l = 0;
    e !== null && (l = e.retryLane), rd(t, l);
  }
  function Th(t, e) {
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
    a !== null && a.delete(e), rd(t, l);
  }
  function zh(t, e) {
    return pa(t, e);
  }
  var Lu = null, jn = null, Zc = !1, Xu = !1, Kc = !1, oa = 0;
  function hl(t) {
    t !== jn && t.next === null && (jn === null ? Lu = jn = t : jn = jn.next = t), Xu = !0, Zc || (Zc = !0, Eh());
  }
  function Oi(t, e) {
    if (!Kc && Xu) {
      Kc = !0;
      do
        for (var l = !1, a = Lu; a !== null; ) {
          if (t !== 0) {
            var n = a.pendingLanes;
            if (n === 0) var i = 0;
            else {
              var u = a.suspendedLanes, c = a.pingedLanes;
              i = (1 << 31 - ye(42 | t) + 1) - 1, i &= n & ~(u & ~c), i = i & 201326741 ? i & 201326741 | 1 : i ? i | 2 : 0;
            }
            i !== 0 && (l = !0, hd(a, i));
          } else
            i = vt, i = en(
              a,
              a === Yt ? i : 0,
              a.cancelPendingCommit !== null || a.timeoutHandle !== -1
            ), (i & 3) === 0 || Ne(a, i) || (l = !0, hd(a, i));
          a = a.next;
        }
      while (l);
      Kc = !1;
    }
  }
  function Mh() {
    sd();
  }
  function sd() {
    Xu = Zc = !1;
    var t = 0;
    oa !== 0 && Nh() && (t = oa);
    for (var e = pe(), l = null, a = Lu; a !== null; ) {
      var n = a.next, i = dd(a, e);
      i === 0 ? (a.next = null, l === null ? Lu = n : l.next = n, n === null && (jn = l)) : (l = a, (t !== 0 || (i & 3) !== 0) && (Xu = !0)), a = n;
    }
    ue !== 0 && ue !== 5 || Oi(t), oa !== 0 && (oa = 0);
  }
  function dd(t, e) {
    for (var l = t.suspendedLanes, a = t.pingedLanes, n = t.expirationTimes, i = t.pendingLanes & -62914561; 0 < i; ) {
      var u = 31 - ye(i), c = 1 << u, r = n[u];
      r === -1 ? ((c & l) === 0 || (c & a) !== 0) && (n[u] = Zi(c, e)) : r <= e && (t.expiredLanes |= c), i &= ~c;
    }
    if (e = Yt, l = vt, l = en(
      t,
      t === e ? l : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a = t.callbackNode, l === 0 || t === e && (Nt === 2 || Nt === 9) || t.cancelPendingCommit !== null)
      return a !== null && a !== null && ya(a), t.callbackNode = null, t.callbackPriority = 0;
    if ((l & 3) === 0 || Ne(t, l)) {
      if (e = l & -l, e === t.callbackPriority) return e;
      switch (a !== null && ya(a), kn(l)) {
        case 2:
        case 8:
          l = Kn;
          break;
        case 32:
          l = Wa;
          break;
        case 268435456:
          l = Qi;
          break;
        default:
          l = Wa;
      }
      return a = md.bind(null, t), l = pa(l, a), t.callbackPriority = e, t.callbackNode = l, e;
    }
    return a !== null && a !== null && ya(a), t.callbackPriority = 2, t.callbackNode = null, 2;
  }
  function md(t, e) {
    if (ue !== 0 && ue !== 5)
      return t.callbackNode = null, t.callbackPriority = 0, null;
    var l = t.callbackNode;
    if (Yu() && t.callbackNode !== l)
      return null;
    var a = vt;
    return a = en(
      t,
      t === Yt ? a : 0,
      t.cancelPendingCommit !== null || t.timeoutHandle !== -1
    ), a === 0 ? null : (ks(t, a, e), dd(t, pe()), t.callbackNode != null && t.callbackNode === l ? md.bind(null, t) : null);
  }
  function hd(t, e) {
    if (Yu()) return null;
    ks(t, e, !0);
  }
  function Eh() {
    jh(function() {
      (Ut & 6) !== 0 ? pa(
        Fa,
        Mh
      ) : sd();
    });
  }
  function Jc() {
    if (oa === 0) {
      var t = Tn;
      t === 0 && (t = Pa, Pa <<= 1, (Pa & 261888) === 0 && (Pa = 256)), oa = t;
    }
    return oa;
  }
  function gd(t) {
    return t == null || typeof t == "symbol" || typeof t == "boolean" ? null : typeof t == "function" ? t : cn("" + t);
  }
  function pd(t, e) {
    var l = e.ownerDocument.createElement("input");
    return l.name = e.name, l.value = e.value, t.id && l.setAttribute("form", t.id), e.parentNode.insertBefore(l, e), t = new FormData(t), l.parentNode.removeChild(l), t;
  }
  function Ah(t, e, l, a, n) {
    if (e === "submit" && l && l.stateNode === n) {
      var i = gd(
        (n[re] || null).action
      ), u = a.submitter;
      u && (e = (e = u[re] || null) ? gd(e.formAction) : u.getAttribute("formAction"), e !== null && (i = e, u = null));
      var c = new dn(
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
                if (oa !== 0) {
                  var r = u ? pd(n, u) : new FormData(n);
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
                typeof i == "function" && (c.preventDefault(), r = u ? pd(n, u) : new FormData(n), mc(
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
    var Fc = Cf[kc], _h = Fc.toLowerCase(), Dh = Fc[0].toUpperCase() + Fc.slice(1);
    al(
      _h,
      "on" + Dh
    );
  }
  al(Jo, "onAnimationEnd"), al(ko, "onAnimationIteration"), al(Fo, "onAnimationStart"), al("dblclick", "onDoubleClick"), al("focusin", "onFocus"), al("focusout", "onBlur"), al(Vm, "onTransitionRun"), al(Zm, "onTransitionStart"), al(Km, "onTransitionCancel"), al(Wo, "onTransitionEnd"), xl("onMouseEnter", ["mouseout", "mouseover"]), xl("onMouseLeave", ["mouseout", "mouseover"]), xl("onPointerEnter", ["pointerout", "pointerover"]), xl("onPointerLeave", ["pointerout", "pointerover"]), bl(
    "onChange",
    "change click focusin focusout input keydown keyup selectionchange".split(" ")
  ), bl(
    "onSelect",
    "focusout contextmenu dragend focusin keydown keyup mousedown mouseup selectionchange".split(
      " "
    )
  ), bl("onBeforeInput", [
    "compositionend",
    "keypress",
    "textInput",
    "paste"
  ]), bl(
    "onCompositionEnd",
    "compositionend focusout keydown keypress keyup mousedown".split(" ")
  ), bl(
    "onCompositionStart",
    "compositionstart focusout keydown keypress keyup mousedown".split(" ")
  ), bl(
    "onCompositionUpdate",
    "compositionupdate focusout keydown keypress keyup mousedown".split(" ")
  );
  var Ci = "abort canplay canplaythrough durationchange emptied encrypted ended error loadeddata loadedmetadata loadstart pause play playing progress ratechange resize seeked seeking stalled suspend timeupdate volumechange waiting".split(
    " "
  ), Oh = new Set(
    "beforetoggle cancel close invalid load scroll scrollend toggle".split(" ").concat(Ci)
  );
  function yd(t, e) {
    e = (e & 4) !== 0;
    for (var l = 0; l < t.length; l++) {
      var a = t[l], n = a.event;
      a = a.listeners;
      t: {
        var i = void 0;
        if (e)
          for (var u = a.length - 1; 0 <= u; u--) {
            var c = a[u], r = c.instance, b = c.currentTarget;
            if (c = c.listener, r !== i && n.isPropagationStopped())
              break t;
            i = c, n.currentTarget = b;
            try {
              i(n);
            } catch (E) {
              au(E);
            }
            n.currentTarget = null, i = r;
          }
        else
          for (u = 0; u < a.length; u++) {
            if (c = a[u], r = c.instance, b = c.currentTarget, c = c.listener, r !== i && n.isPropagationStopped())
              break t;
            i = c, n.currentTarget = b;
            try {
              i(n);
            } catch (E) {
              au(E);
            }
            n.currentTarget = null, i = r;
          }
      }
    }
  }
  function yt(t, e) {
    var l = e[Wn];
    l === void 0 && (l = e[Wn] = /* @__PURE__ */ new Set());
    var a = t + "__bubble";
    l.has(a) || (vd(e, t, 2, !1), l.add(a));
  }
  function Wc(t, e, l) {
    var a = 0;
    e && (a |= 4), vd(
      l,
      t,
      a,
      e
    );
  }
  var Qu = "_reactListening" + Math.random().toString(36).slice(2);
  function $c(t) {
    if (!t[Qu]) {
      t[Qu] = !0, Fi.forEach(function(l) {
        l !== "selectionchange" && (Oh.has(l) || Wc(l, !1, t), Wc(l, !0, t));
      });
      var e = t.nodeType === 9 ? t : t.ownerDocument;
      e === null || e[Qu] || (e[Qu] = !0, Wc("selectionchange", !1, e));
    }
  }
  function vd(t, e, l, a) {
    switch (Jd(e)) {
      case 2:
        var n = ag;
        break;
      case 8:
        n = ng;
        break;
      default:
        n = mo;
    }
    l = n.bind(
      null,
      e,
      l,
      t
    ), n = void 0, !za || e !== "touchstart" && e !== "touchmove" && e !== "wheel" || (n = !0), a ? n !== void 0 ? t.addEventListener(e, l, {
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
    tu(function() {
      var b = i, E = Pn(l), O = [];
      t: {
        var S = $o.get(t);
        if (S !== void 0) {
          var M = dn, Y = t;
          switch (t) {
            case "keypress":
              if (sn(l) === 0) break t;
            case "keydown":
            case "keyup":
              M = Tm;
              break;
            case "focusin":
              Y = "focus", M = ut;
              break;
            case "focusout":
              Y = "blur", M = ut;
              break;
            case "beforeblur":
            case "afterblur":
              M = ut;
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
              M = Oa;
              break;
            case "drag":
            case "dragend":
            case "dragenter":
            case "dragexit":
            case "dragleave":
            case "dragover":
            case "dragstart":
            case "drop":
              M = w;
              break;
            case "touchcancel":
            case "touchend":
            case "touchmove":
            case "touchstart":
              M = Em;
              break;
            case Jo:
            case ko:
            case Fo:
              M = Et;
              break;
            case Wo:
              M = _m;
              break;
            case "scroll":
            case "scrollend":
              M = xf;
              break;
            case "wheel":
              M = Om;
              break;
            case "copy":
            case "cut":
            case "paste":
              M = ze;
              break;
            case "gotpointercapture":
            case "lostpointercapture":
            case "pointercancel":
            case "pointerdown":
            case "pointermove":
            case "pointerout":
            case "pointerover":
            case "pointerup":
              M = Do;
              break;
            case "toggle":
            case "beforetoggle":
              M = Um;
          }
          var $ = (e & 4) !== 0, Gt = !$ && (t === "scroll" || t === "scrollend"), p = $ ? S !== null ? S + "Capture" : null : S;
          $ = [];
          for (var h = b, v; h !== null; ) {
            var A = h;
            if (v = A.stateNode, A = A.tag, A !== 5 && A !== 26 && A !== 27 || v === null || p === null || (A = Zl(h, p), A != null && $.push(
              Ui(h, A, v)
            )), Gt) break;
            h = h.return;
          }
          0 < $.length && (S = new M(
            S,
            Y,
            null,
            l,
            E
          ), O.push({ event: S, listeners: $ }));
        }
      }
      if ((e & 7) === 0) {
        t: {
          if (S = t === "mouseover" || t === "pointerover", M = t === "mouseout" || t === "pointerout", S && l !== on && (Y = l.relatedTarget || l.fromElement) && (cl(Y) || Y[Ll]))
            break t;
          if ((M || S) && (S = E.window === E ? E : (S = E.ownerDocument) ? S.defaultView || S.parentWindow : window, M ? (Y = l.relatedTarget || l.toElement, M = b, Y = Y ? cl(Y) : null, Y !== null && (Gt = k(Y), $ = Y.tag, Y !== Gt || $ !== 5 && $ !== 27 && $ !== 6) && (Y = null)) : (M = null, Y = b), M !== Y)) {
            if ($ = Oa, A = "onMouseLeave", p = "onMouseEnter", h = "mouse", (t === "pointerout" || t === "pointerover") && ($ = Do, A = "onPointerLeave", p = "onPointerEnter", h = "pointer"), Gt = M == null ? S : ol(M), v = Y == null ? S : ol(Y), S = new $(
              A,
              h + "leave",
              M,
              l,
              E
            ), S.target = Gt, S.relatedTarget = v, A = null, cl(E) === b && ($ = new $(
              p,
              h + "enter",
              Y,
              l,
              E
            ), $.target = v, $.relatedTarget = Gt, A = $), Gt = A, M && Y)
              e: {
                for ($ = Ch, p = M, h = Y, v = 0, A = p; A; A = $(A))
                  v++;
                A = 0;
                for (var J = h; J; J = $(J))
                  A++;
                for (; 0 < v - A; )
                  p = $(p), v--;
                for (; 0 < A - v; )
                  h = $(h), A--;
                for (; v--; ) {
                  if (p === h || h !== null && p === h.alternate) {
                    $ = p;
                    break e;
                  }
                  p = $(p), h = $(h);
                }
                $ = null;
              }
            else $ = null;
            M !== null && bd(
              O,
              S,
              M,
              $,
              !1
            ), Y !== null && Gt !== null && bd(
              O,
              Gt,
              Y,
              $,
              !0
            );
          }
        }
        t: {
          if (S = b ? ol(b) : window, M = S.nodeName && S.nodeName.toLowerCase(), M === "select" || M === "input" && S.type === "file")
            var At = Ho;
          else if (Bo(S))
            if (jo)
              At = Lm;
            else {
              At = Gm;
              var Q = qm;
            }
          else
            M = S.nodeName, !M || M.toLowerCase() !== "input" || S.type !== "checkbox" && S.type !== "radio" ? b && zt(b.elementType) && (At = Ho) : At = Ym;
          if (At && (At = At(t, b))) {
            No(
              O,
              At,
              l,
              E
            );
            break t;
          }
          Q && Q(t, S, b), t === "focusout" && b && S.type === "number" && b.memoizedProps.value != null && d(S, "number", S.value);
        }
        switch (Q = b ? ol(b) : window, t) {
          case "focusin":
            (Bo(Q) || Q.contentEditable === "true") && (hn = Q, _f = b, ui = null);
            break;
          case "focusout":
            ui = _f = hn = null;
            break;
          case "mousedown":
            Df = !0;
            break;
          case "contextmenu":
          case "mouseup":
          case "dragend":
            Df = !1, Zo(O, l, E);
            break;
          case "selectionchange":
            if (Qm) break;
          case "keydown":
          case "keyup":
            Zo(O, l, E);
        }
        var st;
        if (zf)
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
          mn ? wo(t, l) && (bt = "onCompositionEnd") : t === "keydown" && l.keyCode === 229 && (bt = "onCompositionStart");
        bt && (Oo && l.locale !== "ko" && (mn || bt !== "onCompositionStart" ? bt === "onCompositionEnd" && mn && (st = ei()) : (ll = E, ti = "value" in ll ? ll.value : ll.textContent, mn = !0)), Q = Vu(b, bt), 0 < Q.length && (bt = new De(
          bt,
          t,
          null,
          l,
          E
        ), O.push({ event: bt, listeners: Q }), st ? bt.data = st : (st = Ro(l), st !== null && (bt.data = st)))), (st = Rm ? Bm(t, l) : Nm(t, l)) && (bt = Vu(b, "onBeforeInput"), 0 < bt.length && (Q = new De(
          "onBeforeInput",
          "beforeinput",
          null,
          l,
          E
        ), O.push({
          event: Q,
          listeners: bt
        }), Q.data = st)), Ah(
          O,
          t,
          b,
          l,
          E
        );
      }
      yd(O, e);
    });
  }
  function Ui(t, e, l) {
    return {
      instance: t,
      listener: e,
      currentTarget: l
    };
  }
  function Vu(t, e) {
    for (var l = e + "Capture", a = []; t !== null; ) {
      var n = t, i = n.stateNode;
      if (n = n.tag, n !== 5 && n !== 26 && n !== 27 || i === null || (n = Zl(t, l), n != null && a.unshift(
        Ui(t, n, i)
      ), n = Zl(t, e), n != null && a.push(
        Ui(t, n, i)
      )), t.tag === 3) return a;
      t = t.return;
    }
    return [];
  }
  function Ch(t) {
    if (t === null) return null;
    do
      t = t.return;
    while (t && t.tag !== 5 && t.tag !== 27);
    return t || null;
  }
  function bd(t, e, l, a, n) {
    for (var i = e._reactName, u = []; l !== null && l !== a; ) {
      var c = l, r = c.alternate, b = c.stateNode;
      if (c = c.tag, r !== null && r === a) break;
      c !== 5 && c !== 26 && c !== 27 || b === null || (r = b, n ? (b = Zl(l, i), b != null && u.unshift(
        Ui(l, b, r)
      )) : n || (b = Zl(l, i), b != null && u.push(
        Ui(l, b, r)
      ))), l = l.return;
    }
    u.length !== 0 && t.push({ event: e, listeners: u });
  }
  var Uh = /\r\n?/g, wh = /\u0000|\uFFFD/g;
  function xd(t) {
    return (typeof t == "string" ? t : "" + t).replace(Uh, `
`).replace(wh, "");
  }
  function Sd(t, e) {
    return e = xd(e), xd(t) === e;
  }
  function qt(t, e, l, a, n, i) {
    switch (l) {
      case "children":
        typeof a == "string" ? e === "body" || e === "textarea" && a === "" || j(t, a) : (typeof a == "number" || typeof a == "bigint") && e !== "body" && j(t, "" + a);
        break;
      case "className":
        un(t, "class", a);
        break;
      case "tabIndex":
        un(t, "tabindex", a);
        break;
      case "dir":
      case "role":
      case "viewBox":
      case "width":
      case "height":
        un(t, l, a);
        break;
      case "style":
        xt(t, a, i);
        break;
      case "data":
        if (e !== "object") {
          un(t, "data", a);
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
        a = cn("" + a), t.setAttribute(l, a);
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
          typeof i == "function" && (l === "formAction" ? (e !== "input" && qt(t, e, "name", n.name, n, null), qt(
            t,
            e,
            "formEncType",
            n.formEncType,
            n,
            null
          ), qt(
            t,
            e,
            "formMethod",
            n.formMethod,
            n,
            null
          ), qt(
            t,
            e,
            "formTarget",
            n.formTarget,
            n,
            null
          )) : (qt(t, e, "encType", n.encType, n, null), qt(t, e, "method", n.method, n, null), qt(t, e, "target", n.target, n, null)));
        if (a == null || typeof a == "symbol" || typeof a == "boolean") {
          t.removeAttribute(l);
          break;
        }
        a = cn("" + a), t.setAttribute(l, a);
        break;
      case "onClick":
        a != null && (t.onclick = tl);
        break;
      case "onScroll":
        a != null && yt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && yt("scrollend", t);
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
        l = cn("" + a), t.setAttributeNS(
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
        yt("beforetoggle", t), yt("toggle", t), Sa(t, "popover", a);
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
        Sa(t, "is", a);
        break;
      case "innerText":
      case "textContent":
        break;
      default:
        (!(2 < l.length) || l[0] !== "o" && l[0] !== "O" || l[1] !== "n" && l[1] !== "N") && (l = Ql.get(l) || l, Sa(t, l, a));
    }
  }
  function Pc(t, e, l, a, n, i) {
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
        a != null && yt("scroll", t);
        break;
      case "onScrollEnd":
        a != null && yt("scrollend", t);
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
        if (!$n.hasOwnProperty(l))
          t: {
            if (l[0] === "o" && l[1] === "n" && (n = l.endsWith("Capture"), e = l.slice(2, n ? l.length - 7 : void 0), i = t[re] || null, i = i != null ? i[l] : null, typeof i == "function" && t.removeEventListener(e, i, n), typeof a == "function")) {
              typeof i != "function" && i !== null && (l in t ? t[l] = null : t.hasAttribute(l) && t.removeAttribute(l)), t.addEventListener(e, a, n);
              break t;
            }
            l in t ? t[l] = a : a === !0 ? t.setAttribute(l, "") : Sa(t, l, a);
          }
    }
  }
  function ge(t, e, l) {
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
        yt("error", t), yt("load", t);
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
                  qt(t, e, i, u, l, null);
              }
          }
        n && qt(t, e, "srcSet", l.srcSet, l, null), a && qt(t, e, "src", l.src, l, null);
        return;
      case "input":
        yt("invalid", t);
        var c = i = u = n = null, r = null, b = null;
        for (a in l)
          if (l.hasOwnProperty(a)) {
            var E = l[a];
            if (E != null)
              switch (a) {
                case "name":
                  n = E;
                  break;
                case "type":
                  u = E;
                  break;
                case "checked":
                  r = E;
                  break;
                case "defaultChecked":
                  b = E;
                  break;
                case "value":
                  i = E;
                  break;
                case "defaultValue":
                  c = E;
                  break;
                case "children":
                case "dangerouslySetInnerHTML":
                  if (E != null)
                    throw Error(s(137, e));
                  break;
                default:
                  qt(t, e, a, E, l, null);
              }
          }
        o(
          t,
          i,
          c,
          r,
          b,
          u,
          n,
          !1
        );
        return;
      case "select":
        yt("invalid", t), a = u = i = null;
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
                qt(t, e, n, c, l, null);
            }
        e = i, l = u, t.multiple = !!a, e != null ? x(t, !!a, e, !1) : l != null && x(t, !!a, l, !0);
        return;
      case "textarea":
        yt("invalid", t), i = n = a = null;
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
                qt(t, e, u, c, l, null);
            }
        H(t, a, n, i);
        return;
      case "option":
        for (r in l)
          l.hasOwnProperty(r) && (a = l[r], a != null) && (r === "selected" ? t.selected = a && typeof a != "function" && typeof a != "symbol" : qt(t, e, r, a, l, null));
        return;
      case "dialog":
        yt("beforetoggle", t), yt("toggle", t), yt("cancel", t), yt("close", t);
        break;
      case "iframe":
      case "object":
        yt("load", t);
        break;
      case "video":
      case "audio":
        for (a = 0; a < Ci.length; a++)
          yt(Ci[a], t);
        break;
      case "image":
        yt("error", t), yt("load", t);
        break;
      case "details":
        yt("toggle", t);
        break;
      case "embed":
      case "source":
      case "link":
        yt("error", t), yt("load", t);
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
        for (b in l)
          if (l.hasOwnProperty(b) && (a = l[b], a != null))
            switch (b) {
              case "children":
              case "dangerouslySetInnerHTML":
                throw Error(s(137, e));
              default:
                qt(t, e, b, a, l, null);
            }
        return;
      default:
        if (zt(e)) {
          for (E in l)
            l.hasOwnProperty(E) && (a = l[E], a !== void 0 && Pc(
              t,
              e,
              E,
              a,
              l,
              void 0
            ));
          return;
        }
    }
    for (c in l)
      l.hasOwnProperty(c) && (a = l[c], a != null && qt(t, e, c, a, l, null));
  }
  function Rh(t, e, l, a) {
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
        var n = null, i = null, u = null, c = null, r = null, b = null, E = null;
        for (M in l) {
          var O = l[M];
          if (l.hasOwnProperty(M) && O != null)
            switch (M) {
              case "checked":
                break;
              case "value":
                break;
              case "defaultValue":
                r = O;
              default:
                a.hasOwnProperty(M) || qt(t, e, M, null, a, O);
            }
        }
        for (var S in a) {
          var M = a[S];
          if (O = l[S], a.hasOwnProperty(S) && (M != null || O != null))
            switch (S) {
              case "type":
                i = M;
                break;
              case "name":
                n = M;
                break;
              case "checked":
                b = M;
                break;
              case "defaultChecked":
                E = M;
                break;
              case "value":
                u = M;
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
                M !== O && qt(
                  t,
                  e,
                  S,
                  M,
                  a,
                  O
                );
            }
        }
        In(
          t,
          u,
          c,
          r,
          b,
          E,
          i,
          n
        );
        return;
      case "select":
        M = u = c = S = null;
        for (i in l)
          if (r = l[i], l.hasOwnProperty(i) && r != null)
            switch (i) {
              case "value":
                break;
              case "multiple":
                M = r;
              default:
                a.hasOwnProperty(i) || qt(
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
                S = i;
                break;
              case "defaultValue":
                c = i;
                break;
              case "multiple":
                u = i;
              default:
                i !== r && qt(
                  t,
                  e,
                  n,
                  i,
                  a,
                  r
                );
            }
        e = c, l = u, a = M, S != null ? x(t, !!l, S, !1) : !!a != !!l && (e != null ? x(t, !!l, e, !0) : x(t, !!l, l ? [] : "", !1));
        return;
      case "textarea":
        M = S = null;
        for (c in l)
          if (n = l[c], l.hasOwnProperty(c) && n != null && !a.hasOwnProperty(c))
            switch (c) {
              case "value":
                break;
              case "children":
                break;
              default:
                qt(t, e, c, null, a, n);
            }
        for (u in a)
          if (n = a[u], i = l[u], a.hasOwnProperty(u) && (n != null || i != null))
            switch (u) {
              case "value":
                S = n;
                break;
              case "defaultValue":
                M = n;
                break;
              case "children":
                break;
              case "dangerouslySetInnerHTML":
                if (n != null) throw Error(s(91));
                break;
              default:
                n !== i && qt(t, e, u, n, a, i);
            }
        R(t, S, M);
        return;
      case "option":
        for (var Y in l)
          S = l[Y], l.hasOwnProperty(Y) && S != null && !a.hasOwnProperty(Y) && (Y === "selected" ? t.selected = !1 : qt(
            t,
            e,
            Y,
            null,
            a,
            S
          ));
        for (r in a)
          S = a[r], M = l[r], a.hasOwnProperty(r) && S !== M && (S != null || M != null) && (r === "selected" ? t.selected = S && typeof S != "function" && typeof S != "symbol" : qt(
            t,
            e,
            r,
            S,
            a,
            M
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
          S = l[$], l.hasOwnProperty($) && S != null && !a.hasOwnProperty($) && qt(t, e, $, null, a, S);
        for (b in a)
          if (S = a[b], M = l[b], a.hasOwnProperty(b) && S !== M && (S != null || M != null))
            switch (b) {
              case "children":
              case "dangerouslySetInnerHTML":
                if (S != null)
                  throw Error(s(137, e));
                break;
              default:
                qt(
                  t,
                  e,
                  b,
                  S,
                  a,
                  M
                );
            }
        return;
      default:
        if (zt(e)) {
          for (var Gt in l)
            S = l[Gt], l.hasOwnProperty(Gt) && S !== void 0 && !a.hasOwnProperty(Gt) && Pc(
              t,
              e,
              Gt,
              void 0,
              a,
              S
            );
          for (E in a)
            S = a[E], M = l[E], !a.hasOwnProperty(E) || S === M || S === void 0 && M === void 0 || Pc(
              t,
              e,
              E,
              S,
              a,
              M
            );
          return;
        }
    }
    for (var p in l)
      S = l[p], l.hasOwnProperty(p) && S != null && !a.hasOwnProperty(p) && qt(t, e, p, null, a, S);
    for (O in a)
      S = a[O], M = l[O], !a.hasOwnProperty(O) || S === M || S == null && M == null || qt(t, e, O, S, a, M);
  }
  function Td(t) {
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
  function Bh() {
    if (typeof performance.getEntriesByType == "function") {
      for (var t = 0, e = 0, l = performance.getEntriesByType("resource"), a = 0; a < l.length; a++) {
        var n = l[a], i = n.transferSize, u = n.initiatorType, c = n.duration;
        if (i && c && Td(u)) {
          for (u = 0, c = n.responseEnd, a += 1; a < l.length; a++) {
            var r = l[a], b = r.startTime;
            if (b > c) break;
            var E = r.transferSize, O = r.initiatorType;
            E && Td(O) && (r = r.responseEnd, u += E * (r < c ? 1 : (c - b) / (r - b)));
          }
          if (--a, e += 8 * (i + u) / (n.duration / 1e3), t++, 10 < t) break;
        }
      }
      if (0 < t) return e / t / 1e6;
    }
    return navigator.connection && (t = navigator.connection.downlink, typeof t == "number") ? t : 5;
  }
  var to = null, eo = null;
  function Zu(t) {
    return t.nodeType === 9 ? t : t.ownerDocument;
  }
  function zd(t) {
    switch (t) {
      case "http://www.w3.org/2000/svg":
        return 1;
      case "http://www.w3.org/1998/Math/MathML":
        return 2;
      default:
        return 0;
    }
  }
  function Md(t, e) {
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
  function Nh() {
    var t = window.event;
    return t && t.type === "popstate" ? t === ao ? !1 : (ao = t, !0) : (ao = null, !1);
  }
  var Ed = typeof setTimeout == "function" ? setTimeout : void 0, Hh = typeof clearTimeout == "function" ? clearTimeout : void 0, Ad = typeof Promise == "function" ? Promise : void 0, jh = typeof queueMicrotask == "function" ? queueMicrotask : typeof Ad < "u" ? function(t) {
    return Ad.resolve(null).then(t).catch(qh);
  } : Ed;
  function qh(t) {
    setTimeout(function() {
      throw t;
    });
  }
  function ra(t) {
    return t === "head";
  }
  function _d(t, e) {
    var l = e, a = 0;
    do {
      var n = l.nextSibling;
      if (t.removeChild(l), n && n.nodeType === 8)
        if (l = n.data, l === "/$" || l === "/&") {
          if (a === 0) {
            t.removeChild(n), Ln(e);
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
            i[Xl] || c === "SCRIPT" || c === "STYLE" || c === "LINK" && i.rel.toLowerCase() === "stylesheet" || l.removeChild(i), i = u;
          }
        } else
          l === "body" && wi(t.ownerDocument.body);
      l = n;
    } while (l);
    Ln(e);
  }
  function Dd(t, e) {
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
          no(l), xa(l);
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
  function Gh(t, e, l, a) {
    for (; t.nodeType === 1; ) {
      var n = l;
      if (t.nodeName.toLowerCase() !== e.toLowerCase()) {
        if (!a && (t.nodeName !== "INPUT" || t.type !== "hidden"))
          break;
      } else if (a) {
        if (!t[Xl])
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
      if (t = $e(t.nextSibling), t === null) break;
    }
    return null;
  }
  function Yh(t, e, l) {
    if (e === "") return null;
    for (; t.nodeType !== 3; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !l || (t = $e(t.nextSibling), t === null)) return null;
    return t;
  }
  function Od(t, e) {
    for (; t.nodeType !== 8; )
      if ((t.nodeType !== 1 || t.nodeName !== "INPUT" || t.type !== "hidden") && !e || (t = $e(t.nextSibling), t === null)) return null;
    return t;
  }
  function io(t) {
    return t.data === "$?" || t.data === "$~";
  }
  function uo(t) {
    return t.data === "$!" || t.data === "$?" && t.ownerDocument.readyState !== "loading";
  }
  function Lh(t, e) {
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
  function $e(t) {
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
  function Cd(t) {
    t = t.nextSibling;
    for (var e = 0; t; ) {
      if (t.nodeType === 8) {
        var l = t.data;
        if (l === "/$" || l === "/&") {
          if (e === 0)
            return $e(t.nextSibling);
          e--;
        } else
          l !== "$" && l !== "$!" && l !== "$?" && l !== "$~" && l !== "&" || e++;
      }
      t = t.nextSibling;
    }
    return null;
  }
  function Ud(t) {
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
  function wd(t, e, l) {
    switch (e = Zu(l), t) {
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
    xa(t);
  }
  var Ie = /* @__PURE__ */ new Map(), Rd = /* @__PURE__ */ new Set();
  function Ku(t) {
    return typeof t.getRootNode == "function" ? t.getRootNode() : t.nodeType === 9 ? t : t.ownerDocument;
  }
  var ql = C.d;
  C.d = {
    f: Xh,
    r: Qh,
    D: Vh,
    C: Zh,
    L: Kh,
    m: Jh,
    X: Fh,
    S: kh,
    M: Wh
  };
  function Xh() {
    var t = ql.f(), e = ju();
    return t || e;
  }
  function Qh(t) {
    var e = yl(t);
    e !== null && e.tag === 5 && e.type === "form" ? Wr(e) : ql.r(t);
  }
  var qn = typeof document > "u" ? null : document;
  function Bd(t, e, l) {
    var a = qn;
    if (a && typeof e == "string" && e) {
      var n = _e(e);
      n = 'link[rel="' + t + '"][href="' + n + '"]', typeof l == "string" && (n += '[crossorigin="' + l + '"]'), Rd.has(n) || (Rd.add(n), t = { rel: t, crossOrigin: l, href: e }, a.querySelector(n) === null && (e = a.createElement("link"), ge(e, "link", t), Wt(e), a.head.appendChild(e)));
    }
  }
  function Vh(t) {
    ql.D(t), Bd("dns-prefetch", t, null);
  }
  function Zh(t, e) {
    ql.C(t, e), Bd("preconnect", t, e);
  }
  function Kh(t, e, l) {
    ql.L(t, e, l);
    var a = qn;
    if (a && t && e) {
      var n = 'link[rel="preload"][as="' + _e(e) + '"]';
      e === "image" && l && l.imageSrcSet ? (n += '[imagesrcset="' + _e(
        l.imageSrcSet
      ) + '"]', typeof l.imageSizes == "string" && (n += '[imagesizes="' + _e(
        l.imageSizes
      ) + '"]')) : n += '[href="' + _e(t) + '"]';
      var i = n;
      switch (e) {
        case "style":
          i = Gn(t);
          break;
        case "script":
          i = Yn(t);
      }
      Ie.has(i) || (t = N(
        {
          rel: "preload",
          href: e === "image" && l && l.imageSrcSet ? void 0 : t,
          as: e
        },
        l
      ), Ie.set(i, t), a.querySelector(n) !== null || e === "style" && a.querySelector(Ri(i)) || e === "script" && a.querySelector(Bi(i)) || (e = a.createElement("link"), ge(e, "link", t), Wt(e), a.head.appendChild(e)));
    }
  }
  function Jh(t, e) {
    ql.m(t, e);
    var l = qn;
    if (l && t) {
      var a = e && typeof e.as == "string" ? e.as : "script", n = 'link[rel="modulepreload"][as="' + _e(a) + '"][href="' + _e(t) + '"]', i = n;
      switch (a) {
        case "audioworklet":
        case "paintworklet":
        case "serviceworker":
        case "sharedworker":
        case "worker":
        case "script":
          i = Yn(t);
      }
      if (!Ie.has(i) && (t = N({ rel: "modulepreload", href: t }, e), Ie.set(i, t), l.querySelector(n) === null)) {
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
        a = l.createElement("link"), ge(a, "link", t), Wt(a), l.head.appendChild(a);
      }
    }
  }
  function kh(t, e, l) {
    ql.S(t, e, l);
    var a = qn;
    if (a && t) {
      var n = vl(a).hoistableStyles, i = Gn(t);
      e = e || "default";
      var u = n.get(i);
      if (!u) {
        var c = { loading: 0, preload: null };
        if (u = a.querySelector(
          Ri(i)
        ))
          c.loading = 5;
        else {
          t = N(
            { rel: "stylesheet", href: t, "data-precedence": e },
            l
          ), (l = Ie.get(i)) && co(t, l);
          var r = u = a.createElement("link");
          Wt(r), ge(r, "link", t), r._p = new Promise(function(b, E) {
            r.onload = b, r.onerror = E;
          }), r.addEventListener("load", function() {
            c.loading |= 1;
          }), r.addEventListener("error", function() {
            c.loading |= 2;
          }), c.loading |= 4, Ju(u, e, a);
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
  function Fh(t, e) {
    ql.X(t, e);
    var l = qn;
    if (l && t) {
      var a = vl(l).hoistableScripts, n = Yn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = N({ src: t, async: !0 }, e), (e = Ie.get(n)) && oo(t, e), i = l.createElement("script"), Wt(i), ge(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Wh(t, e) {
    ql.M(t, e);
    var l = qn;
    if (l && t) {
      var a = vl(l).hoistableScripts, n = Yn(t), i = a.get(n);
      i || (i = l.querySelector(Bi(n)), i || (t = N({ src: t, async: !0, type: "module" }, e), (e = Ie.get(n)) && oo(t, e), i = l.createElement("script"), Wt(i), ge(i, "link", t), l.head.appendChild(i)), i = {
        type: "script",
        instance: i,
        count: 1,
        state: null
      }, a.set(n, i));
    }
  }
  function Nd(t, e, l, a) {
    var n = (n = ct.current) ? Ku(n) : null;
    if (!n) throw Error(s(446));
    switch (t) {
      case "meta":
      case "title":
        return null;
      case "style":
        return typeof l.precedence == "string" && typeof l.href == "string" ? (e = Gn(l.href), l = vl(
          n
        ).hoistableStyles, a = l.get(e), a || (a = {
          type: "style",
          instance: null,
          count: 0,
          state: null
        }, l.set(e, a)), a) : { type: "void", instance: null, count: 0, state: null };
      case "link":
        if (l.rel === "stylesheet" && typeof l.href == "string" && typeof l.precedence == "string") {
          t = Gn(l.href);
          var i = vl(
            n
          ).hoistableStyles, u = i.get(t);
          if (u || (n = n.ownerDocument || n, u = {
            type: "stylesheet",
            instance: null,
            count: 0,
            state: { loading: 0, preload: null }
          }, i.set(t, u), (i = n.querySelector(
            Ri(t)
          )) && !i._p && (u.instance = i, u.state.loading = 5), Ie.has(t) || (l = {
            rel: "preload",
            as: "style",
            href: l.href,
            crossOrigin: l.crossOrigin,
            integrity: l.integrity,
            media: l.media,
            hrefLang: l.hrefLang,
            referrerPolicy: l.referrerPolicy
          }, Ie.set(t, l), i || $h(
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
        return e = l.async, l = l.src, typeof l == "string" && e && typeof e != "function" && typeof e != "symbol" ? (e = Yn(l), l = vl(
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
  function Gn(t) {
    return 'href="' + _e(t) + '"';
  }
  function Ri(t) {
    return 'link[rel="stylesheet"][' + t + "]";
  }
  function Hd(t) {
    return N({}, t, {
      "data-precedence": t.precedence,
      precedence: null
    });
  }
  function $h(t, e, l, a) {
    t.querySelector('link[rel="preload"][as="style"][' + e + "]") ? a.loading = 1 : (e = t.createElement("link"), a.preload = e, e.addEventListener("load", function() {
      return a.loading |= 1;
    }), e.addEventListener("error", function() {
      return a.loading |= 2;
    }), ge(e, "link", l), Wt(e), t.head.appendChild(e));
  }
  function Yn(t) {
    return '[src="' + _e(t) + '"]';
  }
  function Bi(t) {
    return "script[async]" + t;
  }
  function jd(t, e, l) {
    if (e.count++, e.instance === null)
      switch (e.type) {
        case "style":
          var a = t.querySelector(
            'style[data-href~="' + _e(l.href) + '"]'
          );
          if (a)
            return e.instance = a, Wt(a), a;
          var n = N({}, l, {
            "data-href": l.href,
            "data-precedence": l.precedence,
            href: null,
            precedence: null
          });
          return a = (t.ownerDocument || t).createElement(
            "style"
          ), Wt(a), ge(a, "style", n), Ju(a, l.precedence, t), e.instance = a;
        case "stylesheet":
          n = Gn(l.href);
          var i = t.querySelector(
            Ri(n)
          );
          if (i)
            return e.state.loading |= 4, e.instance = i, Wt(i), i;
          a = Hd(l), (n = Ie.get(n)) && co(a, n), i = (t.ownerDocument || t).createElement("link"), Wt(i);
          var u = i;
          return u._p = new Promise(function(c, r) {
            u.onload = c, u.onerror = r;
          }), ge(i, "link", a), e.state.loading |= 4, Ju(i, l.precedence, t), e.instance = i;
        case "script":
          return i = Yn(l.src), (n = t.querySelector(
            Bi(i)
          )) ? (e.instance = n, Wt(n), n) : (a = l, (n = Ie.get(i)) && (a = N({}, l), oo(a, n)), t = t.ownerDocument || t, n = t.createElement("script"), Wt(n), ge(n, "link", a), t.head.appendChild(n), e.instance = n);
        case "void":
          return null;
        default:
          throw Error(s(443, e.type));
      }
    else
      e.type === "stylesheet" && (e.state.loading & 4) === 0 && (a = e.instance, e.state.loading |= 4, Ju(a, l.precedence, t));
    return e.instance;
  }
  function Ju(t, e, l) {
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
  var ku = null;
  function qd(t, e, l) {
    if (ku === null) {
      var a = /* @__PURE__ */ new Map(), n = ku = /* @__PURE__ */ new Map();
      n.set(l, a);
    } else
      n = ku, a = n.get(l), a || (a = /* @__PURE__ */ new Map(), n.set(l, a));
    if (a.has(t)) return a;
    for (a.set(t, null), l = l.getElementsByTagName(t), n = 0; n < l.length; n++) {
      var i = l[n];
      if (!(i[Xl] || i[te] || t === "link" && i.getAttribute("rel") === "stylesheet") && i.namespaceURI !== "http://www.w3.org/2000/svg") {
        var u = i.getAttribute(e) || "";
        u = t + u;
        var c = a.get(u);
        c ? c.push(i) : a.set(u, [i]);
      }
    }
    return a;
  }
  function Gd(t, e, l) {
    t = t.ownerDocument || t, t.head.insertBefore(
      l,
      e === "title" ? t.querySelector("head > title") : null
    );
  }
  function Ih(t, e, l) {
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
  function Yd(t) {
    return !(t.type === "stylesheet" && (t.state.loading & 3) === 0);
  }
  function Ph(t, e, l, a) {
    if (l.type === "stylesheet" && (typeof a.media != "string" || matchMedia(a.media).matches !== !1) && (l.state.loading & 4) === 0) {
      if (l.instance === null) {
        var n = Gn(a.href), i = e.querySelector(
          Ri(n)
        );
        if (i) {
          e = i._p, e !== null && typeof e == "object" && typeof e.then == "function" && (t.count++, t = Fu.bind(t), e.then(t, t)), l.state.loading |= 4, l.instance = i, Wt(i);
          return;
        }
        i = e.ownerDocument || e, a = Hd(a), (n = Ie.get(n)) && co(a, n), i = i.createElement("link"), Wt(i);
        var u = i;
        u._p = new Promise(function(c, r) {
          u.onload = c, u.onerror = r;
        }), ge(i, "link", a), l.instance = i;
      }
      t.stylesheets === null && (t.stylesheets = /* @__PURE__ */ new Map()), t.stylesheets.set(l, e), (e = l.state.preload) && (l.state.loading & 3) === 0 && (t.count++, l = Fu.bind(t), e.addEventListener("load", l), e.addEventListener("error", l));
    }
  }
  var ro = 0;
  function tg(t, e) {
    return t.stylesheets && t.count === 0 && $u(t, t.stylesheets), 0 < t.count || 0 < t.imgCount ? function(l) {
      var a = setTimeout(function() {
        if (t.stylesheets && $u(t, t.stylesheets), t.unsuspend) {
          var i = t.unsuspend;
          t.unsuspend = null, i();
        }
      }, 6e4 + e);
      0 < t.imgBytes && ro === 0 && (ro = 62500 * Bh());
      var n = setTimeout(
        function() {
          if (t.waitingForImages = !1, t.count === 0 && (t.stylesheets && $u(t, t.stylesheets), t.unsuspend)) {
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
  function Fu() {
    if (this.count--, this.count === 0 && (this.imgCount === 0 || !this.waitingForImages)) {
      if (this.stylesheets) $u(this, this.stylesheets);
      else if (this.unsuspend) {
        var t = this.unsuspend;
        this.unsuspend = null, t();
      }
    }
  }
  var Wu = null;
  function $u(t, e) {
    t.stylesheets = null, t.unsuspend !== null && (t.count++, Wu = /* @__PURE__ */ new Map(), e.forEach(eg, t), Wu = null, Fu.call(t));
  }
  function eg(t, e) {
    if (!(e.state.loading & 4)) {
      var l = Wu.get(t);
      if (l) var a = l.get(null);
      else {
        l = /* @__PURE__ */ new Map(), Wu.set(t, l);
        for (var n = t.querySelectorAll(
          "link[data-precedence],style[data-precedence]"
        ), i = 0; i < n.length; i++) {
          var u = n[i];
          (u.nodeName === "LINK" || u.getAttribute("media") !== "not all") && (l.set(u.dataset.precedence, u), a = u);
        }
        a && l.set(null, a);
      }
      n = e.instance, u = n.getAttribute("data-precedence"), i = l.get(u) || a, i === a && l.set(null, n), l.set(u, n), this.count++, a = Fu.bind(this), n.addEventListener("load", a), n.addEventListener("error", a), i ? i.parentNode.insertBefore(n, i.nextSibling) : (t = t.nodeType === 9 ? t.head : t, t.insertBefore(n, t.firstChild)), e.state.loading |= 4;
    }
  }
  var Ni = {
    $$typeof: dt,
    Provider: null,
    Consumer: null,
    _currentValue: Z,
    _currentValue2: Z,
    _threadCount: 0
  };
  function lg(t, e, l, a, n, i, u, c, r) {
    this.tag = 1, this.containerInfo = t, this.pingCache = this.current = this.pendingChildren = null, this.timeoutHandle = -1, this.callbackNode = this.next = this.pendingContext = this.context = this.cancelPendingCommit = null, this.callbackPriority = 0, this.expirationTimes = Gl(-1), this.entangledLanes = this.shellSuspendCounter = this.errorRecoveryDisabledLanes = this.expiredLanes = this.warmLanes = this.pingedLanes = this.suspendedLanes = this.pendingLanes = 0, this.entanglements = Gl(0), this.hiddenUpdates = Gl(null), this.identifierPrefix = a, this.onUncaughtError = n, this.onCaughtError = i, this.onRecoverableError = u, this.pooledCache = null, this.pooledCacheLanes = 0, this.formState = r, this.incompleteTransitions = /* @__PURE__ */ new Map();
  }
  function Ld(t, e, l, a, n, i, u, c, r, b, E, O) {
    return t = new lg(
      t,
      e,
      l,
      u,
      r,
      b,
      E,
      O,
      c
    ), e = 1, i === !0 && (e |= 24), i = qe(3, null, null, e), t.current = i, i.stateNode = t, e = Qf(), e.refCount++, t.pooledCache = e, e.refCount++, i.memoizedState = {
      element: a,
      isDehydrated: l,
      cache: e
    }, Jf(i), t;
  }
  function Xd(t) {
    return t ? (t = yn, t) : yn;
  }
  function Qd(t, e, l, a, n, i) {
    n = Xd(n), a.context === null ? a.context = n : a.pendingContext = n, a = Pl(e), a.payload = { element: l }, i = i === void 0 ? null : i, i !== null && (a.callback = i), l = ta(t, a, e), l !== null && (Re(l, t, e), mi(l, t, e));
  }
  function Vd(t, e) {
    if (t = t.memoizedState, t !== null && t.dehydrated !== null) {
      var l = t.retryLane;
      t.retryLane = l !== 0 && l < e ? l : e;
    }
  }
  function so(t, e) {
    Vd(t, e), (t = t.alternate) && Vd(t, e);
  }
  function Zd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Ra(t, 67108864);
      e !== null && Re(e, t, 67108864), so(t, 67108864);
    }
  }
  function Kd(t) {
    if (t.tag === 13 || t.tag === 31) {
      var e = Qe();
      e = Jn(e);
      var l = Ra(t, e);
      l !== null && Re(l, t, e), so(t, e);
    }
  }
  var Iu = !0;
  function ag(t, e, l, a) {
    var n = g.T;
    g.T = null;
    var i = C.p;
    try {
      C.p = 2, mo(t, e, l, a);
    } finally {
      C.p = i, g.T = n;
    }
  }
  function ng(t, e, l, a) {
    var n = g.T;
    g.T = null;
    var i = C.p;
    try {
      C.p = 8, mo(t, e, l, a);
    } finally {
      C.p = i, g.T = n;
    }
  }
  function mo(t, e, l, a) {
    if (Iu) {
      var n = ho(a);
      if (n === null)
        Ic(
          t,
          e,
          a,
          Pu,
          l
        ), kd(t, a);
      else if (ug(
        n,
        t,
        e,
        l,
        a
      ))
        a.stopPropagation();
      else if (kd(t, a), e & 4 && -1 < ig.indexOf(t)) {
        for (; n !== null; ) {
          var i = yl(n);
          if (i !== null)
            switch (i.tag) {
              case 3:
                if (i = i.stateNode, i.current.memoizedState.isDehydrated) {
                  var u = fl(i.pendingLanes);
                  if (u !== 0) {
                    var c = i;
                    for (c.pendingLanes |= 2, c.entangledLanes |= 2; u; ) {
                      var r = 1 << 31 - ye(u);
                      c.entanglements[1] |= r, u &= ~r;
                    }
                    hl(i), (Ut & 6) === 0 && (Nu = pe() + 500, Oi(0));
                  }
                }
                break;
              case 31:
              case 13:
                c = Ra(i, 2), c !== null && Re(c, i, 2), ju(), so(i, 2);
            }
          if (i = ho(a), i === null && Ic(
            t,
            e,
            a,
            Pu,
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
    return t = Pn(t), go(t);
  }
  var Pu = null;
  function go(t) {
    if (Pu = null, t = cl(t), t !== null) {
      var e = k(t);
      if (e === null) t = null;
      else {
        var l = e.tag;
        if (l === 13) {
          if (t = I(e), t !== null) return t;
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
    return Pu = t, null;
  }
  function Jd(t) {
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
          case Fa:
            return 2;
          case Kn:
            return 8;
          case Wa:
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
  var po = !1, sa = null, da = null, ma = null, Hi = /* @__PURE__ */ new Map(), ji = /* @__PURE__ */ new Map(), ha = [], ig = "mousedown mouseup touchcancel touchend touchstart auxclick dblclick pointercancel pointerdown pointerup dragend dragstart drop compositionend compositionstart keydown keypress keyup input textInput copy cut paste click change contextmenu reset".split(
    " "
  );
  function kd(t, e) {
    switch (t) {
      case "focusin":
      case "focusout":
        sa = null;
        break;
      case "dragenter":
      case "dragleave":
        da = null;
        break;
      case "mouseover":
      case "mouseout":
        ma = null;
        break;
      case "pointerover":
      case "pointerout":
        Hi.delete(e.pointerId);
        break;
      case "gotpointercapture":
      case "lostpointercapture":
        ji.delete(e.pointerId);
    }
  }
  function qi(t, e, l, a, n, i) {
    return t === null || t.nativeEvent !== i ? (t = {
      blockedOn: e,
      domEventName: l,
      eventSystemFlags: a,
      nativeEvent: i,
      targetContainers: [n]
    }, e !== null && (e = yl(e), e !== null && Zd(e)), t) : (t.eventSystemFlags |= a, e = t.targetContainers, n !== null && e.indexOf(n) === -1 && e.push(n), t);
  }
  function ug(t, e, l, a, n) {
    switch (e) {
      case "focusin":
        return sa = qi(
          sa,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "dragenter":
        return da = qi(
          da,
          t,
          e,
          l,
          a,
          n
        ), !0;
      case "mouseover":
        return ma = qi(
          ma,
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
          qi(
            Hi.get(i) || null,
            t,
            e,
            l,
            a,
            n
          )
        ), !0;
      case "gotpointercapture":
        return i = n.pointerId, ji.set(
          i,
          qi(
            ji.get(i) || null,
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
  function Fd(t) {
    var e = cl(t.target);
    if (e !== null) {
      var l = k(e);
      if (l !== null) {
        if (e = l.tag, e === 13) {
          if (e = I(l), e !== null) {
            t.blockedOn = e, Ji(t.priority, function() {
              Kd(l);
            });
            return;
          }
        } else if (e === 31) {
          if (e = lt(l), e !== null) {
            t.blockedOn = e, Ji(t.priority, function() {
              Kd(l);
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
      var l = ho(t.nativeEvent);
      if (l === null) {
        l = t.nativeEvent;
        var a = new l.constructor(
          l.type,
          l
        );
        on = a, l.target.dispatchEvent(a), on = null;
      } else
        return e = yl(l), e !== null && Zd(e), t.blockedOn = l, !1;
      e.shift();
    }
    return !0;
  }
  function Wd(t, e, l) {
    tf(t) && l.delete(e);
  }
  function fg() {
    po = !1, sa !== null && tf(sa) && (sa = null), da !== null && tf(da) && (da = null), ma !== null && tf(ma) && (ma = null), Hi.forEach(Wd), ji.forEach(Wd);
  }
  function ef(t, e) {
    t.blockedOn === e && (t.blockedOn = null, po || (po = !0, T.unstable_scheduleCallback(
      T.unstable_NormalPriority,
      fg
    )));
  }
  var lf = null;
  function $d(t) {
    lf !== t && (lf = t, T.unstable_scheduleCallback(
      T.unstable_NormalPriority,
      function() {
        lf === t && (lf = null);
        for (var e = 0; e < t.length; e += 3) {
          var l = t[e], a = t[e + 1], n = t[e + 2];
          if (typeof a != "function") {
            if (go(a || l) === null)
              continue;
            break;
          }
          var i = yl(l);
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
  function Ln(t) {
    function e(r) {
      return ef(r, t);
    }
    sa !== null && ef(sa, t), da !== null && ef(da, t), ma !== null && ef(ma, t), Hi.forEach(e), ji.forEach(e);
    for (var l = 0; l < ha.length; l++) {
      var a = ha[l];
      a.blockedOn === t && (a.blockedOn = null);
    }
    for (; 0 < ha.length && (l = ha[0], l.blockedOn === null); )
      Fd(l), l.blockedOn === null && ha.shift();
    if (l = (t.ownerDocument || t).$$reactFormReplay, l != null)
      for (a = 0; a < l.length; a += 3) {
        var n = l[a], i = l[a + 1], u = n[re] || null;
        if (typeof i == "function")
          u || $d(l);
        else if (u) {
          var c = null;
          if (i && i.hasAttribute("formAction")) {
            if (n = i, u = i[re] || null)
              c = u.formAction;
            else if (go(n) !== null) continue;
          } else c = u.action;
          typeof c == "function" ? l[a + 1] = c : (l.splice(a, 3), a -= 3), $d(l);
        }
      }
  }
  function Id() {
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
  af.prototype.render = yo.prototype.render = function(t) {
    var e = this._internalRoot;
    if (e === null) throw Error(s(409));
    var l = e.current, a = Qe();
    Qd(l, a, t, e, null, null);
  }, af.prototype.unmount = yo.prototype.unmount = function() {
    var t = this._internalRoot;
    if (t !== null) {
      this._internalRoot = null;
      var e = t.containerInfo;
      Qd(t.current, 2, null, t, null, null), ju(), e[Ll] = null;
    }
  };
  function af(t) {
    this._internalRoot = t;
  }
  af.prototype.unstable_scheduleHydration = function(t) {
    if (t) {
      var e = Fn();
      t = { blockedOn: null, target: t, priority: e };
      for (var l = 0; l < ha.length && e !== 0 && e < ha[l].priority; l++) ;
      ha.splice(l, 0, t), l === 0 && Fd(t);
    }
  };
  var Pd = f.version;
  if (Pd !== "19.2.3")
    throw Error(
      s(
        527,
        Pd,
        "19.2.3"
      )
    );
  C.findDOMNode = function(t) {
    var e = t._reactInternals;
    if (e === void 0)
      throw typeof t.render == "function" ? Error(s(188)) : (t = Object.keys(t).join(","), Error(s(268, t)));
    return t = y(e), t = t !== null ? q(t) : null, t = t === null ? null : t.stateNode, t;
  };
  var cg = {
    bundleType: 0,
    version: "19.2.3",
    rendererPackageName: "react-dom",
    currentDispatcherRef: g,
    reconcilerVersion: "19.2.3"
  };
  if (typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ < "u") {
    var nf = __REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!nf.isDisabled && nf.supportsFiber)
      try {
        va = nf.inject(
          cg
        ), xe = nf;
      } catch {
      }
  }
  return Yi.createRoot = function(t, e) {
    if (!L(t)) throw Error(s(299));
    var l = !1, a = "", n = us, i = fs, u = cs;
    return e != null && (e.unstable_strictMode === !0 && (l = !0), e.identifierPrefix !== void 0 && (a = e.identifierPrefix), e.onUncaughtError !== void 0 && (n = e.onUncaughtError), e.onCaughtError !== void 0 && (i = e.onCaughtError), e.onRecoverableError !== void 0 && (u = e.onRecoverableError)), e = Ld(
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
      Id
    ), t[Ll] = e.current, $c(t), new yo(e);
  }, Yi.hydrateRoot = function(t, e, l) {
    if (!L(t)) throw Error(s(299));
    var a = !1, n = "", i = us, u = fs, c = cs, r = null;
    return l != null && (l.unstable_strictMode === !0 && (a = !0), l.identifierPrefix !== void 0 && (n = l.identifierPrefix), l.onUncaughtError !== void 0 && (i = l.onUncaughtError), l.onCaughtError !== void 0 && (u = l.onCaughtError), l.onRecoverableError !== void 0 && (c = l.onRecoverableError), l.formState !== void 0 && (r = l.formState)), e = Ld(
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
      Id
    ), e.context = Xd(null), l = e.current, a = Qe(), a = Jn(a), n = Pl(a), n.callback = null, ta(l, n, a), l = a, e.current.lanes = l, Yl(e, l), hl(e), t[Ll] = e.current, $c(t), new af(e);
  }, Yi.version = "19.2.3", Yi;
}
var om;
function vg() {
  if (om) return bo.exports;
  om = 1;
  function T() {
    if (!(typeof __REACT_DEVTOOLS_GLOBAL_HOOK__ > "u" || typeof __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE != "function"))
      try {
        __REACT_DEVTOOLS_GLOBAL_HOOK__.checkDCE(T);
      } catch (f) {
        console.error(f);
      }
  }
  return T(), bo.exports = yg(), bo.exports;
}
var bg = vg(), Mo = { exports: {} }, Eo = {};
var rm;
function xg() {
  if (rm) return Eo;
  rm = 1;
  var T = cf().__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE;
  return Eo.c = function(f) {
    return T.H.useMemoCache(f);
  }, Eo;
}
var sm;
function Sg() {
  return sm || (sm = 1, Mo.exports = xg()), Mo.exports;
}
var ka = Sg(), dm = cf();
const Tg = {
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
function Ao() {
  return !1;
}
function _o(T, f = {}) {
  const z = /* @__PURE__ */ new Set();
  return (s) => {
    const L = T?.[s];
    if (typeof L == "string" && L.trim() !== "")
      return L;
    if (f.assertMissing && !z.has(s))
      throw z.add(s), new Error(`Missing cmux diff viewer label: ${s}`);
    return Tg[s];
  };
}
const zg = {
  background: "#ffffff",
  foreground: "#000000",
  ghosttyName: "Apple System Colors Light",
  name: "cmux-ghostty-light",
  palette: {},
  selectionBackground: "#abd8ff",
  selectionForeground: "#000000",
  type: "light"
}, Mg = {
  background: "#000000",
  foreground: "#ffffff",
  ghosttyName: "Apple System Colors",
  name: "cmux-ghostty-dark",
  palette: {},
  selectionBackground: "#3f638b",
  selectionForeground: "#ffffff",
  type: "dark"
};
function mm(T) {
  const f = {
    ...zg,
    ...T?.themes?.light
  }, z = {
    ...Mg,
    ...T?.themes?.dark
  };
  return {
    backgroundOpacity: gm(T?.backgroundOpacity),
    fontFamily: T?.fontFamily ?? "Menlo",
    fontSize: ff(T?.fontSize, 10),
    lineHeight: ff(T?.lineHeight, 20),
    theme: {
      light: T?.theme?.light ?? f.name ?? "cmux-ghostty-light",
      dark: T?.theme?.dark ?? z.name ?? "cmux-ghostty-dark"
    },
    themes: {
      light: f,
      dark: z
    }
  };
}
function hm(T) {
  if (!T)
    return;
  const f = T.themes?.light ?? {}, z = T.themes?.dark ?? {}, s = document.documentElement.style;
  s.setProperty("--cmux-diff-bg-light", Ka(f.background, "#ffffff")), s.setProperty("--cmux-diff-bg-dark", Ka(z.background, "#000000")), s.setProperty("--cmux-diff-fg-light", Ka(f.foreground, "#000000")), s.setProperty("--cmux-diff-fg-dark", Ka(z.foreground, "#ffffff")), s.setProperty("--cmux-diff-selection-bg-light", Ka(f.selectionBackground, "#abd8ff")), s.setProperty("--cmux-diff-selection-bg-dark", Ka(z.selectionBackground, "#3f638b")), s.setProperty("--cmux-diff-code-font-family", Ag(T.fontFamily)), s.setProperty("--cmux-diff-font-size", `${ff(T.fontSize, 10)}px`), s.setProperty("--cmux-diff-line-height", `${ff(T.lineHeight, 20)}px`);
}
function Eg(T, f) {
  return gm(f?.backgroundOpacity) < 0.999 ? "transparent" : Ka(T, "#000000");
}
function Ka(T, f) {
  return typeof T == "string" && T.trim() !== "" ? T.trim() : f;
}
function Ag(T) {
  const f = typeof T == "string" && T.trim() !== "" ? T.trim() : "Menlo";
  return `${JSON.stringify(f)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`;
}
function ff(T, f) {
  return typeof T == "number" && Number.isFinite(T) && T > 0 ? T : f;
}
function gm(T) {
  return typeof T != "number" || !Number.isFinite(T) ? 1 : Math.max(0, Math.min(1, T));
}
function _g(T, f, z) {
  if (!T)
    return {
      kind: "reset"
    };
  const s = T.pathCount ?? T.paths?.length ?? 0, L = f.pathCount ?? z.length;
  return !(f.previousSource === T || Dg(T, f)) || L < s ? {
    kind: "reset"
  } : {
    addedPaths: z.slice(s, L),
    kind: "append"
  };
}
function Dg(T, f) {
  const z = T.paths, s = f.paths, L = T.pathCount ?? z?.length ?? 0, k = f.pathCount ?? s?.length ?? 0;
  if (!Array.isArray(z) || !Array.isArray(s) || L > k)
    return !1;
  for (let I = 0; I < L; I += 1)
    if (z[I] !== s[I])
      return !1;
  return !0;
}
function uf(T, f = {}) {
  const z = f.pending === !0;
  return {
    error: f.error === !0,
    loading: f.loading === !0 || z,
    message: T,
    pending: z,
    statusOnly: f.statusOnly === !0
  };
}
function Og(T, f) {
  const z = T.payload;
  return z?.pendingReplacement === !0 ? uf(z.statusMessage ?? f("loadingDiff"), {
    loading: !0,
    pending: !0
  }) : typeof z?.statusMessage == "string" && z.statusMessage.length > 0 ? uf(z.statusMessage, {
    error: z.statusIsError === !0,
    loading: !1,
    statusOnly: !0
  }) : uf(f("loadingDiff"), {
    loading: !0
  });
}
function pm(T) {
  document.body.dataset.loading = T.loading ? "true" : "false", document.body.dataset.statusOnly = T.statusOnly ? "true" : "false";
}
function Cg(T, f) {
  const z = (o) => {
    const d = document.getElementById(o);
    if (!d)
      throw new Error(`Missing cmux diff viewer element: ${o}`);
    return d;
  }, s = T.assets ?? {}, L = (o, d) => {
    if (typeof o != "string" || o.length === 0)
      throw new Error(`Missing cmux diff viewer asset: ${d}`);
    return new URL(o, window.location.href).href;
  }, k = L(s.diffsModuleURL, "diffsModuleURL"), I = L(s.treesModuleURL, "treesModuleURL"), lt = L(s.workerPoolModuleURL, "workerPoolModuleURL"), U = L(s.workerModuleURL, "workerModuleURL"), y = T.payload ?? {}, q = mm(y.appearance), N = z("viewer"), et = z("toolbar"), rt = z("source-select"), ht = z("repo-select"), mt = z("base-select"), Dt = z("source-detail"), P = z("jump-select"), Ot = z("external-link"), dt = z("files-toggle"), Ct = z("layout-toggle"), wt = z("options-button"), gt = z("options-menu"), W = z("files-sidebar"), Rt = z("file-list"), Pt = z("files-count"), Ft = z("file-search-toggle"), Vt = z("file-collapse-toggle"), Zt = z("stats-files"), oe = z("stats-added"), ie = z("stats-deleted"), X = _o(y.labels, {
    assertMissing: Ao()
  }), g = {
    layout: y.layout === "unified" ? "unified" : "split",
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
  let C, Z, F;
  const at = [], m = [], _ = /* @__PURE__ */ new Map();
  let B = /* @__PURE__ */ new Set(), G = null, nt = null, ct = /* @__PURE__ */ new Map(), Tt = {
    value: null
  }, fe = "", Bt = "", gl = !1, Ve = /* @__PURE__ */ new Map(), ul = /* @__PURE__ */ new Map();
  typeof y.title == "string" && y.title.trim() !== "" && (document.title = y.title), hm(q), va(), Ji(y.sourceOptions ?? []), re(ht, y.repoOptions ?? [], y.repoRoot ?? "", X("repoPath")), re(mt, y.baseOptions ?? [], y.branchBaseRef ?? "", X("branchBase"));
  const Xn = globalThis.queueMicrotask ?? ((o) => setTimeout(o, 0));
  y.pendingReplacement === !0 ? (Be(y.statusMessage ?? X("loadingDiff"), {
    loading: !0,
    pending: !0
  }), of()) : typeof y.statusMessage == "string" && y.statusMessage.length > 0 ? Be(y.statusMessage, {
    error: y.statusIsError === !0,
    loading: !1,
    statusOnly: !0
  }) : Xn(() => {
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
      preloadHighlighter: R,
      processFile: H,
      registerCustomTheme: j
    }, K] = await Promise.all([
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(k),
      // oxlint-disable-next-line react-doctor/no-dynamic-import-path -- cmux serves this external module URL from its bundled resources at runtime.
      import(I).catch((xt) => (console.warn("cmux diff file tree import failed", xt), null))
    ]);
    if (fn(j, q.themes.light), fn(j, q.themes.dark), Be(X("parsingDiff"), {
      loading: !0
    }), pa("loading"), Z = await Li(), xl(at), Se(), window.__cmuxDiffViewer = {
      codeView: C,
      items: at,
      state: g,
      workerPool: Z
    }, Vn(Z), Z?.initialize?.()?.then?.(() => ya(Z?.getStats?.()))?.catch?.((xt) => console.warn("cmux diff worker pool initialization failed", xt)), window.addEventListener("pagehide", () => Z?.terminate?.(), {
      once: !0
    }), await rf({
      CodeView: o,
      parsePatchFiles: x,
      processFile: H,
      treesModule: K
    }), at.length === 0)
      throw new Error(X("noFileDiffs"));
    Z || _e(q, m.length > 0 ? m : at, d, R).catch((xt) => console.warn("cmux diff highlighter preload failed", xt));
  }
  function Be(o, d = {}) {
    const x = uf(o, d);
    pm(x), f.setStatus(x);
  }
  async function Qn(o) {
    return o.ok ? (await o.text()).includes('data-cmux-diff-pending="true"') ? !1 : (window.location.reload(), !0) : (Be(X("renderFailed"), {
      error: !0,
      loading: !1,
      statusOnly: !0
    }), !1);
  }
  async function of() {
    try {
      const o = await fetch("/__cmux_diff_viewer_wait" + location.pathname, {
        cache: "no-store"
      });
      await Qn(o);
    } catch (o) {
      document.documentElement.dataset.cmuxDiffWait = "failed", Be(X("renderFailed"), {
        error: !0,
        loading: !1,
        statusOnly: !0
      }), console.warn("cmux diff viewer deferred load failed", o);
    }
  }
  async function Li() {
    if (typeof Worker > "u")
      return null;
    try {
      const o = await import(lt);
      fn(o.registerCustomTheme, q.themes.light), fn(o.registerCustomTheme, q.themes.dark);
      const d = new URL(U, window.location.href).href;
      return o.createDiffWorkerPool({
        workerURL: d,
        highlighterOptions: Xi()
      }) ?? null;
    } catch (o) {
      return console.warn("cmux diff worker pool unavailable; falling back to main-thread highlighting", o), null;
    }
  }
  function Vn(o) {
    if (!o) {
      pa("fallback");
      return;
    }
    pa("enabled"), ya(o.getStats?.());
    const d = o.subscribeToStatChanges?.((x) => {
      ya(x);
    });
    typeof d == "function" && window.addEventListener("pagehide", d, {
      once: !0
    });
  }
  function pa(o) {
    document.body.dataset.workerPool = o;
  }
  function ya(o) {
    !o || typeof o != "object" || (typeof o.managerState == "string" && (document.body.dataset.workerPoolState = o.managerState), Number.isFinite(o.totalWorkers) && (document.body.dataset.workerPoolWorkers = String(o.totalWorkers)), typeof o.workersFailed == "boolean" && (document.body.dataset.workerPoolFailed = String(o.workersFailed)));
  }
  function Xi() {
    return {
      theme: q.theme,
      preferredHighlighter: "shiki-wasm",
      lineDiffType: g.wordDiffs ? "word" : "none",
      maxLineDiffLength: 1e3,
      tokenizeMaxLineLength: 1e3,
      useTokenTransformer: !1
    };
  }
  const Zn = /^From\s+([a-f0-9]+)\s/im;
  function pe(o, d) {
    const x = o?.match(Zn);
    return x?.[1] ? new TextDecoder().decode(new TextEncoder().encode(x[1].slice(0, 5))) : `${X("commit")} ${d + 1}`;
  }
  async function rf({
    CodeView: o,
    parsePatchFiles: d,
    processFile: x,
    treesModule: R
  }) {
    const H = Wa(), j = {
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
    let it = performance.now(), xt = performance.now(), zt = !0;
    const Ql = {
      initialBatchSize: Wt(),
      incrementalBatchSize: 25,
      initialMaxWait: 500,
      incrementalMaxWait: 100
    };
    function bf(D, w) {
      const tt = cn(H, D, w);
      return tt?.renamedItem && Vl(tt.renamedItem), tt?.item;
    }
    function cn(D, w, tt) {
      if (!w)
        return null;
      const ut = Te(w), Mt = tt == null ? ut : `${tt}/${ut}`, Et = ut.length === 0 ? void 0 : D.pathStateByTreePath.get(Mt), Kt = Et == null ? void 0 : tl(D, Mt, Et), ze = Sl(w), De = {
        id: D.itemIdToFile.has(Mt) ? on(D, `${Mt}?2`) : Mt,
        type: "diff",
        fileDiff: w,
        version: 0,
        // Inherit the current collapse state so items flushed after "Collapse all
        // diffs" (while a large diff is still streaming) render collapsed too.
        collapsed: g.collapsed
      }, eu = D.items.length;
      D.fileIndex += 1, D.items.push(De), D.pendingItems.push(De), D.pendingItemById.set(De.id, De), D.itemIdToFile.set(De.id, {
        fileOrder: eu,
        path: ut
      }), D.itemIdByTreePath.set(Mt, De.id), D.treePathByItemId.set(De.id, Mt), D.diffStats.addedLines += ze.added, D.diffStats.deletedLines += ze.deleted, D.diffStats.fileCount += 1, D.diffStats.totalLinesOfCode += w.unifiedLineCount ?? w.splitLineCount ?? 0;
      const Sf = D.statsByPath.get(Mt);
      return D.statsByPath.set(Mt, ze), Et != null && !Pi(Sf, ze) && (D.pendingStatsChanged = !0), ut.length > 0 && (Et == null && D.paths.push(Mt), D.pathToItemId.set(Mt, De.id), Pn(D, Mt, w.type, Et?.sawDeleted === !0), D.pathStateByTreePath.set(Mt, {
        currentItem: De,
        currentItemId: De.id,
        currentType: w.type,
        fileOrder: eu,
        sawDeleted: Et?.sawDeleted === !0 || w.type === "deleted"
      })), {
        item: De,
        renamedItem: Kt
      };
    }
    function tl(D, w, tt) {
      const ut = tt.currentItemId, Mt = tt.currentType === "deleted" ? "?deleted" : "?previous", Et = on(D, `${w}${Mt}`);
      if (tt.currentItem.id = Et, tt.currentItemId = Et, D.itemIdToFile.has(ut)) {
        const Kt = D.itemIdToFile.get(ut);
        D.itemIdToFile.delete(ut), D.itemIdToFile.set(Et, Kt);
      }
      if (D.treePathByItemId.has(ut) && (D.treePathByItemId.delete(ut), D.treePathByItemId.set(Et, w)), D.pendingItemById.has(ut)) {
        const Kt = D.pendingItemById.get(ut);
        D.pendingItemById.delete(ut), D.pendingItemById.set(Et, Kt);
        return;
      }
      return {
        oldId: ut,
        newId: Et
      };
    }
    function on(D, w) {
      if (!D.itemIdToFile.has(w))
        return w;
      let tt = D.nextCollisionSuffixByBase.get(w) ?? 2, ut = `${w}-${tt}`;
      for (; D.itemIdToFile.has(ut); )
        tt += 1, ut = `${w}-${tt}`;
      return D.nextCollisionSuffixByBase.set(w, tt + 1), ut;
    }
    function Pn(D, w, tt, ut) {
      if (ut && tt !== "deleted") {
        D.gitStatusByPath.delete(w) && Tl(D, w);
        return;
      }
      const Mt = Ii(tt);
      if (Mt === "modified") {
        D.gitStatusByPath.delete(w) && Tl(D, w);
        return;
      }
      if (D.gitStatusByPath.get(w)?.status === Mt)
        return;
      const Kt = {
        path: w,
        status: Mt
      };
      D.gitStatusByPath.set(w, Kt), D.pendingGitStatusRemovePaths.delete(w), D.pendingGitStatusSetByPath.set(w, Kt);
    }
    function Tl(D, w) {
      D.pendingGitStatusSetByPath.delete(w), D.pendingGitStatusRemovePaths.add(w);
    }
    function Vl(D) {
      if (B.delete(D.oldId) && B.add(D.newId), _.has(D.oldId)) {
        const w = _.get(D.oldId);
        _.delete(D.oldId), w && _.set(D.newId, w);
      }
      Wi(D.oldId, D.newId), C?.updateItemId?.(D.oldId, D.newId);
    }
    async function rn(D, w) {
      bf(D, w) && await Ta(!1);
    }
    async function Ta(D) {
      if (H.pendingItems.length === 0)
        return;
      const w = performance.now();
      if (!D && zt && w - it >= 8 && H.pendingItems.length < Ql.initialBatchSize && w - xt < Ql.initialMaxWait) {
        await Vi(), it = performance.now();
        return;
      }
      const tt = zt ? Ql.initialBatchSize : Ql.incrementalBatchSize, ut = zt ? Ql.initialMaxWait : Ql.incrementalMaxWait;
      if (D || H.pendingItems.length >= tt || w - xt >= ut) {
        tu(), await Vi(), it = performance.now();
        return;
      }
    }
    function tu() {
      if (H.pendingItems.length === 0)
        return;
      const D = H.pendingItems.splice(0, H.pendingItems.length);
      H.pendingItemById.clear();
      const w = D, tt = m.length > 0;
      at.push(...D);
      for (const ut of D)
        _.set(ut.id, ut);
      if (w.length > 0) {
        m.push(...w);
        for (const ut of w)
          B.add(ut.id);
        C ? C.addItems(w) : (C = new o(fl(), Z ?? void 0), C.setup(N), C.setItems(m), C.render(!0), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.codeView = C));
      }
      yf(D), He(R, !1, D.length), K.flushCount += 1, K.maxBatchSize = Math.max(K.maxBatchSize, D.length), K.fileCount = at.length, K.renderableFileCount = m.length, Fa(K), xt = performance.now(), zt && (zt = !1, document.body.dataset.loading = "false"), tt || Sa(m[0]?.id ?? at[0]?.id ?? ""), window.__cmuxDiffViewer && (window.__cmuxDiffViewer.items = at, window.__cmuxDiffViewer.codeViewItems = m, window.__cmuxDiffViewer.streamMetrics = K);
    }
    function Zl() {
      C && (C.syncContainerHeight?.(), C.render(!0));
    }
    function He(D, w, tt = 1) {
      if (j.treesModule = D, j.dirtyCount += tt, w || j.lastRefreshAt === 0) {
        za(j.treesModule);
        return;
      }
      const ut = performance.now() - j.lastRefreshAt;
      if (j.dirtyCount >= 1e3 || ut >= 1e3) {
        za(j.treesModule);
        return;
      }
      if (j.timeout !== 0)
        return;
      const Mt = Math.max(0, 1e3 - ut);
      j.timeout = window.setTimeout(() => {
        j.timeout = 0, za(j.treesModule);
      }, Mt);
    }
    function za(D) {
      j.timeout !== 0 && (window.clearTimeout(j.timeout), j.timeout = 0), j.dirtyCount = 0, j.lastRefreshAt = performance.now(), K.treeRefreshCount += 1, nt = sf(H), Wn(nt, D), Se(), Fa(K);
    }
    const el = await fetch(y.patchURL, {
      cache: "no-store"
    });
    if (!el.ok)
      throw new Error(`${X("loadingDiff")} (${el.status})`);
    if (!el.body?.getReader) {
      const D = await el.text();
      await Kn(D, d, rn), await Ta(!0), Zl(), He(R, !0), K.completedAt = performance.now();
      return;
    }
    const ll = new TextDecoder(), ti = el.body.getReader(), Ma = "diff --git ", ei = `
` + Ma, sn = ei.length - 1, Ea = /\S/;
    function Aa(D, w) {
      const tt = Math.max(w, 0);
      if (tt === 0 && D.startsWith(Ma))
        return 0;
      const ut = D.indexOf(ei, tt);
      return ut === -1 ? void 0 : ut + 1;
    }
    function se(D, w) {
      return Math.max(w, D.length - sn);
    }
    function zl(D, w, tt) {
      const ut = Math.max(w, 0), Mt = Math.min(tt, D.length);
      if (ut >= Mt)
        return;
      let Et = D.lastIndexOf(`
From `, Mt - 1);
      for (; Et !== -1; ) {
        const Kt = Et + 1;
        if (Kt < ut)
          return;
        if (Kt >= Mt) {
          Et = D.lastIndexOf(`
From `, Et - 1);
          continue;
        }
        const ze = D.indexOf(`
`, Kt + 1), Ca = D.slice(Kt, ze === -1 || ze > Mt ? Mt : ze);
        if (Zn.test(Ca))
          return Kt;
        Et = D.lastIndexOf(`
From `, Et - 1);
      }
    }
    function dn(D) {
      const w = Aa(D, 0);
      if (w == null || w <= 0)
        return;
      const tt = D.slice(0, w);
      return Zn.test(tt) ? tt : void 0;
    }
    async function Kl(D) {
      if (D.trim() === "")
        return;
      const w = dn(D);
      w != null && (Jl = pe(w, Da), Da += 1);
      const tt = `cmux-diff-file-${H.fileIndex}`;
      await rn(x(D, {
        cacheKey: tt,
        isGitDiff: !0
      }), Jl);
    }
    function xf() {
      let D, w = "", tt = 0, ut = !1;
      function Mt() {
        if (D == null) {
          if (D = Aa(w, tt), D == null)
            return tt = se(w, 0), null;
          ut = !0, tt = D + 1;
        }
        for (; ; ) {
          const Et = D;
          if (Et == null)
            return null;
          const Kt = Aa(w, tt);
          if (Kt == null)
            return tt = se(w, Et + 1), null;
          const ze = zl(w, Et + 1, Kt) ?? Kt, Ca = w.slice(0, ze);
          if (w = w.slice(ze), D = Aa(w, 0), tt = D == null ? 0 : D + 1, Ea.test(Ca))
            return Ca;
        }
      }
      return {
        push(Et) {
          Et.length > 0 && (w += Et);
        },
        takeAvailableFile: Mt,
        finish() {
          const Et = Mt();
          if (Et != null)
            return {
              fileText: Et
            };
          if (!Ea.test(w))
            return w = "", {};
          if (!ut) {
            const ze = w;
            return w = "", {
              fallbackPatchContent: ze
            };
          }
          const Kt = w;
          return w = "", {
            fileText: Kt
          };
        }
      };
    }
    async function _a(D) {
      let w;
      for (; (w = D.takeAvailableFile()) != null; )
        await Kl(w);
    }
    const rl = xf();
    let Jl, Da = 0;
    for (; ; ) {
      const {
        done: D,
        value: w
      } = await ti.read();
      if (D) {
        const tt = ll.decode();
        tt.length > 0 && (rl.push(tt), await _a(rl));
        break;
      }
      rl.push(ll.decode(w, {
        stream: !0
      })), await _a(rl);
    }
    const Oa = rl.finish();
    Oa.fileText != null ? (await Kl(Oa.fileText), await _a(rl)) : Oa.fallbackPatchContent != null && await Kn(Oa.fallbackPatchContent, d, rn), await Ta(!0), Zl(), He(R, !0), K.completedAt = performance.now(), Fa(K);
  }
  function Fa(o) {
    document.body.dataset.streamFileCount = String(o.fileCount ?? at.length), document.body.dataset.streamRenderableFileCount = String(o.renderableFileCount ?? m.length), document.body.dataset.streamFlushCount = String(o.flushCount ?? 0), document.body.dataset.streamMaxBatchSize = String(o.maxBatchSize ?? 0), document.body.dataset.streamTreeRefreshCount = String(o.treeRefreshCount ?? 0), Number.isFinite(o.completedAt) && o.completedAt > 0 && (document.body.dataset.streamElapsedMs = String(Math.round(o.completedAt - o.startedAt)));
  }
  async function Kn(o, d, x) {
    const R = d(o, "cmux-diff"), H = R.length > 1;
    for (const [j, K] of R.entries()) {
      const it = H ? pe(K.patchMetadata, j) : void 0;
      for (const xt of K.files ?? [])
        await x(xt, it);
    }
  }
  function Wa() {
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
  function sf(o) {
    const d = o.lastTreeSource, x = Qi(o), R = {
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
    return o.pendingStatsChanged = !1, o.lastTreeSource = R, R;
  }
  function Qi(o) {
    if (o.pendingGitStatusRemovePaths.size === 0 && o.pendingGitStatusSetByPath.size === 0)
      return;
    const d = {};
    return o.pendingGitStatusRemovePaths.size > 0 && (d.remove = Array.from(o.pendingGitStatusRemovePaths), o.pendingGitStatusRemovePaths.clear()), o.pendingGitStatusSetByPath.size > 0 && (d.set = Array.from(o.pendingGitStatusSetByPath.values()), o.pendingGitStatusSetByPath.clear()), d;
  }
  function Vi() {
    return new Promise((o) => {
      let d = !1, x = 0;
      const R = () => {
        d || (d = !0, x !== 0 && window.clearTimeout(x), o());
      };
      if (document.visibilityState === "visible" && document.hasFocus())
        x = window.setTimeout(R, 50), window.requestAnimationFrame(R);
      else if (typeof MessageChannel < "u") {
        const H = new MessageChannel();
        H.port1.onmessage = R, H.port2.postMessage(void 0);
      } else
        queueMicrotask(R);
    });
  }
  async function df() {
    return Tt.value == null && (Tt.value = fetch(y.patchURL, {
      cache: "no-store"
    }).then(async (o) => {
      if (!o.ok)
        throw new Error(`${X("loadingDiff")} (${o.status})`);
      return o.text();
    })), Tt.value;
  }
  function va() {
    dt.innerHTML = ve("files"), Ft.innerHTML = ve("search"), Vt.innerHTML = ve("sidebarCollapse"), Ct.innerHTML = ve(g.layout), wt.innerHTML = ve("dots"), typeof y.externalURL == "string" && y.externalURL.length > 0 && (Ot.href = y.externalURL, Ot.innerHTML = ve("external"), Ot.hidden = !1), dt.addEventListener("click", () => Gl(!g.filesVisible)), Vt.addEventListener("click", () => Gl(!1)), Ft.addEventListener("click", () => Yl(!g.fileSearchOpen)), Ct.addEventListener("click", () => Ki(g.layout === "split" ? "unified" : "split")), wt.addEventListener("click", () => ln(gt.hidden)), document.addEventListener("click", (o) => {
      gt.hidden || o.target instanceof Node && et.contains(o.target) || ln(!1);
    }), document.addEventListener("keydown", (o) => {
      o.key === "Escape" && ln(!1);
    }), xe(), Se();
  }
  function xe() {
    const o = y.shortcuts ?? {}, d = Ee(o.diffViewerScrollDown), x = Ee(o.diffViewerScrollUp), R = Ee(o.diffViewerScrollToBottom), H = Ee(o.diffViewerScrollToTop), j = Ee(o.diffViewerOpenFileSearch);
    let K = null, it = 0;
    document.addEventListener("keydown", (zt) => {
      if (!(zt.defaultPrevented || tn(zt.target))) {
        if (K && !Ia(K.shortcut.second, zt) && xt(), K && Ia(K.shortcut.second, zt)) {
          zt.preventDefault(), K.action(), xt();
          return;
        }
        if ($a(d, zt)) {
          zt.preventDefault(), ba(1);
          return;
        }
        if ($a(x, zt)) {
          zt.preventDefault(), ba(-1);
          return;
        }
        if ($a(R, zt)) {
          zt.preventDefault(), N.scrollTo({
            top: N.scrollHeight,
            behavior: "auto"
          });
          return;
        }
        if ($a(j, zt) && F) {
          zt.preventDefault(), Gl(!0), Yl(!0);
          return;
        }
        H && mf(H, zt) && (zt.preventDefault(), K = {
          shortcut: H,
          action: () => N.scrollTo({
            top: 0,
            behavior: "auto"
          })
        }, it = window.setTimeout(xt, 700));
      }
    });
    function xt() {
      K = null, it !== 0 && (window.clearTimeout(it), it = 0);
    }
  }
  function Ee(o) {
    return !o || o.unbound === !0 || !o.first ? null : {
      first: ye(o.first),
      second: o.second ? ye(o.second) : null
    };
  }
  function ye(o) {
    return {
      key: String(o?.key ?? "").toLowerCase(),
      command: o?.command === !0,
      shift: o?.shift === !0,
      option: o?.option === !0,
      control: o?.control === !0
    };
  }
  function $a(o, d) {
    return o && !o.second && Ia(o.first, d);
  }
  function mf(o, d) {
    return o && o.second && Ia(o.first, d);
  }
  function Ia(o, d) {
    return !o || d.metaKey !== o.command || d.ctrlKey !== o.control || d.altKey !== o.option || d.shiftKey !== o.shift ? !1 : Pa(d) === o.key;
  }
  function Pa(o) {
    return o.code === "Space" ? "space" : typeof o.key != "string" || o.key.length === 0 ? "" : (o.key.length === 1, o.key.toLowerCase());
  }
  function tn(o) {
    const d = o instanceof Element ? o : null;
    return d ? !!d.closest("input, textarea, select, [contenteditable='true']") : !1;
  }
  function ba(o) {
    const d = Math.max(80, Math.floor(N.clientHeight * 0.38));
    N.scrollBy({
      top: o * d,
      behavior: "auto"
    });
  }
  function fl() {
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
      unsafeCSS: en(),
      theme: q.theme,
      themeType: "system"
    };
  }
  function en() {
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
  function Ne() {
    const o = fl();
    if (!C) {
      Zi();
      return;
    }
    C.setOptions(o), Zi(), C.render(!0);
  }
  function Zi() {
    Z?.setRenderOptions && Z.setRenderOptions(Xi()).then(() => C?.render(!0)).catch((o) => console.warn("cmux diff worker render options update failed", o));
  }
  function Ki(o) {
    g.layout = o === "unified" ? "unified" : "split", Se(), Ne();
  }
  function Gl(o) {
    g.filesVisible = o, document.body.dataset.filesHidden = o ? "false" : "true", W.setAttribute("aria-hidden", String(!o)), o ? W.removeAttribute("inert") : W.setAttribute("inert", ""), Se();
  }
  function Yl(o) {
    g.fileSearchOpen = !!o, F && (g.fileSearchOpen ? F.openSearch("") : F.closeSearch()), Se();
  }
  function hf(o) {
    g.collapsed = o;
    const d = m.map((H) => ({
      ...H,
      collapsed: o,
      version: (H.version ?? 0) + 1
    })), x = new Map(d.map((H) => [H.id, H])), R = at.map((H) => x.get(H.id) ?? {
      ...H,
      collapsed: o,
      version: (H.version ?? 0) + 1
    });
    m.splice(0, m.length, ...d), at.splice(0, at.length, ...R), C && (C.setItems(m), C.render(!0)), Se();
  }
  function Se() {
    dt.setAttribute("aria-pressed", String(g.filesVisible)), dt.title = g.filesVisible ? X("hideFiles") : X("showFiles"), dt.setAttribute("aria-label", dt.title), Vt.title = X("hideFiles"), Vt.setAttribute("aria-label", Vt.title), Ct.innerHTML = ve(g.layout), Ct.title = g.layout === "split" ? X("switchToUnifiedDiff") : X("switchToSplitDiff"), Ct.setAttribute("aria-label", Ct.title), wt.setAttribute("aria-expanded", String(!gt.hidden)), document.documentElement.dataset.layout = g.layout, document.documentElement.dataset.wordWrap = String(g.wordWrap), document.documentElement.dataset.diffIndicators = g.diffIndicators, Ft.disabled = !F, Ft.setAttribute("aria-pressed", String(g.fileSearchOpen)), Ft.title = g.fileSearchOpen ? X("hideFileSearch") : X("showFileSearch"), Ft.setAttribute("aria-label", Ft.title);
  }
  function ln(o) {
    o && an(), gt.hidden = !o, Se();
  }
  function an() {
    gt.textContent = "";
    const o = [{
      label: X("refresh"),
      icon: "refresh",
      action: () => window.location.reload()
    }, {
      label: g.wordWrap ? X("disableWordWrap") : X("enableWordWrap"),
      icon: "wrap",
      checked: g.wordWrap,
      action: () => {
        g.wordWrap = !g.wordWrap, Ne();
      }
    }, {
      label: g.collapsed ? X("expandAllDiffs") : X("collapseAllDiffs"),
      icon: "collapse",
      checked: g.collapsed,
      action: () => hf(!g.collapsed)
    }, "separator", {
      label: g.filesVisible ? X("hideFiles") : X("showFiles"),
      icon: "files",
      checked: g.filesVisible,
      action: () => Gl(!g.filesVisible)
    }, {
      label: g.expandUnchanged ? X("collapseUnchangedContext") : X("expandUnchangedContext"),
      icon: "document",
      checked: g.expandUnchanged,
      action: () => {
        g.expandUnchanged = !g.expandUnchanged, Ne();
      }
    }, {
      label: g.showBackgrounds ? X("hideBackgrounds") : X("showBackgrounds"),
      icon: "background",
      checked: g.showBackgrounds,
      action: () => {
        g.showBackgrounds = !g.showBackgrounds, Ne();
      }
    }, {
      label: g.lineNumbers ? X("hideLineNumbers") : X("showLineNumbers"),
      icon: "numbers",
      checked: g.lineNumbers,
      action: () => {
        g.lineNumbers = !g.lineNumbers, Ne();
      }
    }, {
      label: g.wordDiffs ? X("disableWordDiffs") : X("enableWordDiffs"),
      icon: "word",
      checked: g.wordDiffs,
      action: () => {
        g.wordDiffs = !g.wordDiffs, Ne();
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
      action: kn
    }];
    for (const d of o) {
      if (d === "separator") {
        const H = document.createElement("div");
        H.className = "menu-separator", gt.append(H);
        continue;
      }
      if (d.kind === "segment") {
        const H = document.createElement("div");
        H.className = "menu-item menu-segment", H.setAttribute("role", "presentation"), H.innerHTML = `${ve(d.icon)}<span class="menu-label"></span><span class="menu-segment-controls"></span>`;
        const j = H.querySelector(".menu-label");
        j && (j.textContent = d.label);
        const K = H.querySelector(".menu-segment-controls");
        if (!K)
          continue;
        for (const it of d.options) {
          const xt = document.createElement("button");
          xt.type = "button", xt.className = "segment-button", xt.title = it.label, xt.setAttribute("aria-label", it.label), xt.setAttribute("aria-pressed", String(g.diffIndicators === it.value)), xt.innerHTML = ve(it.icon), xt.addEventListener("click", () => {
            g.diffIndicators = it.value, Ne(), an(), Se();
          }), K.append(xt);
        }
        gt.append(H);
        continue;
      }
      const x = document.createElement("button");
      x.type = "button", x.className = "menu-item", x.setAttribute("role", d.checked == null ? "menuitem" : "menuitemcheckbox"), d.checked != null && x.setAttribute("aria-checked", String(!!d.checked)), x.disabled = !!d.disabled, x.innerHTML = `${ve(d.icon)}<span class="menu-label"></span><span class="menu-check">${d.checked ? ve("check") : ""}</span>`;
      const R = x.querySelector(".menu-label");
      R && (R.textContent = d.label), x.addEventListener("click", () => {
        x.disabled || (d.action?.(), an(), Se());
      }), gt.append(x);
    }
  }
  function Jn(o) {
    const d = new Set(o.split(/\r?\n/));
    let x = "CMUX_DIFF_PATCH", R = 0;
    for (; d.has(x); )
      R += 1, x = `CMUX_DIFF_PATCH_${R}`;
    return x;
  }
  async function kn() {
    const d = await df(), x = d.endsWith(`
`) ? d : `${d}
`, R = Jn(x), H = `git apply <<'${R}'
${x}${R}`;
    if (navigator.clipboard?.writeText)
      try {
        await navigator.clipboard.writeText(H);
      } catch {
        Fn(H);
      }
    else
      Fn(H);
    wt.title = X("copiedGitApplyCommand"), wt.setAttribute("aria-label", X("copiedGitApplyCommand"));
  }
  function Fn(o) {
    const d = document.createElement("textarea");
    d.value = o, d.setAttribute("readonly", ""), d.style.position = "fixed", d.style.left = "-9999px", document.body.append(d), d.select(), document.execCommand("copy"), d.remove();
  }
  function Ji(o) {
    if (Dt.textContent = te(), !Array.isArray(o) || o.length < 2)
      return;
    rt.textContent = "";
    const d = o.find((x) => x.selected) ?? o.find((x) => !x.disabled);
    for (const x of o) {
      const R = document.createElement("option");
      R.value = x.value, R.textContent = x.label, R.disabled = x.disabled || !x.url, R.selected = x.value === d?.value, x.message && (R.title = x.message), rt.append(R);
    }
    Dt.textContent = d?.sourceLabel ?? te(), rt.hidden = !1, rt.addEventListener("change", () => {
      const x = o.find((R) => R.value === rt.value);
      if (!x?.url) {
        rt.value = d?.value ?? "";
        return;
      }
      Be(X("loadingDiff"), {
        pending: !0
      }), window.location.href = Pe(x.url);
    });
  }
  function Pe(o) {
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
  function te() {
    return [y.sourceLabel, y.repoRoot, y.branchBaseRef].filter((d) => typeof d == "string" && d.trim() !== "").join(" | ");
  }
  function re(o, d, x, R) {
    if (!o || !Array.isArray(d) || d.length < 2)
      return;
    o.textContent = "";
    const H = d.find((j) => j.selected) ?? d.find((j) => !j.disabled);
    for (const j of d) {
      const K = document.createElement("option");
      K.value = j.value, K.textContent = j.label, K.disabled = j.disabled || !j.url, K.selected = j.value === H?.value, j.message && (K.title = j.message), o.append(K);
    }
    o.hidden = !1, o.title = R, o.addEventListener("change", () => {
      const j = d.find((K) => K.value === o.value);
      if (!j?.url) {
        o.value = H?.value ?? x ?? "";
        return;
      }
      Be(X("loadingDiff"), {
        pending: !0
      }), window.location.href = Pe(j.url);
    });
  }
  function Ll(o, d) {
    const x = Xl(o), R = ki(d);
    if (ol(o, []), F && (F.cleanUp?.(), F = null), G = null, g.fileSearchOpen = !1, Rt.textContent = "", Pt.textContent = `${x}`, $n(o), R)
      try {
        gf(o, d), Se();
        return;
      } catch (j) {
        console.warn("cmux diff file tree setup failed", j);
      }
    const H = xa(o);
    ol(o, H), vl(H), Se();
  }
  function Wn(o, d) {
    const x = Xl(o);
    if (ol(o, []), Pt.textContent = `${x}`, $n(o), F && Rt.dataset.treeMode === "pierre" && d?.preparePresortedFileTreeInput) {
      pf(o, d);
      return;
    }
    if (F || Rt.childElementCount === 0) {
      Ll(o, d);
      return;
    }
    const R = xa(o);
    ol(o, R), Rt.textContent = "", vl(R);
  }
  function gf(o, d) {
    const {
      FileTree: x,
      preparePresortedFileTreeInput: R
    } = d, H = cl(o);
    G = o;
    const j = H[0];
    yl(o), Rt.dataset.treeMode = "pierre", F = new x({
      flattenEmptyDirectories: !0,
      id: "cmux-diff-file-tree",
      initialExpansion: "open",
      initialSelectedPaths: j ? [j] : [],
      initialVisibleRowCount: Wt(),
      itemHeight: 24,
      overscan: 12,
      preparedInput: R(H),
      search: !0,
      searchBlurBehavior: "retain",
      stickyFolders: !0,
      gitStatus: o.gitStatus,
      renderRowDecoration(K) {
        if (K.item.kind !== "file")
          return null;
        const it = ct.get(K.item.path);
        return it == null || it.added === 0 && it.deleted === 0 ? null : {
          text: `+${it.added} -${it.deleted}`,
          title: `${it.added} ${X("additions")}, ${it.deleted} ${X("deletions")}`
        };
      },
      sort: () => 0,
      unsafeCSS: Fi(),
      onSelectionChange(K) {
        if (gl)
          return;
        const it = K[K.length - 1], xt = Ve.get(it);
        xt && nn(xt);
      }
    }), F.render({
      containerWrapper: Rt
    });
  }
  function pf(o, d) {
    const x = G, R = cl(o);
    G = o, yl(o);
    let H = !1;
    const j = _g(x, o, R);
    if (j.kind === "append") {
      const K = j.addedPaths;
      if (K.length > 0)
        try {
          F.batch(K.map((it) => ({
            type: "add",
            path: it
          })));
        } catch (it) {
          console.warn("cmux diff file tree incremental update failed; resetting paths", it), F.resetPaths(R, {
            preparedInput: d.preparePresortedFileTreeInput(R)
          }), H = !0;
        }
    } else
      F.resetPaths(R, {
        preparedInput: d.preparePresortedFileTreeInput(R)
      }), H = !0;
    o.gitStatusPatch ? typeof F.applyGitStatusPatch == "function" ? F.applyGitStatusPatch(o.gitStatusPatch) : F.setGitStatus(o.gitStatus) : (H || o.statsChanged === !0) && F.setGitStatus(o.gitStatus);
  }
  function ki(o) {
    return !!(o?.FileTree && o?.preparePresortedFileTreeInput);
  }
  function Xl(o) {
    return o?.pathCount ?? o?.entries?.length ?? 0;
  }
  function xa(o) {
    const d = o?.pathCount ?? o?.entries?.length ?? 0, x = o?.entries ?? [];
    if (x.length > 0)
      return x.length === d ? x : x.slice(0, d);
    const R = cl(o), H = o?.pathToItemId, j = o?.statsByPath;
    return R.map((K) => {
      const it = H instanceof Map ? H.get(K) : void 0, xt = it ? _.get(it) : void 0, zt = xt?.fileDiff ?? {};
      return {
        item: xt ?? {
          id: it ?? K,
          fileDiff: zt
        },
        path: K,
        status: $i(zt),
        stats: j instanceof Map ? j.get(K) ?? Sl(zt) : Sl(zt)
      };
    });
  }
  function cl(o) {
    const d = o?.pathCount ?? o?.paths?.length ?? 0, x = o?.paths ?? [];
    return x.length === d ? x : x.slice(0, d);
  }
  function yl(o) {
    if (o?.statsByPath instanceof Map) {
      ct = o.statsByPath;
      return;
    }
    ct = /* @__PURE__ */ new Map();
    const d = xa(o);
    for (const x of d)
      ct.set(x.path, x.stats);
  }
  function ol(o, d) {
    if (o?.pathToItemId instanceof Map && o?.treePathByItemId instanceof Map)
      Ve = o.pathToItemId, ul = o.treePathByItemId;
    else if (o?.pathToItemId instanceof Map) {
      Ve = o.pathToItemId, ul = /* @__PURE__ */ new Map();
      for (const [x, R] of Ve)
        ul.set(R, x);
    } else {
      Ve = /* @__PURE__ */ new Map(), ul = /* @__PURE__ */ new Map();
      for (const x of d) {
        const R = x.item?.id;
        R && (Ve.set(x.path, R), ul.set(R, x.path));
      }
    }
    Bt && !Ve.has(Bt) && (Bt = "");
  }
  function vl(o) {
    delete Rt.dataset.treeMode;
    for (const d of o) {
      const x = d.item, R = x.fileDiff ?? {}, H = d.stats ?? Sl(R), j = document.createElement("button");
      j.type = "button", j.className = "file-entry", j.dataset.itemId = x.id, j.title = Te(R), j.innerHTML = `
      <span class="file-status">${Ae(R)}</span>
      <span class="file-name"></span>
      <span class="file-stats">
        <span class="stat-add">+${H.added}</span>
        <span class="stat-del">-${H.deleted}</span>
      </span>
    `;
      const K = j.querySelector(".file-name");
      K && (K.textContent = Te(R)), j.addEventListener("click", () => nn(x.id)), Rt.append(j);
    }
  }
  function Wt() {
    const o = window.visualViewport?.height ?? window.innerHeight;
    return !Number.isFinite(o) || o <= 0 ? 25 : Math.min(96, Math.max(25, Math.ceil(o / 24)));
  }
  function Fi() {
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
  function $n(o) {
    const d = o?.diffStats;
    if (d && Number.isFinite(d.addedLines) && Number.isFinite(d.deletedLines) && Number.isFinite(d.fileCount)) {
      Zt.textContent = `${d.fileCount}`, oe.textContent = `+${d.addedLines}`, ie.textContent = `-${d.deletedLines}`;
      return;
    }
    bl(o?.entries ?? []);
  }
  function bl(o) {
    const d = o.reduce((x, R) => {
      const H = R.stats ?? Sl(R.item?.fileDiff ?? {});
      return x.added += H.added, x.deleted += H.deleted, x;
    }, {
      added: 0,
      deleted: 0
    });
    Zt.textContent = `${o.length}`, oe.textContent = `+${d.added}`, ie.textContent = `-${d.deleted}`;
  }
  function xl(o) {
    P.textContent = "";
    const d = document.createElement("option");
    d.value = "", d.textContent = X("jumpToFile"), P.append(d), P.dataset.initialized = "true";
    for (const x of o) {
      const R = document.createElement("option");
      R.value = x.id, R.textContent = Te(x.fileDiff ?? {}), P.append(R);
    }
    P.hidden = o.length === 0, P.onchange = () => {
      P.value && nn(P.value);
    };
  }
  function yf(o) {
    if (o.length === 0)
      return;
    P.dataset.initialized !== "true" && xl([]);
    const d = document.createDocumentFragment();
    for (const x of o) {
      const R = document.createElement("option");
      R.value = x.id, R.textContent = Te(x.fileDiff ?? {}), d.append(R);
    }
    P.append(d), P.hidden = !1;
  }
  function Wi(o, d) {
    if (P.dataset.initialized === "true") {
      for (const x of P.options)
        if (x.value === o) {
          x.value = d;
          return;
        }
    }
  }
  function nn(o) {
    if (!C)
      return;
    const d = vf(o);
    d && (C.scrollTo({
      type: "item",
      id: d,
      align: "start",
      behavior: "smooth-auto"
    }), Sa(d));
  }
  function vf(o) {
    if (B.has(o))
      return o;
    const d = at.findIndex((x) => x.id === o);
    if (d === -1)
      return m[0]?.id ?? "";
    for (let x = d + 1; x < at.length; x += 1)
      if (B.has(at[x].id))
        return at[x].id;
    for (let x = d - 1; x >= 0; x -= 1)
      if (B.has(at[x].id))
        return at[x].id;
    return "";
  }
  function Sa(o) {
    if (!(!o || fe === o)) {
      fe = o, un(o);
      for (const d of Rt.querySelectorAll(".file-entry"))
        d.setAttribute("aria-current", d.dataset.itemId === o ? "true" : "false");
      P.value !== o && (P.value = o);
    }
  }
  function un(o) {
    if (!F)
      return;
    const d = ul.get(o);
    if (!(!d || d === Bt)) {
      gl = !0;
      try {
        Bt && F.getItem(Bt)?.deselect(), F.getItem(d)?.select(), F.scrollToPath(d, {
          focus: !1,
          offset: "nearest"
        }), Bt = d;
      } finally {
        Xn(() => {
          gl = !1;
        });
      }
    }
  }
  function Te(o) {
    return o.name ?? o.newName ?? o.oldName ?? o.prevName ?? X("untitled");
  }
  function Ae(o) {
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
  function $i(o) {
    return Ii(o.type);
  }
  function Ii(o) {
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
  function Sl(o) {
    const d = {
      added: 0,
      deleted: 0
    };
    for (const x of o.hunks ?? [])
      d.added += x.additionLines ?? 0, d.deleted += x.deletionLines ?? 0;
    return d;
  }
  function Pi(o, d) {
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
  function fn(o, d) {
    o(d.name, () => Promise.resolve(In(d)));
  }
  function _e(o, d, x, R) {
    const H = Array.from(new Set([o.theme?.light, o.theme?.dark].filter(Boolean))), j = Array.from(new Set(d.flatMap((K) => {
      const it = K.fileDiff ?? {}, xt = it.name ?? it.newName ?? it.oldName ?? it.prevName ?? "", zt = it.lang ?? x(xt) ?? "text";
      return zt ? [zt] : [];
    })));
    return R({
      themes: H,
      langs: j.length > 0 ? j : ["text"]
    });
  }
  function In(o) {
    const d = o.palette ?? {}, x = o.foreground, R = Eg(o.background, q);
    return {
      name: o.name,
      displayName: o.ghosttyName,
      type: o.type,
      colors: {
        "editor.background": R,
        "editor.foreground": x,
        "terminal.background": R,
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
          background: R
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
const Ug = ["82%", "64%", "76%", "58%", "70%", "46%"], wg = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
function Rg() {
  const T = ka.c(1);
  let f;
  return T[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ V.jsx("div", { className: "diff-loading-placeholder", "aria-hidden": "true", children: Ug.map(Bg) }), T[0] = f) : f = T[0], f;
}
function Bg(T, f) {
  return /* @__PURE__ */ V.jsxs("div", { className: "grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]", children: [
    /* @__PURE__ */ V.jsx("span", { className: "size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" }),
    /* @__PURE__ */ V.jsx("span", { className: "h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: T
    } }),
    /* @__PURE__ */ V.jsx("span", { className: "h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70", style: {
      width: f % 2 === 0 ? "34px" : "24px"
    } })
  ] }, `${T}-${f}`);
}
function Ng() {
  const T = ka.c(2);
  let f;
  T[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (f = /* @__PURE__ */ V.jsxs("div", { className: "mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3", children: [
    /* @__PURE__ */ V.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ V.jsx("span", { className: "h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" }),
    /* @__PURE__ */ V.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" })
  ] }), T[0] = f) : f = T[0];
  let z;
  return T[1] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (z = /* @__PURE__ */ V.jsxs("div", { className: "diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3", "aria-hidden": "true", children: [
    f,
    /* @__PURE__ */ V.jsx("div", { className: "space-y-[13px] px-3 py-1", children: wg.map(Hg) })
  ] }), T[1] = z) : z = T[1], z;
}
function Hg(T, f) {
  return /* @__PURE__ */ V.jsxs("div", { className: "grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4", children: [
    /* @__PURE__ */ V.jsx("span", { className: "h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" }),
    /* @__PURE__ */ V.jsx("span", { className: "h-3 rounded bg-[var(--cmux-diff-muted-bg)]", style: {
      width: T
    } })
  ] }, `${T}-${f}`);
}
function jg(T) {
  const f = ka.c(13), {
    label: z,
    status: s
  } = T, L = s.error ? "true" : "false", k = s.pending ? "true" : "false";
  let I;
  f[0] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (I = /* @__PURE__ */ V.jsx("span", { id: "status-icon", "aria-hidden": "true" }), f[0] = I) : I = f[0];
  let lt;
  f[1] !== z || f[2] !== s.message ? (lt = s.message || z("loadingDiff"), f[1] = z, f[2] = s.message, f[3] = lt) : lt = f[3];
  let U;
  f[4] !== lt ? (U = /* @__PURE__ */ V.jsx("span", { id: "status-text", children: lt }), f[4] = lt, f[5] = U) : U = f[5];
  let y;
  f[6] !== L || f[7] !== k || f[8] !== U ? (y = /* @__PURE__ */ V.jsxs("div", { id: "status", "data-error": L, "data-pending": k, children: [
    I,
    U
  ] }), f[6] = L, f[7] = k, f[8] = U, f[9] = y) : y = f[9];
  let q;
  f[10] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (q = /* @__PURE__ */ V.jsx(Ng, {}), f[10] = q) : q = f[10];
  let N;
  return f[11] !== y ? (N = /* @__PURE__ */ V.jsxs("div", { id: "loading-layer", "aria-live": "polite", children: [
    y,
    q
  ] }), f[11] = y, f[12] = N) : N = f[12], N;
}
function qg(T) {
  const f = ka.c(17), {
    label: z
  } = T;
  let s;
  f[0] !== z ? (s = z("diffTarget"), f[0] = z, f[1] = s) : s = f[1];
  let L;
  f[2] !== s ? (L = /* @__PURE__ */ V.jsx("select", { id: "source-select", "aria-label": s, hidden: !0 }), f[2] = s, f[3] = L) : L = f[3];
  let k;
  f[4] !== z ? (k = z("repoPath"), f[4] = z, f[5] = k) : k = f[5];
  let I;
  f[6] !== k ? (I = /* @__PURE__ */ V.jsx("select", { id: "repo-select", "aria-label": k, hidden: !0 }), f[6] = k, f[7] = I) : I = f[7];
  let lt;
  f[8] !== z ? (lt = z("branchBase"), f[8] = z, f[9] = lt) : lt = f[9];
  let U;
  f[10] !== lt ? (U = /* @__PURE__ */ V.jsx("select", { id: "base-select", "aria-label": lt, hidden: !0 }), f[10] = lt, f[11] = U) : U = f[11];
  let y;
  f[12] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (y = /* @__PURE__ */ V.jsx("span", { id: "source-detail" }), f[12] = y) : y = f[12];
  let q;
  return f[13] !== L || f[14] !== I || f[15] !== U ? (q = /* @__PURE__ */ V.jsxs("div", { className: "toolbar-left flex min-w-0 items-center gap-1.5", children: [
    L,
    I,
    U,
    y
  ] }), f[13] = L, f[14] = I, f[15] = U, f[16] = q) : q = f[16], q;
}
function Gg(T) {
  const f = ka.c(50), {
    config: z,
    label: s
  } = T;
  let L;
  f[0] !== z || f[1] !== s ? (L = /* @__PURE__ */ V.jsx(qg, { config: z, label: s }), f[0] = z, f[1] = s, f[2] = L) : L = f[2];
  let k;
  f[3] !== s ? (k = s("jumpToFile"), f[3] = s, f[4] = k) : k = f[4];
  let I;
  f[5] !== k ? (I = /* @__PURE__ */ V.jsx("div", { className: "toolbar-middle flex min-w-0 flex-1 items-center justify-center gap-1.5", children: /* @__PURE__ */ V.jsx("select", { id: "jump-select", "aria-label": k, hidden: !0 }) }), f[5] = k, f[6] = I) : I = f[6];
  const lt = z.payload?.externalURL ?? "#";
  let U;
  f[7] !== s ? (U = s("openSourceURL"), f[7] = s, f[8] = U) : U = f[8];
  let y;
  f[9] !== s ? (y = s("openSourceURL"), f[9] = s, f[10] = y) : y = f[10];
  let q;
  f[11] !== lt || f[12] !== U || f[13] !== y ? (q = /* @__PURE__ */ V.jsx("a", { id: "external-link", className: "toolbar-icon", href: lt, target: "_blank", rel: "noreferrer", title: U, "aria-label": y, hidden: !0 }), f[11] = lt, f[12] = U, f[13] = y, f[14] = q) : q = f[14];
  let N;
  f[15] !== s ? (N = s("hideFiles"), f[15] = s, f[16] = N) : N = f[16];
  let et;
  f[17] !== s ? (et = s("hideFiles"), f[17] = s, f[18] = et) : et = f[18];
  let rt;
  f[19] !== N || f[20] !== et ? (rt = /* @__PURE__ */ V.jsx("button", { id: "files-toggle", className: "toolbar-icon", type: "button", title: N, "aria-label": et, "aria-pressed": "true" }), f[19] = N, f[20] = et, f[21] = rt) : rt = f[21];
  let ht;
  f[22] !== s ? (ht = s("switchToUnifiedDiff"), f[22] = s, f[23] = ht) : ht = f[23];
  let mt;
  f[24] !== s ? (mt = s("switchToUnifiedDiff"), f[24] = s, f[25] = mt) : mt = f[25];
  let Dt;
  f[26] !== ht || f[27] !== mt ? (Dt = /* @__PURE__ */ V.jsx("button", { id: "layout-toggle", className: "toolbar-icon", type: "button", title: ht, "aria-label": mt }), f[26] = ht, f[27] = mt, f[28] = Dt) : Dt = f[28];
  let P;
  f[29] !== s ? (P = s("options"), f[29] = s, f[30] = P) : P = f[30];
  let Ot;
  f[31] !== s ? (Ot = s("options"), f[31] = s, f[32] = Ot) : Ot = f[32];
  let dt;
  f[33] !== P || f[34] !== Ot ? (dt = /* @__PURE__ */ V.jsx("button", { id: "options-button", className: "toolbar-icon", type: "button", title: P, "aria-label": Ot, "aria-expanded": "false", "aria-haspopup": "menu" }), f[33] = P, f[34] = Ot, f[35] = dt) : dt = f[35];
  let Ct;
  f[36] !== rt || f[37] !== Dt || f[38] !== dt || f[39] !== q ? (Ct = /* @__PURE__ */ V.jsxs("div", { className: "toolbar-actions flex shrink-0 items-center gap-1.5", children: [
    q,
    rt,
    Dt,
    dt
  ] }), f[36] = rt, f[37] = Dt, f[38] = dt, f[39] = q, f[40] = Ct) : Ct = f[40];
  let wt;
  f[41] !== s ? (wt = s("options"), f[41] = s, f[42] = wt) : wt = f[42];
  let gt;
  f[43] !== wt ? (gt = /* @__PURE__ */ V.jsx("div", { id: "options-menu", role: "menu", "aria-label": wt, hidden: !0 }), f[43] = wt, f[44] = gt) : gt = f[44];
  let W;
  return f[45] !== L || f[46] !== Ct || f[47] !== gt || f[48] !== I ? (W = /* @__PURE__ */ V.jsxs("header", { id: "toolbar", children: [
    L,
    I,
    Ct,
    gt
  ] }), f[45] = L, f[46] = Ct, f[47] = gt, f[48] = I, f[49] = W) : W = f[49], W;
}
function Yg(T) {
  const f = ka.c(62), {
    label: z
  } = T;
  let s;
  f[0] !== z ? (s = z("changedFiles"), f[0] = z, f[1] = s) : s = f[1];
  let L;
  f[2] !== z ? (L = z("files"), f[2] = z, f[3] = L) : L = f[3];
  let k;
  f[4] !== L ? (k = /* @__PURE__ */ V.jsx("span", { children: L }), f[4] = L, f[5] = k) : k = f[5];
  let I;
  f[6] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (I = /* @__PURE__ */ V.jsx("span", { id: "files-count" }), f[6] = I) : I = f[6];
  let lt;
  f[7] !== k ? (lt = /* @__PURE__ */ V.jsxs("span", { id: "files-title", children: [
    k,
    I
  ] }), f[7] = k, f[8] = lt) : lt = f[8];
  let U;
  f[9] !== z ? (U = z("showFileSearch"), f[9] = z, f[10] = U) : U = f[10];
  let y;
  f[11] !== z ? (y = z("showFileSearch"), f[11] = z, f[12] = y) : y = f[12];
  let q;
  f[13] !== U || f[14] !== y ? (q = /* @__PURE__ */ V.jsx("button", { id: "file-search-toggle", type: "button", title: U, "aria-label": y, "aria-pressed": "false" }), f[13] = U, f[14] = y, f[15] = q) : q = f[15];
  let N;
  f[16] !== z ? (N = z("hideFiles"), f[16] = z, f[17] = N) : N = f[17];
  let et;
  f[18] !== z ? (et = z("hideFiles"), f[18] = z, f[19] = et) : et = f[19];
  let rt;
  f[20] !== et || f[21] !== N ? (rt = /* @__PURE__ */ V.jsx("button", { id: "file-collapse-toggle", type: "button", title: N, "aria-label": et }), f[20] = et, f[21] = N, f[22] = rt) : rt = f[22];
  let ht;
  f[23] !== rt || f[24] !== q ? (ht = /* @__PURE__ */ V.jsxs("span", { id: "files-header-actions", children: [
    q,
    rt
  ] }), f[23] = rt, f[24] = q, f[25] = ht) : ht = f[25];
  let mt;
  f[26] !== ht || f[27] !== lt ? (mt = /* @__PURE__ */ V.jsxs("div", { id: "files-header", children: [
    lt,
    ht
  ] }), f[26] = ht, f[27] = lt, f[28] = mt) : mt = f[28];
  let Dt;
  f[29] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Dt = /* @__PURE__ */ V.jsx("div", { id: "file-list", children: /* @__PURE__ */ V.jsx(Rg, {}) }), f[29] = Dt) : Dt = f[29];
  let P;
  f[30] !== z ? (P = z("diffStats"), f[30] = z, f[31] = P) : P = f[31];
  let Ot;
  f[32] !== z ? (Ot = z("files"), f[32] = z, f[33] = Ot) : Ot = f[33];
  let dt;
  f[34] !== Ot ? (dt = /* @__PURE__ */ V.jsx("span", { children: Ot }), f[34] = Ot, f[35] = dt) : dt = f[35];
  let Ct;
  f[36] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Ct = /* @__PURE__ */ V.jsx("strong", { id: "stats-files", children: "0" }), f[36] = Ct) : Ct = f[36];
  let wt;
  f[37] !== dt ? (wt = /* @__PURE__ */ V.jsxs("div", { className: "stats-row", children: [
    dt,
    Ct
  ] }), f[37] = dt, f[38] = wt) : wt = f[38];
  let gt;
  f[39] !== z ? (gt = z("additions"), f[39] = z, f[40] = gt) : gt = f[40];
  let W;
  f[41] !== gt ? (W = /* @__PURE__ */ V.jsx("span", { children: gt }), f[41] = gt, f[42] = W) : W = f[42];
  let Rt;
  f[43] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Rt = /* @__PURE__ */ V.jsx("strong", { id: "stats-added", className: "stat-add", children: "+0" }), f[43] = Rt) : Rt = f[43];
  let Pt;
  f[44] !== W ? (Pt = /* @__PURE__ */ V.jsxs("div", { className: "stats-row", children: [
    W,
    Rt
  ] }), f[44] = W, f[45] = Pt) : Pt = f[45];
  let Ft;
  f[46] !== z ? (Ft = z("deletions"), f[46] = z, f[47] = Ft) : Ft = f[47];
  let Vt;
  f[48] !== Ft ? (Vt = /* @__PURE__ */ V.jsx("span", { children: Ft }), f[48] = Ft, f[49] = Vt) : Vt = f[49];
  let Zt;
  f[50] === /* @__PURE__ */ Symbol.for("react.memo_cache_sentinel") ? (Zt = /* @__PURE__ */ V.jsx("strong", { id: "stats-deleted", className: "stat-del", children: "-0" }), f[50] = Zt) : Zt = f[50];
  let oe;
  f[51] !== Vt ? (oe = /* @__PURE__ */ V.jsxs("div", { className: "stats-row", children: [
    Vt,
    Zt
  ] }), f[51] = Vt, f[52] = oe) : oe = f[52];
  let ie;
  f[53] !== P || f[54] !== wt || f[55] !== Pt || f[56] !== oe ? (ie = /* @__PURE__ */ V.jsxs("div", { id: "files-footer", "aria-label": P, children: [
    wt,
    Pt,
    oe
  ] }), f[53] = P, f[54] = wt, f[55] = Pt, f[56] = oe, f[57] = ie) : ie = f[57];
  let X;
  return f[58] !== s || f[59] !== mt || f[60] !== ie ? (X = /* @__PURE__ */ V.jsxs("aside", { id: "files-sidebar", "aria-label": s, children: [
    mt,
    Dt,
    ie
  ] }), f[58] = s, f[59] = mt, f[60] = ie, f[61] = X) : X = f[61], X;
}
function Lg(T) {
  const f = ka.c(25), {
    config: z,
    initialStatus: s
  } = T, L = dm.useRef(!1), [k, I] = dm.useState(s), lt = z.payload?.labels;
  let U;
  f[0] !== lt ? (U = _o(lt, {
    assertMissing: Ao()
  }), f[0] = lt, f[1] = U) : U = f[1];
  const y = U;
  let q;
  f[2] !== z ? (q = (dt) => {
    !dt || L.current || (L.current = !0, Cg(z, {
      setStatus: I
    }));
  }, f[2] = z, f[3] = q) : q = f[3];
  const N = q;
  let et;
  f[4] !== z || f[5] !== y ? (et = /* @__PURE__ */ V.jsx(Gg, { config: z, label: y }), f[4] = z, f[5] = y, f[6] = et) : et = f[6];
  let rt;
  f[7] !== z || f[8] !== y ? (rt = /* @__PURE__ */ V.jsx(Yg, { config: z, label: y }), f[7] = z, f[8] = y, f[9] = rt) : rt = f[9];
  let ht;
  f[10] !== y ? (ht = y("diffViewer"), f[10] = y, f[11] = ht) : ht = f[11];
  let mt;
  f[12] !== ht ? (mt = /* @__PURE__ */ V.jsx("main", { id: "viewer", "aria-label": ht }), f[12] = ht, f[13] = mt) : mt = f[13];
  let Dt;
  f[14] !== y || f[15] !== k ? (Dt = /* @__PURE__ */ V.jsx(jg, { label: y, status: k }), f[14] = y, f[15] = k, f[16] = Dt) : Dt = f[16];
  let P;
  f[17] !== rt || f[18] !== mt || f[19] !== Dt ? (P = /* @__PURE__ */ V.jsxs("section", { id: "content", children: [
    rt,
    mt,
    Dt
  ] }), f[17] = rt, f[18] = mt, f[19] = Dt, f[20] = P) : P = f[20];
  let Ot;
  return f[21] !== N || f[22] !== et || f[23] !== P ? (Ot = /* @__PURE__ */ V.jsxs("div", { id: "app", ref: N, children: [
    et,
    P
  ] }), f[21] = N, f[22] = et, f[23] = P, f[24] = Ot) : Ot = f[24], Ot;
}
const Xg = `@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{--tw-space-y-reverse:0;--tw-border-style:solid}}}@layer theme{:root,:host{--font-sans:ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";--font-mono:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;--spacing:.25rem;--radius-md:.375rem;--default-font-family:var(--font-sans);--default-mono-font-family:var(--font-mono)}}@layer base{*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}::file-selector-button{box-sizing:border-box;border:0 solid;margin:0;padding:0}html,:host{-webkit-text-size-adjust:100%;tab-size:4;line-height:1.5;font-family:var(--default-font-family,ui-sans-serif, system-ui, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji");font-feature-settings:var(--default-font-feature-settings,normal);font-variation-settings:var(--default-font-variation-settings,normal);-webkit-tap-highlight-color:transparent}hr{height:0;color:inherit;border-top-width:1px}abbr:where([title]){-webkit-text-decoration:underline dotted;text-decoration:underline dotted}h1,h2,h3,h4,h5,h6{font-size:inherit;font-weight:inherit}a{color:inherit;-webkit-text-decoration:inherit;text-decoration:inherit}b,strong{font-weight:bolder}code,kbd,samp,pre{font-family:var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace);font-feature-settings:var(--default-mono-font-feature-settings,normal);font-variation-settings:var(--default-mono-font-variation-settings,normal);font-size:1em}small{font-size:80%}sub,sup{vertical-align:baseline;font-size:75%;line-height:0;position:relative}sub{bottom:-.25em}sup{top:-.5em}table{text-indent:0;border-color:inherit;border-collapse:collapse}:-moz-focusring{outline:auto}progress{vertical-align:baseline}summary{display:list-item}ol,ul,menu{list-style:none}img,svg,video,canvas,audio,iframe,embed,object{vertical-align:middle;display:block}img,video{max-width:100%;height:auto}button,input,select,optgroup,textarea{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}::file-selector-button{font:inherit;font-feature-settings:inherit;font-variation-settings:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}:where(select:is([multiple],[size])) optgroup{font-weight:bolder}:where(select:is([multiple],[size])) optgroup option{padding-inline-start:20px}::file-selector-button{margin-inline-end:4px}::placeholder{opacity:1}@supports (not ((-webkit-appearance:-apple-pay-button))) or (contain-intrinsic-size:1px){::placeholder{color:currentColor}@supports (color:color-mix(in lab,red,red)){::placeholder{color:color-mix(in oklab,currentcolor 50%,transparent)}}}textarea{resize:vertical}::-webkit-search-decoration{-webkit-appearance:none}::-webkit-date-and-time-value{min-height:1lh;text-align:inherit}::-webkit-datetime-edit{display:inline-flex}::-webkit-datetime-edit-fields-wrapper{padding:0}::-webkit-datetime-edit{padding-block:0}::-webkit-datetime-edit-year-field{padding-block:0}::-webkit-datetime-edit-month-field{padding-block:0}::-webkit-datetime-edit-day-field{padding-block:0}::-webkit-datetime-edit-hour-field{padding-block:0}::-webkit-datetime-edit-minute-field{padding-block:0}::-webkit-datetime-edit-second-field{padding-block:0}::-webkit-datetime-edit-millisecond-field{padding-block:0}::-webkit-datetime-edit-meridiem-field{padding-block:0}::-webkit-calendar-picker-indicator{line-height:1}:-moz-ui-invalid{box-shadow:none}button,input:where([type=button],[type=reset],[type=submit]){appearance:button}::file-selector-button{appearance:button}::-webkit-inner-spin-button{height:auto}::-webkit-outer-spin-button{height:auto}[hidden]:where(:not([hidden=until-found])){display:none!important}}@layer components;@layer utilities{.\\@container{container-type:inline-size}.collapse{visibility:collapse}.visible{visibility:visible}.fixed{position:fixed}.static{position:static}.mx-3\\.5{margin-inline:calc(var(--spacing) * 3.5)}.mt-3\\.5{margin-top:calc(var(--spacing) * 3.5)}.mb-3{margin-bottom:calc(var(--spacing) * 3)}.flex{display:flex}.grid{display:grid}.hidden{display:none}.size-4{width:calc(var(--spacing) * 4);height:calc(var(--spacing) * 4)}.h-3{height:calc(var(--spacing) * 3)}.h-6{height:calc(var(--spacing) * 6)}.h-9{height:calc(var(--spacing) * 9)}.h-\\[11px\\]{height:11px}.h-px{height:1px}.w-2\\/5{width:40%}.min-w-0{min-width:calc(var(--spacing) * 0)}.flex-1{flex:1}.shrink-0{flex-shrink:0}.grid-cols-\\[16px_minmax\\(0\\,1fr\\)_44px\\]{grid-template-columns:16px minmax(0,1fr) 44px}.grid-cols-\\[42px_minmax\\(0\\,1fr\\)\\]{grid-template-columns:42px minmax(0,1fr)}.grid-cols-\\[72px_minmax\\(0\\,1fr\\)_96px\\]{grid-template-columns:72px minmax(0,1fr) 96px}.items-center{align-items:center}.justify-center{justify-content:center}.gap-1\\.5{gap:calc(var(--spacing) * 1.5)}.gap-2{gap:calc(var(--spacing) * 2)}.gap-3{gap:calc(var(--spacing) * 3)}.gap-4{gap:calc(var(--spacing) * 4)}:where(.space-y-\\[13px\\]>:not(:last-child)){--tw-space-y-reverse:0;margin-block-start:calc(13px * var(--tw-space-y-reverse));margin-block-end:calc(13px * calc(1 - var(--tw-space-y-reverse)))}.justify-self-end{justify-self:flex-end}.rounded{border-radius:.25rem}.rounded-\\[5px\\]{border-radius:5px}.rounded-md{border-radius:var(--radius-md)}.border{border-style:var(--tw-border-style);border-width:1px}.border-t{border-top-style:var(--tw-border-style);border-top-width:1px}.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.border-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_18\\%\\,transparent\\)\\]{border-color:color-mix(in lab,var(--cmux-diff-fg) 18%,transparent)}}.border-\\[var\\(--cmux-diff-border\\)\\]{border-color:var(--cmux-diff-border)}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_5\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.bg-\\[color-mix\\(in_lab\\,var\\(--cmux-diff-fg\\)_10\\%\\,transparent\\)\\]{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.bg-\\[var\\(--cmux-diff-muted-bg\\)\\]{background-color:var(--cmux-diff-muted-bg)}.px-3{padding-inline:calc(var(--spacing) * 3)}.px-\\[7px\\]{padding-inline:7px}.py-1{padding-block:calc(var(--spacing) * 1)}.pt-3{padding-top:calc(var(--spacing) * 3)}.italic{font-style:italic}.opacity-70{opacity:.7}}:root{color-scheme:light dark;--cmux-diff-bg-light:#fff;--cmux-diff-bg-dark:#000;--cmux-diff-fg-light:#000;--cmux-diff-fg-dark:#fff;--cmux-diff-selection-bg-light:#abd8ff;--cmux-diff-selection-bg-dark:#3f638b;--cmux-diff-ui-font-family:system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;--cmux-diff-ui-font-size:12px;--cmux-diff-ui-line-height:16px;--cmux-diff-code-font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;--cmux-diff-font-size:10px;--cmux-diff-line-height:20px;--cmux-diff-bg:var(--cmux-diff-bg-light);--cmux-diff-fg:var(--cmux-diff-fg-light);--cmux-diff-border:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-border:color-mix(in lab, var(--cmux-diff-fg) 12%, transparent)}}:root{--cmux-diff-sidebar-bg:transparent;--cmux-diff-muted-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-muted-bg:color-mix(in lab, var(--cmux-diff-fg) 8%, transparent)}}:root{--cmux-diff-hover-bg:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){:root{--cmux-diff-hover-bg:color-mix(in lab, var(--cmux-diff-fg) 10%, transparent)}}:root{--cmux-diff-accent:light-dark(#0a84ff,#7ab7ff);color:var(--cmux-diff-fg);background:0 0}@media(prefers-color-scheme:dark){:root{--cmux-diff-bg:var(--cmux-diff-bg-dark);--cmux-diff-fg:var(--cmux-diff-fg-dark)}}*{box-sizing:border-box}html,body{background:0 0;height:100%;overflow:hidden}body{height:100vh;min-height:0;color:var(--cmux-diff-fg);font-family:var(--cmux-diff-ui-font-family);font-size:var(--cmux-diff-ui-font-size);line-height:var(--cmux-diff-ui-line-height);background:0 0;flex-direction:column;margin:0;display:flex;overflow:hidden}#root{background:0 0;height:100%;min-height:0}#app{overscroll-behavior:contain;contain:strict;height:100vh;min-height:0;color:inherit;background:0 0;grid-template-rows:auto minmax(0,1fr);grid-template-columns:minmax(0,1fr);display:grid;overflow:hidden}#toolbar{border-bottom:1px solid var(--cmux-diff-fg);flex:none;align-items:center;gap:7px;min-height:32px;padding:3px 8px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#toolbar{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}#toolbar{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#toolbar{color:color-mix(in lab,var(--cmux-diff-fg) 76%,var(--cmux-diff-bg))}}#toolbar{z-index:50}.toolbar-left,.toolbar-middle,.toolbar-actions{align-items:center;gap:6px;min-width:0;display:flex}.toolbar-left{flex:0 36%}.toolbar-middle{flex:auto;justify-content:center}.toolbar-actions{flex:none}#source-select,#repo-select,#base-select,#jump-select{appearance:none;background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,var(--cmux-diff-fg);border:1px solid #0000;border-radius:6px;min-width:118px;max-width:min(30vw,320px);height:24px;padding:0 24px 0 9px}@supports (color:color-mix(in lab,red,red)){#source-select,#repo-select,#base-select,#jump-select{background:linear-gradient(45deg,transparent 50%,currentColor 50%) right 11px center / 4px 4px no-repeat,linear-gradient(135deg,currentColor 50%,transparent 50%) right 7px center / 4px 4px no-repeat,color-mix(in lab,var(--cmux-diff-fg) 7%,transparent)}}#source-select,#repo-select,#base-select,#jump-select{color:inherit;font:inherit}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{border-color:color-mix(in lab,var(--cmux-diff-fg) 24%,transparent)}}#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:hover,#repo-select:hover,#base-select:hover,#jump-select:hover{background-color:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#source-select[hidden],#repo-select[hidden],#base-select[hidden],#jump-select[hidden]{display:none}#jump-select{min-width:min(250px,30vw)}#repo-select{min-width:132px;max-width:min(26vw,320px)}#base-select{min-width:120px;max-width:min(22vw,260px)}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline:2px solid color-mix(in lab,var(--cmux-diff-fg) 36%,transparent)}}#source-select:focus,#repo-select:focus,#base-select:focus,#jump-select:focus,.toolbar-icon:focus-visible,.menu-item:focus-visible,.file-entry:focus-visible{outline-offset:1px}#source-detail{text-overflow:ellipsis;white-space:nowrap;min-width:0;color:var(--cmux-diff-fg);overflow:hidden}@supports (color:color-mix(in lab,red,red)){#source-detail{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}.toolbar-icon{width:28px;height:26px;color:var(--cmux-diff-fg);background:0 0;border:1px solid #0000;border-radius:6px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.toolbar-icon{color:color-mix(in lab,var(--cmux-diff-fg) 60%,var(--cmux-diff-bg))}}.toolbar-icon{cursor:pointer;padding:0}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{border-color:color-mix(in lab,var(--cmux-diff-fg) 14%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon:hover,.toolbar-icon[aria-expanded=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.toolbar-icon:hover,.toolbar-icon[aria-expanded=true],.toolbar-icon[aria-pressed=true]{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.toolbar-icon[aria-pressed=true]{color:color-mix(in lab,var(--cmux-diff-fg) 78%,var(--cmux-diff-bg))}}.toolbar-icon[hidden]{display:none}.toolbar-icon svg,.menu-item svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:16px;height:16px;display:block}#layout-toggle svg [data-accent]{stroke:light-dark(#0a84ff,#7ab7ff)}#options-menu{border:1px solid var(--cmux-diff-fg);min-width:246px;padding:8px;position:absolute;top:calc(100% + 7px);right:10px}@supports (color:color-mix(in lab,red,red)){#options-menu{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 13%,transparent)}}#options-menu{background:var(--cmux-diff-bg);z-index:100;border-radius:8px;box-shadow:0 16px 34px lab(0% none none/.28)}#options-menu[hidden]{display:none}.menu-separator{background:var(--cmux-diff-fg);height:1px;margin:7px 6px}@supports (color:color-mix(in lab,red,red)){.menu-separator{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.menu-item{width:100%;min-height:31px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:6px;grid-template-columns:22px minmax(0,1fr) 18px;align-items:center;gap:10px;display:grid}@supports (color:color-mix(in lab,red,red)){.menu-item{color:color-mix(in lab,var(--cmux-diff-fg) 86%,var(--cmux-diff-bg))}}.menu-item{font:inherit;text-align:left;padding:0 7px}.menu-item:hover:not(:disabled){background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:hover:not(:disabled){background:color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}.menu-item:hover:not(:disabled){color:var(--cmux-diff-fg)}.menu-segment{cursor:default}.menu-segment:hover{background:0 0}.menu-segment-controls{background:0 0;border-radius:7px;justify-self:end;align-items:center;gap:2px;padding:2px;display:inline-flex}.segment-button{width:27px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.segment-button{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.segment-button{padding:0}.segment-button:hover,.segment-button[aria-pressed=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.segment-button:hover,.segment-button[aria-pressed=true]{background:color-mix(in lab,var(--cmux-diff-fg) 12%,transparent)}}.segment-button:hover,.segment-button[aria-pressed=true],.menu-item:disabled{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.menu-item:disabled{color:color-mix(in lab,var(--cmux-diff-fg) 36%,var(--cmux-diff-bg))}}.menu-label{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.menu-check{justify-self:end}#content{--cmux-diff-files-width:clamp(190px, 22vw, 252px);grid-template-columns:minmax(0,1fr) var(--cmux-diff-files-width);overscroll-behavior:contain;contain:strict;background:0 0;flex:auto;grid-template-rows:minmax(0,1fr);grid-template-areas:"viewer files";min-width:0;min-height:0;display:grid;position:relative;overflow:hidden}body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr) 0}body[data-status-only=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{border-left:1px solid var(--cmux-diff-border);contain:strict;opacity:1;background:0 0;flex-direction:column;grid-area:files;width:100%;min-width:0;height:100%;min-height:0;transition:opacity .1s,visibility linear;display:flex;position:relative;overflow:hidden}body[data-files-hidden=true] #files-sidebar{opacity:0;pointer-events:none;visibility:hidden;transition:opacity .1s,visibility 0s linear .1s}body[data-status-only=true] #files-sidebar{display:none}#files-header{z-index:1;border-bottom:1px solid var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:8px;min-height:30px;padding:0 7px 0 10px;display:flex;position:relative}@supports (color:color-mix(in lab,red,red)){#files-header{border-bottom:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-header{color:var(--cmux-diff-fg);background:0 0}@supports (color:color-mix(in lab,red,red)){#files-header{color:color-mix(in lab,var(--cmux-diff-fg) 52%,var(--cmux-diff-bg))}}#files-title{align-items:center;gap:6px;min-width:0;display:inline-flex}#files-header-actions{flex:none;align-items:center;gap:2px;display:inline-flex}#file-search-toggle,#file-collapse-toggle{width:24px;height:24px;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:5px;flex:none;justify-content:center;align-items:center;display:inline-flex}@supports (color:color-mix(in lab,red,red)){#file-search-toggle,#file-collapse-toggle{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}#file-search-toggle,#file-collapse-toggle{padding:0}#file-search-toggle:hover,#file-search-toggle[aria-pressed=true],#file-collapse-toggle:hover{background:var(--cmux-diff-hover-bg);color:var(--cmux-diff-fg)}#file-search-toggle svg,#file-collapse-toggle svg{fill:none;stroke:currentColor;stroke-width:1.75px;stroke-linecap:round;stroke-linejoin:round;width:15px;height:15px}#file-list{--trees-bg-override:var(--cmux-diff-sidebar-bg);--trees-fg-override:var(--cmux-diff-fg);flex:auto;min-height:0;padding:6px 4px 6px 6px;overflow:hidden}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-override:color-mix(in lab, var(--cmux-diff-fg) 72%, var(--cmux-diff-bg))}}#file-list{--trees-fg-muted-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-fg-muted-override:color-mix(in lab, var(--cmux-diff-fg) 48%, var(--cmux-diff-bg))}}#file-list{--trees-bg-muted-override:var(--cmux-diff-hover-bg);--trees-selected-bg-override:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-selected-bg-override:color-mix(in lab, var(--cmux-diff-fg) 11%, transparent)}}#file-list{--trees-selected-fg-override:var(--cmux-diff-fg);--trees-selected-focused-border-color-override:transparent;--trees-border-color-override:var(--cmux-diff-border);--trees-focus-ring-color-override:var(--cmux-diff-accent)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-focus-ring-color-override:color-mix(in lab, var(--cmux-diff-accent) 72%, transparent)}}#file-list{--trees-font-family-override:var(--cmux-diff-ui-font-family);--trees-font-size-override:var(--cmux-diff-ui-font-size);--trees-font-weight-semibold-override:500;--trees-density-override:.78;--trees-border-radius-override:5px;--trees-item-padding-x-override:7px;--trees-item-margin-x-override:0;--trees-padding-inline-override:0;--trees-search-bg-override:var(--cmux-diff-bg)}@supports (color:color-mix(in lab,red,red)){#file-list{--trees-search-bg-override:color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))}}#file-list{--trees-status-added-override:light-dark(#257a3e,#8fd88f);--trees-status-modified-override:var(--cmux-diff-accent);--trees-status-renamed-override:light-dark(#a26300,#ffd166);--trees-status-deleted-override:light-dark(#b42318,#ff8a80)}body[data-loading=false] .diff-loading-placeholder,body[data-loading=false]:not([data-status-only=true]) #loading-layer{display:none}#file-list file-tree-container{width:100%;height:100%}#files-footer{border-top:1px solid var(--cmux-diff-fg);flex:none;padding:7px 10px 8px}@supports (color:color-mix(in lab,red,red)){#files-footer{border-top:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#files-footer{background:0 0}.stats-row{min-height:19px;color:var(--cmux-diff-fg);justify-content:space-between;align-items:center;gap:10px;display:flex}@supports (color:color-mix(in lab,red,red)){.stats-row{color:color-mix(in lab,var(--cmux-diff-fg) 54%,var(--cmux-diff-bg))}}.stats-row strong{color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.stats-row strong{color:color-mix(in lab,var(--cmux-diff-fg) 82%,var(--cmux-diff-bg))}}.stats-row strong{font-weight:600}.file-entry{width:100%;min-height:30px;color:inherit;font:inherit;text-align:left;background:0 0;border:0;border-radius:6px;grid-template-columns:18px minmax(0,1fr) auto;align-items:center;gap:8px;padding:3px 7px;display:grid}.file-entry:hover,.file-entry[aria-current=true]{background:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){.file-entry:hover,.file-entry[aria-current=true]{background:color-mix(in lab,var(--cmux-diff-fg) 9%,transparent)}}.file-status{width:17px;height:17px;color:var(--cmux-diff-fg);border:1px solid;border-radius:5px;justify-content:center;align-items:center;font-size:9px;line-height:1;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-status{color:color-mix(in lab,var(--cmux-diff-fg) 62%,var(--cmux-diff-bg))}}.file-name{text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.file-stats{color:var(--cmux-diff-fg);gap:5px;display:inline-flex}@supports (color:color-mix(in lab,red,red)){.file-stats{color:color-mix(in lab,var(--cmux-diff-fg) 50%,var(--cmux-diff-bg))}}.stat-add{color:light-dark(#257a3e,#8fd88f)}.stat-del{color:light-dark(#b42318,#ff8a80)}#viewer{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));overscroll-behavior:contain;overflow-anchor:none;contain:strict;border-bottom:1px solid var(--cmux-diff-border);background:0 0;grid-area:viewer;width:100%;min-width:0;height:100%;min-height:0;position:relative;overflow:clip auto}@media(max-width:520px){#content,body[data-files-hidden=true] #content{grid-template-columns:minmax(0,1fr);grid-template-areas:"viewer"}#files-sidebar{display:none}}@media(prefers-reduced-motion:reduce){#files-sidebar{transition:none}}#viewer diffs-container{--diffs-font-family:var(--cmux-diff-code-font-family);--diffs-header-font-family:var(--cmux-diff-ui-font-family);--diffs-font-size:var(--cmux-diff-font-size);--diffs-line-height:var(--cmux-diff-line-height);--diffs-bg-selection-override:light-dark(var(--cmux-diff-selection-bg-light),var(--cmux-diff-selection-bg-dark));contain:layout paint style;box-shadow:0 -1px 0 var(--cmux-diff-border),0 1px 0 var(--cmux-diff-border);display:block;overflow:clip}#loading-layer{z-index:4;pointer-events:none;contain:strict;background:0 0;grid-area:viewer;position:absolute;inset:0;overflow:hidden}body[data-status-only=true] #loading-layer{pointer-events:auto;justify-content:center;align-items:center;width:100%;height:100%;padding:32px;display:flex;position:static}#status{z-index:5;border:1px solid var(--cmux-diff-fg);align-items:center;gap:10px;max-width:calc(100% - 24px);min-height:32px;padding:8px 12px;display:flex;position:absolute;top:10px;left:12px}@supports (color:color-mix(in lab,red,red)){#status{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 10%,transparent)}}#status{background:var(--cmux-diff-bg);font-family:var(--cmux-diff-ui-font-family);font-size:13px;line-height:var(--cmux-diff-ui-line-height);color:var(--cmux-diff-fg);border-radius:7px}@supports (color:color-mix(in lab,red,red)){#status{color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}body[data-status-only=true] #status{text-align:center;text-wrap:balance;width:auto;max-width:340px;min-height:0;color:var(--cmux-diff-fg);background:0 0;border:0;border-radius:0;flex-direction:column;justify-content:center;align-items:center;gap:14px;padding:0;font-size:14px;line-height:1.55;position:static}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status{color:color-mix(in lab,var(--cmux-diff-fg) 58%,var(--cmux-diff-bg))}}body[data-status-only=true] #status-text{letter-spacing:.005em;font-weight:500}#status-icon{display:none}body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{background:var(--cmux-diff-fg);border-radius:16px;justify-content:center;align-items:center;width:56px;height:56px;display:flex}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{background:color-mix(in lab,var(--cmux-diff-fg) 5%,transparent)}}body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{border:1px solid var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon{border:1px solid color-mix(in lab,var(--cmux-diff-fg) 8%,transparent)}}body[data-status-only=true] #status:not([data-error=true]):not([data-pending=true]) #status-icon:before{content:"";opacity:.8;background-color:currentColor;width:26px;height:26px;display:block;-webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23000' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z'/%3E%3Cpath d='M14 2v6h6'/%3E%3Cpath d='M9 13h6'/%3E%3Cpath d='M9 17h4'/%3E%3C/svg%3E") 50%/contain no-repeat;mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23000' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z'/%3E%3Cpath d='M14 2v6h6'/%3E%3Cpath d='M9 13h6'/%3E%3Cpath d='M9 17h4'/%3E%3C/svg%3E") 50%/contain no-repeat}#status[data-pending=true]:before,body[data-loading=true] #status:before{content:"";border:2px solid var(--cmux-diff-fg);flex:none;width:14px;height:14px}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border:2px solid color-mix(in lab,var(--cmux-diff-fg) 20%,transparent)}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:var(--cmux-diff-fg)}@supports (color:color-mix(in lab,red,red)){#status[data-pending=true]:before,body[data-loading=true] #status:before{border-top-color:color-mix(in lab,var(--cmux-diff-fg) 70%,var(--cmux-diff-bg))}}#status[data-pending=true]:before,body[data-loading=true] #status:before{border-radius:50%;animation:.8s linear infinite cmuxDiffPendingSpin}#status[data-error=true]{color:light-dark(#b42318,#ff8a80)}@keyframes cmuxDiffPendingSpin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){#status[data-pending=true]:before,body[data-loading=true] #status:before{animation:none}}@property --tw-space-y-reverse{syntax:"*";inherits:false;initial-value:0}@property --tw-border-style{syntax:"*";inherits:false;initial-value:solid}`;
function Qg() {
  const T = document.getElementById("cmux-diff-viewer-config");
  if (!T?.textContent)
    throw new Error("Missing cmux diff viewer config");
  return JSON.parse(T.textContent);
}
function Vg() {
  const T = document.createElement("style");
  T.dataset.cmuxDiffViewerStyle = "true", T.textContent = Xg, document.head.append(T);
}
const Ja = Qg();
Vg();
hm(mm(Ja.payload?.appearance));
typeof Ja.payload?.title == "string" && Ja.payload.title.trim() !== "" && (document.title = Ja.payload.title);
const Zg = _o(Ja.payload?.labels, {
  assertMissing: Ao()
}), ym = Og(Ja, Zg);
document.body.dataset.filesHidden = "false";
pm(ym);
const vm = document.getElementById("root");
if (!vm)
  throw new Error("Missing cmux diff viewer root");
bg.createRoot(vm).render(/* @__PURE__ */ V.jsx(Lg, { config: Ja, initialStatus: ym }));
