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
        let recoveryGrant = state.withLock { state in
            _ = state.reservationIDs.remove(reservation.id)
            return takeNextRecoveryGrant(from: &state)
        }
        schedule(recoveryGrant)
    }

    func setCloseTeardownDegraded(_ degraded: Bool) {
        let recoveryGrant = state.withLock { state in
            state.closeTeardownDegraded = degraded
            return takeNextRecoveryGrant(from: &state)
        }
        schedule(recoveryGrant)
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

    private func takeNextRecoveryGrant(
        from state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> TerminalSurfaceRuntimeOwnershipRecoveryGrant? {
        guard !state.closeTeardownDegraded,
              !state.recoveryGrantIsScheduled,
              state.reservationIDs.count < maximumOwnerCount,
              let recoveryID = state.recoveryHeadID,
              let recoveryAction = removeRecoveryAction(
                  recoveryID,
                  from: &state
              ) else {
            return nil
        }
        let reservation = TerminalSurfaceRuntimeOwnershipReservation()
        state.reservationIDs.insert(reservation.id)
        state.recoveryGrantIsScheduled = true
        return TerminalSurfaceRuntimeOwnershipRecoveryGrant(
            action: recoveryAction,
            reservation: reservation
        )
    }

    private func schedule(
        _ recoveryGrant: TerminalSurfaceRuntimeOwnershipRecoveryGrant?
    ) {
        guard let recoveryGrant else { return }
        Task { @MainActor in
            recoveryGrant.action(recoveryGrant.reservation)
            recoveryGrantDidComplete()
        }
    }

    private func recoveryGrantDidComplete() {
        let recoveryGrant = state.withLock { state in
            state.recoveryGrantIsScheduled = false
            return takeNextRecoveryGrant(from: &state)
        }
        schedule(recoveryGrant)
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
