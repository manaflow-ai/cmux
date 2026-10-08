import Foundation

/// One authenticated collaborator, coalesced across all of their live devices.
public struct WorkspacePresenceParticipant: Codable, Equatable, Identifiable, Sendable {
    /// Verified Stack user id; never supplied by a viewer message.
    public let id: String
    /// Profile name, or nil when the account has no name.
    public let displayName: String?
    /// HTTPS profile image, or nil when unavailable.
    public let avatarURL: URL?
    /// Whether at least one live device for this collaborator is focused on the workspace.
    public let isActive: Bool

    /// Creates a participant value for projections and tests.
    public init(id: String, displayName: String? = nil, avatarURL: URL? = nil, isActive: Bool = true) {
        self.id = id
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name?.isEmpty == false ? String(name!.prefix(128)) : nil
        self.avatarURL = avatarURL?.scheme == "https" ? avatarURL : nil
        self.isActive = isActive
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        self.init(id: try c.decode(String.self, forKey: .id),
                  displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
                  avatarURL: rawURL.flatMap(URL.init(string:)),
                  // Older workers only sent focused viewers and had no activity
                  // field. Treat those snapshots as active while rolling out the
                  // richer participant shape.
                  isActive: try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(avatarURL?.absoluteString, forKey: .avatarURL)
        try c.encode(isActive, forKey: .isActive)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, avatarURL
        case isActive = "active"
    }
}
