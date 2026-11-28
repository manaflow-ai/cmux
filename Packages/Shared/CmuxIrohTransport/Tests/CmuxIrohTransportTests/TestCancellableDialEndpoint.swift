import CMUXMobileCore
import Foundation
@testable import CmuxIrohTransport

/// Test endpoint whose parked dials settle immediately when their task is cancelled.
actor TestCancellableDialEndpoint: CmxIrohEndpoint {
    private let localIdentity: CmxIrohPeerIdentity
    private var dialCount = 0
    private var deliveredConnectionCount = 0
    private var pendingDialOrder: [UUID] = []
    private var pendingDials: [
        UUID: CheckedContinuation<any CmxIrohConnection, any Error>
    ] = [:]

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
        let dialID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingDialOrder.append(dialID)
                pendingDials[dialID] = continuation
            }
        }, onCancel: {
            Task { await self.cancelDial(dialID) }
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
        let pending = Array(pendingDials.values)
        pendingDials.removeAll()
        pendingDialOrder.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    func releaseNextDial(with connection: any CmxIrohConnection) {
        guard !pendingDialOrder.isEmpty else { return }
        let dialID = pendingDialOrder.removeFirst()
        guard let continuation = pendingDials.removeValue(forKey: dialID) else {
            return
        }
        deliveredConnectionCount += 1
        continuation.resume(returning: connection)
    }

    func observedDialCount() -> Int {
        dialCount
    }

    func observedDeliveredConnectionCount() -> Int {
        deliveredConnectionCount
    }

    private func cancelDial(_ dialID: UUID) {
        guard let continuation = pendingDials.removeValue(forKey: dialID) else {
            return
        }
        pendingDialOrder.removeAll { $0 == dialID }
        continuation.resume(throwing: CancellationError())
    }
}
