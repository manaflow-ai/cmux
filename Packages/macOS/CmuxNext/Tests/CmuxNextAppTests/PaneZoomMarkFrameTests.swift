import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import Foundation
import Testing

// CmuxNextLayout has its own PaneID and ScreenID; the daemon tree takes the daemon's.
private typealias DaemonPaneID = CmuxNextDaemon.PaneID
private typealias DaemonScreenID = CmuxNextDaemon.ScreenID

/// A zoomed pane shows one Exit Zoom control: the button in its tab bar's trailing controls
/// (`PaneToolbarView.zoomButton`), or the indicator at its content's corner while the tab bar shows no controls
/// (`PaneZoomIndicatorView`).
///
/// Toggle Pane Zoom changes the store in its own turn. The window's layout takes the change in that turn and shows it
/// at a later frame tick (`ScreenContentView+SnapFrame`, `PaneZoomDim`): until that tick the screen shows the layout
/// from before the action. These tests hold the control to that tick. For a zoom: no control while the screen still
/// shows both panes, and the control in the frame that shows the zoomed pane alone. For an unzoom: the control while
/// the screen still shows the zoomed pane alone, and no control in the frame that shows both panes again.
///
/// The control takes the zoom from the layout, in the pass that shows the change (`PaneZoomDim.showMarks(on:)`,
/// `PaneContentView.setPaneShownZoomed`). It once took the store's zoom, through two observation tasks that run after
/// the action's turn (`PaneController.observe`, `PaneToolbar.init(pane:view:)`), and so changed frames before the
/// screen did. Each test is one main-actor turn from the store's snapshot to its last expectation, so neither task
/// runs in it. The test calls instead the two functions that apply the store's state to a pane directly
/// (`PaneController.syncStripFromStore`, `PaneToolbar.refresh`; see `Shown.takeStoreZoom`), so a control that
/// follows the store again fails here. That these two calls stand in for one step of the two tasks is by a read of
/// that code, not by a run.
///
/// The test is the layout's clock (`DisplayLinkDriver.isManual`), as in `PaneCloseKeyTurnTests`, and no number of
/// frames is an expectation. The app has a connection that never becomes ready, as in `PaneVerbsKeyTurnTests`, so
/// no answer of the daemon comes in a test's turn.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct PaneZoomMarkFrameTests {
    private static let left = DaemonPaneID(rawValue: 1), right = DaemonPaneID(rawValue: 2)
    private static let screenID = DaemonScreenID(rawValue: 1)
    private static let workspace = "zoom-mark-ws"
    private static let zoom: ActionID = "toggleSplitZoom"
    /// One frame of the layout's time at 120 Hz.
    private static let dt = 1.0 / 120
    /// The most frames a test steps for one change, as a failure limit only. An unzoom's dim goes in at most
    /// `PaneZoomDim.longest` (30 frames at `dt`); a change waits at most `ScreenContentView.commitBound` frames
    /// for its panes.
    private static let frames = 60

    /// One workspace with one screen: pane 1 on the left, pane 2 on its right, one tab each.
    private static func tree() -> DaemonTree {
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(left), b: .leaf(right))
        let panes = layout.paneIDs.map { PaneSnapshot(id: $0, tabs: [TabSnapshot(surface: SurfaceID(rawValue: $0.rawValue), title: "~")]) }
        let screen = ScreenSnapshot(id: screenID, active: true, activePane: left, layout: layout, panes: panes)
        var snapshot = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: workspace), name: "zoom mark", screens: [screen]),
        ])
        snapshot.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: workspace), index: 0)])
        return snapshot
    }

    /// The app's services, with windows that are never ordered in.
    private static func makeServices() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        return services
    }

    /// Gives `services` a daemon connection that never becomes ready and a connected store. It holds the one `await`
    /// of a test.
    private static func connect(_ services: AppServices) async throws {
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-zoom-mark-\(UUID().uuidString).sock"))
        services.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
        await services.daemon.firstConnection()
        try #require(services.daemon.connection != nil, "SETUP: the service never took the connection")
        services.daemon.store.connectionState = .connected(identity)
    }

    /// The store takes the workspace's tree and a window opens on it, in the caller's turn.
    private static func open(_ services: AppServices) -> WindowController? {
        services.daemon.store.apply(snapshot: tree())
        return services.windows.openWindow(workspaces: [workspace], frame: CGRect(x: 200, y: 200, width: 1200, height: 760))
    }

    private static func close(_ controller: WindowController) {
        controller.teardown()
        controller.window?.close()
    }

    /// The window's workspace, with the frames of its layout stepped by the test.
    private struct Shown {
        let services: AppServices
        let controller: WindowController
        let content: WorkspaceContentController
        let layout: LayoutRootView
        let screen: ScreenContentView
        /// Daemon pane 1, on the left: the pane the tests zoom.
        let left: PaneController
        /// Daemon pane 2, on its right.
        let right: PaneController

        /// Takes the content of `controller`'s window in the turn that opened it, makes the test the layout's clock and
        /// steps the layout to rest.
        init(_ controller: WindowController, _ services: AppServices) throws {
            // The window manager shows the workspace in the turn that makes the window (`makeController`). This is the
            // call the window's own observer makes after that turn: it builds nothing when the content is there.
            controller.showWorkspace(requested: PaneZoomMarkFrameTests.workspace)
            let content = try #require(controller.workspaceContent, "SETUP: the window has no workspace content in the turn that opened it")
            try #require(content.panes.count == 2, "SETUP: the window shows \(content.panes.count) panes in the turn that opened it, not 2")
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            content.contentView.layoutSubtreeIfNeeded()
            let first = content.panes.values.first { $0.pane.handle == PaneZoomMarkFrameTests.left }
            let second = content.panes.values.first { $0.pane.handle == PaneZoomMarkFrameTests.right }
            let left = try #require(first, "SETUP: the left pane has no controller")
            let right = try #require(second, "SETUP: the right pane has no controller")
            PaneHandlers.focus(left.layoutPaneID, in: content)
            let layout = content.layoutView
            layout.context.reduceMotionOverride = false
            layout.driver.isManual = true
            // A layout change waits for a frame tick only in a root that runs frames (`snapWaitsForFrame`).
            try #require(layout.isLive && layout.driver.isAttached,
                         "SETUP: the layout runs no frames in a window that is not ordered in: live \(layout.isLive), attached \(layout.driver.isAttached)")
            let active = try #require(content.layoutModel.activeScreenID, "SETUP: the layout has no active screen")
            let screen = try #require(layout.screenViews[active], "SETUP: the active screen has no view")
            self.services = services
            self.controller = controller
            self.content = content
            self.layout = layout
            self.screen = screen
            self.left = left
            self.right = right
            layOut()
            try #require(rests(), "SETUP: the layout did not come to rest in 240 frames after the window opened")
            layOut()
        }

        /// A layout pass of the window's views.
        func layOut() {
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            content.contentView.layoutSubtreeIfNeeded()
        }

        /// Steps the layout's frames until one asks for no more. False when 240 frames did not end the motion.
        func rests() -> Bool {
            for _ in 0..<240 {
                if !layout.advanceFrame(PaneZoomMarkFrameTests.dt) { return true }
            }
            return false
        }

        /// Whether the screen shows `pane`: the pane's host is a subview of the screen, not hidden, with an alpha above
        /// 0 and a size.
        func shows(_ pane: PaneController) -> Bool {
            screen.subviews.contains { view in
                guard let host = view as? PaneHostView, host.pane == pane.layoutPaneID else { return false }
                return !host.isHidden && host.alphaValue > 0 && host.frame.width > 0 && host.frame.height > 0
            }
        }

        /// The shown view of the left pane that offers Exit Zoom, in either of its two places.
        var exitZoom: NSView? {
            func find(_ view: NSView) -> NSView? {
                if !view.isHiddenOrHasHiddenAncestor, view.accessibilityLabel() == CmuxNextTabs.Strings.exitZoom, !view.frame.isEmpty { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(left.view)
        }

        var storeZooms: Bool {
            services.daemon.store.screen(containing: PaneZoomMarkFrameTests.left)?.zoomedPane == PaneZoomMarkFrameTests.left
        }

        var layoutZooms: Bool { content.layoutModel.screens.first?.zoomed ?? false }

        /// Runs Toggle Pane Zoom on the left pane through the action registry, in the caller's turn. False when no
        /// handler ran.
        func toggleZoom() -> Bool {
            services.registry.perform(PaneZoomMarkFrameTests.zoom,
                                      invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: left.paneKey), origin: .user))
        }

        /// Applies the store's state to each pane as one step of its two observation tasks does, then a layout pass.
        /// The pane's task applies the layout if it changed and then the pane's state composed from the store
        /// (`PaneController.observe`): here `applyLayoutIfChanged` and `syncStripFromStore`, which composes and
        /// applies that state. The trailing controls' task applies `PaneToolbar.state` (`PaneToolbar.init(pane:view:)`):
        /// here `refresh`, which applies it too.
        func takeStoreZoom() {
            for pane in [left, right] {
                content.applyLayoutIfChanged()
                pane.syncStripFromStore()
                pane.view.toolbar?.refresh()
            }
            layOut()
        }

        /// Zooms the left pane and steps the layout to rest: the screen shows the zoomed pane alone, with its control.
        func zoomToRest() throws {
            try #require(toggleZoom(), "SETUP: no handler ran Toggle Pane Zoom")
            takeStoreZoom()
            _ = try #require(firstFrame(where: { !shows(right) }, noting: { false }), "SETUP: no frame of \(PaneZoomMarkFrameTests.frames) showed the zoom")
            try #require(rests(), "SETUP: the layout did not come to rest in 240 frames after the zoom")
            layOut()
            try #require(shows(left) && !shows(right), "SETUP: the screen does not show the zoomed pane alone at rest")
            try #require(exitZoom != nil, "SETUP: the zoomed pane shows no Exit Zoom control at rest")
        }

        /// Steps the layout frame by frame, a layout pass after each, to the first frame for which `done` holds.
        /// Returns that frame's number, from 1, and the numbers of the frames before it for which `flaw` held. Nil
        /// when `done` held for no frame of `frames`.
        func firstFrame(where done: () -> Bool, noting flaw: () -> Bool) -> (number: Int, flawed: [Int])? {
            var flawed: [Int] = []
            for number in 1...PaneZoomMarkFrameTests.frames {
                _ = layout.advanceFrame(PaneZoomMarkFrameTests.dt)
                layOut()
                if done() { return (number, flawed) }
                if flaw() { flawed.append(number) }
            }
            return nil
        }
    }

    @Test func aZoomShowsItsExitZoomControlInTheFrameThatShowsTheZoomedPaneAlone() async throws {
        let services = Self.makeServices()
        defer { services.daemon.shutdownConnection() }
        try await Self.connect(services)
        // One main-actor turn from here to the end of the test: no `await`.
        let controller = try #require(Self.open(services), "SETUP: no window opened")
        defer { Self.close(controller) }
        let shown = try Shown(controller, services)
        try #require(shown.shows(shown.left) && shown.shows(shown.right), "SETUP: the screen does not show both panes at rest")
        try #require(shown.exitZoom == nil, "SETUP: a pane that is not zoomed shows an Exit Zoom control")

        try #require(shown.toggleZoom(), "SETUP: no handler ran Toggle Pane Zoom")
        try #require(shown.storeZooms && shown.layoutZooms, "SETUP: the store and the layout model do not both have the zoom in the action's turn")
        shown.layOut()
        try #require(shown.shows(shown.left) && shown.shows(shown.right),
                     "SETUP: the zoom did not wait for a frame: the screen does not show both panes in the action's turn")
        #expect(shown.exitZoom == nil, "the action's own turn shows the Exit Zoom control while the screen still shows both panes")

        shown.takeStoreZoom()
        try #require(shown.shows(shown.left) && shown.shows(shown.right),
                     "SETUP: the screen does not show both panes after the calls of the two observation tasks")
        #expect(shown.exitZoom == nil, "the Exit Zoom control shows before a frame tick, while the screen still shows both panes")

        let stepped = shown.firstFrame(where: { !shown.shows(shown.right) }, noting: { shown.exitZoom != nil })
        let zoom = try #require(stepped, "SETUP: no frame of \(Self.frames) showed the zoom")
        try #require(shown.shows(shown.left), "SETUP: the frame that hides the right pane does not show the zoomed pane")
        let early = zoom.flawed
        #expect(early.isEmpty,
                "the Exit Zoom control shows in \(early.count) frame(s) that still show both panes, from frame \(early.first ?? 0); the zoom shows in frame \(zoom.number)")
        #expect(shown.exitZoom != nil, "the frame that shows the zoomed pane alone shows no Exit Zoom control")
    }

    @Test func anUnzoomKeepsItsExitZoomControlUntilTheFrameThatShowsBothPanes() async throws {
        let services = Self.makeServices()
        defer { services.daemon.shutdownConnection() }
        try await Self.connect(services)
        // One main-actor turn from here to the end of the test: no `await`.
        let controller = try #require(Self.open(services), "SETUP: no window opened")
        defer { Self.close(controller) }
        let shown = try Shown(controller, services)
        try #require(shown.shows(shown.left) && shown.shows(shown.right), "SETUP: the screen does not show both panes at rest")

        // The zoom, shown and at rest, with its control.
        try #require(shown.toggleZoom(), "SETUP: no handler ran Toggle Pane Zoom")
        shown.takeStoreZoom()
        let zoomed = shown.firstFrame(where: { !shown.shows(shown.right) }, noting: { false })
        _ = try #require(zoomed, "SETUP: no frame of \(Self.frames) showed the zoom")
        try #require(shown.rests(), "SETUP: the layout did not come to rest in 240 frames after the zoom")
        shown.layOut()
        try #require(shown.shows(shown.left) && !shown.shows(shown.right), "SETUP: the screen does not show the zoomed pane alone at rest")
        try #require(shown.exitZoom != nil, "SETUP: the zoomed pane shows no Exit Zoom control at rest")

        try #require(shown.toggleZoom(), "SETUP: no handler ran Toggle Pane Zoom for the unzoom")
        try #require(!shown.storeZooms && !shown.layoutZooms, "SETUP: the store or the layout model still has the zoom in the unzoom's turn")
        shown.layOut()
        try #require(shown.shows(shown.left) && !shown.shows(shown.right),
                     "SETUP: the unzoom did not wait for a frame: the screen does not show the zoomed pane alone in the action's turn")
        #expect(shown.exitZoom != nil, "the action's own turn takes the Exit Zoom control away while the screen still shows the zoomed pane alone")

        shown.takeStoreZoom()
        try #require(shown.shows(shown.left) && !shown.shows(shown.right),
                     "SETUP: the screen does not show the zoomed pane alone after the calls of the two observation tasks")
        #expect(shown.exitZoom != nil, "the Exit Zoom control goes before a frame tick, while the screen still shows the zoomed pane alone")

        let stepped = shown.firstFrame(where: { shown.shows(shown.right) }, noting: { shown.exitZoom == nil })
        let unzoom = try #require(stepped, "SETUP: no frame of \(Self.frames) showed the unzoom")
        try #require(shown.shows(shown.left), "SETUP: the frame that shows the right pane again does not show the left pane")
        let bare = unzoom.flawed
        #expect(bare.isEmpty,
                "no Exit Zoom control in \(bare.count) frame(s) that still show the zoomed pane alone, from frame \(bare.first ?? 0); the unzoom shows in frame \(unzoom.number)")
        #expect(shown.exitZoom == nil, "the frame that shows both panes again still shows the Exit Zoom control")
    }

    /// A page that has the whole window (its fullscreen) shows its pane alone, as a zoom does, and the store has no
    /// zoom (`LayoutMapping.Result.presenting`, `LayoutScreen.presented`). No Exit Zoom control comes with it, and
    /// none stays when the page gives the window back. The test sets the flag that the window sets on the page's pane
    /// (`PaneController.presentsPage`, `WindowController+FullScreen`); it has no page and no full screen window.
    @Test func aPageWithTheWholeWindowShowsNoExitZoomControl() async throws {
        let services = Self.makeServices()
        defer { services.daemon.shutdownConnection() }
        try await Self.connect(services)
        // One main-actor turn from here to the end of the test: no `await`.
        let controller = try #require(Self.open(services), "SETUP: no window opened")
        defer { Self.close(controller) }
        let shown = try Shown(controller, services)
        try #require(shown.shows(shown.left) && shown.shows(shown.right), "SETUP: the screen does not show both panes at rest")
        try #require(shown.exitZoom == nil, "SETUP: a pane that is not zoomed shows an Exit Zoom control")

        shown.left.presentsPage = true
        try #require(shown.layoutZooms && !shown.storeZooms,
                     "SETUP: the layout model does not show the page's pane alone, or the store has a zoom: layout \(shown.layoutZooms), store \(shown.storeZooms)")
        shown.layOut()
        #expect(shown.exitZoom == nil, "the turn that gives the page the whole window shows an Exit Zoom control")
        let stepped = shown.firstFrame(where: { !shown.shows(shown.right) }, noting: { shown.exitZoom != nil })
        let alone = try #require(stepped, "SETUP: no frame of \(Self.frames) showed the page's pane alone")
        #expect(alone.flawed.isEmpty, "an Exit Zoom control shows in \(alone.flawed.count) frame(s) before the page's pane shows alone")
        #expect(shown.exitZoom == nil, "the frame that shows the page's pane alone shows an Exit Zoom control")
        try #require(shown.rests(), "SETUP: the layout did not come to rest in 240 frames with the page's pane alone")
        shown.layOut()
        #expect(shown.exitZoom == nil, "the page's pane, alone and at rest, shows an Exit Zoom control")

        // The store's zoom under the page: the pane's own state takes it from the store (`PaneController.apply`).
        try #require(shown.toggleZoom() && shown.storeZooms, "SETUP: Toggle Pane Zoom under the page did not zoom the store")
        shown.takeStoreZoom()
        #expect(shown.exitZoom != nil, "a zoom key under a page with the whole window shows no Exit Zoom control")
        try #require(shown.toggleZoom() && !shown.storeZooms, "SETUP: Toggle Pane Zoom under the page did not unzoom the store")
        shown.takeStoreZoom()
        #expect(shown.exitZoom == nil, "an unzoom key under a page with the whole window keeps the Exit Zoom control")

        shown.left.presentsPage = false
        try #require(!shown.layoutZooms, "SETUP: the layout model still shows the page's pane alone after the page gave the window back")
        let back = shown.firstFrame(where: { shown.shows(shown.right) }, noting: { shown.exitZoom != nil })
        let both = try #require(back, "SETUP: no frame of \(Self.frames) showed both panes again")
        #expect(both.flawed.isEmpty, "an Exit Zoom control shows in \(both.flawed.count) frame(s) before both panes show again")
        #expect(shown.exitZoom == nil, "the frame that shows both panes again shows an Exit Zoom control")
    }

    /// A page takes the whole window in the frames between an unzoom key and the frame that shows the unzoom. The
    /// store has no zoom then, and the pane's Exit Zoom control still shows: the frame that takes it away has not
    /// come. The page's pane takes the store's zoom in the turn that gives the page the window
    /// (`PaneController.presentsPage`), so the page shows with no control.
    @Test func aPageThatStartsBeforeAnUnzoomShowsHasNoExitZoomControl() async throws {
        let services = Self.makeServices()
        defer { services.daemon.shutdownConnection() }
        try await Self.connect(services)
        // One main-actor turn from here to the end of the test: no `await`.
        let controller = try #require(Self.open(services), "SETUP: no window opened")
        defer { Self.close(controller) }
        let shown = try Shown(controller, services)
        try shown.zoomToRest()

        try #require(shown.toggleZoom(), "SETUP: no handler ran Toggle Pane Zoom for the unzoom")
        try #require(!shown.storeZooms, "SETUP: the store still has the zoom in the unzoom's turn")
        shown.layOut()
        try #require(shown.exitZoom != nil, "SETUP: the unzoom's own turn took the Exit Zoom control away")
        shown.left.presentsPage = true
        shown.layOut()
        #expect(shown.exitZoom == nil, "a page that takes the whole window before an unzoom shows keeps the Exit Zoom control, and the store has no zoom")
        try #require(shown.rests(), "SETUP: the layout did not come to rest in 240 frames with the page's pane alone")
        shown.layOut()
        #expect(shown.exitZoom == nil, "the page's pane, alone and at rest, shows an Exit Zoom control, and the store has no zoom")
    }

    /// A zoom key in the turn that ends a page's time with the whole window, after an unzoom under the page. The
    /// store has the zoom, the pane's own state has none (its task did not run since the key), and the layout shows
    /// the same pane alone before and after, so no pass shows another zoom than the pass before. The screen's first
    /// pass after the page's time tells each pane that it placed (`PaneZoomDim.showMarks(on:)`): the zoomed pane has
    /// its Exit Zoom control then. The test makes that pass itself (`ScreenContentView.applyPresentation`).
    @Test func aZoomKeyInTheTurnThatEndsAPageShowsItsExitZoomControlAtTheNextPass() async throws {
        let services = Self.makeServices()
        defer { services.daemon.shutdownConnection() }
        try await Self.connect(services)
        // One main-actor turn from here to the end of the test: no `await`.
        let controller = try #require(Self.open(services), "SETUP: no window opened")
        defer { Self.close(controller) }
        let shown = try Shown(controller, services)
        try shown.zoomToRest()

        shown.left.presentsPage = true
        shown.layOut()
        try #require(shown.rests(), "SETUP: the layout did not come to rest in 240 frames with the page's pane alone")
        shown.layOut()
        // An unzoom under the page: the pane takes the store's state, and its control goes.
        try #require(shown.toggleZoom() && !shown.storeZooms, "SETUP: Toggle Pane Zoom under the page did not unzoom the store")
        shown.takeStoreZoom()
        try #require(shown.exitZoom == nil, "SETUP: after an unzoom under the page the Exit Zoom control still shows")
        // One turn: a zoom key, then the page gives the window back. No step of the pane's task between or after.
        try #require(shown.toggleZoom() && shown.storeZooms, "SETUP: Toggle Pane Zoom under the page did not zoom the store")
        shown.left.presentsPage = false
        try #require(shown.layoutZooms, "SETUP: the layout model does not have the store's zoom after the page's time")
        shown.layOut()
        try #require(shown.exitZoom == nil, "SETUP: the Exit Zoom control shows before the screen's next pass")
        shown.screen.applyPresentation()
        shown.layOut()
        try #require(shown.shows(shown.left) && !shown.shows(shown.right), "SETUP: the screen does not show the zoomed pane alone after the page's time")
        #expect(shown.exitZoom != nil, "after a zoom key in the turn that ends a page's time, the zoomed pane shows no Exit Zoom control at the screen's next pass")
    }
}
