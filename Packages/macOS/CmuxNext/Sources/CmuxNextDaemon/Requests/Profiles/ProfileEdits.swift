import Foundation

/// Renames a profile or sets/clears its appearance or terminal defaults.
public struct UpdateProfileRequest: DaemonRequest {
    public typealias Response = ProfileResult
    public static let command = "update-profile"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var profile: ProfileID
    public var name: String?
    public var color: FieldUpdate<String>
    public var icon: FieldUpdate<String>
    public var theme: FieldUpdate<String>
    public var browserProfileID: FieldUpdate<BrowserProfileKey>
    public var defaults: FieldUpdate<ProfileDefaults>

    public init(profile: ProfileID, name: String? = nil, color: FieldUpdate<String> = .unchanged,
                icon: FieldUpdate<String> = .unchanged, theme: FieldUpdate<String> = .unchanged,
                browserProfileID: FieldUpdate<BrowserProfileKey> = .unchanged, defaults: FieldUpdate<ProfileDefaults> = .unchanged) {
        self.profile = profile
        self.name = name
        self.color = color
        self.icon = icon
        self.theme = theme
        self.browserProfileID = browserProfileID
        self.defaults = defaults
    }

    enum CodingKeys: String, CodingKey {
        case profile, name, color, icon, theme, defaults
        case browserProfileID = "browser_profile_id"
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profile, forKey: .profile)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(icon, forKey: .icon)
        try c.encode(theme, forKey: .theme)
        try c.encode(browserProfileID, forKey: .browserProfileID)
        try c.encode(defaults, forKey: .defaults)
    }
}

/// Moves a profile to an insertion index (the `move-workspace` rule).
public struct MoveProfileRequest: DaemonRequest {
    public typealias Response = ProfileResult
    public static let command = "move-profile"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var profile: ProfileID
    public var index: Int
    public init(profile: ProfileID, index: Int) {
        self.profile = profile
        self.index = index
    }
}

/// Deletes a room. With `moveTo` its pins and groups move there. Without
/// it this is Delete Space (SPACE-DELETE-CLOSES-ITS-WORKSPACES): the daemon
/// closes every workspace of its session that only this room shows and
/// records the room and them as one closed group (`closedID`), which
/// `closed.reopen` restores. Workspaces of other sessions only lose their
/// pin. The daemon refuses `default`.
public struct DeleteProfileRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var profile: ProfileID
        public var movedTo: ProfileID?
        /// The closed group of a Delete Space; nil for a move or an older daemon.
        public var closedID: String?
        enum CodingKeys: String, CodingKey {
            case profile
            case movedTo = "moved_to"
            case closedID = "closed_id"
        }
    }
    public static let command = "delete-profile"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var profile: ProfileID
    public var moveTo: ProfileID?
    public init(profile: ProfileID, moveTo: ProfileID? = nil) {
        self.profile = profile
        self.moveTo = moveTo
    }
}
