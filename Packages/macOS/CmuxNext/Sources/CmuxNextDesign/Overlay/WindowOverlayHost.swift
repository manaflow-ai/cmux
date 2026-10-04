public import AppKit

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
    var isReordering = false
    /// Reorders done (diagnostics).
    public private(set) var reorderCount = 0
    /// Called after the panel was attached, detached or reordered.
    public var onPanelChange: (() -> Void)?

    private static var hosts: [ObjectIdentifier: WindowOverlayHost] = [:]
    private static var app: WindowOverlayHost?

    init(window: NSWindow?) {
        self.window = window
        isAppHost = window == nil
        panel = OverlayHostPanel()
        panel.onCancel = { [weak self] in self?.escape() }
        if isAppHost { panel.level = .modalPanel }
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
            MainActor.assumeIsolated { host?.tearDown() }
        })
        return host
    }

    /// The host of `window` if one exists (never makes one).
    public static func existingHost(for window: NSWindow) -> WindowOverlayHost? {
        hosts[ObjectIdentifier(window)].flatMap { $0.window === window ? $0 : nil }
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

    public var hasPresentations: Bool { !handles.isEmpty }
    public var presentedHandles: [OverlayHandle] { handles }

    /// The window's layout planes need the panel while pages show (`WindowOverlayLayer`).
    public func setPlanesWantPanel(_ wanted: Bool) {
        guard planesWantPanel != wanted else { return }
        planesWantPanel = wanted
        syncPanel()
    }

    /// Whether the panel is attached to the window now.
    public var isPanelAttached: Bool { isAppHost ? panel.isVisible : panel.parent === window && window != nil }

    func tearDown() {
        for handle in handles { handle.dismiss() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        removeMouseMonitor()
        stopObservingWindow()
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
        let wanted = planesWantPanel || !handles.isEmpty
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
        let children = window.childWindows ?? []
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

    /// Page windows (Chromium) are the child windows that are not panels.
    public nonisolated static func isPageWindow(_ child: NSWindow) -> Bool { !(child is NSPanel) }

    private func observeWindow(_ window: NSWindow) {
        stopObservingWindow()
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertOrder() }
        })
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
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
    }

    private func syncAppPanel() {
        if handles.isEmpty {
            panel.orderOut(nil)
        } else {
            layoutAppPanel()
            panel.orderFrontRegardless()
        }
        onPanelChange?()
    }
}
