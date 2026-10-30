import Foundation

// Profiles (`profiles-v1`, plans/cmux-next/data-model.md section 3). Profile
// edits emit `tree-changed`; a workspace changing profile emits
// `workspace-moved` with the entity carrying `profile`.

public struct ProfileResult: Decodable, Sendable, Equatable {
    public var profile: ProfileSnapshot
    public var changed: Bool
}

public struct CreateProfileRequest: DaemonRequest {
    public typealias Response = ProfileResult
    public static let command = "create-profile"
    public static let requiredCapability: String? = DaemonCapability.profiles.rawValue
    public var name: String
    /// Caller-chosen id makes a retry idempotent; nil lets the daemon mint one.
    public var profile: ProfileID?
    public var color: String?
    public var icon: String?
    public var theme: String?
    public var index: Int?
    public var browserProfileID: BrowserProfileKey?
    public var defaults: ProfileDefaults?
    /// The session New Workspace creates in (a Cloud space's machine); nil for the local daemon.
    public var defaultSessionID: String?
    /// Sessions whose unpinned workspaces this profile shows (data-model.md 3.2).
    public var follows: [String]?

    public init(name: String, profile: ProfileID? = nil, color: String? = nil, icon: String? = nil, theme: String? = nil,
                index: Int? = nil, browserProfileID: BrowserProfileKey? = nil, defaults: ProfileDefaults? = nil,
                defaultSessionID: String? = nil, follows: [String]? = nil) {
        self.name = name
        self.profile = profile
        self.color = color
        self.icon = icon
        self.theme = theme
        self.index = index
        self.browserProfileID = browserProfileID
        self.defaults = defaults
        self.defaultSessionID = defaultSessionID
        self.follows = follows
    }
}
