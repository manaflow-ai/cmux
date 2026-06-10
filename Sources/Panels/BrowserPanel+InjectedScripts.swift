import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Injected bootstrap scripts
extension BrowserPanel {
    static let telemetryHookBootstrapScriptSource = """
    (() => {
      if (window.__cmuxHooksInstalled) return true;
      window.__cmuxHooksInstalled = true;

      window.__cmuxConsoleLog = window.__cmuxConsoleLog || [];
      const __pushConsole = (level, args) => {
        try {
          const text = Array.from(args || []).map((x) => {
            if (typeof x === 'string') return x;
            try { return JSON.stringify(x); } catch (_) { return String(x); }
          }).join(' ');
          window.__cmuxConsoleLog.push({ level, text, timestamp_ms: Date.now() });
          if (window.__cmuxConsoleLog.length > 512) {
            window.__cmuxConsoleLog.splice(0, window.__cmuxConsoleLog.length - 512);
          }
        } catch (_) {}
      };

      const methods = ['log', 'info', 'warn', 'error', 'debug'];
      for (const m of methods) {
        const orig = (window.console && window.console[m]) ? window.console[m].bind(window.console) : null;
        window.console[m] = function(...args) {
          __pushConsole(m, args);
          if (orig) return orig(...args);
        };
      }

      window.__cmuxErrorLog = window.__cmuxErrorLog || [];
      window.addEventListener('error', (ev) => {
        try {
          const message = String((ev && ev.message) || '');
          const source = String((ev && ev.filename) || '');
          const line = Number((ev && ev.lineno) || 0);
          const col = Number((ev && ev.colno) || 0);
          window.__cmuxErrorLog.push({ message, source, line, column: col, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });
      window.addEventListener('unhandledrejection', (ev) => {
        try {
          const reason = ev && ev.reason;
          const message = typeof reason === 'string' ? reason : (reason && reason.message ? String(reason.message) : String(reason));
          window.__cmuxErrorLog.push({ message, source: 'unhandledrejection', line: 0, column: 0, timestamp_ms: Date.now() });
          if (window.__cmuxErrorLog.length > 512) {
            window.__cmuxErrorLog.splice(0, window.__cmuxErrorLog.length - 512);
          }
        } catch (_) {}
      });

      return true;
    })()
    """

    static let dialogTelemetryHookBootstrapScriptSource = """
    (() => {
      if (window.__cmuxDialogHooksInstalled) return true;
      window.__cmuxDialogHooksInstalled = true;

      window.__cmuxDialogQueue = window.__cmuxDialogQueue || [];
      window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
      const __pushDialog = (type, message, defaultText) => {
        window.__cmuxDialogQueue.push({
          type,
          message: String(message || ''),
          default_text: defaultText == null ? null : String(defaultText),
          timestamp_ms: Date.now()
        });
        if (window.__cmuxDialogQueue.length > 128) {
          window.__cmuxDialogQueue.splice(0, window.__cmuxDialogQueue.length - 128);
        }
      };

      window.alert = function(message) {
        __pushDialog('alert', message, null);
      };
      window.confirm = function(message) {
        __pushDialog('confirm', message, null);
        return !!window.__cmuxDialogDefaults.confirm;
      };
      window.prompt = function(message, defaultValue) {
        __pushDialog('prompt', message, defaultValue == null ? null : defaultValue);
        const v = window.__cmuxDialogDefaults.prompt;
        if (v === null || v === undefined) {
          return defaultValue == null ? '' : String(defaultValue);
        }
        return String(v);
      };

      return true;
    })()
    """

    static let addressBarFocusCaptureScript = """
    (() => {
      try {
        const syncState = (state) => {
          window.__cmuxAddressBarFocusState = state;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: state }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = state;
            }
          } catch (_) {}
        };

        const active = document.activeElement;
        if (!active) {
          syncState(null);
          return "cleared:none";
        }

        const tag = (active.tagName || "").toLowerCase();
        const type = (active.type || "").toLowerCase();
        const isEditable =
          !!active.isContentEditable ||
          tag === "textarea" ||
          (tag === "input" && type !== "hidden");
        if (!isEditable) {
          syncState(null);
          return "cleared:noneditable";
        }

        let id = active.getAttribute("data-cmux-addressbar-focus-id");
        if (!id) {
          id = "cmux-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
          active.setAttribute("data-cmux-addressbar-focus-id", id);
        }

        const state = { id, selectionStart: null, selectionEnd: null };
        if (typeof active.selectionStart === "number" && typeof active.selectionEnd === "number") {
          state.selectionStart = active.selectionStart;
          state.selectionEnd = active.selectionEnd;
        }
        syncState(state);
        return "captured:" + id;
      } catch (_) {
        return "error";
      }
    })();
    """
    static let addressBarFocusTrackingBootstrapScript = """
    (() => {
      try {
        if (window.__cmuxAddressBarFocusTrackerInstalled) return true;
        window.__cmuxAddressBarFocusTrackerInstalled = true;

        const syncState = (state) => {
          window.__cmuxAddressBarFocusState = state;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: state }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = state;
            }
          } catch (_) {}
        };

        if (window.top === window && !window.__cmuxAddressBarFocusMessageBridgeInstalled) {
          window.__cmuxAddressBarFocusMessageBridgeInstalled = true;
          window.addEventListener("message", (ev) => {
            try {
              const data = ev ? ev.data : null;
              if (!data || !Object.prototype.hasOwnProperty.call(data, "cmuxAddressBarFocusState")) return;
              window.__cmuxAddressBarFocusState = data.cmuxAddressBarFocusState || null;
            } catch (_) {}
          }, true);
        }

        const isEditable = (el) => {
          if (!el) return false;
          const tag = (el.tagName || "").toLowerCase();
          const type = (el.type || "").toLowerCase();
          return !!el.isContentEditable || tag === "textarea" || (tag === "input" && type !== "hidden");
        };

        const ensureFocusId = (el) => {
          let id = el.getAttribute("data-cmux-addressbar-focus-id");
          if (!id) {
            id = "cmux-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
            el.setAttribute("data-cmux-addressbar-focus-id", id);
          }
          return id;
        };

        const snapshot = (el) => {
          if (!isEditable(el)) {
            syncState(null);
            return;
          }
          const state = {
            id: ensureFocusId(el),
            selectionStart: null,
            selectionEnd: null
          };
          if (typeof el.selectionStart === "number" && typeof el.selectionEnd === "number") {
            state.selectionStart = el.selectionStart;
            state.selectionEnd = el.selectionEnd;
          }
          syncState(state);
        };

        document.addEventListener("focusin", (ev) => {
          snapshot(ev && ev.target ? ev.target : document.activeElement);
        }, true);
        document.addEventListener("selectionchange", () => {
          snapshot(document.activeElement);
        }, true);
        document.addEventListener("input", () => {
          snapshot(document.activeElement);
        }, true);
        document.addEventListener("mousedown", (ev) => {
          const target = ev && ev.target ? ev.target : null;
          if (!isEditable(target)) {
            syncState(null);
          }
        }, true);
        window.addEventListener("beforeunload", () => {
          syncState(null);
        }, true);

        snapshot(document.activeElement);
        return true;
      } catch (_) {
        return false;
      }
    })();
    """
    static let addressBarFocusRestoreScript = """
    (() => {
      try {
        const readState = () => {
          let state = window.__cmuxAddressBarFocusState;
          try {
            if ((!state || typeof state.id !== "string" || !state.id) &&
                window.top && window.top.__cmuxAddressBarFocusState) {
              state = window.top.__cmuxAddressBarFocusState;
            }
          } catch (_) {}
          return state;
        };

        const clearState = () => {
          window.__cmuxAddressBarFocusState = null;
          try {
            if (window.top && window.top !== window) {
              window.top.postMessage({ cmuxAddressBarFocusState: null }, "*");
            } else if (window.top) {
              window.top.__cmuxAddressBarFocusState = null;
            }
          } catch (_) {}
        };

        const state = readState();
        if (!state || typeof state.id !== "string" || !state.id) {
          return "no_state";
        }

        const selector = '[data-cmux-addressbar-focus-id="' + state.id + '"]';
        const findTarget = (doc) => {
          if (!doc) return null;
          const direct = doc.querySelector(selector);
          if (direct && direct.isConnected) return direct;
          const frames = doc.querySelectorAll("iframe,frame");
          for (let i = 0; i < frames.length; i += 1) {
            const frame = frames[i];
            try {
              const childDoc = frame.contentDocument;
              if (!childDoc) continue;
              const nested = findTarget(childDoc);
              if (nested) return nested;
            } catch (_) {}
          }
          return null;
        };

        const target = findTarget(document);
        if (!target) {
          clearState();
          return "missing_target";
        }

        try {
          target.focus({ preventScroll: true });
        } catch (_) {
          try { target.focus(); } catch (_) {}
        }

        let focused = false;
        try {
          focused =
            target === target.ownerDocument.activeElement ||
            (typeof target.matches === "function" && target.matches(":focus"));
        } catch (_) {}
        if (!focused) {
          return "not_focused";
        }

        if (
          typeof state.selectionStart === "number" &&
          typeof state.selectionEnd === "number" &&
          typeof target.setSelectionRange === "function"
        ) {
          try {
            target.setSelectionRange(state.selectionStart, state.selectionEnd);
          } catch (_) {}
        }
        clearState();
        return "restored";
      } catch (_) {
        return "error";
      }
    })();
    """

}
