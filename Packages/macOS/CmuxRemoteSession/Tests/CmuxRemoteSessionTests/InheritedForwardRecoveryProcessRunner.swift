import Foundation
@testable import CmuxRemoteSession

final class InheritedForwardRecoveryProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - synchronous test requests consume one scripted counter.
    private let lock = NSLock()
    private let mode: InheritedForwardRecoveryMode
    private let relayID: String
    private let relayPort: Int
    private var _requests: [RemoteProcessRequest] = []
    private var forwardAttempts = 0
    private var metadataProbeAttempts = 0

    init(
        mode: InheritedForwardRecoveryMode,
        relayID: String = "relay-startup-cancellation",
        relayPort: Int = 64_044
    ) {
        self.mode = mode
        self.relayID = relayID
        self.relayPort = relayPort
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
                            "remote port forwarding failed for listen port \(relayPort)"
                    )
                }
            }
            if isMetadataOwnershipProbe(request) {
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

    private func isMetadataOwnershipProbe(
        _ request: RemoteProcessRequest
    ) -> Bool {
        guard request.arguments.last == "sh -s",
              let stdin = request.stdin,
              let script = String(data: stdin, encoding: .utf8) else {
            return false
        }
        return script.contains("tr -d") &&
            script.contains("auth_file=") &&
            script.contains(relayID)
    }
}
