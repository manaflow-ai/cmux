import CmuxTerminalBackend
import Foundation

struct TerminalBackendTopologyAdmissionLease: Equatable, Sendable {
    let admissionEpoch: UInt64
    let authorizationToken: UUID
    let placement: TerminalBackendTopologyPlacement
}

enum TerminalBackendTopologyAdmissionError: Equatable, Error, Sendable {
    case invalidated
}

/// Suspends terminal attachment until startup topology chooses either daemon state or legacy import.
actor TerminalBackendTopologyAuthorizationGate {
    private struct Authorization: Sendable {
        let authority: BackendAuthority?
        let revision: UInt64?
        let token: UUID
        let legacyToken: UUID?
        let admissionEpoch: UInt64
        let placements: Set<TerminalBackendTopologyPlacement>
    }

    nonisolated private let admissionBarrier = TerminalBackendTopologyAdmissionEpochBarrier()
    private var authorization: Authorization?
    private var didFail = false
    private var waiters: [
        UUID: (
            placement: TerminalBackendTopologyPlacement,
            continuation: CheckedContinuation<TerminalBackendTopologyAdmissionLease, any Error>
        )
    ] = [:]

    /// Invalidates every authorization installed under the preceding epoch.
    ///
    /// This operation is intentionally synchronous and nonisolated. Callers
    /// use it at topology admission boundaries before scheduling actor work,
    /// so an old placement cannot remain usable while a revoke is queued.
    @discardableResult
    nonisolated func advanceAdmissionEpoch() -> UInt64 {
        admissionBarrier.advance()
    }

    nonisolated var currentAdmissionEpoch: UInt64 {
        admissionBarrier.current()
    }

    func waitUntilAuthorized(
        _ placement: TerminalBackendTopologyPlacement
    ) async throws -> TerminalBackendTopologyAdmissionLease {
        while true {
            try Task.checkCancellation()
            if didFail {
                throw TerminalBackendClientError.unavailable
            }
            if let lease = currentLease(for: placement) {
                return lease
            }

            let identifier = UUID()
            let lease = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[identifier] = (placement, continuation)
                }
            } onCancel: {
                Task { await self.cancelWaiter(identifier) }
            }
            try Task.checkCancellation()

            // The synchronous barrier may advance after a continuation is
            // resumed but before this task runs. Recheck instead of leaking a
            // one-shot permit from an obsolete topology.
            if admissionBarrier.isCurrent(lease.admissionEpoch),
               authorization?.admissionEpoch == lease.admissionEpoch,
               authorization?.token == lease.authorizationToken,
               authorization?.placements.contains(lease.placement) == true,
               lease.placement == placement {
                return lease
            }
        }
    }

    /// Revalidates the exact permit after a backend suspension point. Epoch,
    /// authorization token, and placement must all still name the installed
    /// topology admission.
    func validate(_ lease: TerminalBackendTopologyAdmissionLease) throws {
        guard admissionBarrier.isCurrent(lease.admissionEpoch),
              authorization?.admissionEpoch == lease.admissionEpoch,
              authorization?.token == lease.authorizationToken,
              authorization?.placements.contains(lease.placement) == true else {
            throw TerminalBackendTopologyAdmissionError.invalidated
        }
    }

    @discardableResult
    func authorize(
        authority: BackendAuthority,
        revision: UInt64,
        placements: Set<TerminalBackendTopologyPlacement>
    ) -> UUID {
        let token = UUID()
        var installedEpoch: UInt64 = 0
        let admitted = admissionBarrier.withCurrentEpoch { admissionEpoch in
            installedEpoch = admissionEpoch
            return installAuthorization(Authorization(
                authority: authority,
                revision: revision,
                token: token,
                legacyToken: nil,
                admissionEpoch: admissionEpoch,
                placements: placements
            ))
        }
        resume(admitted, at: installedEpoch)
        return token
    }

    /// Installs only if the reconciliation epoch is still current. The epoch
    /// check and actor-state mutation share the barrier lock, preventing a
    /// stale reconciliation from racing a synchronous invalidation.
    @discardableResult
    func authorize(
        authority: BackendAuthority,
        revision: UInt64,
        placements: Set<TerminalBackendTopologyPlacement>,
        admissionEpoch: UInt64
    ) -> UUID? {
        let token = UUID()
        guard let admitted = admissionBarrier.withEpoch(admissionEpoch, {
            installAuthorization(Authorization(
                authority: authority,
                revision: revision,
                token: token,
                legacyToken: nil,
                admissionEpoch: admissionEpoch,
                placements: placements
            ))
        }) else {
            return nil
        }
        resume(admitted, at: admissionEpoch)
        return token
    }

    /// Compatibility seam for focused tests and legacy import while no daemon
    /// authority has been installed yet.
    @discardableResult
    func authorize(_ placements: Set<TerminalBackendTopologyPlacement>) -> UUID {
        let token = UUID()
        var installedEpoch: UInt64 = 0
        let admitted = admissionBarrier.withCurrentEpoch { admissionEpoch in
            installedEpoch = admissionEpoch
            return installAuthorization(Authorization(
                authority: nil,
                revision: nil,
                token: token,
                legacyToken: token,
                admissionEpoch: admissionEpoch,
                placements: placements
            ))
        }
        resume(admitted, at: installedEpoch)
        return token
    }

    /// Epoch-checked variant used by legacy import reconciliation.
    @discardableResult
    func authorize(
        _ placements: Set<TerminalBackendTopologyPlacement>,
        admissionEpoch: UInt64
    ) -> UUID? {
        let token = UUID()
        guard let admitted = admissionBarrier.withEpoch(admissionEpoch, {
            installAuthorization(Authorization(
                authority: nil,
                revision: nil,
                token: token,
                legacyToken: token,
                admissionEpoch: admissionEpoch,
                placements: placements
            ))
        }) else {
            return nil
        }
        resume(admitted, at: admissionEpoch)
        return token
    }

    /// Revokes a disconnected daemon generation without failing pending binds.
    /// They remain suspended until a fresh authoritative snapshot arrives.
    func revoke(authority: BackendAuthority? = nil) {
        guard authority == nil || authorization?.authority == authority else { return }
        authorization = nil
    }

    /// Revokes only the exact installed daemon value. A superseded reconcile
    /// task must not clear a newer revision from the same daemon generation.
    func revoke(authority: BackendAuthority, revision: UInt64) {
        guard authorization?.authority == authority,
              authorization?.revision == revision else { return }
        authorization = nil
    }

    /// Revokes one exact canonical installation epoch. This remains safe when
    /// the same daemon revision is reprojected after a window registry change.
    func revoke(authority: BackendAuthority, revision: UInt64, token: UUID) {
        guard authorization?.authority == authority,
              authorization?.revision == revision,
              authorization?.token == token else { return }
        authorization = nil
    }

    /// Revokes only the authority-free legacy import admission.
    func revokeLegacyAuthorization() {
        guard authorization?.authority == nil,
              authorization?.revision == nil else { return }
        authorization = nil
    }

    /// Revokes only the legacy admission created by one reconciliation task.
    /// A stale task cannot clear a newer legacy import authorization.
    func revokeLegacyAuthorization(token: UUID) {
        guard authorization?.authority == nil,
              authorization?.revision == nil,
              authorization?.legacyToken == token else { return }
        authorization = nil
    }

    func isAuthorized(_ placement: TerminalBackendTopologyPlacement) -> Bool {
        currentLease(for: placement) != nil
    }

    private func currentLease(
        for placement: TerminalBackendTopologyPlacement
    ) -> TerminalBackendTopologyAdmissionLease? {
        guard let authorization,
              authorization.placements.contains(placement) else { return nil }
        guard admissionBarrier.isCurrent(authorization.admissionEpoch) else { return nil }
        return TerminalBackendTopologyAdmissionLease(
            admissionEpoch: authorization.admissionEpoch,
            authorizationToken: authorization.token,
            placement: placement
        )
    }

    private func installAuthorization(
        _ next: Authorization
    ) -> [(
        continuation: CheckedContinuation<TerminalBackendTopologyAdmissionLease, any Error>,
        lease: TerminalBackendTopologyAdmissionLease
    )] {
        didFail = false
        authorization = next
        let admitted = waiters.compactMap { identifier, waiter in
            next.placements.contains(waiter.placement) ? identifier : nil
        }
        var continuations: [(
            continuation: CheckedContinuation<TerminalBackendTopologyAdmissionLease, any Error>,
            lease: TerminalBackendTopologyAdmissionLease
        )] = []
        continuations.reserveCapacity(admitted.count)
        for identifier in admitted {
            if let waiter = waiters.removeValue(forKey: identifier) {
                continuations.append((
                    continuation: waiter.continuation,
                    lease: TerminalBackendTopologyAdmissionLease(
                        admissionEpoch: next.admissionEpoch,
                        authorizationToken: next.token,
                        placement: waiter.placement
                    )
                ))
            }
        }
        return continuations
    }

    private func resume(
        _ admissions: [(
            continuation: CheckedContinuation<TerminalBackendTopologyAdmissionLease, any Error>,
            lease: TerminalBackendTopologyAdmissionLease
        )],
        at admissionEpoch: UInt64
    ) {
        for admission in admissions {
            precondition(admission.lease.admissionEpoch == admissionEpoch)
            admission.continuation.resume(returning: admission.lease)
        }
    }

    func fail() {
        didFail = true
        authorization = nil
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

/// A small lock-backed generation counter shared with the authorization actor.
/// The lock makes invalidation synchronous without moving waiter management out
/// of actor isolation.
private final class TerminalBackendTopologyAdmissionEpochBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    @discardableResult
    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        epoch &+= 1
        return epoch
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return epoch == candidate
    }

    func withCurrentEpoch<Result>(
        _ body: (UInt64) -> Result
    ) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(epoch)
    }

    func withEpoch<Result>(
        _ candidate: UInt64,
        _ body: () -> Result
    ) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == candidate else { return nil }
        return body()
    }
}
