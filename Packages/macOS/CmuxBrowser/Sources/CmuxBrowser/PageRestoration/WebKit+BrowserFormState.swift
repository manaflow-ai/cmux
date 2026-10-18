public import WebKit

// The scripts that keep a discarded pane's unsaved form input.
//
// Both run in an isolated content world: they share the DOM with the page
// but not its JavaScript globals, so page script can neither read the
// reported values nor post fake reports. The observer is passive (capture
// phase listeners, no prototype or global changes) and main frame only.

extension WKContentWorld {
    /// Isolated world shared by the form-state observer, its message handler
    /// and the restore call.
    @MainActor
    public static var browserFormState: WKContentWorld {
        .world(name: browserFormStateName)
    }

    /// Name shared by the content world and the script message handler.
    fileprivate static let browserFormStateName = "cmuxFormState"
}

extension WKUserScript {
    /// Document-start observer. After input settles, and when the page is
    /// hidden, it reports every control whose value differs from its default,
    /// keyed by a locator the restore script can resolve again, and whether
    /// the page holds typed input the restore cannot replay: a changed
    /// password, payment or file field, a value past the size limits, or an
    /// edit to rich text or a shadow-root control. Rich-text edits stay
    /// counted until the document goes away.
    @MainActor
    public static func browserFormStateObserver() -> WKUserScript {
        WKUserScript(
            source: browserFormStateObserverSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .browserFormState
        )
    }

    private static let browserFormStateObserverSource = #"""
    (() => {
      try {
        // Keep these transport caps in sync with BrowserFormStateSnapshot constants.
        const MAX_FIELDS = 200;
        const MAX_VALUE = 65536;
        const EXCLUDED_TYPES = new Set(["password", "hidden", "file", "button", "submit", "reset", "image"]);
        const NON_INPUT_TYPES = new Set(["hidden", "button", "submit", "reset", "image"]);
        const isSensitiveAutocomplete = (raw) => String(raw || "").toLowerCase().split(/\s+/).some((token) =>
          token === "off" || token === "one-time-code" || token.startsWith("cc-") || token.endsWith("-password"));
        const isEligible = (el) => {
          if (el.disabled) return false;
          if (el instanceof HTMLInputElement && EXCLUDED_TYPES.has(el.type)) return false;
          if (isSensitiveAutocomplete(el.getAttribute("autocomplete"))) return false;
          if (el.form && isSensitiveAutocomplete(el.form.getAttribute("autocomplete"))) return false;
          return true;
        };
        const keyFor = (el) => {
          if (el.id) return "id:" + el.id;
          if (el.name) {
            const form = el.form;
            const formIndex = form ? Array.prototype.indexOf.call(document.forms, form) : -1;
            const scope = form ? form.elements : document.getElementsByName(el.name);
            let index = 0;
            for (const other of scope) {
              if (other === el) break;
              if (other.name === el.name) index += 1;
            }
            return "name:" + formIndex + ":" + el.name + ":" + index;
          }
          const parts = [];
          let node = el;
          while (node && node !== document.documentElement && node.parentElement) {
            parts.push(node.tagName.toLowerCase() + ":" + Array.prototype.indexOf.call(node.parentElement.children, node));
            node = node.parentElement;
          }
          return "path:" + parts.reverse().join("/");
        };
        const selectState = (el) => {
          const options = Array.from(el.options);
          const selected = [];
          let defaults = [];
          options.forEach((option, index) => {
            if (option.selected) selected.push(index);
            if (option.defaultSelected) defaults.push(index);
          });
          if (!el.multiple) {
            if (defaults.length > 1) defaults = [defaults[defaults.length - 1]];
            if (defaults.length === 0 && el.size <= 1) {
              const first = options.findIndex((option) => !option.disabled);
              if (first >= 0) defaults = [first];
            }
          }
          return selected.join(",") === defaults.join(",") ? null : { s: selected };
        };
        const fieldState = (el) => {
          if (el instanceof HTMLSelectElement) return selectState(el);
          if (el instanceof HTMLInputElement && (el.type === "checkbox" || el.type === "radio")) {
            return el.checked === el.defaultChecked ? null : { c: el.checked };
          }
          if (el.value === el.defaultValue || el.value.length > MAX_VALUE) return null;
          return { v: el.value };
        };
        const isChanged = (el) => {
          if (el.disabled) return false;
          if (el instanceof HTMLSelectElement) return selectState(el) !== null;
          if (el instanceof HTMLInputElement) {
            if (NON_INPUT_TYPES.has(el.type)) return false;
            if (el.type === "file") return !!el.files && el.files.length > 0;
            if (el.type === "checkbox" || el.type === "radio") return el.checked !== el.defaultChecked;
          }
          return el.value !== el.defaultValue;
        };
        let editedUntrackedContent = false;
        const collect = () => {
          const fields = [];
          const seen = new Set();
          let unrestorable = editedUntrackedContent;
          for (const el of document.querySelectorAll("input, textarea, select")) {
            if (!isChanged(el)) continue;
            if (!isEligible(el) || fields.length >= MAX_FIELDS) {
              unrestorable = true;
              continue;
            }
            const state = fieldState(el);
            const key = state ? keyFor(el) : null;
            if (!state || seen.has(key)) {
              unrestorable = true;
              continue;
            }
            seen.add(key);
            state.k = key;
            fields.push(state);
          }
          return { fields, unrestorable };
        };
        let lastReported = JSON.stringify({ fields: [], unrestorable: false });
        let timer = null;
        let unloading = false;
        const flush = () => {
          if (timer !== null) {
            clearTimeout(timer);
            timer = null;
          }
          if (unloading) return;
          let state = { fields: [], unrestorable: editedUntrackedContent };
          try { state = collect(); } catch (_) {}
          const serialized = JSON.stringify(state);
          if (serialized === lastReported) return;
          lastReported = serialized;
          try {
            window.webkit.messageHandlers["\#(WKContentWorld.browserFormStateName)"].postMessage({
              url: String(location.href),
              fields: state.fields,
              unrestorable: state.unrestorable
            });
          } catch (_) {}
        };
        const schedule = () => {
          if (timer !== null) clearTimeout(timer);
          timer = setTimeout(flush, 250);
        };
        document.addEventListener("input", (event) => {
          // The first composed path entry is the edited node even inside an
          // open shadow root, which the form scan above cannot reach.
          const origin = typeof event.composedPath === "function" ? event.composedPath()[0] : event.target;
          const nativeControl = origin instanceof HTMLInputElement || origin instanceof HTMLTextAreaElement || origin instanceof HTMLSelectElement;
          if (origin && (!nativeControl || origin.isContentEditable || (origin.getRootNode && origin.getRootNode() !== document))) {
            editedUntrackedContent = true;
          }
          schedule();
        }, true);
        document.addEventListener("change", schedule, true);
        document.addEventListener("visibilitychange", () => {
          if (document.visibilityState === "hidden") flush();
        }, true);
        // A report sent while the document unloads can arrive after the next
        // document commits and be taken for its input. WebKit keeps form
        // values of pages navigated away from in their history items.
        window.addEventListener("pagehide", () => {
          unloading = true;
          if (timer !== null) clearTimeout(timer);
          timer = null;
        }, true);
        // A back/forward cache return commits natively, which clears the
        // pane's copy of the input, so report it again.
        window.addEventListener("pageshow", (event) => {
          unloading = false;
          if (event.persisted) {
            lastReported = JSON.stringify({ fields: [], unrestorable: false });
            schedule();
          }
        }, true);
      } catch (_) {}
      return true;
    })();
    """#
}

extension WKUserContentController {
    /// Routes reports from ``WKUserScript/browserFormStateObserver()`` to
    /// `handler`.
    @MainActor
    public func addBrowserFormStateHandler(_ handler: BrowserFormStateMessageHandler) {
        add(handler, contentWorld: .browserFormState, name: WKContentWorld.browserFormStateName)
    }

    @MainActor
    public func removeBrowserFormStateHandler() {
        removeScriptMessageHandler(forName: WKContentWorld.browserFormStateName, contentWorld: .browserFormState)
    }
}

extension WKWebView {
    /// Refills the current document's controls from `formState`: only
    /// controls the page has not changed itself, dispatching `input` and
    /// `change` so frameworks see the values, and waiting a bounded time for
    /// controls rendered later.
    ///
    /// - Parameter onFailure: Called on the main actor if the script fails.
    @MainActor
    public func restoreBrowserFormState(
        _ formState: BrowserFormStateSnapshot,
        onFailure: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
        callAsyncJavaScript(
            Self.browserFormStateRestoreFunctionBody,
            arguments: [
                "fields": formState.restorePayload,
                "timeoutMs": Self.browserFormStateRestoreTimeoutMilliseconds
            ],
            in: nil,
            in: .browserFormState
        ) { result in
            guard case .failure(let error) = result else { return }
            Task { @MainActor in
                onFailure(error)
            }
        }
    }

    /// How long the restore script waits for late-rendered controls, such as
    /// a single-page app that builds its form after the document loads.
    private static let browserFormStateRestoreTimeoutMilliseconds = 5_000

    /// Body for `callAsyncJavaScript` with arguments `fields` (the snapshot's
    /// ``BrowserFormStateSnapshot/restorePayload``) and `timeoutMs`. Fills
    /// controls the page has not changed itself, dispatches `input` and
    /// `change` so frameworks see the values, waits up to `timeoutMs` for
    /// controls rendered later, and resolves to the number restored.
    private static let browserFormStateRestoreFunctionBody = #"""
    const pending = new Map();
    for (const field of fields) pending.set(field.k, field);
    let restored = 0;
    const findByKey = (key) => {
      if (key.startsWith("id:")) return document.getElementById(key.slice(3));
      if (key.startsWith("name:")) {
        const rest = key.slice(5);
        const first = rest.indexOf(":");
        const last = rest.lastIndexOf(":");
        if (first < 0 || last <= first) return null;
        const formIndex = Number(rest.slice(0, first));
        const name = rest.slice(first + 1, last);
        const wanted = Number(rest.slice(last + 1));
        const form = formIndex >= 0 ? document.forms[formIndex] : null;
        if (formIndex >= 0 && !form) return null;
        const scope = form ? form.elements : document.getElementsByName(name);
        let index = 0;
        for (const el of scope) {
          if (el.name !== name) continue;
          if (index === wanted) return el;
          index += 1;
        }
        return null;
      }
      if (key.startsWith("path:")) {
        let node = document.documentElement;
        for (const part of key.slice(5).split("/")) {
          if (!part) continue;
          const separator = part.lastIndexOf(":");
          const child = node ? node.children[Number(part.slice(separator + 1))] : null;
          if (!child || child.tagName.toLowerCase() !== part.slice(0, separator)) return null;
          node = child;
        }
        return node;
      }
      return null;
    };
    const apply = (el, field) => {
      if (el instanceof HTMLSelectElement) {
        if (!Array.isArray(field.s)) return true;
        const current = Array.from(el.options).flatMap((option, index) => option.selected ? [index] : []);
        let defaults = Array.from(el.options).flatMap((option, index) => option.defaultSelected ? [index] : []);
        if (!el.multiple && defaults.length === 0 && el.options.length > 0) defaults.push(0);
        if (current.join(",") !== defaults.join(",")) return true;
        if (field.s.some((index) => index < 0 || index >= el.options.length) || (!el.multiple && field.s.length > 1)) return true;
        const wanted = new Set(field.s);
        Array.from(el.options).forEach((option, index) => { option.selected = wanted.has(index); });
      } else if (el instanceof HTMLInputElement && (el.type === "checkbox" || el.type === "radio")) {
        if (typeof field.c !== "boolean" || el.checked === field.c || el.checked !== el.defaultChecked) return true;
        el.checked = field.c;
      } else if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
        if (el instanceof HTMLInputElement && (el.type === "password" || el.type === "file" || el.type === "hidden")) return true;
        if (typeof field.v !== "string" || el.value === field.v || el.value !== el.defaultValue) return true;
        el.value = field.v;
      } else {
        return false;
      }
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      restored += 1;
      return true;
    };
    const applyPending = () => {
      for (const [key, field] of pending) {
        const el = findByKey(key);
        if (el && apply(el, field)) pending.delete(key);
      }
      return pending.size === 0;
    };
    if (applyPending()) return restored;
    return await new Promise((resolve) => {
      let timer = null;
      let observer = null;
      const finish = () => {
        if (observer) observer.disconnect();
        if (timer !== null) clearTimeout(timer);
        resolve(restored);
      };
      observer = new MutationObserver(() => { if (applyPending()) finish(); });
      observer.observe(document.documentElement, { childList: true, subtree: true });
      timer = setTimeout(finish, timeoutMs);
    });
    """#
}
