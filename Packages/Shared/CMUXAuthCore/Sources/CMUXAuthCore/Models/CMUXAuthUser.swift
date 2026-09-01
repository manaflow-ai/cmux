import Foundation

/// The signed-in cmux user, as both apps cache and display it.
///
/// A plain value mirrored from the Stack Auth user record. Codable so the
/// apps can persist it through ``CMUXAuthIdentityStore`` and restore the
/// identity card before the network session validates at launch.
public struct CMUXAuthUser: Codable, Equatable, Sendable {
    /// The Stack Auth `clientReadOnlyMetadata` key that marks an account as a
    /// demonstration-content account (the App Review demo account). Written
    /// server-side only; clients can read but never set it.
    public static let demonstrationContentMetadataKey = "cmuxReviewDemoContent"

    /// The Stack Auth `clientReadOnlyMetadata` key that opts an account into
    /// verbose diagnostics reporting (the app streams its privacy-safe
    /// diagnostic events to the cmux backend). Written server-side only;
    /// clients can read but never set it.
    public static let verboseDiagnosticsMetadataKey = "cmuxVerboseDiagnostics"

    /// The Stack Auth user id.
    public let id: String
    /// The user's primary email, if one is set.
    public let primaryEmail: String?
    /// The user's display name, if one is set.
    public let displayName: String?
    /// The user's Stack Auth profile image URL, if one is set.
    public let profileImageURL: String?
    /// Whether this account is server-flagged to show demonstration content
    /// (a local demo computer with sample workspaces), so App Review can
    /// exercise the full app without live infrastructure. Mirrored from the
    /// account's `clientReadOnlyMetadata`, so it rides the same session
    /// payload the app already fetches at sign-in and persists with the
    /// cached identity. Defaults to `false` for every payload that predates
    /// the flag.
    public let demonstrationContentEnabled: Bool
    /// Whether this account is server-flagged for verbose diagnostics: the
    /// app batches its structured diagnostic events (bounded integer codes,
    /// never terminal contents or credentials) to the cmux backend so an App
    /// Review session can be reconstructed from server logs. Mirrored from
    /// the account's `clientReadOnlyMetadata` exactly like
    /// ``demonstrationContentEnabled`` and persisted with the cached
    /// identity. Defaults to `false` for every payload that predates the
    /// flag.
    public let verboseDiagnosticsEnabled: Bool

    /// Creates a user value.
    /// - Parameters:
    ///   - id: The Stack Auth user id.
    ///   - primaryEmail: The user's primary email, if any.
    ///   - displayName: The user's display name, if any.
    ///   - profileImageURL: The user's profile image URL, if any.
    ///   - demonstrationContentEnabled: Whether the account is server-flagged
    ///     for demonstration content. Defaults to `false`.
    ///   - verboseDiagnosticsEnabled: Whether the account is server-flagged
    ///     for verbose diagnostics reporting. Defaults to `false`.
    public init(
        id: String,
        primaryEmail: String?,
        displayName: String?,
        profileImageURL: String? = nil,
        demonstrationContentEnabled: Bool = false,
        verboseDiagnosticsEnabled: Bool = false
    ) {
        self.id = id
        self.primaryEmail = primaryEmail
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.demonstrationContentEnabled = demonstrationContentEnabled
        self.verboseDiagnosticsEnabled = verboseDiagnosticsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case primaryEmail
        case displayName
        case profileImageURL
        case demonstrationContentEnabled
        case verboseDiagnosticsEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.primaryEmail = try container.decodeIfPresent(String.self, forKey: .primaryEmail)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.profileImageURL = try container.decodeIfPresent(String.self, forKey: .profileImageURL)
        // Identity cards persisted by builds that predate the flag decode as
        // not demo-flagged, so a cached session can never invent the mode.
        self.demonstrationContentEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .demonstrationContentEnabled
        ) ?? false
        // Same fail-closed default for the verbose-diagnostics opt-in.
        self.verboseDiagnosticsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .verboseDiagnosticsEnabled
        ) ?? false
    }

    /// Resolves the demonstration-content flag from a Stack Auth
    /// `clientReadOnlyMetadata` dictionary.
    ///
    /// Only an explicit boolean `true` under
    /// ``demonstrationContentMetadataKey`` activates the flag; every other
    /// shape (absent key, strings, numbers, objects) resolves `false` so a
    /// malformed metadata write fails closed.
    /// - Parameter metadata: The raw metadata dictionary from the Stack user.
    /// - Returns: Whether demonstration content is enabled for the account.
    public static func demonstrationContentEnabled(
        fromClientReadOnlyMetadata metadata: [String: Any]?
    ) -> Bool {
        explicitBooleanFlag(demonstrationContentMetadataKey, in: metadata)
    }

    /// Resolves the verbose-diagnostics flag from a Stack Auth
    /// `clientReadOnlyMetadata` dictionary, with the same fail-closed parse
    /// as ``demonstrationContentEnabled(fromClientReadOnlyMetadata:)``: only
    /// an explicit boolean `true` under ``verboseDiagnosticsMetadataKey``
    /// activates it.
    /// - Parameter metadata: The raw metadata dictionary from the Stack user.
    /// - Returns: Whether verbose diagnostics are enabled for the account.
    public static func verboseDiagnosticsEnabled(
        fromClientReadOnlyMetadata metadata: [String: Any]?
    ) -> Bool {
        explicitBooleanFlag(verboseDiagnosticsMetadataKey, in: metadata)
    }

    /// `true` only for an explicit JSON boolean `true` under `key`; every
    /// other shape (absent key, strings, numbers, objects) fails closed.
    private static func explicitBooleanFlag(
        _ key: String,
        in metadata: [String: Any]?
    ) -> Bool {
        guard let value = metadata?[key] else { return false }
        guard let number = value as? NSNumber else { return false }
        // Reject non-boolean numbers (1, 2.5) so only a JSON `true` counts.
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}
