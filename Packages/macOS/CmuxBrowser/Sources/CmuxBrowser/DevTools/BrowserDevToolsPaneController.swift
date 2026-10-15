public import AppKit

/// Developer tools of one in-pane page (Chromium): docked below or beside the page inside the
/// pane, resizable by a divider, or in their own window.
///
/// The docked tools are an engine child of `host`, a view in the page's
/// ``BrowserDevToolsPaneView``, so they follow the pane's layout, clipping and moves like the
/// page. Moving between a dock side and the window only reparents `host`; the engine's DevTools
/// (console, selection, open panel) stay alive. Ported from cmux Next's Chromium DevTools
/// controller and made engine-neutral behind ``BrowserDevToolsEngineDriving``.
///
/// ```swift
/// let controller = BrowserDevToolsPaneController(paneView: pane, store: layoutStore)
/// controller.driver = chromiumPage            // conforms to BrowserDevToolsEngineDriving
/// controller.perform(.toggle)                 // Cmd-Opt-I
/// // engine events: engineWillOpenDevTools(), engineDidOpenDevTools(docked:), engineDidCloseDevTools()
/// ```
@MainActor
public final class BrowserDevToolsPaneController {
    /// The engine; the page sets itself once created.
    public weak var driver: (any BrowserDevToolsEngineDriving)?
    /// What the tools look like now.
    public private(set) var state: BrowserDevToolsState
    /// The layout the tools use (and open with next).
    public private(set) var layout: BrowserDevToolsLayout
    /// Called after the tools open, close or move; `focused` is whether they take the keyboard.
    public var onStateChange: ((BrowserDevToolsState, _ focused: Bool) -> Void)?
    /// The page title, for the DevTools window title.
    public var pageTitle: () -> String = { "" }
    /// Called after the pane laid out page, divider and tools, with the frames used (engines
    /// whose pages are separate windows cut holes for the divider's grab area).
    public var onLayout: ((BrowserDevToolsLayoutFrames) -> Void)?

    private unowned let paneView: BrowserDevToolsPaneView
    private let store: BrowserDevToolsLayoutStore
    private let makeWindow: (NSWindow?) -> any BrowserDevToolsWindowHosting
    private let makeHostView: () -> NSView
    /// Between the engine's will-open and opened events: the layout keeps room.
    private var opening = false
    /// The docked tools' parent view and the divider, while the engine shows tools in a cmux view.
    private var views: (host: NSView, divider: BrowserDevToolsDividerView)?
    private var window: (any BrowserDevToolsWindowHosting)?

    /// Creates a controller for one page.
    /// - Parameters:
    ///   - paneView: The view that holds the page and the docked tools.
    ///   - store: Remembers dock side and sizes across pages.
    ///   - makeWindow: Makes the window for undocked tools near the given cmux window. Defaults
    ///     to ``BrowserDevToolsWindow``.
    ///   - makeHostView: Makes the view the engine's DevTools attach to. Engines whose pages
    ///     are child windows pass their tracked host view type. Defaults to a plain `NSView`.
    public init(
        paneView: BrowserDevToolsPaneView,
        store: BrowserDevToolsLayoutStore,
        makeWindow: @escaping (NSWindow?) -> any BrowserDevToolsWindowHosting = { BrowserDevToolsWindow(near: $0) },
        makeHostView: @escaping () -> NSView = { NSView() }
    ) {
        self.paneView = paneView
        self.store = store
        self.makeWindow = makeWindow
        self.makeHostView = makeHostView
        let layout = store.load()
        self.layout = layout
        self.state = BrowserDevToolsState(isOpen: false, dock: layout.dock)
        paneView.devTools = self
    }

    // MARK: Commands

    /// Runs a command from a shortcut, menu, the divider menu or automation.
    /// - Parameter command: The command.
    public func perform(_ command: BrowserDevToolsCommand) {
        guard let driver else {
            // No engine to ask (the page is gone): a close still takes the tools' views down.
            if command == .close { tearDown() }
            return
        }
        switch command {
        case .toggle:
            perform(state.isOpen ? .close : .show)
        case .show:
            driver.runDevToolsRequest(.show)
        case .console:
            driver.runDevToolsRequest(.console)
        case .inspectElement:
            driver.runDevToolsRequest(.inspectElement)
        case .inspect(let x, let y):
            driver.runDevToolsRequest(.inspectAt(x: x, y: y))
        case .close:
            driver.runDevToolsRequest(.close)
        case .dock(let dock):
            move(to: dock)
        }
    }

    /// Gives keyboard focus to the open tools, or returns it to the page.
    /// - Parameter focused: `true` to focus the tools.
    public func setFocused(_ focused: Bool) {
        guard state.isOpen else { return }
        driver?.setDevToolsFocused(focused)
    }

    /// Whether `candidate` (a window that became key) is these tools: their own window, or the
    /// engine's child window over the docked area.
    /// - Parameter candidate: The key window.
    /// - Returns: `true` when key focus is on these DevTools.
    public func contains(window candidate: NSWindow) -> Bool {
        guard state.isOpen else { return false }
        if let window, window.contains(candidate) { return true }
        guard state.dock.isDocked, let host = views?.host, let parent = host.window, candidate.parent === parent else {
            return false
        }
        let frame = parent.convertToScreen(host.convert(host.bounds, to: nil))
        return frame.contains(NSPoint(x: candidate.frame.midX, y: candidate.frame.midY))
    }

    /// Closes the tools and drops their views and window; the page is going away.
    public func tearDown() {
        let wasOpen = state.isOpen
        if wasOpen { driver?.runDevToolsRequest(.close) }
        removeViews()
        opening = false
        state.isOpen = false
        if wasOpen { onStateChange?(state, false) }
    }

    private func move(to dock: BrowserDevToolsDock) {
        layout.dock = dock
        store.save(layout)
        guard state.isOpen else {
            state.dock = dock
            onStateChange?(state, false)
            return
        }
        if state.dock.isDocked == dock.isDocked {
            // Between dock sides: the same tools, new frames.
            state.dock = dock
            if let divider = views?.divider {
                divider.needsDisplay = true
                divider.window?.invalidateCursorRects(for: divider)
            }
            paneView.needsLayout = true
            onStateChange?(state, true)
            return
        }
        // Tools in the engine's own window cannot become a cmux child; the next DevTools open
        // with the remembered layout.
        guard views != nil, driver?.supportsEmbeddedDevTools == true else { return }
        state.dock = dock
        dock.isDocked ? dockViews() : undockViews()
        onStateChange?(state, true)
    }

    private func dockViews() {
        guard let views else { return }
        views.host.autoresizingMask = []
        paneView.addSubview(views.host)
        paneView.addSubview(views.divider)
        closeWindow()
        paneView.needsLayout = true
    }

    private func undockViews() {
        guard let views else { return }
        let window = self.window ?? openWindow()
        views.divider.removeFromSuperview()
        window.adopt(views.host)
        window.show()
        paneView.needsLayout = true
    }

    private func openWindow() -> any BrowserDevToolsWindowHosting {
        let window = makeWindow(paneView.window)
        window.title = BrowserDevToolsWindow.title(forPage: pageTitle())
        window.onClose = { [weak self] in self?.perform(.close) }
        self.window = window
        return window
    }

    private func closeWindow() {
        guard let window else { return }
        self.window = nil
        window.onClose = nil
        window.dismiss()
    }

    // MARK: Engine events

    /// The engine is about to create DevTools for this page (any path: shortcut, the engine's
    /// own command, the context menu's Inspect). Decides their place now; the engine reads it
    /// when this returns.
    public func engineWillOpenDevTools() {
        guard let driver else { return }
        opening = true
        if paneView.window != nil, driver.supportsEmbeddedDevTools {
            let views = self.views ?? makeViews()
            paneView.needsLayout = true
            paneView.layoutSubtreeIfNeeded()
            if views.host.bounds.isEmpty { views.host.frame = paneView.bounds }
            let size = views.host.bounds.size
            driver.setDevToolsPlacement(.inView(views.host, size: CGSize(width: max(size.width, 1), height: max(size.height, 1))))
        } else {
            opening = false
            removeViews()
            driver.setDevToolsPlacement(.ownWindow(Self.undockedFrame(near: paneView.window)))
        }
    }

    /// The engine created DevTools.
    /// - Parameter docked: Whether they are a child of the cmux host view (else the engine's own
    ///   window).
    public func engineDidOpenDevTools(docked: Bool) {
        opening = false
        state = BrowserDevToolsState(isOpen: true, dock: docked ? layout.dock : .window)
        if docked, !layout.dock.isDocked { undockViews() }
        // The engine put DevTools in its own window after all: keep no empty docked area.
        if !docked { removeViews() }
        paneView.needsLayout = true
        onStateChange?(state, true)
    }

    /// The engine closed DevTools (any path).
    public func engineDidCloseDevTools() {
        opening = false
        state = BrowserDevToolsState(isOpen: false, dock: layout.dock)
        removeViews()
        paneView.needsLayout = true
        onStateChange?(state, false)
    }

    /// The user picked a dock side in the DevTools frontend menu (cmux fork dock-side event).
    /// - Parameter forkSide: The fork's side value.
    public func engineDidChooseDockSide(_ forkSide: Int) {
        guard state.isOpen, let dock = BrowserDevToolsDock(forkSide: forkSide), dock != state.dock else { return }
        perform(.dock(dock))
    }

    /// Where undocked DevTools open: over the cmux window, inset by 40 points, in Chromium screen
    /// coordinates (top-left origin of the primary screen); `.zero` lets the engine choose.
    /// - Parameter window: The cmux window the page shows in.
    /// - Returns: The frame.
    public static func undockedFrame(near window: NSWindow?) -> CGRect {
        guard let window, let primary = NSScreen.screens.first else { return .zero }
        let frame = window.frame.insetBy(dx: 40, dy: 40)
        guard frame.width >= 400, frame.height >= 300 else { return .zero }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: Layout (BrowserDevToolsPaneView)

    /// The view the engine's DevTools attach to, while open (in the pane or the DevTools window).
    public var devToolsHostView: NSView? { views?.host }

    /// Whether the pane keeps room for docked tools.
    var reservesRoom: Bool {
        views != nil && layout.dock.isDocked && (state.isOpen || opening)
    }

    /// The frames for the pane's bounds.
    /// - Parameter bounds: The pane view's bounds.
    /// - Returns: The page, tools, line and grab frames.
    public func frames(in bounds: CGRect) -> BrowserDevToolsLayoutFrames {
        layout.frames(in: bounds, devToolsDocked: reservesRoom)
    }

    func applyLayout(_ frames: BrowserDevToolsLayoutFrames) {
        if let views, views.host.superview === paneView {
            views.host.frame = frames.devTools
            views.divider.frame = frames.grab
            views.divider.isHidden = frames.grab.isEmpty
        }
        onLayout?(frames)
    }

    func dragDivider(to point: CGPoint) {
        layout.dragDivider(to: point, in: paneView.bounds)
        paneView.needsLayout = true
        paneView.layoutSubtreeIfNeeded()
    }

    func finishDividerDrag() {
        store.save(layout)
    }

    private func makeViews() -> (host: NSView, divider: BrowserDevToolsDividerView) {
        let host = makeHostView()
        host.setAccessibilityIdentifier("browser.devtools.host")
        let divider = BrowserDevToolsDividerView()
        divider.controller = self
        paneView.addSubview(host)
        paneView.addSubview(divider)
        views = (host, divider)
        return (host, divider)
    }

    private func removeViews() {
        closeWindow()
        guard let views else { return }
        self.views = nil
        views.divider.removeFromSuperview()
        views.host.removeFromSuperview()
    }
}
