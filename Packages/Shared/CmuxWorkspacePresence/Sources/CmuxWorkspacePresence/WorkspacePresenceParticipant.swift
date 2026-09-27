import Foundation

/// One authenticated collaborator, coalesced across all of their live devices.
public struct WorkspacePresenceParticipant: Codable, Equatable, Identifiable, Sendable {
    /// Verified Stack user id; never supplied by a viewer message.
    public let id: String
    /// Profile name, or nil when the account has no name.
    public let displayName: String?
    /// HTTPS profile image, or nil when unavailable.
    public let avatarURL: URL?

    /// Creates a participant value for projections and tests.
    public init(id: String, displayName: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name?.isEmpty == false ? String(name!.prefix(128)) : nil
        self.avatarURL = avatarURL?.scheme == "https" ? avatarURL : nil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        self.init(id: try c.decode(String.self, forKey: .id),
                  displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
                  avatarURL: rawURL.flatMap(URL.init(string:)))
    }
    private enum CodingKeys: String, CodingKey { case id, displayName, avatarURL }
}
