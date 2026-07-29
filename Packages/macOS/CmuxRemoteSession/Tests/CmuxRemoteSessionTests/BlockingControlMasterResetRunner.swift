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
    private let release = DispatchSemaphore(value: 0)

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
        release.wait()
        try operation?.throwIfCancelled()
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }

    func finish() {
        release.signal()
    }
}
