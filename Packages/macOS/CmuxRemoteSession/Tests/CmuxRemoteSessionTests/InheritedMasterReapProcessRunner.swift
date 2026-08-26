import CmuxRemoteWorkspace
import Foundation
@testable import CmuxRemoteSession

final class InheritedMasterReapProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    let requestStream: AsyncStream<RemoteProcessRequest>

    // lint:allow lock - synchronous test requests append and snapshot only.
    private let lock = NSLock()
    private var recordedRequests: [RemoteProcessRequest] = []
    private let requestContinuation:
        AsyncStream<RemoteProcessRequest>.Continuation

    init() {
        (requestStream, requestContinuation) = AsyncStream.makeStream()
    }

    var requests: [RemoteProcessRequest] {
        lock.withLock { recordedRequests }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            recordedRequests.append(request)
        }
        requestContinuation.yield(request)
        if Self.isControlCommand("forward", in: request.arguments) {
            return RemoteCommandResult(
                status: 255,
                stdout: "",
                stderr:
                    "remote port forwarding failed for listen port 64044"
            )
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }
}
