import Foundation
import IrohLib

/// Owns the FFI online wait without making a caller's deadline join that wait.
///
/// `Endpoint.online()` does not observe Swift cancellation. Its single task is
/// retained until online or endpoint shutdown; the endpoint owner must close
/// the endpoint at teardown. Consumers wait on a cancellation-aware signal.
public final class IrohEndpointOnlineWait: Sendable {
    private let signal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let onlineTask: Task<Void, Never>

    /// Starts one readiness observation for an endpoint owned by the caller.
    /// - Parameter endpoint: The endpoint whose owner guarantees eventual shutdown.
    public init(endpoint: Endpoint) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = pair.stream
        continuation = pair.continuation
        // The FFI operation cannot inherit a UI executor and outlives a
        // readiness timeout deliberately; endpoint.close releases it.
        onlineTask = Task.detached {
            await endpoint.online()
            if !Task.isCancelled { pair.continuation.yield(()) }
            pair.continuation.finish()
        }
    }

    /// Waits once for online, without blocking on the FFI task after timeout.
    /// - Parameters:
    ///   - timeout: The genuine readiness deadline.
    ///   - sleep: A cancellation-aware deadline clock, injectable in tests.
    /// - Returns: Whether the endpoint became online before the deadline.
    public func value(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [signal] in
                var iterator = signal.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                do { try await sleep(timeout) } catch { return false }
                return false
            }
            let online = await group.next() ?? false
            group.cancelAll()
            return online && !Task.isCancelled
        }
    }

    /// Releases consumers immediately; the owner then closes the endpoint to
    /// release the underlying FFI operation, rather than joining it here.
    public func cancel() {
        continuation.finish()
        onlineTask.cancel()
    }

    deinit { cancel() }
}
