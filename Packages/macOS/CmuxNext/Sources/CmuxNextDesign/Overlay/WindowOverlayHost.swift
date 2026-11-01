public import AppKit
public import CmuxNextDesignTokens
import CmuxNextWakeups

/// The one place app overlays draw above Chromium pages.
///
/// Each Chromium page is a child window of the main window, and the CEF fork
/// re-adds it above every other child each time it shows or moves to
/// another parent. Anything in the main window's view tree, and any app
/// child window shown before such a re-add, is then below the page. The
/// host keeps one transparent child panel per main window (`OverlayHostPanel`,
/// the size of the window) above every page window: it re-asserts that order
/// whenever the window's children change (`childWindowsDidChange(of:)`, called
/// by the window's `addChildWindow` override) and on every event cycle of the
/// window while it shows. Overlays presented on it (tooltips, popovers,
/// toasts, menus, drag ghosts, dialogs) are therefore always above pages.
///
/// The panel ignores the mouse except over interactive overlays (and the
/// whole window under a modal or dimming overlay, or a tab-region
/// `modalRegion`), and becomes key only while a modal overlay shows. It is a
/// child window at the parent's level, so it never floats above other apps.
/// `appHost()` is the same API for the moments with no window (the quit
/// dialog with every window closed).
@MainActor
public final class WindowOverlayHost {
    /// The parent window; nil for the app host.
    public private(set) weak var window: NSWindow?
    public let panel: OverlayHostPanel
    let isAppHost: Bool
    var handles: [OverlayHandle] = []
    /// Dialogs still fading out after their removal: the panel stays until they finish.
    var fadingOut = 0
    var nextID = 1
    /// The window's layout planes need the panel (pages show) even with no overlay presented.
    var planesWantPanel = false
    var observers: [any NSObjectProtocol] = []
    /// Window notification observers held while the panel is attached.
    var windowObservers: [any NSObjectProtocol] = []
    var mouseMonitor: Any?
    /// The key window and first responder to give back when the last modal overlay goes.
    weak var restoreWindow: NSWindow?
    weak var restoreResponder: NSResponder?
    /// The text selection of a restored text field (making it first responder again selects everything).
    var restoreSelection: [NSValue]?
    var isReordering = false
    /// A detach waiting for its empty frame to be drawn before the panel orders out
    /// (``detachAfterEmptyFrame()``); a re-attach meanwhile cancels it.
    var detachGeneration = 0
    var detachPending = false
    /// The window is closing: nothing takes key status back.
    var isTearingDown = false
    /// Where the app host centers its panel (tests pass an off-screen rect).
    public static var appHostScreenFrame: () -> NSRect = {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }
    /// Reorders done (diagnostics).
    public private(set) var reorderCount = 0
    /// Called after the panel was attached, detached or reordered.
    public var onPanelChange: (() -> Void)?
    /// Called when `blocksWholeWindow` may have changed (a modal or dimming overlay came or went).
    public var onBlockingChange: (() -> Void)?
    var escapeMonitor: Any?
    /// Rects in window coordinates that sit above `.pane` overlays and pages (the sidebar), by id.
    var occluders: [String: NSRect] = [:]
    /// `interactiveRegions()`, rebuilt on present, layout, dismiss, occluder and content frame changes.
    var cachedRegions: [NSRect]?
    /// The window that gets the rest of a click the panel passed on.
    weak var forwardTarget: NSWindow?
    /// The button of that click (`NSEvent.buttonNumber`).
    var forwardButton = 0
    /// Another window (not the panel nor the overlay's own window) became key while a modal
    /// showed: dismissing it leaves the keyboard there (`focusMoved`).
    var otherWindowTookKey = false
    /// A tab dialog (a modal with a region) showed: the rest of the window took clicks, so
    /// a first responder change there is a move. Kept here, as `endModal` runs after it left.
    var modalLeftWindowUsable = false
    var keyObserver: (any NSObjectProtocol)?
    /// Called when an occluder changed (the window layer re-masks its pages).
    public var onOccludersChange: (() -> Void)?
    /// Carries `agentCursorLayer` (made on first use; `WindowOverlayHost+AgentCursor`).
    var agentCursorCarrier: AgentCursorCarrierView?
    /// The window's clickable agent cursor tags (the app's source).
    public weak var agentCursorTags: (any AgentCursorTagSource)? {
        didSet { agentCursorCarrier?.tags = agentCursorTags }
    }

    private static var hosts: [ObjectIdentifier: WindowOverlayHost] = [:]
    private static var app: WindowOverlayHost?

    init(window: NSWindow?) {
        self.window = window
        isAppHost = window == nil
        panel = OverlayHostPanel()
        panel.onCancel = { [weak self] in self?.escape() }
        panel.onCycleKeyView = { [weak self] forward in self?.cycleKeyView(forward: forward) ?? false }
        panel.onMouseEvent = { [weak self] event in self?.panelMouseEvent(event) ?? false }
        if isAppHost {
            // Above the app's own windows while cmux is active; hidden while
            // another app is active, so it never covers other apps.
            panel.level = .modalPanel
            panel.hidesOnDeactivate = true
        }
    }

    /// The host of `window`, made on first use; it goes away with the window. A closed window keeps
    /// its torn-down host (whose panel is closed and never attaches again) until it shows again:
    /// work that reaches a closed window late (its controller's teardown, a task) makes no new
    /// panel that nothing would close.
    public static func host(for window: NSWindow) -> WindowOverlayHost {
        let key = ObjectIdentifier(window)
        if let host = hosts[key], host.window === window, !host.isTearingDown || !window.isVisible { return host }
        hosts = hosts.filter { $0.value.window != nil }
        let host = WindowOverlayHost(window: window)
        hosts[key] = host
        host.observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak host] _ in
            // main-proof: observer on queue: .main
            MainActor.assumeIsolated { host?.tearDown() }
        })
        return host
    }

    /// `window` is closing (its controller tears down): its host tears down, also a host made
    /// during the close (by that teardown), which came after the close notification and never
    /// heard it, or for a window that never had a host before its close.
    public static func windowIsClosing(_ window: NSWindow) {
        guard let host = hosts[ObjectIdentifier(window)], host.window === window, !host.isTearingDown else { return }
        host.tearDown()
    }

    /// The host of `window` if one exists (never makes one).
    public static func existingHost(for window: NSWindow) -> WindowOverlayHost? {
        hosts[ObjectIdentifier(window)].flatMap { $0.window === window && !$0.isTearingDown ? $0 : nil }
    }

    /// The host for overlays with no window (its own small panel, centered on the main screen).
    public static func appHost() -> WindowOverlayHost {
        if let app { return app }
        let host = WindowOverlayHost(window: nil)
        app = host
        return host
    }

    /// `window`'s children changed (a page window was added or re-added):
    /// the panel goes back above every page window before the window
    /// server composites a frame.
    public static func childWindowsDidChange(of window: NSWindow) {
        existingHost(for: window)?.reassertOrder()
    }

    /// Occluder rects (window coordinates), sorted by id.
    public var occluderRects: [NSRect] { occluders.sorted { $0.key < $1.key }.map(\.value) }

    /// Something of the main window's own view tree that must stay above
    /// pages and `.pane` overlays (the sidebar): pages are masked there (the
    /// window layer adds these rects to the pages' occlusion rects) and pane
    /// overlays are clipped. Nil removes it.
    public func setOccluder(id: String, rect: NSRect?) {
        let rect = rect.flatMap { $0.isEmpty ? nil : $0 }
        guard occluders[id] != rect else { return }
        occluders[id] = rect
        cachedRegions = nil
        for handle in handles where handle.clipView != nil { layout(handle) }
        updateMouseRouting()
        onOccludersChange?()
    }
    /// A modal (without a region) or dimming overlay shows: nothing else in the window takes input.
    public var blocksWholeWindow: Bool {
        handles.contains { $0.options.dimsContent || ($0.options.isModal && $0.options.modalRegion == nil) }
    }
    public var presentedHandles: [OverlayHandle] { handles }

    /// The window's layout planes need the panel while pages show (`WindowOverlayLayer`).
    public func setPlanesWantPanel(_ wanted: Bool) {
        guard planesWantPanel != wanted else { return }
        planesWantPanel = wanted
        syncPanel()
    }

    /// Whether the panel is attached to the window now.
    /// A panel leaving (``detachAfterEmptyFrame()``) is no longer attached: nothing new goes on it
    /// (planes, the agent cursor) while it waits for its empty frame.
    public var isPanelAttached: Bool { isAppHost ? panel.isVisible : panel.parent === window && window != nil && !detachPending }

    func tearDown() {
        isTearingDown = true
        // A detach still waiting for its empty frame is moot: the panel closes below.
        detachGeneration += 1
        detachPending = false
        for handle in handles { handle.dismiss() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        removeMouseMonitor()
        updateEscapeMonitor()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        stopObservingWindow()
        removeAgentCursor()
        // The host stays in `hosts` for the closed window (`host(for:)`) until the window is gone.
        if let window, panel.parent === window { window.removeChildWindow(panel) }
        // The window closed and the host goes with it: nothing orders this panel in again, so it
        // closes (ordered out only, it stayed in the app's window list, open, for good).
        panel.close()
    }

    // MARK: Attach and order

    /// Attaches the panel while something needs it, detaches it otherwise.
    func syncPanel() {
        if isAppHost { return syncAppPanel() }
        guard let window, !isTearingDown else { return }
        let wanted = planesWantPanel || !handles.isEmpty || fadingOut > 0
        if wanted {
            if panel.frame != window.frame { panel.setFrame(window.frame, display: false) }
            // A detach still waiting for its empty frame: the panel stays (it never left).
            detachGeneration += 1
            detachPending = false
            if panel.parent !== window {
                window.themeScope.adopt(panel)
                window.addChildWindow(panel, ordered: .above)
                observeWindow(window)
            }
            reassertOrder()
        } else if panel.parent === window, !detachPending {
            detachAfterEmptyFrame()
        }
        placeAgentCursor()
        // The cursor may just have left a panel that is leaving: route the mouse again, or the empty
        // panel keeps catching clicks (and its mouse monitor runs) until it orders out.
        updateMouseRouting()
        onPanelChange?()
    }

    /// Child order, bottom to top: page windows, this panel, then app panels
    /// at the panel's level that are not on the host yet. `order(_:relativeTo:)`
    /// has no effect on child windows, so reordering re-adds them.
    public func reassertOrder() {
        // Re-adding windows below calls back here (the window's addChildWindow override).
        guard !isReordering, let window, panel.parent === window else { return }
        isReordering = true
        defer { isReordering = false }
        // AppKit places its own children (the full screen titlebar); they are never re-added.
        let children = (window.childWindows ?? []).filter { !Self.isAppKitChrome($0) }
        guard let index = children.firstIndex(where: { $0 === panel }) else { return }
        let visible = children.enumerated().filter { $0.element.isVisible || $0.element === panel }
        let pageAbove = visible.contains { $0.offset > index && Self.isPageWindow($0.element) }
        let panelBelow = visible.contains { $0.offset < index && !Self.isPageWindow($0.element) && $0.element.level <= panel.level }
        guard pageAbove || panelBelow else { return }
        reorderCount += 1
        let panels = children.filter { $0 !== panel && !Self.isPageWindow($0) && $0.level <= panel.level }
        window.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
        for child in panels {
            window.removeChildWindow(child)
            window.addChildWindow(child, ordered: .above)
        }
        onPanelChange?()
    }

    /// Whether the panel is above every visible page window of the window.
    public var isAbovePages: Bool {
        guard let window else { return true }
        let children = window.childWindows ?? []
        guard let last = children.lastIndex(where: { Self.isPageWindow($0) && $0.isVisible }) else { return true }
        guard let index = children.firstIndex(where: { $0 === panel }) else { return false }
        return index > last
    }

    /// Page windows are the child windows that are not panels (Chromium),
    /// and content panels (`ContentChildPanel`: remote browser popups).
    /// AppKit's own child windows are not pages (`isAppKitChrome`).
    public nonisolated static func isPageWindow(_ child: NSWindow) -> Bool {
        if child is ContentChildPanel { return true }
        return !(child is NSPanel) && !isAppKitChrome(child)
    }

    /// A child window AppKit adds by itself: the full screen titlebar
    /// (`NSToolbarFullScreenWindow`, a plain `NSWindow` that is a child of
    /// every full screen window for as long as it stays in full screen).
    /// Counted as a page, it put the window in page mode for the whole of
    /// full screen: overlay planes moved into the panel, mouse-catcher panels
    /// covered every divider, pages re-synced on every layout, and the child
    /// order was checked on every event, so divider drags, sidebar hovers,
    /// group toggles and tab switches lagged (fullscreen-lag, user 2026-10-20).
    public nonisolated static func isAppKitChrome(_ child: NSWindow) -> Bool {
        appKitChromeClassNames.contains { name in
            NSClassFromString(name).map { child.isKind(of: $0) } ?? false
        }
    }

    /// AppKit's private child window classes (`isAppKitChrome`).
    public nonisolated static let appKitChromeClassNames = ["NSToolbarFullScreenWindow"]

    private func observeWindow(_ window: NSWindow) {
        stopObservingWindow()
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            // main-proof: observer on queue: .main
            MainActor.assumeIsolated { self?.reassertOrder() }
        })
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                // main-proof: observer on queue: .main
                MainActor.assumeIsolated { self?.windowGeometryDidChange() }
            })
        }
    }

    private func stopObservingWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
    }

    private func windowGeometryDidChange() {
        guard let window, panel.parent === window else { return }
        if panel.frame != window.frame { panel.setFrame(window.frame, display: false) }
        handles.forEach(layout)
        updateMouseRouting()
        placeAgentCursor()
        // A copy: a callback may resize, move or end its overlay.
        for handle in handles { handle.onWindowGeometryChange?() }
    }

    private func syncAppPanel() {
        if handles.isEmpty, fadingOut == 0 {
            panel.orderOut(nil)
        } else {
            layoutAppPanel()
            panel.orderFrontRegardless()
        }
        placeAgentCursor()
        onPanelChange?()
    }
}

extension WindowOverlayHost {
    /// Takes the panel off its window once nothing on it needs it, but only after the frame that
    /// draws it empty: its content left it this turn, and a panel ordered out before that commit
    /// keeps its last drawn surface (a dialog at full opacity, its scrim). The next attach then
    /// showed that surface for a frame before its own content drew: an old dialog, then the new one
    /// fading in from zero (debug.dialog_strip: 2 opens in 10 with a fresh attach, 0 in 20 while
    /// the panel stayed attached). Ordered out with an empty surface, any later attach shows at
    /// once. A re-attach in between cancels the detach; the panel never left.
    ///
    /// The host stops using the panel at once (``isPanelAttached`` is false): the agent cursor and
    /// the window's planes go back to the window this turn; only the order-out waits.
    func detachAfterEmptyFrame() {
        detachGeneration += 1
        detachPending = true
        let generation = detachGeneration
        AfterFrameCommit().run { [weak self] in
            guard let self, generation == detachGeneration, detachPending else { return }
            detachPending = false
            guard let window, panel.parent === window else { return }
            window.removeChildWindow(panel)
            panel.orderOut(nil)
            stopObservingWindow()
            onPanelChange?()
        }
    }
}
