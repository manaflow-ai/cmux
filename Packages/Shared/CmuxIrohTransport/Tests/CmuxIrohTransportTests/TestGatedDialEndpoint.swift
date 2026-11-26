import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

/// Test endpoint whose parked dials deliberately ignore task cancellation.
actor TestGatedDialEndpoint: CmxIrohEndpoint {
    private let localIdentity: CmxIrohPeerIdentity
    private var dialCount = 0
    private var pendingDials: [
        CheckedContinuation<any CmxIrohConnection, any Error>
    ] = []

    init(localIdentity: CmxIrohPeerIdentity) {
        self.localIdentity = localIdentity
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
        dialCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingDials.append(continuation)
        }
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
        let pending = pendingDials
        pendingDials.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    func releaseNextDial(with connection: any CmxIrohConnection) {
        guard !pendingDials.isEmpty else { return }
        pendingDials.removeFirst().resume(returning: connection)
    }

    func releaseNewestDial(with connection: any CmxIrohConnection) {
        guard !pendingDials.isEmpty else { return }
        pendingDials.removeLast().resume(returning: connection)
    }

    func failNextDial(_ error: TestIrohTransportError) {
        guard !pendingDials.isEmpty else { return }
        pendingDials.removeFirst().resume(throwing: error)
    }

    func observedDialCount() -> Int {
        dialCount
    }
}
