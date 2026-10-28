import AppKit
import CmuxNextOnboarding
import CmuxNextWakeups

/// The onboarding step's view of Computer Use Setup (`ComputerUseSetup`):
/// the same grants the Settings card and the palette action show, pushed
/// on each change (no read of its own, no poll). The step shows while it
/// is on screen; showing it reads the grants again.
@MainActor
final class AppComputerUsePermissionSource: ComputerUsePermissionSource {
    private let setup: ComputerUseSetup
    private let mainWork: MainWorkScheduler

    /// - Parameter mainWork: The app's main-thread scheduler: a change of the grants reaches the step as one
    ///   `visible` task on it.
    init(setup: ComputerUseSetup, mainWork: MainWorkScheduler) {
        self.setup = setup
        self.mainWork = mainWork
    }

    var helperAppURL: URL? { setup.helperAppURL }

    var helperAppIcon: NSImage? { setup.helperAppIcon }

    func permissions() -> AsyncStream<ComputerUsePermissions> {
        let setup = setup, mainWork = mainWork
        setup.recheck()
        let (stream, continuation) = AsyncStream<ComputerUsePermissions>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // `visible`: the step draws the grants; the current ones go out now. The stream's end releases the follower.
        let grants = ServiceObservation(.visible, owner: "Onboarding.computerUsePermissions", on: mainWork) {
            setup.stepPermissions
        } apply: { continuation.yield($0) }
        continuation.onTermination = { _ in
            mainWork.postFromAnyThread(.visible, owner: "Onboarding.computerUsePermissions.end") { grants.cancel() }
        }
        return stream
    }

    func openSettings(_ pane: ComputerUsePermissionPane) {
        setup.open(pane)
    }

    func restart() {
        guard let restart = setup.prepareRestart() else { return }
        // task-owner: one helper restart from the person's click in the step.
        Task { await restart() }
    }

    func enable() {
        setup.enable()
    }
}
