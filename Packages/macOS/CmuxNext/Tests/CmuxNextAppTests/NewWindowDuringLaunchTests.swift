import AppKit
@testable import CmuxNextApp
import CmuxNextAppCore
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextRemote
@testable import CmuxNextSidebar
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/38128: a new window sometimes opened on a loading state, with
/// several untitled rows that then collapsed to its one workspace, and with no open animation. Those are the
/// launch's stand-ins (each connecting machine's three loading bars, the launch's in-place open), which every
/// window got while `registry.isLaunching` was set: during the launch, and for the rest of the run after a
/// restore that gave up. A window this run opens is new: its sidebar lists only its own live rows from its
/// first frame, and it opens like a new window. The launch window keeps its stand-ins.
@MainActor @Suite(.serialized, .closesItsWindows) struct NewWindowDuringLaunchTests {
    static let launchID = "launch-window-38128"

    /// The app mid-launch (the restore has not ended, or gave up): the local daemon lists `k1` and `k2`, and an
    /// SSH machine is still connecting, so a launch window's sidebar shows its loading bars.
    static func launching() throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["k1", "k2"], personal: ["k1", "k2"]))
        services.machines.add(try SSHConnectingRowsWindowTests.connectingSession("devbox-38128"))
        services.windows.ordersWindowsIn = false
        services.windows.registry.isLaunching = true
        services.windows.launchWindowID = launchID
        return services
    }

    /// The launch's untitled loading bars (`SidebarSeed.placeholders`), not the connecting machine's own
    /// "Connecting to …" row, which lists in one window only (`SSHConnectingRows`).
    static func loadingBars(_ controller: WindowController) -> Int {
        controller.sidebar.model.sections.flatMap(\.workspaces).filter { $0.rowState == .placeholder && $0.id.rawValue.hasPrefix("placeholder:") }.count
    }

    /// The control: the launch window shows the connecting machine's loading bars once their grace ends, so the
    /// new window's test below is not passing on a setup that never draws them.
    @Test func theLaunchWindowStandsInWithLoadingBars() async throws {
        let services = try Self.launching()
        let launch = services.windows.makeController(for: WindowRegistry.Window(id: Self.launchID))
        defer { launch.teardown(); launch.window?.close() }
        #expect(services.windows.restoresSession(Self.launchID))
        let shown = await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { Self.loadingBars(launch) == SidebarSeed.placeholderCount }
        #expect(shown, "the launch window never drew the connecting machine's loading bars")
    }

    /// A window opened while the launch runs (Cmd-Shift-N, `cmux app new-window`) lists its one workspace and
    /// never a loading bar, past the bars' grace.
    @Test func aNewWindowDuringTheLaunchShowsOnlyItsOwnWorkspace() async throws {
        let services = try Self.launching()
        // The launch window is on screen first, as at a real launch (it lists the connecting machine's row).
        let launch = services.windows.makeController(for: WindowRegistry.Window(id: Self.launchID))
        defer { launch.teardown(); launch.window?.close() }
        let controller = try #require(services.windows.openWindow(workspaces: ["k2"]))
        defer { controller.teardown(); controller.window?.close() }
        let drewBars = await RapidWorkspaceCreateTests.wait(within: .seconds(2)) { Self.loadingBars(controller) > 0 }
        #expect(!drewBars, "a new window drew \(Self.loadingBars(controller)) untitled loading rows")
        let listed = controller.sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue)
        #expect(listed == ["k2"], "a new window listed \(listed), not only its own workspace")
    }

    /// The new window opens with the new-window animation (motion on); the launch window shows in place.
    @Test func aNewWindowDuringTheLaunchOpensLikeANewWindow() throws {
        let previous = Motion.reduceMotionOverride
        defer { Motion.reduceMotionOverride = previous }
        Motion.reduceMotionOverride = false
        try #require(Motion.panes.animatesMovement, "motion is off on this host: the test would not prove the rule")
        let services = try Self.launching()
        let fresh = services.windows.makeController(for: WindowRegistry.Window(id: "new-window-38128"))
        defer { fresh.teardown(); fresh.window?.close() }
        #expect(fresh.window?.animationBehavior == NSWindow.AnimationBehavior.documentWindow,
                "a window opened during the launch showed in place, as a restored one does")
        let launch = services.windows.makeController(for: WindowRegistry.Window(id: Self.launchID))
        defer { launch.teardown(); launch.window?.close() }
        #expect(launch.window?.animationBehavior == NSWindow.AnimationBehavior.none)
    }

    /// A saved window the restore opens is the launch's too, until the launch ends; after it nothing is.
    @Test func savedWindowsRestoreOnlyWhileTheLaunchRuns() throws {
        let services = try Self.launching()
        let windows = services.windows
        windows.previousLaunch = PreviousLaunch(windowIDs: ["saved-1"], restoredAtMs: 0)
        #expect(windows.restoresSession("saved-1"))
        #expect(!windows.restoresSession("new-window-38128"))
        windows.registry.isLaunching = false
        #expect(!windows.restoresSession("saved-1"))
        #expect(!windows.restoresSession(Self.launchID))
    }
}
