@testable import CmuxRemoteSession

struct IntentionalCleanupUnusedProcessRunner: RemoteSessionProcessRunning {
    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        fatalError("Intentional cleanup tests do not spawn processes")
    }
}
