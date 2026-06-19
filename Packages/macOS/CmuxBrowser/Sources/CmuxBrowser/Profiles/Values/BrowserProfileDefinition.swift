public import Foundation

/// Persisted metadata describing one browser profile.
///
/// A profile owns an isolated `WKWebsiteDataStore` and an isolated history file,
/// keyed by ``id``. Exactly one profile is the built-in default
/// (``isBuiltInDefault`` is `true`), which maps to the shared/default backing
/// stores rather than per-profile ones.
public struct BrowserProfileDefinition: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier used as the key for the profile's data and history stores.
    public let id: UUID
    /// Human-readable profile name shown in the UI.
    public var displayName: String
    /// Creation timestamp; the built-in default uses the Unix epoch so it sorts deterministically.
    public let createdAt: Date
    /// Whether this is the immovable built-in default profile.
    public let isBuiltInDefault: Bool

    /// Creates a profile definition.
    /// - Parameters:
    ///   - id: Stable identifier for the profile's stores.
    ///   - displayName: Human-readable name.
    ///   - createdAt: Creation timestamp.
    ///   - isBuiltInDefault: Whether this is the built-in default profile.
    public init(id: UUID, displayName: String, createdAt: Date, isBuiltInDefault: Bool) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.isBuiltInDefault = isBuiltInDefault
    }

    /// URL/socket-safe identifier derived from ``displayName``.
    ///
    /// The built-in default always slugs to `"default"`. Other profiles lowercase
    /// the name, collapse runs of non-alphanumerics to `-`, trim leading/trailing
    /// `-`, and fall back to the lowercased UUID string when the result is empty.
    public var slug: String {
        if isBuiltInDefault {
            return "default"
        }

        let normalized = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? id.uuidString.lowercased() : normalized
    }
}
