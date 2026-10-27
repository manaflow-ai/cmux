public import AppKit
public import Observation
import WebKit
import CmuxNextCompat
import CmuxNextWakeups

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
@MainActor
public final class WebKitInspectorWatch: NSObject {
    public private(set) var isVisible = false
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var closeObserver: EventSubscription?

    override init() {}

    /// Watches `webView`'s inspector: views WebKit adds to `container`, and any window's close from `events` (the
    /// engine's one observer for every tab, which delivers a close off main on main).
    func attach(webView: WKWebView, container: WebKitPageContainer, events: AppEvents) {
        self.webView = webView
        container.onSubviewsChange = { [weak self] in self?.refresh() }
        closeObserver = events.subscribe(NSWindow.willCloseNotification, owner: "WebKitInspectorWatch") { [weak self] in
            self?.refresh()
        }
    }

    /// Reads the inspector's visibility now and once more on the next turn.
    public func refresh() {
        read()
        MainRunLoopBlock.perform { [weak self] in self?.read() }
    }

    private func read() {
        let visible = webView.map { WebKitInspector.isVisible(of: $0) } ?? false
        if visible != isVisible { isVisible = visible }
    }
}
