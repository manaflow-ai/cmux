import Foundation
@testable import CmuxRemoteSession

/// Gives relay tests deterministic `ssh -G` expansion while preserving their
/// existing process-runner scripts for forward and cancel commands.
final class ResolvedControlPathProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    private let base: any RemoteSessionProcessRunning
    private let controlPath: String

    init(
        base: any RemoteSessionProcessRunning,
        controlPath: String = ResolvedControlPathFixture.path
    ) {
        self.base = base
        self.controlPath = controlPath
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        if request.executable == "/usr/bin/ssh",
           request.arguments.first == "-G" {
            return RemoteCommandResult(
                status: 0,
                stdout: "controlpath \(controlPath)\n",
                stderr: ""
            )
        }
        return try base.run(request, operation: operation)
    }
}
