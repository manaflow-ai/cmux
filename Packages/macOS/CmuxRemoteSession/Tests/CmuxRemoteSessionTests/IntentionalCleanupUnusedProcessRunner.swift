@testable import CmuxRemoteSession

struct IntentionalCleanupUnusedProcessRunner: RemoteSessionProcessRunning {
    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        // Lifecycle cleanup now removes the per-session paste directory on a
        // normal coordinator stop. Keep this seam local and deterministic,
        // while avoiding a real SSH process in these state-transition tests.
        RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}
