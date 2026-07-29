import Foundation
@testable import CmuxRemoteSession

final class BlockingControlMasterResetRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    let starts: AsyncStream<Void>
    private let startsContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var _requests: [RemoteProcessRequest] = []
    private let releaseCondition = NSCondition()
    private var finished = false

    init() {
        (starts, startsContinuation) = AsyncStream.makeStream()
    }

    var requests: [RemoteProcessRequest] {
        lock.withLock { _requests }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock { _requests.append(request) }
        startsContinuation.yield()
        releaseCondition.lock()
        while !finished {
            releaseCondition.wait()
        }
        releaseCondition.unlock()
        try operation?.throwIfCancelled()
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }

    func finish() {
        releaseCondition.lock()
        finished = true
        releaseCondition.broadcast()
        releaseCondition.unlock()
    }
}
