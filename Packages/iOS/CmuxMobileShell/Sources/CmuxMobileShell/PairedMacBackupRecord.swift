public import CMUXMobileCore
public import Foundation

/// One saved-host backup record on the wire.
public struct PairedMacBackupRecord: Codable, Sendable, Equatable {
    /// Stable device id of the Mac this backup row describes.
    public var macDeviceID: String
    /// Latest user-facing Mac name reported by the host, if any.
    public var displayName: String?
    /// Reconnect routes the phone can use to reach this Mac.
    public var routes: [CmxAttachRoute]
    /// Authenticated Mac app-instance tag that owns those routes. `nil` keeps
    /// the conservative legacy sole-instance policy.
    public var instanceTag: String?
    /// Creation time in epoch milliseconds.
    public var createdAt: Double
    /// Last update time in epoch milliseconds.
    public var lastSeenAt: Double
    /// Whether this Mac was the active host in its account/team scope.
    public var isActive: Bool
    /// User-selected display name override.
    public var customName: String?
    /// User-selected color override, or `nil` for automatic color selection.
    public var customColor: String?
    /// User-selected icon override, or `nil` for the platform default.
    public var customIcon: String?

    /// Create one wire backup record.
    public init(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        createdAt: Double,
        lastSeenAt: Double,
        isActive: Bool,
        customName: String? = nil,
        customColor: String? = nil,
        customIcon: String? = nil,
        routeDisclosureDate: Date = Date(),
        instanceTag: String? = nil
    ) {
        self.macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        self.displayName = displayName
        self.routes = PairedMacBackupRouteDisclosure(routes: routes)
            .cloudSafe(at: routeDisclosureDate)
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
        self.customName = customName
        self.customColor = customColor
        self.customIcon = customIcon
        self.instanceTag = instanceTag
    }

    enum CodingKeys: String, CodingKey {
        case macDeviceID, displayName, routes, createdAt, lastSeenAt, isActive
        case customName, customColor, customIcon, instanceTag
        case instanceTagWriteMode
    }

    /// Decode one saved-host backup record, dropping unsupported route entries
    /// while preserving the rest of the record for restore.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macDeviceID = cmxCanonicalDeviceID(
            try c.decode(String.self, forKey: .macDeviceID)
        )
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        let decodedRoutes = try c.decodeIfPresent(
            [PairedMacBackupFailableRoute].self,
            forKey: .routes
        )?.compactMap(\.value) ?? []
        // Decoding must be deterministic. Upload boundaries already prune
        // expired hints with an injected clock; restore defensively removes
        // every non-public Iroh hint without consulting wall time.
        routes = PairedMacBackupRouteDisclosure(routes: decodedRoutes).cloudPrivacySafe()
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        lastSeenAt = try c.decode(Double.self, forKey: .lastSeenAt)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        customColor = try c.decodeIfPresent(String.self, forKey: .customColor)
        customIcon = try c.decodeIfPresent(String.self, forKey: .customIcon)
        instanceTag = try c.decodeIfPresent(String.self, forKey: .instanceTag)
    }

    /// Encode custom override keys even when they are `nil`, so clears sync.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cmxCanonicalDeviceID(macDeviceID), forKey: .macDeviceID)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encode(
            PairedMacBackupRouteDisclosure(routes: routes).cloudPrivacySafe(),
            forKey: .routes
        )
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastSeenAt, forKey: .lastSeenAt)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(customName, forKey: .customName)
        try c.encode(customColor, forKey: .customColor)
        try c.encode(customIcon, forKey: .customIcon)
        try c.encode(instanceTag, forKey: .instanceTag)
    }
}
