import Foundation

/// Renames a profile or sets/clears its appearance or terminal defaults.
public struct UpdateProfileRequest: DaemonRequest {
    public typealias Response = ProfileResult
    public static let command = "update-profile"
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
    public var profile: ProfileID
    public var index: Int
    public init(profile: ProfileID, index: Int) {
        self.profile = profile
        self.index = index
    }
}

/// Deletes a room. Its pins and groups move to `moveTo`, or are removed
/// (the workspaces return to the rooms that follow their sessions). The
/// daemon refuses `default`. Closing the workspaces is the app's separate
/// step on their own sessions.
public struct DeleteProfileRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var profile: ProfileID
        public var movedTo: ProfileID?
        enum CodingKeys: String, CodingKey {
            case profile
            case movedTo = "moved_to"
        }
    }
    public static let command = "delete-profile"
    public var profile: ProfileID
    public var moveTo: ProfileID?
    public init(profile: ProfileID, moveTo: ProfileID? = nil) {
        self.profile = profile
        self.moveTo = moveTo
    }
}
