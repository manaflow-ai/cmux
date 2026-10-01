import CmuxSurfaceCatalogModel
import Foundation

/// Async streams give each caller independent cancellation, without creating
/// a task per waiter to bridge a cancellation-deaf remote operation.
@MainActor
final class CloudProjectionCompletion {
    private var result: Result<SurfaceRemotePlacement, Error>?
    private var waiters: [UUID: AsyncStream<Result<SurfaceRemotePlacement, Error>>.Continuation] = [:]
    var waiterCount: Int { waiters.count }

    func value() async throws -> SurfaceRemotePlacement {
        try Task.checkCancellation()
        if let result { return try result.get() }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Result<SurfaceRemotePlacement, Error>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        waiters[id] = continuation
        defer {
            waiters[id] = nil
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let answer = await iterator.next()
        try Task.checkCancellation()
        guard let answer else { throw CancellationError() }
        return try answer.get()
    }

    func resolve(_ result: Result<SurfaceRemotePlacement, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending {
            continuation.yield(result)
            continuation.finish()
        }
    }
}

