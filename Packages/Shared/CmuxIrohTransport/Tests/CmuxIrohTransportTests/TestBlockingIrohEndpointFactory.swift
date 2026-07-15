@testable import CmuxIrohTransport

actor TestBlockingIrohEndpointFactory: CmxIrohEndpointFactory {
    private let endpoint: TestIrohEndpoint
    private let startedStream: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private var pendingBind: CheckedContinuation<any CmxIrohEndpoint, any Error>?

    init(endpoint: TestIrohEndpoint) {
        self.endpoint = endpoint
        let started = AsyncStream<Void>.makeStream()
        startedStream = started.stream
        startedContinuation = started.continuation
    }

    func bind(
        configuration _: CmxIrohEndpointConfiguration
    ) async throws -> any CmxIrohEndpoint {
        startedContinuation.yield()
        return try await withCheckedThrowingContinuation { continuation in
            pendingBind = continuation
        }
    }

    func bindStartedEvents() -> AsyncStream<Void> {
        startedStream
    }

    func release() {
        pendingBind?.resume(returning: endpoint)
        pendingBind = nil
    }
}
