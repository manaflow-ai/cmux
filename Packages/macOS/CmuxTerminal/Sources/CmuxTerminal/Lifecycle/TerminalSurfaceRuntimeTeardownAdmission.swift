import Foundation
internal import os

/// Synchronous, bounded admission for native-surface ownership.
///
/// Creation and deinit cannot suspend while transferring a native pointer, so
/// this ledger uses one short unfair-lock critical section. Native work never
/// runs under the lock. A fully stalled close pool degrades admission until a
/// worker returns, preventing repeated create/close cycles from growing an
/// unbounded retained teardown backlog.
final class TerminalSurfaceRuntimeOwnershipAdmission: @unchecked Sendable {
    private struct State {
        var reservationIDs: Set<UUID> = []
        var closeTeardownDegraded = false
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

    func reserve() -> TerminalSurfaceRuntimeOwnershipReservation? {
        state.withLock { state in
            guard !state.closeTeardownDegraded,
                  state.reservationIDs.count < maximumOwnerCount else {
                return nil
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
        state.withLock { state in
            _ = state.reservationIDs.remove(reservation.id)
        }
    }

    func setCloseTeardownDegraded(_ degraded: Bool) {
        state.withLock { $0.closeTeardownDegraded = degraded }
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
