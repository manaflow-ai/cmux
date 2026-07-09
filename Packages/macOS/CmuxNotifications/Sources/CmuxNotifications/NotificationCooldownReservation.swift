public import Foundation

/// A pending cooldown bookkeeping entry captured before a notification is
/// applied.
///
/// Pure value type. It records the cooldown key and that key's previous
/// last-fired timestamp so the apply pipeline can either commit the new fire
/// time (when the notification produced an effect) or restore the prior value
/// (when it did not), keeping the per-key cooldown clock accurate either way.
public struct NotificationCooldownReservation: Sendable {
    /// The cooldown key this reservation governs.
    public let key: String
    /// The key's last-fired timestamp at reservation time, or `nil` when the
    /// key had never fired.
    public let previousDate: Date?

    /// Creates a cooldown reservation for `key` capturing its `previousDate`.
    public init(key: String, previousDate: Date?) {
        self.key = key
        self.previousDate = previousDate
    }
}
