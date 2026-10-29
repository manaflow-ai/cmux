import AppKit

/// DevTools of one Chromium tab: docked below or beside
/// the page inside the pane, resizable, or in its own window. The docked
/// DevTools is a Chromium child window over `views.host`, a subview of the
/// tab's content view, so it follows the pane's layout, clipping and moves
/// like the page. Where the fork hosts or attaches DevTools
/// its pixels show in `views.host`'s layers, or its Chromium view is a subview of it,
/// as a pane's page. In host mode it is a hosted context shown in
/// a page view inside `views.host` instead (`CEFDevToolsController+Hosted.swift`).
/// DevTools browsers have their own shim client: they never
/// become tabs and never change the tab's URL or title.
///
/// Owns the DevTools placement state (layout, views, window, open/close
/// sequencing). The tab keeps the observable `devTools` state, which only
/// this controller writes.
@MainActor
final class CEFDevToolsController {
    weak var tab: CEFTab?
    var layout: CEFDevToolsLayout
    /// The DevTools browser, while open.
    var devToolsBrowserID: Int32?
    /// Between `DEVTOOLS_WILL_OPEN` and `OPENED`: the layout keeps room.
    var opening = false
    /// Runs once DevTools closed (a move into or out of a window reopens).
    var afterClose: BrowserDevToolsCommand?
    /// The docked DevTools' parent view and the divider, while docked.
    var views: (host: CEFHostView, divider: CEFDevToolsDivider)?
    /// The window that holds `views.host` while DevTools is not docked.
    var window: CEFDevToolsWindow?
    /// DevTools device mode (fork API 24): the device's screen area the
    /// frontend asks for, DIPs from the DevTools view's top-left corner.
    /// While set, docked DevTools cover the whole content view (device
    /// toolbar, rulers, the panels) and the page sits in this area, as in
    /// Chrome's docked DevTools.
    private(set) var deviceModeBounds: CGRect?
    /// Host mode: the view the DevTools page shows in, at the bottom of `views.host`. Kept while
    /// the tab lives, so its wire token names the same view of the host at every open.
    var hostedPage: ChromiumHostPageView?
    /// Host mode: the inspected browser the host holds a standing placement for. Every DevTools of
    /// it goes in ``hostedPage``, Chromium's own opens too; only a new browser of the tab places again.
    var hostedPlacement: Int32?
    /// Host mode: the opens and closes cmux sent the host that it has not answered yet.
    var hostedRequests = CEFHostedDevToolsRequests()
    /// Host mode: the open under way is the reopen of one that opened unplaced (``closeUnplaced``).
    var reopeningUnplaced = false

    init(layout: CEFDevToolsLayout) {
        self.layout = layout
    }

    // MARK: Commands

    func perform(_ command: BrowserDevToolsCommand) {
        guard let tab, !tab.isClosed, let browserID = tab.browserID, let shim = tab.runtime.shim else { return }
        if tab.host.isHostMode, Self.mayCreateDevTools(command) {
            placeHosted(in: tab)
            hostedOpenSent(command, browser: browserID)
        }
        switch command {
        case .toggle:
            perform(isOpenOrRequested ? .close : .show)
        case .show:
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.show, 0, 0)
        case .console:
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.console, 0, 0)
        case .inspectElement:
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.inspect, 0, 0)
        case .close:
            afterClose = nil
            reopeningUnplaced = false
            if tab.host.isHostMode, isOpenOrRequested { hostedRequests.sent(.close, browser: browserID) }
            _ = shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.close, 0, 0)
        case .dock(let dock):
            move(to: dock)
        case .panel(let panel):
            _ = shim.devToolsShowPanel(browserID, panel.chromiumID)
        }
    }

    /// Whether DevTools is open once every change cmux sent is done: Cmd-Opt-I toggles from it. In host
    /// mode that is the state the host reaches after answering the changes in flight
    /// (``hostedRequests``), so a second press before the host's answer closes the DevTools the first
    /// asked for; in process Chromium answers in the command's own turn.
    var isOpenOrRequested: Bool {
        guard let tab else { return false }
        guard tab.host.isHostMode, let browser = tab.browserID else { return tab.devTools.isOpen }
        return hostedRequests.expectsOpen(browser: browser) ?? tab.devTools.isOpen
    }

    func setFocused(_ focused: Bool) {
        guard let tab, let browserID = tab.browserID, tab.devTools.isOpen else { return }
        tab.runtime.shim?.devToolsSetFocus(browserID, focused ? 1 : 0)
    }

    func contains(window candidate: NSWindow) -> Bool {
        guard let tab, tab.devTools.isOpen, let host = views?.host, let parent = host.window,
              candidate.parent === parent else { return false }
        if parent === window { return true }
        guard tab.devTools.dock.isDocked else { return false }
        let frame = parent.convertToScreen(host.convert(host.bounds, to: nil))
        return frame.contains(NSPoint(x: candidate.frame.midX, y: candidate.frame.midY))
    }

    /// Moves DevTools to `dock`. Every move keeps the same DevTools (its
    /// view is reparented between the pane and `window`), except with a
    /// fork that cannot embed DevTools, where a window means Chromium's own
    /// window and a move into or out of it reopens DevTools.
    private func move(to dock: BrowserDevToolsDock) {
        guard let tab else { return }
        let wasDocked = layout.dock.isDocked
        layout.dock = dock
        rememberLayout()
        guard tab.devTools.isOpen else {
            tab.devTools.dock = dock
            refreshHostedPlacement(in: tab)
            return
        }
        if wasDocked == dock.isDocked {
            // Between dock sides: the same DevTools window, a new frame.
            tab.devTools.dock = dock
            views?.divider.needsDisplay = true
            tab.container.layoutContent()
            return
        }
        if views != nil, tab.runtime.supportsEmbeddedDevTools {
            tab.devTools.dock = dock
            dock.isDocked ? dockViews() : undockViews()
            tab.devToolsObserver?.browserTab(tab, devToolsDidChange: tab.devTools, focused: true)
            return
        }
        // Chromium's own DevTools window cannot become a child window (or the
        // reverse): reopen DevTools in its new place.
        afterClose = .show
        if let browserID = tab.browserID {
            if tab.host.isHostMode, isOpenOrRequested { hostedRequests.sent(.close, browser: browserID) }
            _ = tab.runtime.shim?.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.close, 0, 0)
        }
    }

    /// The DevTools view leaves its window for the pane.
    private func dockViews() {
        guard let tab, let views else { return }
        views.host.autoresizingMask = []
        tab.container.addSubview(views.host)
        tab.container.addSubview(views.divider)
        closeWindow()
        tab.container.layoutContent()
    }

    /// The DevTools view leaves the pane for its own window.
    private func undockViews() {
        guard let tab, let views else { return }
        let window = window ?? makeWindow(for: tab)
        views.divider.removeFromSuperview()
        window.adopt(views.host)
        window.orderFront(nil)
        tab.container.layoutContent()
    }

    private func makeWindow(for tab: CEFTab) -> CEFDevToolsWindow {
        let window = CEFDevToolsWindow(frame: CEFDevToolsWindow.frame(near: tab.container.window), owner: tab.container.window,
                                       pageSurface: tab.pageSurface)
        window.title = Strings.devToolsWindowTitle(tab.state.title)
        window.onClose = { [weak self] in self?.perform(.close) }
        self.window = window
        return window
    }

    private func closeWindow() {
        guard let window else { return }
        self.window = nil
        window.onClose = nil
        window.orderOut(nil)
    }

    // MARK: Shim events (CEFRuntime)

    /// Chromium is about to create DevTools for this page (any path:
    /// shortcut, Chromium command, context menu Inspect). Decides its place
    /// now; the shim reads it when this returns. In host mode Chromium did
    /// not wait: the place was given before (`placeHosted`).
    func willOpen() {
        guard let tab, let browserID = tab.browserID, let shim = tab.runtime.shim else { return }
        opening = true
        if tab.host.isHostMode { return hostedWillOpen(in: tab) }
        if tab.container.window != nil, tab.runtime.supportsEmbeddedDevTools {
            // Docked or in its own window, DevTools is a child of a cmux
            // view, so a later move keeps it alive.
            // Chromium creates DevTools synchronously over a view in the
            // page's window; a window of its own takes the same view after
            // DEVTOOLS_OPENED (opened), like a later move does.
            let views = views ?? makeViews(in: tab)
            tab.container.layoutContent()
            if views.host.bounds.isEmpty { views.host.frame = tab.container.bounds }
            let size = views.host.bounds.size
            shim.devToolsSetPlacement(browserID, CEFParentView(view: views.host), 0, 0,
                                      Int32(max(size.width, 1)), Int32(max(size.height, 1)))
        } else {
            opening = false
            removeViews()
            let frame = Self.undockedFrame(near: tab.container.window)
            shim.devToolsSetPlacement(browserID, nil, Int32(frame.minX), Int32(frame.minY),
                                      Int32(frame.width), Int32(frame.height))
        }
    }

    /// Where an undocked DevTools window opens: over the cmux window, inset,
    /// in Chromium's screen coordinates (top-left origin of the primary
    /// screen). Zero (Chromium's default) without a window.
    static func undockedFrame(near window: NSWindow?) -> CGRect {
        guard let window, let primary = NSScreen.screens.first else { return .zero }
        let frame = window.frame.insetBy(dx: 40, dy: 40)
        guard frame.width >= 400, frame.height >= 300 else { return .zero }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    func opened(browser: Int32, docked: Bool) {
        guard let tab else { return }
        opening = false
        devToolsBrowserID = browser
        if tab.host.isHostMode, let inspected = tab.browserID {
            let answer = hostedRequests.opened(browser: inspected)
            let reopened = reopeningUnplaced
            reopeningUnplaced = false
            // A close cmux sent after this open is on the wire: it closes this DevTools before it shows.
            if answer.closing { return }
            // `docked`: the shim had the placement's view when it made this DevTools (PrepareDevToolsPopup).
            if !docked { return closeUnplaced(in: tab, reopen: reopened ? nil : answer.command ?? .show) }
        }
        // `docked` = a child of a cmux view (the pane's DevTools host).
        tab.devTools = BrowserDevToolsState(isOpen: true, dock: docked ? layout.dock : .window)
        if docked, !layout.dock.isDocked { undockViews() }
        tab.container.layoutContent()
        // An embedded DevTools is its own page window on its own host view, docked in the pane or in cmux's
        // DevTools window: attached or hosted there as a pane's page is where the fork does it for DevTools
        // (`CEFLayerHosting.Widget.devTools`, ``CEFLayerHosting/Fork/hostedWidgets``; the benches' arm
        // `cefLayerHostingEveryPage` hosts it on any fork), from this open on. Its view keeps the attached view
        // or hosted context across dock moves. In host mode it shows in the hosted page view, from the context
        // the host gives.
        if docked, tab.host.isHostMode {
            showHostedContext(of: browser)
        } else if docked {
            views?.host.layerHosting.pageWindowCreated(browser: browser, fork: CEFLayerHosting.Fork(runtime: tab.runtime))
        }
        tab.devToolsObserver?.browserTab(tab, devToolsDidChange: tab.devTools, focused: true)
    }

    func closed(browser: Int32) {
        guard let tab, devToolsBrowserID == nil || devToolsBrowserID == browser else { return }
        opening = false
        if tab.host.isHostMode, let inspected = tab.browserID { hostedRequests.closed(browser: inspected) }
        // The frontend's DevTools session ended with its emulation: cmux's own applies again.
        if deviceModeBounds != nil {
            deviceModeBounds = nil
            tab.devToolsDeviceModeEnded()
        }
        devToolsBrowserID = nil
        // The placement stands for the next open (its size may have changed while this one was open).
        hostedPage?.show(contextID: 0)
        refreshHostedPlacement(in: tab)
        tab.devTools = BrowserDevToolsState(isOpen: false, dock: layout.dock)
        removeViews()
        tab.container.layoutContent()
        tab.devToolsObserver?.browserTab(tab, devToolsDidChange: tab.devTools, focused: false)
        if let next = afterClose {
            afterClose = nil
            perform(next)
        }
    }

    /// The DevTools menu's dock side for a fork side value (0 undocked,
    /// 1 left, 2 bottom, 3 right); nil for a side cmux panes do not offer.
    nonisolated static func dock(forkSide value: Int) -> BrowserDevToolsDock? {
        switch value {
        case 0: .window
        case 1: .left
        case 2: .bottom
        case 3: .right
        default: nil
        }
    }

    /// Chromium reported a dock-side choice from the DevTools frontend menu
    /// (`CMUX_DEVTOOLS_DOCK_SIDE`, fork API v5). Chromium leaves its DevTools
    /// window alone; this moves the same DevTools view through the pane's
    /// dock command (bottom and right keep the frontend's state).
    func dockSideChosen(_ value: Int) {
        guard let tab, tab.devTools.isOpen, let dock = Self.dock(forkSide: value), dock != tab.devTools.dock else { return }
        perform(.dock(dock))
    }

    /// The frontend turned device mode on or off or moved the device's
    /// screen area (`CMUX_DEVTOOLS_DEVICE_MODE`). The page follows it, and
    /// cmux's own emulation of the tab yields to the frontend's until it ends.
    func deviceModeChanged(on: Bool) {
        guard let tab, let browserID = tab.browserID, let shim = tab.runtime.shim else { return }
        let read = on ? shim.devToolsInspectedBounds(browserID) : CEFShimBounds()
        let bounds = read.result == 1
            ? CGRect(x: CGFloat(read.x), y: CGFloat(read.y), width: CGFloat(read.width), height: CGFloat(read.height)) : nil
        let wasOn = deviceModeBounds != nil
        guard bounds != deviceModeBounds else { return }
        deviceModeBounds = bounds
        if !wasOn, bounds != nil { tab.devToolsDeviceModeStarted() }
        tab.container.layoutContent()
        if wasOn, bounds == nil { tab.devToolsDeviceModeEnded() }
    }

    /// Whether the DevTools frontend's device mode owns the page's emulation:
    /// docked or not, cmux's own emulation (a device or a fit) yields to it.
    var deviceModeOn: Bool { deviceModeBounds != nil }

    /// Whether the page is placed in the device's screen area (docked DevTools only).
    var deviceModeActive: Bool { deviceModeBounds != nil && reservesRoom }

    // MARK: Layout

    /// Whether the content view reserves room for docked DevTools.
    var reservesRoom: Bool {
        views != nil && layout.dock.isDocked && ((tab?.devTools.isOpen ?? false) || opening)
    }

    func frames(in bounds: CGRect) -> CEFDevToolsLayout.Frames {
        guard let area = deviceModeBounds, reservesRoom else { return layout.frames(in: bounds, devToolsDocked: reservesRoom) }
        return Self.deviceModeFrames(in: bounds, area: area)
    }

    /// Device mode: DevTools take `bounds`, the page the frontend's area
    /// (top-left origin) converted to the content view's bottom-left origin.
    nonisolated static func deviceModeFrames(in bounds: CGRect, area: CGRect) -> CEFDevToolsLayout.Frames {
        // The page keeps the device's full screen area, as in Chrome: its widget size is the
        // emulated viewport (the frontend sets dontSetVisibleSize). A part past the pane is masked
        // by the fork's clip, never cut from the page (cutting gave innerHeight 428 for 430).
        let page = CGRect(x: bounds.minX + area.minX, y: bounds.maxY - area.minY - area.height, width: area.width, height: area.height)
        return CEFDevToolsLayout.Frames(page: page, devTools: bounds, line: .zero, grab: .zero)
    }

    func dragDivider(to point: CGPoint) {
        guard let tab else { return }
        layout.dragDivider(to: point, in: tab.container.bounds)
        tab.container.layoutContent()
    }

    func rememberLayout() {
        CEFDevToolsLayout.remember(layout)
    }

    func makeViews(in tab: CEFTab) -> (host: CEFHostView, divider: CEFDevToolsDivider) {
        let host = CEFHostView()
        host.layerHosting.widget = .devTools
        // Docked DevTools shows with its page's tab (`CEFTab.setContentVisible`); hidden, it joins no resize fence.
        host.layerHosting.isPageVisible = { [weak tab] in tab.map { !$0.isContentHidden } ?? false }
        // A hidden DevTools keeps its last frame in the app-wide list, as a hidden tab's page does.
        host.layerHosting.switchCommit.hiddenFrames = tab.runtime.hiddenFrames
        if tab.host.isHostMode { installHostedPage(for: tab, in: host) }
        let divider = CEFDevToolsDivider()
        divider.devTools = self
        divider.onMove = { [weak self] point in self?.dragDivider(to: point) }
        divider.pointerFrames = tab.runtime.pointerFrames
        tab.container.addSubview(host)
        tab.container.addSubview(divider)
        views = (host, divider)
        // Host mode: the DevTools frontend is a widget context filling this view, docked in the pane or
        // in cmux's DevTools window, as the view moves (dockViews, undockViews).
        if let browserID = tab.browserID { tab.runtime.widgetHost?.place(.devTools, owner: browserID, in: host) }
        return (host, divider)
    }

    func removeViews() {
        closeWindow()
        guard let views else { return }
        self.views = nil
        if let tab, let browserID = tab.browserID { tab.runtime.widgetHost?.place(.devTools, owner: browserID, in: nil) }
        views.host.layerHosting.stop()
        views.divider.removeFromSuperview()
        views.host.removeFromSuperview()
    }

    /// Screen frames of the page area and the docked DevTools area (nil
    /// when not in a window), for `debug.cef`.
    var diagnosticFrames: (page: CGRect, devTools: CGRect?)? {
        guard let tab, let window = tab.container.window else { return nil }
        let frames = frames(in: tab.container.bounds)
        let screen = { (rect: CGRect) in window.convertToScreen(tab.container.convert(rect, to: nil)) }
        return (screen(frames.page), frames.devTools.isEmpty ? nil : screen(frames.devTools))
    }
}
