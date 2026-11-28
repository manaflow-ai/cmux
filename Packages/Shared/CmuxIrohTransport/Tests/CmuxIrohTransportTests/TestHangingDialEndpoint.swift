import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

actor TestHangingDialEndpoint: CmxIrohEndpoint {
    private let localIdentity: CmxIrohPeerIdentity
    private let startedStream: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let cancelledStream: AsyncStream<Void>
    private let cancelledContinuation: AsyncStream<Void>.Continuation
    private var pendingConnect: CheckedContinuation<any CmxIrohConnection, any Error>?

    init(localIdentity: CmxIrohPeerIdentity) {
        self.localIdentity = localIdentity
        let started = AsyncStream<Void>.makeStream()
        startedStream = started.stream
        startedContinuation = started.continuation
        let cancelled = AsyncStream<Void>.makeStream()
        cancelledStream = cancelled.stream
        cancelledContinuation = cancelled.continuation
    }

    func identity() -> CmxIrohPeerIdentity {
        localIdentity
    }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: localIdentity, pathHints: [])
    }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) async throws -> any CmxIrohConnection {
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pendingConnect = continuation
                startedContinuation.yield()
            }
        }, onCancel: { [cancelledContinuation] in
            cancelledContinuation.yield()
            Task { await self.cancelPendingConnect() }
        })
    }

    func accept() async throws -> (any CmxIrohConnection)? {
        nil
    }

    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        AsyncStream { $0.finish() }
    }

    func isHealthy() -> Bool { true }

    func close() {
        cancelPendingConnect()
    }

    func startedEvents() -> AsyncStream<Void> {
        startedStream
    }

    func cancelledEvents() -> AsyncStream<Void> {
        cancelledStream
    }

    private func cancelPendingConnect() {
        pendingConnect?.resume(throwing: CancellationError())
        pendingConnect = nil
    }
}
