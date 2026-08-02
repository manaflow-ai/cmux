import Foundation
internal import os

typealias TerminalSurfaceRuntimeOwnershipRecovery =
    @MainActor @Sendable (TerminalSurfaceRuntimeOwnershipReservation) -> Void

/// Synchronous, bounded admission for native-surface ownership.
///
/// Creation and deinit cannot suspend while transferring a native pointer, so
/// this ledger uses one short unfair-lock critical section. Native work never
/// runs under the lock. A fully stalled close pool degrades admission until a
/// worker returns, preventing repeated create/close cycles from growing an
/// unbounded retained teardown backlog.
final class TerminalSurfaceRuntimeOwnershipAdmission: @unchecked Sendable {
    private struct RecoveryGrant: Sendable {
        let action: TerminalSurfaceRuntimeOwnershipRecovery
        let reservation: TerminalSurfaceRuntimeOwnershipReservation
    }

    private struct RecoveryEntry {
        var action: TerminalSurfaceRuntimeOwnershipRecovery
        var previousID: UUID?
        var nextID: UUID?
    }

    private struct State {
        var reservationIDs: Set<UUID> = []
        var closeTeardownDegraded = false
        var recoveryEntriesByID: [UUID: RecoveryEntry] = [:]
        var recoveryHeadID: UUID?
        var recoveryTailID: UUID?
    }

    private let maximumOwnerCount: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

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
        from state: inout State
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
        in state: inout State
    ) {
        if state.recoveryEntriesByID[recoveryID] != nil {
            state.recoveryEntriesByID[recoveryID]?.action = action
            return
        }
        let previousID = state.recoveryTailID
        state.recoveryEntriesByID[recoveryID] = RecoveryEntry(
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
        from state: inout State
    ) -> [RecoveryGrant] {
        guard !state.closeTeardownDegraded else { return [] }
        let availableCount = maximumOwnerCount - state.reservationIDs.count
        guard availableCount > 0, state.recoveryHeadID != nil else {
            return []
        }
        var recoveryGrants: [RecoveryGrant] = []
        while recoveryGrants.count < availableCount,
              let recoveryID = state.recoveryHeadID {
            if let recoveryAction = removeRecoveryAction(
                recoveryID,
                from: &state
            ) {
                let reservation = TerminalSurfaceRuntimeOwnershipReservation()
                state.reservationIDs.insert(reservation.id)
                recoveryGrants.append(
                    RecoveryGrant(
                        action: recoveryAction,
                        reservation: reservation
                    )
                )
            }
        }
        return recoveryGrants
    }

    private func schedule(
        _ recoveryGrants: [RecoveryGrant]
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

/// Main-actor admission state for one coordinator's bounded native-free slots.
@MainActor
final class TerminalSurfaceRuntimeTeardownAdmission {
    private var availableExecutionSlots: Set<Int>
    private var executionSlotByReservationID: [UUID: Int] = [:]

    nonisolated init() {
        availableExecutionSlots = Set(
            0..<TerminalSurfaceRuntimeTeardownCoordinator
                .maximumIsolatedHibernationTeardownCount
        )
    }

    func reserve() -> TerminalSurfaceRuntimeTeardownReservation? {
        guard let executionSlot = availableExecutionSlots.min() else {
            return nil
        }
        let reservation = TerminalSurfaceRuntimeTeardownReservation()
        availableExecutionSlots.remove(executionSlot)
        executionSlotByReservationID[reservation.id] = executionSlot
        return reservation
    }

    func executionSlot(
        for reservation: TerminalSurfaceRuntimeTeardownReservation
    ) -> Int? {
        executionSlotByReservationID[reservation.id]
    }

    func release(_ reservation: TerminalSurfaceRuntimeTeardownReservation) {
        guard let executionSlot = executionSlotByReservationID.removeValue(
            forKey: reservation.id
        ) else {
            return
        }
        availableExecutionSlots.insert(executionSlot)
    }
}
