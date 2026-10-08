public import Foundation

/// One browser profile (plans/cmux-next/data-model.md section 5): a name, an
/// optional color and icon, and its own storage in every engine. The wire id
/// is `default` or a lowercase UUID; engines key their stores by the
/// matching `BrowserProfileID` (WebKit `WKWebsiteDataStore(forIdentifier:)`,
/// Chromium `Profile-<UUID>`).
public nonisolated struct BrowserProfileRecord: Codable, Hashable, Sendable, Identifiable {
    /// The built-in profile's wire id. Its store is `BrowserProfileID.default`.
    public static let defaultID = "default"

    public var id: String
    public var name: String
    /// One of the 9 group color names (`GroupColor`), or nil.
    public var color: String?
    /// An SF Symbol name or one emoji, or nil (the name's first letter shows).
    public var icon: String?
    public var position: Int
    /// Where an imported profile came from (`browser`, `profile_dir`,
    /// `display_name`); nil for a profile made in cmux.
    public var source: [String: String]?

    public init(id: String, name: String, color: String? = nil, icon: String? = nil, position: Int = 0,
                source: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.position = position
        self.source = source
    }

    public var isDefault: Bool { id == Self.defaultID }

    /// The engine store of this profile.
    public var engineProfile: BrowserProfileID { Self.engineProfile(for: id) ?? .default }

    /// `default` -> `BrowserProfileID.default`; a lowercase UUID -> that UUID;
    /// anything else (nil, uppercase, a room id) -> nil.
    public static func engineProfile(for wireID: String?) -> BrowserProfileID? {
        guard let wireID else { return nil }
        if wireID == defaultID { return .default }
        guard isValidID(wireID), let uuid = UUID(uuidString: wireID) else { return nil }
        return BrowserProfileID(rawValue: uuid)
    }

    /// The wire id of an engine profile.
    public static func wireID(for profile: BrowserProfileID) -> String {
        profile == .default ? defaultID : profile.rawValue.uuidString.lowercased()
    }

    /// `default` or a lowercase UUID (the daemon's `validate_browser_profile_ref`).
    public static func isValidID(_ id: String) -> Bool {
        if id == defaultID { return true }
        guard id.count == 36, UUID(uuidString: id) != nil else { return false }
        return id == id.lowercased()
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// What a badge shows: the icon, else the name's first letter.
    public var monogram: String {
        if let icon, !icon.isEmpty { return icon }
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// Why a browser profile edit was refused.
public nonisolated enum BrowserProfileBookError: Error, Hashable, Sendable {
    case unknownProfile
    /// The default profile cannot be deleted.
    case defaultProfile
    case invalidName
    case invalidID
    case invalidColor
    case invalidIcon
}
