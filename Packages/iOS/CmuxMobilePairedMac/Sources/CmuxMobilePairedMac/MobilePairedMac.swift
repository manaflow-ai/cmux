public import CMUXMobileCore
public import Foundation

/// A Mac paired with this iOS device, persisted across launches.
///
/// The attach token is local-only durable reconnect state hydrated from
/// device-only secret storage; backup sync deliberately omits it so only this
/// device can redeem the ticket without a Stack round trip.
public struct MobilePairedMac: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier of the paired Mac device.
    public var macDeviceID: String
    /// Human-readable name of the Mac, if the pairing payload supplied one.
    public var displayName: String?
    /// Attach routes advertised by the Mac, ordered by priority (lowest first).
    public var routes: [CmxAttachRoute]
    /// Local-only attach ticket secret, hydrated from device-only secret storage.
    public var attachToken: String? = nil
    /// Expiration time for ``attachToken``.
    public var attachTokenExpiresAt: Date? = nil
    /// Workspace scope for ``attachToken``. `nil` means the scope was not persisted.
    public var attachTokenWorkspaceID: String? = nil
    /// Terminal scope for ``attachToken``. `nil` means the token is not terminal-pinned.
    public var attachTokenTerminalID: String? = nil
    /// When this pairing was first recorded.
    public var createdAt: Date
    /// When this pairing was last refreshed or used.
    public var lastSeenAt: Date
    /// Whether this is the currently active pairing for its Stack user scope.
    public var isActive: Bool
    /// Stack Auth user that owns this pairing, if any.
    public var stackUserID: String?
    /// Stack team this pairing belongs to (the team whose per-team backup it was
    /// paired/restored under). `nil` for a pre-v3 row or an anonymous pairing; a
    /// nil-team row is visible under every team until re-stamped. Scopes the local
    /// list so a multi-team user only sees the current team's Macs.
    public var teamID: String?
    /// User's custom name override. When set, wins over the Mac-reported
    /// ``displayName`` everywhere. `nil` = use the Mac-reported name. Synced per
    /// user so the rename appears on every signed-in device.
    public var customName: String?
    /// User's custom color override, synced per user. `nil` = the automatic
    /// position-based color. `"palette:<n>"` selects one of the built-in machine
    /// colors; `"#RRGGBB"` is a custom color. Opaque to the store/worker.
    public var customColor: String?
    /// User's custom icon override, synced per user. `nil` = the automatic icon.
    /// An SF Symbol name (ASCII, e.g. `"desktopcomputer"`) or an emoji.
    public var customIcon: String?

    /// The Mac device identifier doubles as the stable `Identifiable` id.
    public var id: String { macDeviceID }

    private enum CodingKeys: String, CodingKey {
        case macDeviceID
        case displayName
        case routes
        case createdAt
        case lastSeenAt
        case isActive
        case stackUserID
        case teamID
        case customName
        case customColor
        case customIcon
    }

    /// The name to show: the user's custom override if set, else the Mac-reported
    /// name, else the device id.
    public var resolvedName: String {
        if let customName, !customName.isEmpty { return customName }
        if let displayName, !displayName.isEmpty { return displayName }
        return macDeviceID
    }

    /// Creates a paired-Mac value.
    /// - Parameters:
    ///   - macDeviceID: Stable identifier of the paired Mac device.
    ///   - displayName: Optional human-readable Mac name.
    ///   - routes: Attach routes advertised by the Mac.
    ///   - attachToken: Local-only attach ticket secret for fast reconnect.
    ///   - attachTokenExpiresAt: Expiration time for `attachToken`.
    ///   - attachTokenWorkspaceID: Workspace scope for `attachToken`; `""` is Mac-wide.
    ///   - attachTokenTerminalID: Optional terminal scope for `attachToken`.
    ///   - createdAt: When the pairing was first recorded.
    ///   - lastSeenAt: When the pairing was last refreshed.
    ///   - isActive: Whether this pairing is currently active for its scope.
    ///   - stackUserID: Owning Stack Auth user, if any.
    public init(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        attachToken: String? = nil,
        attachTokenExpiresAt: Date? = nil,
        attachTokenWorkspaceID: String? = nil,
        attachTokenTerminalID: String? = nil,
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool,
        stackUserID: String?,
        teamID: String? = nil,
        customName: String? = nil,
        customColor: String? = nil,
        customIcon: String? = nil
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.attachToken = attachToken
        self.attachTokenExpiresAt = attachTokenExpiresAt
        self.attachTokenWorkspaceID = attachTokenWorkspaceID
        self.attachTokenTerminalID = attachTokenTerminalID
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
        self.stackUserID = stackUserID
        self.teamID = teamID
        self.customName = customName
        self.customColor = customColor
        self.customIcon = customIcon
    }
}
