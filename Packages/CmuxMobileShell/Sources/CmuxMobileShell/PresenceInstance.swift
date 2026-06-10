/// One running cmux app instance on a device, as reported by the presence
/// service (`workers/presence`). Identities match the durable registry:
/// `deviceId` is the cmux device UUID (`devices.device_uuid`) and `tag` the
/// app-instance tag (`device_app_instances.tag`).
public struct PresenceInstance: Codable, Equatable, Sendable {
    /// cmux device UUID, matching the registry's `devices.device_uuid`.
    public var deviceId: String
    /// App-instance build tag ("default" for stable), matching
    /// `device_app_instances.tag`.
    public var tag: String
    /// Device platform reported by the host, e.g. "mac" or "ios".
    public var platform: String
    /// Human-readable device name, when the host announced one.
    public var displayName: String?
    /// Capability strings announced by the host instance.
    public var capabilities: [String]
    /// Whether the instance is currently considered online by the service.
    public var online: Bool
    /// Last heartbeat time in epoch milliseconds, matching the service's JSON.
    public var lastSeenAt: Double
    /// Epoch milliseconds of the most recent offline-to-online transition.
    public var onlineSince: Double?
    /// Epoch milliseconds when the instance was declared offline.
    public var offlineAt: Double?
}
