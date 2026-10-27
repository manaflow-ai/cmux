public import AppKit
public import CmuxNextDesign
import CmuxNextSettings

// The window's chrome state reaches the page as `data-*` attributes of `<html>`, kept current:
// `data-app-sidebar` is `hidden` while the window's sidebar is hidden, else `shown` (the Settings
// page fades its section list's border then, nxdog41). Set when the page joins a window and when
// the window's sidebar changes (`WindowChromeHosting`), and again on every new document.
extension PageWebView {
    /// Sets `data-<name>` on the page's `<html>` now and on every later document.
    public func setDocumentAttribute(_ name: String, _ value: String) {
        guard liveDocumentAttributes[name] != value else { return }
        liveDocumentAttributes[name] = value
        applyLiveDocumentAttributes()
    }

    /// The window's chrome changed (it joined a window, or the window's sidebar hid or showed).
    public func windowDidChangeChrome() {
        guard let host = window as? WindowChromeHosting else { return }
        setDocumentAttribute("app-sidebar", host.sidebarHidden ? "hidden" : "shown")
    }

    /// The script that sets `data-<name>` attributes on `<html>`; nil for none. Names keep only
    /// lowercase letters, digits and dashes; values are JSON string literals.
    ///
    /// WebKit runs a document-start script once `<html>` exists, but Chromium runs a new-document
    /// script (``PageChromiumDocumentScripts``) before the parser makes it, when
    /// `document.documentElement` is null: setting the attributes then threw, and a Chromium page
    /// (the agent chat by default) got none of them, so `data-needs-you="off"` never hid Needs you.
    /// Without `<html>` the script waits for it with a MutationObserver, whose callback runs before
    /// the page's first script.
    nonisolated static func attributesScript(_ attributes: [String: String]) -> String? {
        let safe = attributes.filter { name, _ in !name.isEmpty && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } }
        guard !safe.isEmpty else { return nil }
        let lines = safe.keys.sorted().map { name in
            "document.documentElement.setAttribute(\(JSONValue.string("data-" + name).compactText), \(JSONValue.string(safe[name] ?? "").compactText));"
        }
        return """
        (() => {
        const set = () => {
        \(lines.joined(separator: "\n"))
        };
        if (document.documentElement) { set(); return; }
        new MutationObserver((_, observer) => {
          if (!document.documentElement) return;
          observer.disconnect();
          set();
        }).observe(document, { childList: true });
        })();
        """
    }

    func applyLiveDocumentAttributes() {
        guard loaded, let script = Self.attributesScript(liveDocumentAttributes) else { return }
        pushes.run(script, whileFrozen: .latest(.documentAttributes))
    }
}
