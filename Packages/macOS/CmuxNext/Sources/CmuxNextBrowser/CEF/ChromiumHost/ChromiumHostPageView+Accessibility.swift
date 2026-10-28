public import AppKit
import CmuxNextRemoteLayer
import CmuxNextWakeups
import Darwin

/// A hosted page's accessibility in host mode (task 049 of
/// plans/cmux-next/chrome-parity/p01-process.md). The page's accessibility tree lives in the
/// Chromium Host, whose page window never shows; cmux's page view gives the host the tokens of
/// itself and its window, the host makes them the parent and window of the page's root element and
/// answers with that element's token, and the page view shows a remote element made from it as its
/// accessibility child. AppKit then forwards an assistive client's reads of that element and
/// everything under it to the host. Chrome's app shim joins the browser process's views the same
/// way: the shim's view and window tokens go to the browser
/// (`NativeWidgetNSWindowHost::SetRemoteAccessibilityTokens`), the browser's element token comes
/// back (`GetRootViewAccessibilityToken`, `RenderWidgetHostViewMac::GetRenderWidgetAccessibilityToken`
/// in content/browser/renderer_host/render_widget_host_view_mac.mm), and the shim shows
/// `ui::RemoteAccessibility::GetRemoteElementFromToken` (ui/base/cocoa/remote_accessibility_api.mm).
///
/// Chrome exchanges the tokens once per view and waits for the answer (a `[Sync]` call); here the
/// exchange starts at the first read of the page view's children and nothing waits: that read gets
/// the children without the page, and the element's arrival posts a layout change so the client
/// reads them again. A page view nobody reads costs no request.
extension ChromiumHostPageView {
    /// The page view's own children, then the page's remote element once the host gave it. The first
    /// read with none asks the host for it.
    public override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren()
        guard let element = remoteAccessibility.element else {
            askForRemoteAccessibility()
            return children
        }
        return (children ?? []) + [element]
    }

    /// Chromium built the page's accessibility tree (an assistive client came, `CEFAccessibility`): a
    /// page the host refused while it had none, or refuses a request already in flight, is asked
    /// again at the next read, which the layout change prompts.
    func retryRemoteAccessibility() {
        if remoteAccessibility.retry() { accessibilityBridge.layoutChanged(self) }
    }

    /// The page view shows `browser`'s page (a tab switch in its pane): the accessibility element
    /// follows it.
    func showAccessibility(of browser: Int32?) {
        guard browser != remoteAccessibility.browser else { return }
        resetRemoteAccessibility(browser: browser)
    }

    /// Drops the page's element and any request in flight: the page view shows another page
    /// (`browser`), window or context. Assistive clients that saw the element read the children again.
    func resetRemoteAccessibility() {
        resetRemoteAccessibility(browser: remoteAccessibility.browser)
    }

    private func resetRemoteAccessibility(browser: Int32?) {
        accessibilityWindowClose = nil
        if remoteAccessibility.reset(browser: browser) { accessibilityBridge.layoutChanged(self) }
    }

    /// Sends the tokens of this view and its window for the shown page, once per page.
    private func askForRemoteAccessibility() {
        guard let source = accessibilityTokenSource, let window, remoteAccessibility.phase == .idle,
              let browser = remoteAccessibility.browser, let viewToken = accessibilityBridge.localToken(self),
              let windowToken = accessibilityBridge.localToken(window), let generation = remoteAccessibility.begin() else { return }
        let request = ChromiumHostAccessibilityRequest(browser: browser, embedderPID: getpid(), viewToken: viewToken,
                                                       windowToken: windowToken)
        source(request) { [weak self] token in self?.remoteAccessibilityAnswered(token, generation: generation) }
    }

    /// The host's answer to the request of `generation`: the page's token, nil for none.
    func remoteAccessibilityAnswered(_ token: [UInt8]?, generation: UInt64) {
        guard generation == remoteAccessibility.generation, remoteAccessibility.phase == .asking else { return }
        let element = token.flatMap { token in window.flatMap { accessibilityBridge.remoteElement(token, $0) } }
        guard remoteAccessibility.answered(element, generation: generation) else { return }
        guard element != nil, let window else {
            // A refusal the tree's arrival made stale (``retryRemoteAccessibility()``): the next read asks again.
            if remoteAccessibility.phase == .idle { accessibilityBridge.layoutChanged(self) }
            return
        }
        accessibilityWindowClose = WindowEvents.of(window).subscribe(NSWindow.willCloseNotification,
                                                                     owner: "ChromiumHostPageView.accessibility") { [weak self] in
            self?.resetRemoteAccessibility()
        }
        accessibilityBridge.layoutChanged(self)
    }

    /// `debug.cef`'s `page_accessibility`: idle, asking, refused or connected; nil in process.
    public var remoteAccessibilityPhaseName: String? {
        guard accessibilityTokenSource != nil else { return nil }
        return switch remoteAccessibility.phase {
        case .idle: "idle"
        case .asking: "asking"
        case .refused: "refused"
        case .connected: "connected"
        }
    }
}

/// AppKit's remote accessibility calls (`NSAccessibilityRemoteUIElement`, CmuxNextRemoteLayer) and
/// its layout change post, so tests run the page view's exchange with no second process.
struct ChromiumHostAccessibilityBridge {
    /// The token another process makes a remote element for `element` from; nil when AppKit gives none.
    var localToken: (Any) -> [UInt8]?
    /// The remote element for a host's `token`, in `window`; nil when AppKit makes none.
    var remoteElement: ([UInt8], NSWindow) -> AnyObject?
    /// The element of the remote tree under a screen point.
    var hitTest: (AnyObject, NSPoint) -> Any?
    /// Tells assistive clients that `element`'s children changed, so they read them again.
    var layoutChanged: (Any) -> Void

    /// AppKit's. The host's process is registered as one whose elements cmux presents, as a WKWebView
    /// registers its web process (`[NSAccessibilityRemoteUIElement registerRemoteUIProcessIdentifier:]`).
    static let system = ChromiumHostAccessibilityBridge(
        localToken: { element in
            guard let token = NSAccessibilityRemoteUIElement.remoteToken(forLocalElement: element), !token.isEmpty else { return nil }
            return [UInt8](token)
        },
        remoteElement: { token, window in
            guard let element = NSAccessibilityRemoteUIElement(remoteToken: Data(token)) else { return nil }
            NSAccessibilityRemoteUIElement.registerRemoteUIProcess(element.remoteProcessIdentifier())
            element.windowUIElement = window
            element.topLevelUIElement = window
            return element
        },
        hitTest: { element, point in (element as? NSAccessibilityRemoteUIElement)?.accessibilityHitTest(point) },
        layoutChanged: { element in NSAccessibility.post(element: element, notification: .layoutChanged) })
}
