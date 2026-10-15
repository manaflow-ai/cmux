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
    private let makeWindow: (NSWindow?, CGRect?) -> any BrowserDevToolsWindowHosting
    private let makeHostView: () -> NSView
    /// Between the engine's will-open and opened events: the layout keeps room.
    private var opening = false
    /// The DevTools frontend reports its own saved dock side once when it loads (Chrome's
    /// default is right); the pane's remembered layout wins over that first report.
    private var awaitsFrontendDockReport = false
    /// The docked tools' parent view and the divider, while the engine shows tools in a cmux view.
    private var views: (host: NSView, divider: BrowserDevToolsDividerView)?
    private var window: (any BrowserDevToolsWindowHosting)?

    /// Creates a controller for one page.
    /// - Parameters:
    ///   - paneView: The view that holds the page and the docked tools.
    ///   - store: Remembers dock side and sizes across pages.
    ///   - makeWindow: Makes the window for undocked tools near the given cmux window, at the
    ///     remembered frame when there is one. Defaults to ``BrowserDevToolsWindow``.
    ///   - makeHostView: Makes the view the engine's DevTools attach to. Engines whose pages
    ///     are child windows pass their tracked host view type. Defaults to a plain `NSView`.
    public init(
        paneView: BrowserDevToolsPaneView,
        store: BrowserDevToolsLayoutStore,
        makeWindow: @escaping (NSWindow?, CGRect?) -> any BrowserDevToolsWindowHosting = {
            BrowserDevToolsWindow(near: $0, remembered: $1)
        },
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

    /// The Toggle Developer Tools shortcut the dock menu shows on its Close row.
    public private(set) var closeShortcut: BrowserDevToolsMenuShortcut?

    /// Applies the app's settings: the divider follows the pane divider thickness, and the dock
    /// menu shows the toggle shortcut.
    /// - Parameters:
    ///   - dividerThickness: The pane divider thickness setting (0 to 12 points).
    ///   - closeShortcut: The Toggle Developer Tools shortcut, if it has a menu key equivalent.
    public func configure(dividerThickness: CGFloat, closeShortcut: BrowserDevToolsMenuShortcut?) {
        self.closeShortcut = closeShortcut
        let thickness = BrowserDevToolsLayout.resolvedLineThickness(dividerThickness)
        guard thickness != layout.lineThickness else { return }
        layout.lineThickness = thickness
        views?.divider.needsDisplay = true
        paneView.needsLayout = true
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
        let window = makeWindow(paneView.window, store.loadWindowFrame())
        window.onFrameChange = { [weak self] frame in self?.store.saveWindowFrame(frame) }
        window.title = BrowserDevToolsWindow.title(forPage: pageTitle())
        window.onClose = { [weak self] in self?.perform(.close) }
        self.window = window
        return window
    }

    private func closeWindow() {
        guard let window else { return }
        self.window = nil
        window.onClose = nil
        window.onFrameChange = nil
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
            driver.setDevToolsPlacement(.ownWindow(Self.undockedFrame(near: paneView.window, remembered: store.loadWindowFrame())))
        }
    }

    /// The engine created DevTools.
    /// - Parameter docked: Whether they are a child of the cmux host view (else the engine's own
    ///   window).
    public func engineDidOpenDevTools(docked: Bool) {
        opening = false
        awaitsFrontendDockReport = true
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
        guard state.isOpen else { return }
        if awaitsFrontendDockReport {
            // The frontend's restored preference, not a choice: keep the pane's layout.
            awaitsFrontendDockReport = false
            return
        }
        guard let dock = BrowserDevToolsDock(forkSide: forkSide), dock != state.dock else { return }
        perform(.dock(dock))
    }

    /// Where the engine's own DevTools window opens, by the same rule as
    /// ``BrowserDevToolsWindow`` (beside the cmux window, or the remembered frame), in Chromium
    /// screen coordinates (top-left origin of the primary screen); `.zero` lets the engine choose.
    /// - Parameters:
    ///   - window: The cmux window the page shows in.
    ///   - remembered: The frame the user last left the DevTools window at.
    /// - Returns: The frame.
    public static func undockedFrame(near window: NSWindow?, remembered: CGRect? = nil) -> CGRect {
        guard let window, let primary = NSScreen.screens.first else { return .zero }
        let frame = BrowserDevToolsWindow.frame(near: window, remembered: remembered)
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

    /// Grows the docked tools by `points` (negative shrinks them) and remembers the size.
    func resizeDevTools(by points: CGFloat) {
        layout.resizeDevTools(by: points, in: paneView.bounds)
        store.save(layout)
        paneView.needsLayout = true
        paneView.layoutSubtreeIfNeeded()
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
