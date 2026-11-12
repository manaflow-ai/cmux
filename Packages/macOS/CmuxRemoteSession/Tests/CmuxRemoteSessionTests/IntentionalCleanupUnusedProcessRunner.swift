@testable import CmuxRemoteSession

struct IntentionalCleanupUnusedProcessRunner: RemoteSessionProcessRunning {
    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}
