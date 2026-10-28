import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Testing

/// The launch window opens when the launch snapshot's read ends, not in
/// `applicationDidFinishLaunching`'s turn. A Dock click or a second `open -a cmux` in that gap
/// (`applicationShouldHandleReopen` with no visible window) found no registered window to reopen, so it
/// created a workspace in a new window, and the launch window opened beside it: two windows.
@MainActor @Suite(.serialized)
struct LaunchWindowReopenGapTests {
    @Test func aReopenBeforeTheLaunchWindowOpensMakesNoSecondWindow() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let launchSnapshot = services.daemon.launchSnapshot, read = SnapshotGate()
        launchSnapshot.hop = StartupMainHop { work in Task { @MainActor in work() } }
        let work = BackgroundWork(label: "test.launch-reopen")
        launchSnapshot.take(read.prefetch(DaemonLaunchSnapshotTakeTests.session), session: DaemonLaunchSnapshotTakeTests.session,
                            stateDirectory: nil, work: work)
        services.windows.restoreWhenLoaded()
        #expect(services.windows.controllers.isEmpty, "the launch window opened before the snapshot's read ended")

        #expect(services.windows.reopenOrCreateWindow() == nil, "the reopen created a workspace in a second window")

        read.end(.missing)
        await withCheckedContinuation { continuation in launchSnapshot.whenSettled { continuation.resume() } }
        #expect(services.windows.controllers.count == 1)
        #expect(services.windows.launchWindowID != nil)
        #expect(!services.windows.launchWindowWaiting, "a reopen after the launch window opened would be dropped")
    }
}
