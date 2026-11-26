/// The full team presence map, delivered first on every subscribe so clients
/// can render immediately and then apply transition events.
public struct PresenceSnapshot: Codable, Equatable, Sendable {
    /// The verified team this snapshot describes.
    public var teamId: String
    /// Server clock at snapshot time, in epoch milliseconds.
    public var now: Double
    /// Server-owned heartbeat cadence; clients render staleness from this
    /// rather than hardcoding the service's timing.
    public var heartbeatIntervalMs: Double
    /// Missed-heartbeat window before the service declares an instance offline.
    public var offlineTimeoutMs: Double
    /// Per-device rollups, most recently seen first.
    public var devices: [PresenceDevice]
}
