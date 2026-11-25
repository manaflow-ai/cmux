import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// #36274: a relaunch whose front window shows a pane with nothing selected (Home's pane under the first-run cover)
/// opened the control socket only at `LaunchSettle`'s 4 s backstop, while the window drew at about 1 s. The launch
/// settles on the first terminal frame or when the pane region is ready, and `PaneController.showSelected` made the
/// pane region ready only when it showed content: a pane with nothing selected shows nothing, so neither came. A pane
/// that has nothing to show is as ready as it will get.
@MainActor @Suite(.serialized, .closesItsWindows) struct LaunchSettleEmptyPaneTests {
    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"launch-settle-empty-pane-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func aPaneShownWithNothingSelectedMakesThePaneRegionReady() throws {
        _ = NSApplication.shared
        // Its own reveal, whose deadline never fires during the test: only the pane can make its region ready.
        let reveal = LaunchReveal(deadline: .seconds(60))
        let services = AppServices(environment: AppEnvironment.current([:]), launchReveal: reveal)
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "Home", screens: [screen])]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let controller = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                        state: WindowState(record: record))
        defer { controller.teardown() }
        controller.showSelected() // what the presentation scheduler runs on the frame after the strip's first apply
        try #require(controller.selectedTab == nil, "the pane has a selected tab: this is not the case under test")
        #expect(reveal.isReady(.pane), "a pane with nothing to show never made the pane region ready: the launch waited its 4 s backstop")

        // The launch then settles at the first window frame, not at the backstop.
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let settle = LaunchSettle(reveal: reveal, firstFrame: firstFrame, imageHold: LaunchImageHold())
        reveal.whenReady(.pane) { settle.settle() } // as `LaunchSettle.install` listens
        firstFrame.open()
        #expect(settle.isSettled, "the launch did not settle at the first window frame")
    }
}
