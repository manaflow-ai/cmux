public import CMUXMobileCore
public import Foundation

/// A Mac paired with this iOS device, persisted across launches.
///
/// Auth tokens are never persisted, only enough to re-mint a fresh attach
/// ticket via the StackAuth-authenticated manual host flow on next launch.
public struct MobilePairedMac: Codable, Equatable, Sendable, Identifiable {
    /// Persisted compatibility grants are intentionally absent. They may move
    /// only through the local SQLite grant table, never Codable state, account
    /// backup, logs, or another device.
    private enum CodingKeys: String, CodingKey {
        case macDeviceID
        case displayName
        case routes
        case instanceTag
        case createdAt
        case lastSeenAt
        case isActive
        case stackUserID
        case teamID
        case customName
        case customColor
        case customIcon
    }

    /// Stable identifier of the paired Mac device.
    public var macDeviceID: String
    /// Human-readable name of the Mac, if the pairing payload supplied one.
    public var displayName: String?
    /// Attach routes advertised by the Mac, ordered by priority (lowest first).
    public var routes: [CmxAttachRoute]
    /// App-instance tag reported by this Mac over authenticated host status.
    /// `nil` means an older host has not established instance-level authority;
    /// route refresh then requires one unambiguous route-advertising instance.
    public var instanceTag: String?
    /// Exact raw Tailscale routes this iPhone had already trusted before the
    /// Iroh migration. This local-only compatibility capability is never
    /// created for new or cloud-restored pairings and is revoked once the Mac
    /// publishes an authenticated Iroh identity.
    public var legacyTailscaleRoutes: [CmxAttachRoute]? = nil
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

    /// Stable identity of this saved app instance.
    ///
    /// A physical Mac can run Stable, Nightly, and tagged development builds at
    /// once. Those processes share ``macDeviceID`` but have distinct
    /// ``instanceTag`` values, so both fields participate in list identity.
    public var id: String { Self.pairingID(macDeviceID: macDeviceID, instanceTag: instanceTag) }

    /// Builds the stable local identity for one saved Mac app instance.
    /// - Parameters:
    ///   - macDeviceID: Stable identifier of the physical Mac.
    ///   - instanceTag: Authenticated app-instance tag, or `nil` for a legacy host.
    /// - Returns: An identifier unique to the physical Mac and app instance.
    public static func pairingID(macDeviceID: String, instanceTag: String?) -> String {
        let canonicalDeviceID = cmxCanonicalDeviceID(macDeviceID)
        guard let instanceTag, !instanceTag.isEmpty else { return canonicalDeviceID }
        return "\(canonicalDeviceID)\u{1F}\(instanceTag)"
    }

    /// Splits a pairing identity received from backup into its physical Mac id
    /// and optional tagged app-instance id. Legacy physical-only ids remain valid.
    public static func pairingIdentity(
        from pairingID: String
    ) -> (macDeviceID: String, instanceTag: String?) {
        let parts = pairingID.split(
            separator: "\u{1F}",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2, !parts[1].isEmpty else {
            return (cmxCanonicalDeviceID(pairingID), nil)
        }
        return (cmxCanonicalDeviceID(String(parts[0])), String(parts[1]))
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
    ///   - createdAt: When the pairing was first recorded.
    ///   - lastSeenAt: When the pairing was last refreshed.
    ///   - isActive: Whether this pairing is currently active for its scope.
    ///   - stackUserID: Owning Stack Auth user, if any.
    public init(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool,
        stackUserID: String?,
        teamID: String? = nil,
        customName: String? = nil,
        customColor: String? = nil,
        customIcon: String? = nil,
        instanceTag: String? = nil,
        legacyTailscaleRoutes: [CmxAttachRoute]? = nil
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
        self.stackUserID = stackUserID
        self.teamID = teamID
        self.customName = customName
        self.customColor = customColor
        self.customIcon = customIcon
        self.instanceTag = instanceTag
        self.legacyTailscaleRoutes = legacyTailscaleRoutes
    }
}
