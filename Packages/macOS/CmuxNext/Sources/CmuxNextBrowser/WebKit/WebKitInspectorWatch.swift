public import AppKit
public import Observation
import WebKit

/// Whether a WebKit tab's Web Inspector is shown, as an observable value
/// (the toolbar's DevTools button). WebKit has no public inspector API and
/// its private `_WKInspectorDelegate` reports no open or close, so this
/// watches what WebKit does to this app's views and windows instead:
///
/// - attached: WebKit adds the inspector's view to the web view's
///   container and removes it on close or detach (`WebKitPageContainer`);
/// - detached: the inspector is a window of this app; any window closing
///   is a reason to read again.
///
/// Each event reads `_inspector.isVisible` at once and again on the next
/// run-loop turn, because WebKit changes the view tree before it updates
/// the flag. Gap: an inspector hidden without a view or window change is
/// missed until the next read; the toolbar also reads when it is shown,
/// when a toolbar menu opens and on every press.
@Observable
public final class WebKitInspectorWatch: NSObject {
    public private(set) var isVisible = false
    @ObservationIgnored private weak var webView: WKWebView?

    override init() {}

    func attach(webView: WKWebView, container: WebKitPageContainer) {
        self.webView = webView
        container.onSubviewsChange = { [weak self] in self?.refresh() }
        // A selector observer is removed when this object is freed.
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) { refresh() }

    /// Reads the inspector's visibility now and once more on the next turn.
    public func refresh() {
        read()
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated { self?.read() } // main-proof: a CFRunLoopGetMain() block runs on the main thread
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func read() {
        let visible = Self.inspector(of: webView).map { $0.value(forKey: "visible") as? Bool ?? false } ?? false
        if visible != isVisible { isVisible = visible }
    }

    private static func inspector(of webView: WKWebView?) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard let webView, webView.responds(to: selector),
              let inspector = webView.perform(selector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("isVisible")) else { return nil }
        return inspector
    }
}
