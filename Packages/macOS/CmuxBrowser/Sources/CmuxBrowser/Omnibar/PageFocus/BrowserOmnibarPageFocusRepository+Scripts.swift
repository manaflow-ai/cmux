import Foundation

extension BrowserOmnibarPageFocusRepository {
    /// JavaScript that records the page's currently focused editable element.
    ///
    /// Stores `{ id, selectionStart, selectionEnd }` into
    /// `window.__cmuxAddressBarFocusState` (mirrored to the top frame) and tags
    /// the element with a stable `data-cmux-addressbar-focus-id`. Returns a
    /// `captured:<id>` / `cleared:*` / `error` status string.
    static let captureScript = """
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

    /// JavaScript injected at document start that continuously tracks the last
    /// editable focused element via `focusin`/`selectionchange`/`input` listeners.
    ///
    /// The app target injects this as a main-frame-only `WKUserScript`. Keeping a
    /// live snapshot lets ``captureScript`` succeed even when capture runs after
    /// first-responder handoff has already cleared `document.activeElement`.
    public static let trackingBootstrapScriptSource = """
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

    /// JavaScript that re-focuses the previously captured editable element and
    /// restores its text selection, searching nested frames for the tagged id.
    ///
    /// Returns one of the ``AddressBarPageFocusRestoreStatus`` raw strings:
    /// `restored`, `no_state`, `missing_target`, `not_focused`, or `error`.
    static let restoreScript = """
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
