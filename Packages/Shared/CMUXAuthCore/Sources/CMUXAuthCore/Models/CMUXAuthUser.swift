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

    /// Creates a user value.
    /// - Parameters:
    ///   - id: The Stack Auth user id.
    ///   - primaryEmail: The user's primary email, if any.
    ///   - displayName: The user's display name, if any.
    public init(
        id: String,
        primaryEmail: String?,
        displayName: String?,
        profileImageURL: String? = nil
    ) {
        self.id = id
        self.primaryEmail = primaryEmail
        self.displayName = displayName
        self.profileImageURL = profileImageURL
    }
}
