import Foundation

/// Suspends terminal attachment until startup topology chooses either daemon state or legacy import.
actor TerminalBackendTopologyAuthorizationGate {
    private var authorizedPlacements: Set<TerminalBackendTopologyPlacement>?
    private var didFail = false
    private var waiters: [
        UUID: (
            placement: TerminalBackendTopologyPlacement,
            continuation: CheckedContinuation<Void, any Error>
        )
    ] = [:]

    func waitUntilAuthorized(
        _ placement: TerminalBackendTopologyPlacement
    ) async throws {
        try Task.checkCancellation()
        if didFail {
            throw TerminalBackendClientError.unavailable
        }
        if authorizedPlacements?.contains(placement) == true {
            return
        }

        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[identifier] = (placement, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    func authorize(_ placements: Set<TerminalBackendTopologyPlacement>) {
        didFail = false
        authorizedPlacements = placements
        let admitted = waiters.compactMap { identifier, waiter in
            placements.contains(waiter.placement) ? identifier : nil
        }
        for identifier in admitted {
            waiters.removeValue(forKey: identifier)?.continuation.resume()
        }
    }

    func fail() {
        didFail = true
        authorizedPlacements = nil
        let pending = waiters.values.map(\.continuation)
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(throwing: TerminalBackendClientError.unavailable)
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        waiters.removeValue(forKey: identifier)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}
