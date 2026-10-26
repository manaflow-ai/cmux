public import AppKit
public import CmuxNextDesignTokens
public import CmuxNextInput
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
    /// The tap observer of pointer moves and clicks that keeps the panel's mouse routing current,
    /// held while an interactive region or agent cursor tag shows (``updateMouseRouting()``).
    var mouseRouting: InputSubscription? {
        didSet {
            if mouseRouting == nil { stopTagHoverMoves() }
            // While the tap routes the mouse it hovers the carrier's tags in the panel: one hover path.
            agentCursorCarrier?.routedPanel = mouseRouting == nil ? nil : panel
        }
    }
    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`, p04-input-036): the agent cursor's
    /// tag hover and the panel's views wait on it; the panel's click routing never does. From the window
    /// (``HoverFrameInputHosting``, the App's main windows) when the host is made; nil (the feature off, any
    /// other window) hovers on every move.
    var hoverFrames: FrameInputCoalescers? {
        didSet {
            guard hoverFrames !== oldValue else { return }
            stopTagHoverMoves()
            agentCursorCarrier?.hoverMoves.frames = hoverFrames
            panel.hoverFrameInput = hoverFrames
        }
    }
    /// The tag hover's consumer on the window's coalescer, made on the first move while ``mouseRouting`` holds.
    var tagHoverMoves: PointerFrameConsumer?
    /// The last event the routing took: the tap and the panel's `sendEvent` see the same panel event.
    weak var lastRoutingEvent: NSEvent?
    /// The key window and first responder to give back when the last modal overlay goes.
    weak var restoreWindow: NSWindow?
    weak var restoreResponder: NSResponder?
    /// The text selection of a restored text field (making it first responder again selects everything).
    var restoreSelection: [NSValue]?
    var isReordering = false
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
    /// The tap intercept for Escape (``InputEventTap/InterceptOrder/modal``), held while an overlay
    /// that dismisses on Escape, or a modal, shows (``updateEscapeIntercept()``).
    var escapeIntercept: InputSubscription?
    /// The app's input tap the overlay hosts and native popups subscribe to, set once by the App's
    /// composition root before any window shows (their owners in many packages make them through
    /// ``host(for:)`` or with no tap). Each takes it when it is made (tests pass their own).
    public static var appInputTap: InputEventTap?
    /// The tap this host subscribes to (``appInputTap`` when made).
    var inputTap: InputEventTap?
    /// Told each time an overlay is presented, dismissed or stops taking the mouse here; the App gives each main
    /// window's host its one feed (`debug.oracle.wait_for` on the overlays facet waits on it).
    public var changes: OverlayChangeFeed?
    /// The pointer in screen coordinates (tests inject one).
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    /// Rects in window coordinates that sit above `.pane` overlays and pages (the sidebar), by id.
    var occluders: [String: NSRect] = [:]
    /// `interactiveRegions()`, rebuilt on present, layout, dismiss, occluder and content frame changes.
    var cachedRegions: [NSRect]?
    /// The container bounds, then each overlay's frame in window coordinates, `cachedRegions` was built from.
    var cachedRegionsFrames: [NSRect] = []
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
        inputTap = Self.appInputTap
        panel = OverlayHostPanel()
        panel.onCancel = { [weak self] in self?.escape() }
        panel.onCycleKeyView = { [weak self] forward in self?.cycleKeyView(forward: forward) ?? false }
        panel.onMouseEvent = { [weak self] event in self?.panelMouseEvent(event) ?? false }
        hoverFrames = (window as? HoverFrameInputHosting)?.hoverFrameInput
        panel.hoverFrameInput = hoverFrames
        for container in [panel.paneContainer, panel.windowContainer, panel.modalContainer] {
            container.onLayout = { [weak self] in self?.containerDidLayout() }
        }
        if isAppHost {
            // Above the app's own windows while cmux is active; hidden while
            // another app is active, so it never covers other apps.
            panel.level = .modalPanel
            panel.hidesOnDeactivate = true
        }
    }

    /// The host of `window`, made on first use; it goes away with the window.
    public static func host(for window: NSWindow) -> WindowOverlayHost {
        let key = ObjectIdentifier(window)
        if let host = hosts[key], host.window === window { return host }
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

    /// The host of `window` if one exists (never makes one).
    public static func existingHost(for window: NSWindow) -> WindowOverlayHost? {
        hosts[ObjectIdentifier(window)].flatMap { $0.window === window ? $0 : nil }
    }

    /// The app host if one exists (never makes one).
    public static var existingAppHost: WindowOverlayHost? { app }

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
    /// The presented overlays bottom to top as the panel draws them: by layer (`.pane`, `.window`, `.modal`
    /// containers), then in the order they were presented within a layer.
    public var stackedHandles: [OverlayHandle] {
        handles.enumerated().sorted { (layerIndex(of: $0.element), $0.offset) < (layerIndex(of: $1.element), $1.offset) }.map(\.element)
    }

    /// The window's layout planes need the panel while pages show (`WindowOverlayLayer`).
    public func setPlanesWantPanel(_ wanted: Bool) {
        guard planesWantPanel != wanted else { return }
        planesWantPanel = wanted
        syncPanel()
    }

    /// Whether the panel is attached to the window now.
    public var isPanelAttached: Bool { isAppHost ? panel.isVisible : panel.parent === window && window != nil }

    func tearDown() {
        isTearingDown = true
        for handle in handles { handle.dismiss() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        mouseRouting = nil
        updateEscapeIntercept()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        stopObservingWindow()
        removeAgentCursor()
        if let window {
            if panel.parent === window { window.removeChildWindow(panel) }
            Self.hosts[ObjectIdentifier(window)] = nil
        }
        panel.orderOut(nil)
    }

    // MARK: Attach and order

    /// Attaches the panel while something needs it, detaches it otherwise.
    func syncPanel() {
        if isAppHost { return syncAppPanel() }
        guard let window else { return }
        let wanted = planesWantPanel || !handles.isEmpty || fadingOut > 0
        if wanted {
            if panel.frame != window.frame { panel.setFrame(window.frame, display: false) }
            if panel.parent !== window {
                window.themeScope.adopt(panel)
                window.addChildWindow(panel, ordered: .above)
                observeWindow(window)
            }
            reassertOrder()
        } else if panel.parent === window {
            window.removeChildWindow(panel)
            panel.orderOut(nil)
            stopObservingWindow()
        }
        placeAgentCursor()
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
