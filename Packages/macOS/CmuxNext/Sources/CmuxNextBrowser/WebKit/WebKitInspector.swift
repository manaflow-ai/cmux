import AppKit
public import WebKit

/// Drives Safari's Web Inspector for any `WKWebView` in the app: a WebKit
/// browser tab, the Markdown page, an agent chat, an internal page.
///
/// WebKit has no public inspector API. This calls the private
/// `_WKInspector` object (`-[WKWebView _inspector]`) by selector, and only
/// after checking that it responds, so a WebKit without one of them makes
/// the call a no-op instead of a crash. Every call first sets
/// `isInspectable`, which WebKit needs before it shows an inspector for an
/// app built on macOS 13.3 or later.
///
/// ```swift
/// let inspector = WebKitInspector(webView: page.webKitView)
/// inspector.show(.console)
/// ```
@MainActor
public struct WebKitInspector {
    /// The inspected web view.
    public let webView: WKWebView

    /// - Parameter webView: The web view to inspect.
    public init(webView: WKWebView) {
        self.webView = webView
    }

    /// Lets the inspector open for this web view (all builds).
    public func prepare() {
        if !webView.isInspectable { webView.isInspectable = true }
    }

    /// Whether the inspector is shown.
    public var isVisible: Bool {
        guard let inspector, inspector.responds(to: Selector(("isVisible"))) else { return false }
        // crash-allow: guarded by responds(to: isVisible) above; KVC's "visible" getter search finds -isVisible, so no undefined-key exception
        return inspector.value(forKey: "visible") as? Bool ?? false
    }

    /// Shows the inspector; with `panel`, on that tab when WebKit can
    /// select it (``WebDevToolsPanel/webKitSelector``).
    public func show(_ panel: WebDevToolsPanel? = nil) {
        call(panel?.webKitSelector ?? "show")
    }

    /// Opens the inspector when closed, closes it when open.
    public func toggle() {
        isVisible ? call("close") : call("show")
    }

    /// Shows the inspector and starts picking an element in the page
    /// (Safari's Develop > Start Element Selection).
    public func inspectElement() {
        call("show")
        let active = inspector.flatMap { inspector in
            inspector.responds(to: Selector(("isElementSelectionActive")))
                // crash-allow: guarded by responds(to: isElementSelectionActive) above; KVC's getter search finds it, so no undefined-key exception
                ? inspector.value(forKey: "elementSelectionActive") as? Bool : nil
        } ?? false
        if !active { call("toggleElementSelection") }
    }

    /// Docks the inspector to the web view's window.
    public func attach() {
        call("show")
        call("attach")
    }

    /// Moves the inspector to its own window.
    public func detach() {
        call("show")
        call("detach")
    }

    /// Closes the inspector.
    public func close() { call("close") }

    /// Starts a Timelines recording, or stops the running one.
    public func togglePageProfiling() {
        call("show")
        call("togglePageProfiling")
    }

    private var inspector: NSObject? {
        prepare()
        guard webView.responds(to: Selector(("_inspector"))) else { return nil }
        return webView.perform(Selector(("_inspector")))?.takeUnretainedValue() as? NSObject
    }

    private func call(_ name: String) {
        let selector = Selector((name))
        guard let inspector, inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }
}
