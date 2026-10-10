import AppKit
import CmuxNextOnboarding
import Observation

/// The onboarding step's view of Computer Use Setup (`ComputerUseSetup`):
/// the same grants the Settings card and the palette action show, pushed
/// on each change (no read of its own, no poll). The step shows while it
/// is on screen; showing it reads the grants again.
@MainActor
final class AppComputerUsePermissionSource: ComputerUsePermissionSource {
    private let setup: ComputerUseSetup

    init(setup: ComputerUseSetup) {
        self.setup = setup
    }

    var helperAppURL: URL? { setup.helperAppURL }

    func permissions() -> AsyncStream<ComputerUsePermissions> {
        let setup = setup
        setup.recheck()
        let (stream, continuation) = AsyncStream<ComputerUsePermissions>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // task-owner: follows the setup's grants until the step's stream ends (onTermination cancels).
        let task = Task { @MainActor in
            for await value in Observations({ setup.stepPermissions }) {
                continuation.yield(value)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func openSettings(_ pane: ComputerUsePermissionPane) {
        setup.open(pane)
    }

    func enable() {
        setup.enable()
    }
}
