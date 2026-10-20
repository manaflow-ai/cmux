/// Per-device presence rollup from the service's snapshot: a device is online
/// when any of its app instances is online.
public struct PresenceDevice: Codable, Equatable, Sendable {
    /// cmux device UUID, matching the registry's `devices.device_uuid`.
    public var deviceId: String
    /// Device platform reported by the host, e.g. "mac" or "ios".
    public var platform: String
    /// Human-readable device name, when any instance announced one.
    public var displayName: String?
    /// Whether any of the device's instances is currently online.
    public var online: Bool
    /// Most recent heartbeat over all instances, in epoch milliseconds.
    public var lastSeenAt: Double
    /// The device's app instances, newest heartbeat first.
    public var instances: [PresenceInstance]
}
