import Foundation

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
