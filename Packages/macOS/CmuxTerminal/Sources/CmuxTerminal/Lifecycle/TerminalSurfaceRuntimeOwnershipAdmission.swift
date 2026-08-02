import Foundation
internal import os

typealias TerminalSurfaceRuntimeOwnershipRecovery =
    @MainActor @Sendable (TerminalSurfaceRuntimeOwnershipReservation) -> Void

/// Synchronous, bounded admission for native-surface ownership.
///
/// Creation, public teardown, and deinit cannot suspend while transferring a
/// native pointer, so this ledger uses one short unfair-lock critical section.
/// Native work never runs under the lock. A fully stalled close pool degrades
/// admission until a worker returns, preventing repeated create/close cycles
/// from growing an unbounded retained teardown backlog.
final class TerminalSurfaceRuntimeOwnershipAdmission: @unchecked Sendable {
    private let maximumOwnerCount: Int
    private let state = OSAllocatedUnfairLock(
        initialState: TerminalSurfaceRuntimeOwnershipAdmissionState()
    )

    init(maximumOwnerCount: Int) {
        precondition(
            maximumOwnerCount >= TerminalSurfaceRuntimeTeardownCoordinator
                .maximumConcurrentCloseTeardownCount,
            "native surface ownership must cover every close worker"
        )
        self.maximumOwnerCount = maximumOwnerCount
    }

    func reserve(
        recoveryID: UUID? = nil,
        onRecovery: TerminalSurfaceRuntimeOwnershipRecovery? = nil
    ) -> TerminalSurfaceRuntimeOwnershipReservation? {
        state.withLock { state in
            guard !state.closeTeardownDegraded,
                  state.reservationIDs.count < maximumOwnerCount else {
                if let recoveryID, let onRecovery {
                    enqueueRecoveryAction(
                        onRecovery,
                        id: recoveryID,
                        in: &state
                    )
                }
                return nil
            }
            if let recoveryID {
                _ = removeRecoveryAction(recoveryID, from: &state)
            }
            let reservation = TerminalSurfaceRuntimeOwnershipReservation()
            state.reservationIDs.insert(reservation.id)
            return reservation
        }
    }

    func contains(_ reservation: TerminalSurfaceRuntimeOwnershipReservation) -> Bool {
        state.withLock { $0.reservationIDs.contains(reservation.id) }
    }

    func release(_ reservation: TerminalSurfaceRuntimeOwnershipReservation) {
        let recoveryActions = state.withLock { state in
            _ = state.reservationIDs.remove(reservation.id)
            return takeAvailableRecoveryActions(from: &state)
        }
        schedule(recoveryActions)
    }

    func setCloseTeardownDegraded(_ degraded: Bool) {
        let recoveryActions = state.withLock { state in
            state.closeTeardownDegraded = degraded
            return takeAvailableRecoveryActions(from: &state)
        }
        schedule(recoveryActions)
    }

    func cancelRecovery(_ recoveryID: UUID) {
        state.withLock { state in
            _ = removeRecoveryAction(recoveryID, from: &state)
        }
    }

    private func removeRecoveryAction(
        _ recoveryID: UUID,
        from state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> TerminalSurfaceRuntimeOwnershipRecovery? {
        guard let entry = state.recoveryEntriesByID.removeValue(
            forKey: recoveryID
        ) else {
            return nil
        }
        if let previousID = entry.previousID {
            state.recoveryEntriesByID[previousID]?.nextID = entry.nextID
        } else {
            state.recoveryHeadID = entry.nextID
        }
        if let nextID = entry.nextID {
            state.recoveryEntriesByID[nextID]?.previousID = entry.previousID
        } else {
            state.recoveryTailID = entry.previousID
        }
        return entry.action
    }

    private func enqueueRecoveryAction(
        _ action: @escaping TerminalSurfaceRuntimeOwnershipRecovery,
        id recoveryID: UUID,
        in state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) {
        if state.recoveryEntriesByID[recoveryID] != nil {
            state.recoveryEntriesByID[recoveryID]?.action = action
            return
        }
        let previousID = state.recoveryTailID
        state.recoveryEntriesByID[recoveryID] =
            TerminalSurfaceRuntimeOwnershipRecoveryEntry(
                action: action,
                previousID: previousID,
                nextID: nil
            )
        if let previousID {
            state.recoveryEntriesByID[previousID]?.nextID = recoveryID
        } else {
            state.recoveryHeadID = recoveryID
        }
        state.recoveryTailID = recoveryID
    }

    private func takeAvailableRecoveryActions(
        from state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> [TerminalSurfaceRuntimeOwnershipRecoveryGrant] {
        guard !state.closeTeardownDegraded else { return [] }
        let availableCount = maximumOwnerCount - state.reservationIDs.count
        guard availableCount > 0, state.recoveryHeadID != nil else {
            return []
        }
        var recoveryGrants: [TerminalSurfaceRuntimeOwnershipRecoveryGrant] = []
        while recoveryGrants.count < availableCount,
              let recoveryID = state.recoveryHeadID {
            if let recoveryAction = removeRecoveryAction(
                recoveryID,
                from: &state
            ) {
                let reservation = TerminalSurfaceRuntimeOwnershipReservation()
                state.reservationIDs.insert(reservation.id)
                recoveryGrants.append(
                    TerminalSurfaceRuntimeOwnershipRecoveryGrant(
                        action: recoveryAction,
                        reservation: reservation
                    )
                )
            }
        }
        return recoveryGrants
    }

    private func schedule(
        _ recoveryGrants: [TerminalSurfaceRuntimeOwnershipRecoveryGrant]
    ) {
        for recoveryGrant in recoveryGrants {
            Task { @MainActor in
                recoveryGrant.action(recoveryGrant.reservation)
            }
        }
    }

#if DEBUG
    var debugCloseTeardownDegraded: Bool {
        state.withLock { $0.closeTeardownDegraded }
    }

    var debugOwnerCount: Int {
        state.withLock { $0.reservationIDs.count }
    }
#endif
}
