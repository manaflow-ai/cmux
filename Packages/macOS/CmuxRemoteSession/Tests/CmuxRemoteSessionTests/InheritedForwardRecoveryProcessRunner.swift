import Foundation
@testable import CmuxRemoteSession

final class InheritedForwardRecoveryProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - synchronous test requests consume one scripted counter.
    private let lock = NSLock()
    private let mode: InheritedForwardRecoveryMode
    private var _requests: [RemoteProcessRequest] = []
    private var forwardAttempts = 0
    private var metadataProbeAttempts = 0

    init(mode: InheritedForwardRecoveryMode) {
        self.mode = mode
    }

    var requests: [RemoteProcessRequest] {
        lock.withLock { _requests }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            _requests.append(request)
            if Self.isControlCommand("forward", in: request.arguments) {
                forwardAttempts += 1
                let failingForwardAttempts =
                    mode == .transientMetadataFailure ? 2 : 1
                if forwardAttempts <= failingForwardAttempts {
                    return RemoteCommandResult(
                        status: 255,
                        stdout: "",
                        stderr:
                            "remote port forwarding failed for listen port 64044"
                    )
                }
            }
            if Self.isMetadataOwnershipProbe(request) {
                metadataProbeAttempts += 1
                if mode == .metadataMismatch {
                    return RemoteCommandResult(
                        status: 64,
                        stdout: "",
                        stderr: ""
                    )
                }
                if mode == .transientMetadataFailure &&
                    metadataProbeAttempts == 1 {
                    return RemoteCommandResult(
                        status: 255,
                        stdout: "",
                        stderr: "temporary probe failure"
                    )
                }
            }
            if Self.isControlCommand("exit", in: request.arguments),
               mode == .exitFailure {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "exit failed"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }

    private static func isMetadataOwnershipProbe(
        _ request: RemoteProcessRequest
    ) -> Bool {
        request.arguments.last?.contains("tr -d") == true &&
            request.arguments.last?.contains("auth_file=") == true &&
            request.arguments.last?.contains(
                "relay-startup-cancellation"
            ) == true
    }
}
