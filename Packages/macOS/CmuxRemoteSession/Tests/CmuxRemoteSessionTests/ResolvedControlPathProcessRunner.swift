import CmuxFoundation
@testable import CmuxRemoteSession

enum ResolvedControlPathFixture {
    static let path =
        "/tmp/cmux-ssh-\(SSHConnectionSharingOptions().userID)-" +
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

/// Gives relay tests deterministic `ssh -G` expansion while preserving their
/// existing process-runner scripts for forward, cancel, and reset commands.
final class ResolvedControlPathProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    private let base: any RemoteSessionProcessRunning

    init(base: any RemoteSessionProcessRunning) {
        self.base = base
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        if request.executable == "/usr/bin/ssh",
           request.arguments.first == "-G" {
            return RemoteCommandResult(
                status: 0,
                stdout: "controlpath \(ResolvedControlPathFixture.path)\n",
                stderr: ""
            )
        }
        return try base.run(request, operation: operation)
    }
}
