package import AppKit
import CmuxNextBrowser
package import CmuxNextBrowserAutomation
package import WebKit

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
/// out of the render window, and the window closes. A tab that left a
/// minimized or covered window goes back to its pane (``AgentRenderHome``)
/// when that window draws again (``windowDidChangeOcclusion(_:)``, from the
/// window's delegate).
@MainActor
package final class AgentRenderWindows {
    /// - Parameter windowDraws: Whether a window draws its content; the
    ///   default reads AppKit (`NSWindow.drawsContent`). Tests pass a fixed answer.
    package init(windowDraws: @escaping @MainActor (NSWindow) -> Bool = { $0.drawsContent }) {
        self.windowDraws = windowDraws
    }

    private let windowDraws: @MainActor (NSWindow) -> Bool
    /// Per parked tab that left a window that did not draw: where it goes back when that window draws.
    private var returns: [String: Return] = [:]

    /// A parked chrome's way back to its pane.
    private struct Return {
        weak var chrome: NSView?
        weak var home: (any AgentRenderHome)?
        weak var window: NSWindow?
    }

    /// Playwright's default page size for a hidden driven tab, so results do
    /// not depend on the pane that last showed it.
    package static let viewport = NSSize(width: 1280, height: 800)

    private var parked: [String: AgentRenderPanel] = [:]
    /// WebKit private calls (occlusion detection) for the parked pages.
    package let privateCalls = WebKitPrivateCalls()

    /// Moves a hidden tab's `chrome` into its render window, with `webView`
    /// (a WebKit page) first responder there. A Chromium tab's content view
    /// entering a window presents the tab (its pane's Chromium window moves
    /// there and activates it). True when it moved; false when a window
    /// shows the tab (a pane, or this render window already).
    package func keepRendering(tabID: String, chrome: NSView, webView: WKWebView?) -> Bool {
        // A chrome its pane parked hidden (`PaneContentView+Parking`) is a
        // background tab too, and so is one in a parked workspace (hidden in
        // place, still in the window): its pane takes it back when the
        // workspace shows (`PaneContentView.viewDidUnhide`). A tab in a
        // minimized or covered window goes back when that window draws.
        guard chrome.isOffScreen(windowDraws: windowDraws) else { return false }
        // Also a parked workspace's window: its pane, shown while the window drew nothing, waits for it to draw.
        let source = chrome.window
        let home = Self.home(of: chrome)
        parked.removeValue(forKey: tabID)?.finish()
        let panel = AgentRenderPanel(viewport: Self.viewport, screens: NSScreen.screens.map(\.frame), privateCalls: privateCalls)
        panel.onRelease = { [weak self, weak panel] in
            guard let self, let panel, self.parked[tabID] === panel else { return }
            self.parked[tabID] = nil
            self.returns[tabID] = nil
        }
        panel.park(chrome, webView: webView)
        parked[tabID] = panel
        returns[tabID] = source.map { Return(chrome: chrome, home: home, window: $0) }
        return true
    }

    /// The tab closed: its render window goes.
    package func release(tabID: String) {
        returns[tabID] = nil
        parked.removeValue(forKey: tabID)?.finish()
    }

    /// The nearest ancestor of `chrome` that takes tabs back (a pane).
    private static func home(of chrome: NSView) -> (any AgentRenderHome)? {
        var view = chrome.superview
        while let current = view {
            if let home = current as? any AgentRenderHome { return home }
            view = current.superview
        }
        return nil
    }

    /// A window's occlusion changed (its delegate): when it draws again
    /// (deminiaturized, uncovered), the tabs that left it go back to their panes.
    /// - Parameter window: The window whose occlusion state changed.
    package func windowDidChangeOcclusion(_ window: NSWindow) {
        guard windowDraws(window) else { return }
        for (tabID, way) in returns where way.window === window {
            returns[tabID] = nil
            if let chrome = way.chrome, let home = way.home { home.takeBack(chrome) }
        }
    }

    /// The frame of a render window of `size`: left of and below every
    /// screen, with a margin, so a screen added later at the old edge does
    /// not overlap it at once.
    package nonisolated static func frame(for size: NSSize, screens: [NSRect]) -> NSRect {
        let union = screens.reduce(NSRect.null) { $0.union($1) }
        let bounds = union.isNull ? NSRect.zero : union
        let margin: CGFloat = 10_000
        return NSRect(x: bounds.minX - size.width - margin, y: bounds.minY - size.height - margin,
                      width: size.width, height: size.height)
    }
}

/// One hidden tab's render window.
@MainActor
package final class AgentRenderPanel: NSPanel {
    /// The parked chrome left (a pane took it, or the tab closed).
    package var onRelease: (() -> Void)?
    private weak var webView: WKWebView?
    private var finished = false

    private let privateCalls: WebKitPrivateCalls

    /// Every render window's identifier: a pane whose content is in one takes it back when it shows.
    package static let windowIdentifier = NSUserInterfaceItemIdentifier.agentRenderWindow

    package init(viewport: NSSize, screens: [NSRect], privateCalls: WebKitPrivateCalls) {
        self.privateCalls = privateCalls
        super.init(contentRect: AgentRenderWindows.frame(for: viewport, screens: screens),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        identifier = Self.windowIdentifier
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
    package nonisolated override var canBecomeKey: Bool { false }
    package nonisolated override var canBecomeMain: Bool { false }
    /// Reports key without becoming key (WebKitTestRunner does the same):
    /// AppKit's real key window and keyboard focus are unaffected.
    package nonisolated override var isKeyWindow: Bool { true }

    package func park(_ chrome: NSView, webView: WKWebView?) {
        guard let content = contentView else { return }
        self.webView = webView
        if let webView { privateCalls.setOcclusionDetection(false, on: webView) }
        chrome.frame = content.bounds
        chrome.autoresizingMask = [.width, .height]
        orderBack(nil)
        content.addSubview(chrome)
        // Parked hidden in a pane until now: it shows here (a Chromium tab
        // presents on unhide).
        chrome.isHidden = false
        if let webView { makeFirstResponder(webView) }
        content.layoutSubtreeIfNeeded()
    }

    /// Closes the window and turns occlusion detection back on; the chrome
    /// stays wherever it is now (a pane), or leaves the window.
    package func finish() {
        guard !finished else { return }
        finished = true
        if let webView { privateCalls.setOcclusionDetection(true, on: webView) }
        (contentView as? AgentRenderContentView)?.onSubviewLeave = nil
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        orderOut(nil)
        close()
        let release = onRelease
        onRelease = nil
        release?()
    }
}

/// Reports when the parked chrome leaves (a pane added it to itself).
package final class AgentRenderContentView: NSView {
    package var onSubviewLeave: (() -> Void)?

    package override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        onSubviewLeave?()
    }
}
