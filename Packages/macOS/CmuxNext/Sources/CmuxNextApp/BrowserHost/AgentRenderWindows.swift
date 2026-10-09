import AppKit
import WebKit

/// Off-screen render windows for agent-driven WebKit tabs that no pane shows
/// (plans/cmux-next/browser-host.md, background agent tabs; ported from the
/// legacy app's `BrowserOffscreenRenderHost` `.offAllScreens` placement).
///
/// A WebKit page with no window takes no trusted input, pauses animation
/// frames (Playwright-style actionability waits for them) and returns no
/// snapshot. Before a driver call, a hidden tab's chrome moves into a
/// borderless panel that lies outside every screen, is fully transparent,
/// ignores the mouse, is ordered behind every window and can never become
/// key or main, so nothing shows and the person's focus never moves. It only
/// reports itself as key to WebKit, which derives focus, blur and `:hover`
/// from `isKeyWindow`. Window occlusion detection is off while parked, so the
/// page keeps rendering.
///
/// The chrome, not the page container, moves: when a pane shows the tab it
/// adds the chrome back to itself (`PaneContentView.show`), AppKit takes it
/// out of the render window, and the window closes.
@MainActor
final class AgentRenderWindows {
    /// Playwright's default page size for a hidden driven tab, so results do
    /// not depend on the pane that last showed it.
    static let viewport = NSSize(width: 1280, height: 800)

    private var parked: [String: AgentRenderPanel] = [:]

    /// Moves a hidden tab's `chrome` into its render window, with `webView`
    /// first responder there. True when it moved; false when the tab already
    /// has a window (a pane shows it, or it is parked).
    func keepRendering(tabID: String, chrome: NSView, webView: WKWebView) -> Bool {
        guard chrome.window == nil else { return false }
        parked.removeValue(forKey: tabID)?.finish()
        let panel = AgentRenderPanel(viewport: Self.viewport, screens: NSScreen.screens.map(\.frame))
        panel.onRelease = { [weak self, weak panel] in
            guard let self, let panel, self.parked[tabID] === panel else { return }
            self.parked[tabID] = nil
        }
        panel.park(chrome, webView: webView)
        parked[tabID] = panel
        return true
    }

    /// The tab closed: its render window goes.
    func release(tabID: String) {
        parked.removeValue(forKey: tabID)?.finish()
    }

    /// The frame of a render window of `size`: left of and below every
    /// screen, with a margin, so a screen added later at the old edge does
    /// not overlap it at once.
    nonisolated static func frame(for size: NSSize, screens: [NSRect]) -> NSRect {
        let union = screens.reduce(NSRect.null) { $0.union($1) }
        let bounds = union.isNull ? NSRect.zero : union
        let margin: CGFloat = 10_000
        return NSRect(x: bounds.minX - size.width - margin, y: bounds.minY - size.height - margin,
                      width: size.width, height: size.height)
    }
}

/// One hidden tab's render window.
@MainActor
final class AgentRenderPanel: NSPanel {
    /// The parked chrome left (a pane took it, or the tab closed).
    var onRelease: (() -> Void)?
    private weak var webView: WKWebView?
    private var finished = false

    init(viewport: NSSize, screens: [NSRect]) {
        super.init(contentRect: AgentRenderWindows.frame(for: viewport, screens: screens),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        identifier = NSUserInterfaceItemIdentifier("cmux.agentRenderWindow")
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        ignoresMouseEvents = true
        sharingType = .none
        level = .normal
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .stationary, .canJoinAllSpaces]
        isExcludedFromWindowsMenu = true
        let content = AgentRenderContentView(frame: NSRect(origin: .zero, size: viewport))
        content.onSubviewLeave = { [weak self] in
            // AppKit is still removing the view: finish after it.
            Task { @MainActor [weak self] in self?.finish() }
        }
        contentView = content
    }

    // WebKit reads these from framework callbacks; the panel stays main-thread owned.
    nonisolated override var canBecomeKey: Bool { false }
    nonisolated override var canBecomeMain: Bool { false }
    /// Reports key without becoming key (WebKitTestRunner does the same):
    /// AppKit's real key window and keyboard focus are unaffected.
    nonisolated override var isKeyWindow: Bool { true }

    func park(_ chrome: NSView, webView: WKWebView) {
        guard let content = contentView else { return }
        self.webView = webView
        Self.setOcclusionDetection(false, on: webView)
        chrome.frame = content.bounds
        chrome.autoresizingMask = [.width, .height]
        content.addSubview(chrome)
        orderBack(nil)
        makeFirstResponder(webView)
        content.layoutSubtreeIfNeeded()
        webView.layoutSubtreeIfNeeded()
    }

    /// Closes the window and turns occlusion detection back on; the chrome
    /// stays wherever it is now (a pane), or leaves the window.
    func finish() {
        guard !finished else { return }
        finished = true
        if let webView { Self.setOcclusionDetection(true, on: webView) }
        (contentView as? AgentRenderContentView)?.onSubviewLeave = nil
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        orderOut(nil)
        close()
        let release = onRelease
        onRelease = nil
        release?()
    }

    /// WebKit's private switch (the legacy app used it the same way): with
    /// detection on, a window no pixel of which is on a display counts as
    /// occluded, and the page stops rendering.
    private static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(webView.method(for: selector), to: Setter.self)
        setter(webView, selector, enabled)
    }
}

/// Reports when the parked chrome leaves (a pane added it to itself).
final class AgentRenderContentView: NSView {
    var onSubviewLeave: (() -> Void)?

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        onSubviewLeave?()
    }
}
