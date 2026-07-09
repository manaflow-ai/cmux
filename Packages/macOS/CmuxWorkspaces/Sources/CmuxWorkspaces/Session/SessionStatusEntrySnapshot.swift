public import Foundation

/// One persisted workspace status-line entry inside a session snapshot.
///
/// A pure leaf value carrying the key/value the status badge displays, its
/// optional SF Symbol `icon` and tint `color` (hex), and the `timestamp` the
/// entry was recorded (`timeIntervalSince1970`). The on-disk wire format is
/// owned by the app's `SessionTerminalPanelSnapshot`, which carries an array of
/// these values; encoding stays byte-identical to the legacy app-target
/// definition (same stored-property set, same `Codable` synthesis).
public struct SessionStatusEntrySnapshot: Codable, Sendable {
    /// Stable status key used to sort and de-duplicate entries.
    public var key: String
    /// Displayed status value.
    public var value: String
    /// Optional SF Symbol name shown beside the value.
    public var icon: String?
    /// Optional tint (hex string) for the badge.
    public var color: String?
    /// When the entry was recorded, as `timeIntervalSince1970`.
    public var timestamp: TimeInterval

    /// Creates a persisted status entry.
    public init(
        key: String,
        value: String,
        icon: String?,
        color: String?,
        timestamp: TimeInterval
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.timestamp = timestamp
    }
}
