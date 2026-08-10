/// Drains accepted teardown operations in ingress order.
///
/// The consumer Task captures only the stream. Each buffered operation retains
/// its coordinator until that operation reaches the actor receive boundary.
internal final class TerminalSurfaceRuntimeTeardownSubmissionDrain: Sendable {
  internal typealias Operation = @Sendable () async -> Void

  private let continuation: AsyncStream<Operation>.Continuation
  private let consumerTask: Task<Void, Never>

  internal init(maximumBufferedOperationCount: Int) {
    let submissions = AsyncStream<Operation>.makeStream(
      bufferingPolicy: .bufferingOldest(maximumBufferedOperationCount)
    )
    let stream = submissions.stream
    continuation = submissions.continuation
    consumerTask = Task {
      for await operation in stream {
        await operation()
      }
    }
  }

  deinit {
    continuation.finish()
    consumerTask.cancel()
  }

  internal func yield(
    _ operation: @escaping Operation
  ) -> AsyncStream<Operation>.Continuation.YieldResult {
    continuation.yield(operation)
  }
}
