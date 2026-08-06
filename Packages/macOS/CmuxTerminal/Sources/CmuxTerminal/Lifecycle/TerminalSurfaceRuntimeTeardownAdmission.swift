import Foundation

/// Main-actor admission state for bounded hibernation teardown reservations.
@MainActor
final class TerminalSurfaceRuntimeTeardownAdmission {
    private var reservationIDs: Set<UUID> = []

    nonisolated init() {}

    func reserve() -> TerminalSurfaceRuntimeTeardownReservation? {
        let maximumCount = TerminalSurfaceRuntimeTeardownCoordinator
            .maximumHibernationTeardownCount
        guard reservationIDs.count < maximumCount else {
            return nil
        }
        let reservation = TerminalSurfaceRuntimeTeardownReservation()
        reservationIDs.insert(reservation.id)
        return reservation
    }

    func release(_ reservation: TerminalSurfaceRuntimeTeardownReservation) {
        _ = reservationIDs.remove(reservation.id)
    }
}
