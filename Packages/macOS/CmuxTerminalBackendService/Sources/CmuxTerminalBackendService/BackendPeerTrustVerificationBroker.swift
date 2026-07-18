internal import CmuxTerminalBackend
internal import Dispatch
internal import Foundation

/// Serializes synchronous live-code inspection behind one dedicated queue.
///
/// Security.framework and token-aware path lookup are synchronous. A wedged
/// call therefore cannot be cancelled safely. This broker permits at most one
/// such call process-wide, deduplicates repeated checks from the same probe and
/// peer identity, and removes cancelled queued waiters before they start work.
internal actor BackendPeerTrustVerificationBroker {
    internal static let shared = BackendPeerTrustVerificationBroker()

    private struct Key: Equatable, Sendable {
        let scopeID: UUID
        let identity: BackendPeerIdentity
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<BackendPeerTrustEvidence, any Error>
    }

    private struct PendingGroup {
        let key: Key
        let verifier: any BackendPeerTrustVerifying
        var waiters: [Waiter]
    }

    private let queue = DispatchQueue(
        label: "com.cmux.terminal-backend.peer-trust",
        qos: .userInitiated
    )
    private var activeKey: Key?
    private var activeWaiters: [Waiter] = []
    private var pending: [PendingGroup] = []

    internal func verify(
        scopeID: UUID,
        identity: BackendPeerIdentity,
        using verifier: any BackendPeerTrustVerifying
    ) async throws -> BackendPeerTrustEvidence {
        let waiterID = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    key: Key(scopeID: scopeID, identity: identity),
                    verifier: verifier,
                    waiter: Waiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    private func enqueue(
        key: Key,
        verifier: any BackendPeerTrustVerifying,
        waiter: Waiter
    ) {
        if activeKey == key {
            activeWaiters.append(waiter)
            return
        }
        if let index = pending.firstIndex(where: { $0.key == key }) {
            pending[index].waiters.append(waiter)
        } else {
            pending.append(PendingGroup(key: key, verifier: verifier, waiters: [waiter]))
        }
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard activeKey == nil, !pending.isEmpty else { return }
        let group = pending.removeFirst()
        activeKey = group.key
        activeWaiters = group.waiters
        let key = group.key
        let verifier = group.verifier
        queue.async {
            let result = Result { try verifier.verify(key.identity) }
            Task { await self.finish(key: key, result: result) }
        }
    }

    private func finish(
        key: Key,
        result: Result<BackendPeerTrustEvidence, any Error>
    ) {
        guard activeKey == key else { return }
        let waiters = activeWaiters
        activeKey = nil
        activeWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.continuation.resume(with: result)
        }
        startNextIfIdle()
    }

    private func cancel(waiterID: UUID) {
        if let index = activeWaiters.firstIndex(where: { $0.id == waiterID }) {
            activeWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
            return
        }
        for groupIndex in pending.indices {
            guard let waiterIndex = pending[groupIndex].waiters.firstIndex(
                where: { $0.id == waiterID }
            ) else { continue }
            pending[groupIndex].waiters.remove(at: waiterIndex)
                .continuation.resume(throwing: CancellationError())
            if pending[groupIndex].waiters.isEmpty {
                pending.remove(at: groupIndex)
            }
            return
        }
    }
}
