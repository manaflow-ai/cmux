import Foundation

/// Reports a letter key the page left alone outside a text field, the way Chromium reports one
/// (``BrowserPageKey``), for an engine that has no such report (WebKit). It runs in its own
/// content world after the page's own handlers: a key the page prevented, a key with Command,
/// Control or Option, a composing key or a key typed into an editable element
/// is never reported. The host then runs the single-key action bound to it (link hints `f`,
/// scroll `j`).
nonisolated struct BrowserPageKeyReportScript {
    static let channel = "cmuxPageKey"
    static let world = "cmuxPageKey"

    /// The script, with `post` the statement that reports (it may use `key`, the letter, uppercase
    /// for Shift) and `ready` the expression that says the report channel exists.
    static func source(post: String, ready: String) -> String {
        """
        (() => {
          const editable = (el) => {
            for (; el; el = el.parentElement) {
              if (el.isContentEditable) return true;
              const tag = el.tagName;
              if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
              if (tag === 'INPUT') {
                const type = (el.type || '').toLowerCase();
                return !['button', 'checkbox', 'color', 'file', 'image', 'radio', 'range', 'reset', 'submit'].includes(type);
              }
            }
            return false;
          };
          const deep = () => {
            let el = document.activeElement;
            while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
            return el;
          };
          window.addEventListener('keydown', (event) => {
            if (!event.isTrusted || event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
            const key = event.key;
            if (typeof key !== 'string' || key.length !== 1 || !/[a-zA-Z]/.test(key)) return;
            // After every page handler of this dispatch: one that prevented the key keeps it.
            setTimeout(() => {
              if (event.defaultPrevented || editable(deep())) return;
              if (\(ready)) { \(post); }
            }, 0);
          }, true);
        })();
        """
    }
}
