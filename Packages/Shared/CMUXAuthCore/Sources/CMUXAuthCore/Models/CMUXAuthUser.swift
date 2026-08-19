import Foundation

/// The signed-in cmux user, as both apps cache and display it.
///
/// A plain value mirrored from the Stack Auth user record. Codable so the
/// apps can persist it through ``CMUXAuthIdentityStore`` and restore the
/// identity card before the network session validates at launch.
public struct CMUXAuthUser: Codable, Equatable, Sendable {
    /// The Stack Auth user id.
    public let id: String
    /// The user's primary email, if one is set.
    public let primaryEmail: String?
    /// The user's display name, if one is set.
    public let displayName: String?
    /// The user's Stack Auth profile image URL, if one is set.
    public let profileImageURL: String?
    /// Whether Stack Auth has verified the primary email. Gates trust in the
    /// email's domain (e.g. the backend environment switcher); identities
    /// persisted before this field existed decode as unverified until the
    /// network session refreshes them.
    public let primaryEmailVerified: Bool

    /// Creates a user value.
    /// - Parameters:
    ///   - id: The Stack Auth user id.
    ///   - primaryEmail: The user's primary email, if any.
    ///   - displayName: The user's display name, if any.
    ///   - profileImageURL: The user's profile image URL, if any.
    ///   - primaryEmailVerified: Whether Stack verified the primary email.
    public init(
        id: String,
        primaryEmail: String?,
        displayName: String?,
        profileImageURL: String? = nil,
        primaryEmailVerified: Bool = false
    ) {
        self.id = id
        self.primaryEmail = primaryEmail
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.primaryEmailVerified = primaryEmailVerified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            primaryEmail: try container.decodeIfPresent(String.self, forKey: .primaryEmail),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            profileImageURL: try container.decodeIfPresent(String.self, forKey: .profileImageURL),
            primaryEmailVerified: try container.decodeIfPresent(Bool.self, forKey: .primaryEmailVerified) ?? false
        )
    }
}
