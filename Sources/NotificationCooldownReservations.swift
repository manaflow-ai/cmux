import Foundation

extension TerminalNotificationStore {
    nonisolated static func externalBannerTransition(
        incoming: TerminalNotification,
        latestExisting: TerminalNotification?
    ) -> (supersededId: String?, suppressIncoming: Bool) {
        guard let latestExisting else { return (nil, false) }
        guard notificationSortPrecedes(incoming, latestExisting) else { return (nil, true) }
        // Every chronological owner superseded its predecessor, so retained
        // history must not re-enter bounded external-dismissal buffers.
        return (latestExisting.id.uuidString, false)
    }
}

struct NotificationCooldownReservations {
    struct Reservation: Sendable {
        let key: String
        let owner: UUID
    }

    private struct KeyState {
        var committedDate: Date?
        var activeDatesByOwner: [UUID: Date]
    }

    private var stateByKey: [String: KeyState] = [:]

    mutating func reserve(
        key: String?,
        interval: TimeInterval?,
        acceptedAt: Date,
        dates: inout [String: Date]
    ) -> Reservation? {
        guard let key, interval != nil else { return nil }
        let reservation = Reservation(key: key, owner: UUID())
        var state = stateByKey[key] ?? KeyState(
            committedDate: dates[key],
            activeDatesByOwner: [:]
        )
        state.activeDatesByOwner[reservation.owner] = acceptedAt
        stateByKey[key] = state
        updateEffectiveDate(for: key, state: state, dates: &dates)
        return reservation
    }

    mutating func commit(
        _ reservation: Reservation?,
        at date: Date,
        dates: inout [String: Date]
    ) {
        guard let reservation,
              var state = stateByKey[reservation.key],
              state.activeDatesByOwner.removeValue(forKey: reservation.owner) != nil else { return }
        state.committedDate = max(state.committedDate ?? date, date)
        finish(reservation, state: state, dates: &dates)
    }

    mutating func restore(
        _ reservation: Reservation?,
        dates: inout [String: Date]
    ) {
        guard let reservation,
              var state = stateByKey[reservation.key],
              state.activeDatesByOwner.removeValue(forKey: reservation.owner) != nil else { return }
        finish(reservation, state: state, dates: &dates)
    }

    private mutating func finish(
        _ reservation: Reservation,
        state: KeyState,
        dates: inout [String: Date]
    ) {
        updateEffectiveDate(for: reservation.key, state: state, dates: &dates)
        if state.activeDatesByOwner.isEmpty {
            stateByKey.removeValue(forKey: reservation.key)
        } else {
            stateByKey[reservation.key] = state
        }
    }

    private func updateEffectiveDate(
        for key: String,
        state: KeyState,
        dates: inout [String: Date]
    ) {
        let effectiveDate = state.activeDatesByOwner.values.reduce(state.committedDate, maxOptionalDate)
        if let effectiveDate {
            dates[key] = effectiveDate
        } else {
            dates.removeValue(forKey: key)
        }
    }

    private func maxOptionalDate(_ current: Date?, _ candidate: Date) -> Date? {
        max(current ?? candidate, candidate)
    }
}
