public import CMUXMobileCore

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
    /// The host app's bundle id, when reported. Lets the UI label the build
    /// channel (Stable / Nightly / RC / DEV) — see ``MacBuildChannel``. `nil` for
    /// an older host that doesn't announce it.
    public var bundleId: String?
    /// The Mac-chosen mobile transport mode (`cmuxRelay`/`ownRelay`/`tailscale`),
    /// shown as a read-only badge on the Computers screen. `nil` for an older
    /// host that doesn't announce it. Opaque string on the wire so new modes
    /// roll out without breaking older phones.
    public var transportMode: String?
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
    /// The instance's current attach routes, mirrored live from the host's
    /// heartbeat (the same set the durable registry stores). `nil` when the
    /// host has not announced routes on this record. Decoded with the same
    /// per-entry leniency as the registry list (``DeviceRegistryService``): a
    /// malformed or unknown-kind route is dropped, never fails the frame, so
    /// new route kinds roll out without breaking older phones.
    public var routes: [CmxAttachRoute]?

    private enum CodingKeys: String, CodingKey {
        case deviceId
        case tag
        case platform
        case displayName
        case bundleId
        case transportMode
        case capabilities
        case online
        case lastSeenAt
        case onlineSince
        case offlineAt
        case routes
    }

    /// A per-entry failable route, so one unknown/malformed route drops out
    /// instead of failing the whole presence frame (mirrors the registry
    /// list's decode contract).
    private struct FailableRoute: Decodable {
        let value: CmxAttachRoute?
        init(from decoder: any Decoder) {
            value = try? CmxAttachRoute(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        tag = try container.decode(String.self, forKey: .tag)
        platform = try container.decode(String.self, forKey: .platform)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        transportMode = try container.decodeIfPresent(String.self, forKey: .transportMode)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        online = try container.decode(Bool.self, forKey: .online)
        lastSeenAt = try container.decode(Double.self, forKey: .lastSeenAt)
        onlineSince = try container.decodeIfPresent(Double.self, forKey: .onlineSince)
        offlineAt = try container.decodeIfPresent(Double.self, forKey: .offlineAt)
        routes = try container.decodeIfPresent([FailableRoute].self, forKey: .routes)?
            .compactMap(\.value)
    }

    public init(
        deviceId: String,
        tag: String,
        platform: String,
        displayName: String? = nil,
        bundleId: String? = nil,
        transportMode: String? = nil,
        capabilities: [String] = [],
        online: Bool,
        lastSeenAt: Double,
        onlineSince: Double? = nil,
        offlineAt: Double? = nil,
        routes: [CmxAttachRoute]? = nil
    ) {
        self.deviceId = deviceId
        self.tag = tag
        self.platform = platform
        self.displayName = displayName
        self.bundleId = bundleId
        self.transportMode = transportMode
        self.capabilities = capabilities
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.onlineSince = onlineSince
        self.offlineAt = offlineAt
        self.routes = routes
    }
}
