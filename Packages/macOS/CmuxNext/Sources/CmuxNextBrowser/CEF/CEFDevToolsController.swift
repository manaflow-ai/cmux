import AppKit
import CmuxNextWakeups

/// DevTools of one Chromium tab: docked below or beside
/// the page inside the pane, resizable, or in its own window. The docked
/// DevTools is a Chromium child window over `views.host`, a subview of the
/// tab's content view, so it follows the pane's layout, clipping and moves
/// like the page. DevTools browsers have their own shim client: they never
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
    /// From the open key's turn until Chromium's `DEVTOOLS_WILL_OPEN`: the docked layout shows with the pane's
    /// ground in the DevTools area while Chromium has not been asked yet (`openWithStandIn`).
    private(set) var standIn = false
    /// Which stand-in the pending after-commit ask belongs to: a cancel or a newer stand-in makes an older ask stale.
    private var standInGeneration = 0
    /// From the close key's turn until Chromium's `DEVTOOLS_CLOSED`: the DevTools area is hidden and the page has its
    /// whole frame while Chromium still tears the DevTools browser down (`closeInThisTurn`).
    private(set) var closing = false
    /// The DevTools cmux closed while Chromium began a new one (`willOpen` during `closing`): its late
    /// `DEVTOOLS_CLOSED` only retires it and never removes the new DevTools' views.
    private var retiredBrowserID: Int32?
    /// The bounded wait for `DEVTOOLS_OPENED` after `DEVTOOLS_WILL_OPEN` (`openedLimit`).
    var openTimer = DemandTimer(owner: "CEFDevToolsController.opened")
    /// How long a DevTools Chromium began may take to report it opened before its room is given back.
    static let openedLimit: Duration = .seconds(5)
    /// Chromium was given `views.host` as a DevTools parent and never reported it opened or closed: the shim keeps that
    /// (unretained) view, so it stays alive, hidden when unused, until OPENED or CLOSED.
    private var hostHeldByChromium = false
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

    init(layout: CEFDevToolsLayout) {
        self.layout = layout
    }

    // MARK: Commands

    func perform(_ command: BrowserDevToolsCommand) {
        guard let tab, !tab.isClosed, let browserID = tab.browserID, let shim = tab.runtime.shim else { return }
        switch command {
        case .toggle:
            perform(tab.devTools.isOpen || standIn || (closing && afterClose != nil) ? .close : .show)
        case .show, .console, .inspectElement:
            // Chromium still has the closing DevTools (its show would only focus it): the open goes after it closed.
            if closing { afterClose = command; return }
            let id = switch command {
            case .console: CEFShimLibrary.DevToolsCommand.console
            case .inspectElement: CEFShimLibrary.DevToolsCommand.inspect
            default: CEFShimLibrary.DevToolsCommand.show
            }
            openWithStandIn(id)
        case .close:
            afterClose = nil
            if standIn { return cancelStandIn() }
            if closing { return }
            closeInThisTurn()
            // A page Chromium no longer has sends no DEVTOOLS_CLOSED: the close ends here.
            if shim.devToolsCommand(browserID, CEFShimLibrary.DevToolsCommand.close, 0, 0) == 0, closing {
                closed(browser: devToolsBrowserID ?? 0)
            }
        case .dock(let dock):
            move(to: dock)
        case .panel(let panel):
            // The closing DevTools would take the panel and stay closed: the panel opens after it closed.
            if closing { afterClose = command; return }
            _ = shim.devToolsShowPanel(browserID, panel.chromiumID)
        }
    }

    /// Opens DevTools as every create in cmux opens (PATTERNS.md P4, instant create). Chromium creates DevTools inside
    /// the command, on this thread, before `DEVTOOLS_WILL_OPEN` gives it its place (CefBrowserHost::ShowDevTools, about
    /// 18 ms); asked in the key's turn, the turn and its frame waited for that creation (BROWSER VIDEO F3: the first
    /// changed frame 5-9 refreshes after the key). So the key's turn only lays out the stand-in (the page at its docked
    /// frame, the DevTools area on the pane's themed ground: the view Chromium's DevTools window goes over), and the run
    /// loop commits that frame as it commits every turn's; Chromium is asked after that commit (`AfterFrameCommit`), as
    /// Chrome commits the frame an input changed before longer work. A main-actor `Task` is not "after": it runs from
    /// the main queue in the key's own pass, before the commit (#32911: ShowDevTools was inside the key's commit,
    /// commit_ms 43 ms p50). `willOpen` takes the stand-in's views; when Chromium opens nothing, the stand-in rolls back.
    /// DevTools open, opening, undocked, or not in a window: the command goes at once, as before.
    private func openWithStandIn(_ command: Int32) {
        guard let tab, let browserID = tab.browserID, let shim = tab.runtime.shim, !standIn else { return }
        // A parked tab (hidden in its pane) has no frame to show early: its open goes at once, to its own browser.
        let shown = tab.container.window != nil && tab.host.visibleTab === tab && !tab.container.isHiddenOrHasHiddenAncestor
        guard !tab.devTools.isOpen, !opening, layout.dock.isDocked, shown, tab.runtime.supportsEmbeddedDevTools else {
            // Console and Inspect are Chromium commands on the pane's active Chromium tab (`ExecuteChromeCommand`): for a
            // tab not shown that is another page. Its own DevTools opens on that panel instead (the shim targets the browser).
            if !shown, let panel = Self.panel(of: command) { _ = shim.devToolsShowPanel(browserID, panel); return }
            _ = shim.devToolsCommand(browserID, command, 0, 0)
            return
        }
        if views == nil { _ = makeViews(in: tab) }
        showViews()
        opening = true
        standIn = true
        standInGeneration &+= 1
        let generation = standInGeneration
        tab.container.layoutContent()
        AfterFrameCommit().run { [weak self] in self?.askChromium(command, generation: generation) }
    }

    /// The DevTools panel a Chromium command opens on (console, inspect), for a tab that is not the shown one.
    static func panel(of command: Int32) -> String? {
        switch command {
        case CEFShimLibrary.DevToolsCommand.console: WebDevToolsPanel.console.chromiumID
        case CEFShimLibrary.DevToolsCommand.inspect: WebDevToolsPanel.elements.chromiumID
        default: nil
        }
    }

    /// After the stand-in's frame committed: Chromium creates DevTools (`willOpen` ends the stand-in) or opens nothing.
    /// Only the stand-in's own ask runs (`generation`), and only while its tab is still the one shown in a window:
    /// console and inspect act on the pane's active Chromium tab (`ExecuteChromeCommand`), so after a tab switch
    /// between the key's turn and the ask they would open DevTools on another page. Otherwise the stand-in rolls back.
    private func askChromium(_ command: Int32, generation: Int) {
        guard standIn, generation == standInGeneration else { return }
        guard let tab, !tab.isClosed, let browserID = tab.browserID, let shim = tab.runtime.shim,
              tab.host.visibleTab === tab, tab.container.window != nil, !tab.container.isHiddenOrHasHiddenAncestor else {
            return cancelStandIn()
        }
        _ = shim.devToolsCommand(browserID, command, 0, 0)
        if standIn { cancelStandIn() }
    }

    /// Closes as Chrome closes docked DevTools: the key's turn hides the DevTools area (the fork's tracker hides the
    /// DevTools page window with its parent view) and lays the page out at its whole frame; Chromium's close, which
    /// ends turns later in `DEVTOOLS_CLOSED` (BROWSER VIDEO F5: 3-6 refreshes with DevTools still on screen), then only
    /// frees the views. The tab's DevTools state is closed in this turn, so focus returns to the page now. DevTools in
    /// Chromium's own window (no cmux views) close through Chromium alone, as before.
    private func closeInThisTurn() {
        guard let tab, tab.devTools.isOpen, !opening, let views else { return }
        closing = true
        views.host.isHidden = true
        views.divider.isHidden = true
        // Only ordered out: this can run inside the window's own close action; `removeViews` releases it.
        window?.orderOut(nil)
        tab.devTools = BrowserDevToolsState(isOpen: false, dock: layout.dock)
        tab.container.layoutContent()
        tab.devToolsObserver?.browserTab(tab, devToolsDidChange: tab.devTools, focused: false)
    }

    /// Chromium opened DevTools (the page's Inspect, a Chromium command) while cmux's close still waited for
    /// `DEVTOOLS_CLOSED`: the new DevTools takes the views, shown, and the older close's event no longer matches.
    private func endClosingForNewDevTools() {
        guard closing else { return }
        closing = false
        // The older session's device mode ended with it (its DEVTOOLS_CLOSED, now retired, would have ended it): the new
        // DevTools gets its docked frame, and the tab's own emulation applies again.
        if deviceModeBounds != nil {
            deviceModeBounds = nil
            tab?.devToolsDeviceModeEnded()
        }
        // The closing DevTools' late event retires it only. The new DevTools is the open a waiting open asked for: a
        // plain open is done; a console or panel the person asked for applies to it once it opened (`opened`).
        retiredBrowserID = devToolsBrowserID
        devToolsBrowserID = nil
        if afterClose == .show || afterClose == .toggle { afterClose = nil }
        views?.host.isHidden = false
        views?.divider.isHidden = false
    }

    /// `openedLimit` passed after `DEVTOOLS_WILL_OPEN` with no `DEVTOOLS_OPENED`: the creation failed. The page gets its
    /// whole frame back. The views stay, hidden: Chromium was given the host view (unretained) as its parent, so a late
    /// OPENED still finds it; the next open or that OPENED shows them again (`showViews`).
    private func openNeverReported() {
        guard opening, !standIn, let tab, !tab.isClosed, !tab.devTools.isOpen, views != nil else { return }
        opening = false
        hideViews()
        tab.container.layoutContent()
    }

    private func hideViews() {
        views?.host.isHidden = true
        views?.divider.isHidden = true
    }

    /// Shows views an unreported open hid (`openNeverReported`).
    private func showViews() {
        views?.host.isHidden = false
        views?.divider.isHidden = false
    }

    /// The page gets its whole frame back and the stand-in's views go.
    private func cancelStandIn() {
        guard standIn else { return }
        standIn = false
        opening = false
        if hostHeldByChromium { hideViews() } else { removeViews() }
        tab?.container.layoutContent()
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
            return
        }
        if wasDocked == dock.isDocked {
            // Between dock sides: the same DevTools window, a new frame.
            tab.devTools.dock = dock
            views?.divider.needsDisplay = true
            if let divider = views?.divider { divider.window?.invalidateCursorRects(for: divider) }
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
        let window = CEFDevToolsWindow(frame: CEFDevToolsWindow.frame(near: tab.container.window), owner: tab.container.window)
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
    /// now; the shim reads it when this returns.
    func willOpen() {
        guard let tab, let browserID = tab.browserID, let shim = tab.runtime.shim else { return }
        standIn = false
        endClosingForNewDevTools()
        opening = true
        let embedded = tab.container.window != nil && tab.runtime.supportsEmbeddedDevTools
        // The DevTools frontend keeps its own dock side (its profile setting) and applies it when it loads; the fork
        // reports that as a dock-side choice (`dockSideChosen`), which moved a just-opened DevTools from cmux's side
        // to the frontend's (BROWSER VIDEO F2: bottom, then right ~13 refreshes later). As in Chrome, one side counts:
        // cmux's is written into that setting here, before the frontend exists, for every way DevTools opens (cmux's
        // commands, a panel, the page's Inspect, Chromium's own commands).
        _ = shim.devToolsSetFrontendDockSide(browserID, Self.forkSide(of: embedded ? layout.dock : .window))
        if embedded {
            // Docked or in its own window, DevTools is a child of a cmux
            // view, so a later move keeps it alive.
            // Chromium creates DevTools synchronously over a view in the
            // page's window; a window of its own takes the same view after
            // DEVTOOLS_OPENED (opened), like a later move does.
            let views = views ?? makeViews(in: tab)
            showViews()
            tab.container.layoutContent()
            if views.host.bounds.isEmpty { views.host.frame = tab.container.bounds }
            // Until its frontend draws, DevTools shows its browser's background: the pane's theme color, as every
            // page of the pane starts with (`CEFPaneHost`), never the color CEF started with (BROWSER VIDEO F1).
            shim.devToolsSetBackground(browserID, PageBackground.themeARGB(in: views.host))
            let size = views.host.bounds.size
            shim.devToolsSetPlacement(browserID, Unmanaged.passUnretained(views.host).toOpaque(), 0, 0,
                                      Int32(max(size.width, 1)), Int32(max(size.height, 1)))
            hostHeldByChromium = true
            // A creation that fails sends no OPENED: the room it reserved stayed for good (an empty DevTools area beside
            // a narrowed page). After a bounded wait the room goes back, as a stand-in rolls back.
            openTimer.schedule(after: Self.openedLimit) { @MainActor [weak self] in self?.openNeverReported() }
        } else {
            opening = false
            removeViews()
            let frame = Self.undockedFrame(near: tab.container.window)
            shim.devToolsSetBackground(browserID, PageBackground.themeARGB(in: tab.container))
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
        endClosingForNewDevTools()
        openTimer.cancel()
        hostHeldByChromium = false
        showViews()
        opening = false
        devToolsBrowserID = browser
        // `docked` = a child of a cmux view (the pane's DevTools host).
        tab.devTools = BrowserDevToolsState(isOpen: true, dock: docked ? layout.dock : .window)
        if docked, !layout.dock.isDocked { undockViews() }
        tab.container.layoutContent()
        // A docked DevTools is its own page window on its own host view: hosted in the window's layers
        // too while layer hosting is on (fork API 26), from this open on (a later tunable change applies
        // at the next open).
        if docked {
            views?.host.layerHosting.pageWindowCreated(browser: browser, fork: CEFLayerHosting.Fork(shim: tab.runtime.shim, apiVersion: tab.runtime.forkAPIVersion), follows: tab.runtime.hostingSwitch)
        }
        tab.devToolsObserver?.browserTab(tab, devToolsDidChange: tab.devTools, focused: true)
        // A console or panel asked while the older DevTools closed, opened now by Chromium itself (see `endClosingForNewDevTools`).
        if let next = afterClose, !closing { afterClose = nil; perform(next) }
    }

    func closed(browser: Int32) {
        if browser == retiredBrowserID { retiredBrowserID = nil; return }
        guard let tab, devToolsBrowserID == nil || devToolsBrowserID == browser else { return }
        opening = false
        openTimer.cancel()
        hostHeldByChromium = false
        // Closed by cmux's close (`closeInThisTurn`): the pane and the tab's state already show it closed.
        let shownClosed = closing
        closing = false
        // The frontend's DevTools session ended with its emulation: cmux's own applies again.
        if deviceModeBounds != nil {
            deviceModeBounds = nil
            tab.devToolsDeviceModeEnded()
        }
        devToolsBrowserID = nil
        tab.devTools = BrowserDevToolsState(isOpen: false, dock: layout.dock)
        removeViews()
        tab.container.layoutContent()
        if !shownClosed { tab.devToolsObserver?.browserTab(tab, devToolsDidChange: tab.devTools, focused: false) }
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

    /// The fork's dock-side value of `dock` (the inverse of `dock(forkSide:)`).
    nonisolated static func forkSide(of dock: BrowserDevToolsDock) -> Int32 {
        switch dock {
        case .window: 0
        case .left: 1
        case .bottom: 2
        case .right: 3
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
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        let bounds = on && shim.devToolsInspectedBounds(browserID, &x, &y, &width, &height) == 1
            ? CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)) : nil
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

    private func makeViews(in tab: CEFTab) -> (host: CEFHostView, divider: CEFDevToolsDivider) {
        let host = CEFHostView()
        let divider = CEFDevToolsDivider()
        divider.devTools = self
        tab.container.addSubview(host)
        tab.container.addSubview(divider)
        views = (host, divider)
        return (host, divider)
    }

    func removeViews() {
        standIn = false
        closeWindow()
        guard let views else { return }
        self.views = nil
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
