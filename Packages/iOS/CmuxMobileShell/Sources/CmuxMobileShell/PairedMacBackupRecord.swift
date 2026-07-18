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
        customIcon: String? = nil
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
        self.customName = customName
        self.customColor = customColor
        self.customIcon = customIcon
    }

    enum CodingKeys: String, CodingKey {
        case macDeviceID, displayName, routes, createdAt, lastSeenAt, isActive
        case customName, customColor, customIcon
    }

    /// Decode one saved-host backup record, dropping unsupported route entries
    /// while preserving the rest of the record for restore.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macDeviceID = try c.decode(String.self, forKey: .macDeviceID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        routes = try c.decodeIfPresent([PairedMacBackupFailableRoute].self, forKey: .routes)?
            .compactMap(\.value) ?? []
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        lastSeenAt = try c.decode(Double.self, forKey: .lastSeenAt)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        customColor = try c.decodeIfPresent(String.self, forKey: .customColor)
        customIcon = try c.decodeIfPresent(String.self, forKey: .customIcon)
    }

    /// Encode custom override keys even when they are `nil`, so clears sync.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(macDeviceID, forKey: .macDeviceID)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encode(routes, forKey: .routes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastSeenAt, forKey: .lastSeenAt)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(customName, forKey: .customName)
        try c.encode(customColor, forKey: .customColor)
        try c.encode(customIcon, forKey: .customIcon)
    }
}
