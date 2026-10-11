public import AppKit
public import CmuxNextDesign

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

    func applyLiveDocumentAttributes() {
        guard loaded, let script = Self.attributesScript(liveDocumentAttributes) else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
