public import Foundation

/// Tracks the last time a notification fired per cooldown key and mints
/// reservations the apply pipeline commits or rolls back.
///
/// Pure value type owned by the terminal-notification store. The store consults
/// ``lastDate(forKey:)`` to drop a notification still inside its cooldown
/// window, takes a ``NotificationCooldownReservation`` via
/// ``makeReservation(key:interval:)`` before applying, then ``commit(_:at:)``s
/// the new fire time once the notification produced an effect or ``restore(_:)``s
/// the previous timestamp when it did not.
public struct NotificationCooldownTracker: Sendable {
    private var lastDateByKey: [String: Date]

    /// Creates an empty cooldown tracker.
    public init() {
        lastDateByKey = [:]
    }

    /// The last time the notification for `key` fired, or `nil` when the key has
    /// never fired.
    public func lastDate(forKey key: String) -> Date? {
        lastDateByKey[key]
    }

    /// Mints a reservation capturing `key`'s current last-fired timestamp, or
    /// `nil` when there is no key or no interval to enforce (callers pass the
    /// already-resolved cooldown interval, so a `nil` interval means no
    /// cooldown applies).
    public func makeReservation(
        key: String?,
        interval: TimeInterval?
    ) -> NotificationCooldownReservation? {
        guard let key, interval != nil else { return nil }
        return NotificationCooldownReservation(
            key: key,
            previousDate: lastDateByKey[key]
        )
    }

    /// Records `date` as the last-fired timestamp for the reservation's key. A
    /// `nil` reservation is a no-op.
    public mutating func commit(
        _ reservation: NotificationCooldownReservation?,
        at date: Date
    ) {
        guard let reservation else { return }
        lastDateByKey[reservation.key] = date
    }

    /// Rolls the reservation's key back to its captured `previousDate`, removing
    /// the entry entirely when the key had never fired. A `nil` reservation is a
    /// no-op.
    public mutating func restore(_ reservation: NotificationCooldownReservation?) {
        guard let reservation else { return }
        if let previousDate = reservation.previousDate {
            lastDateByKey[reservation.key] = previousDate
        } else {
            lastDateByKey.removeValue(forKey: reservation.key)
        }
    }

    /// Removes stale cooldown entries and caps the retained cache size.
    /// - Returns: Number of entries removed.
    public mutating func trim(
        now: Date,
        staleAge: TimeInterval,
        maxEntries: Int
    ) -> Int {
        let beforeCount = lastDateByKey.count
        lastDateByKey = Self.trimDateCache(
            lastDateByKey,
            now: now,
            staleAge: staleAge,
            maxEntries: maxEntries
        )
        return Swift.max(0, beforeCount - lastDateByKey.count)
    }

    private static func trimDateCache<Key: Hashable>(
        _ cache: [Key: Date],
        now: Date,
        staleAge: TimeInterval,
        maxEntries: Int
    ) -> [Key: Date] {
        let freshEntries = cache.filter { _, date in
            now.timeIntervalSince(date) <= staleAge
        }
        guard freshEntries.count > maxEntries else { return freshEntries }
        return Dictionary(
            uniqueKeysWithValues: freshEntries
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) }
        )
    }
}
