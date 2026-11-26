import Foundation

/// Result of wiping one profile's website data and history.
///
/// Produced by ``BrowserProfileRepository/clearProfileData(id:)`` and surfaced to
/// the automation socket via ``socketPayload``.
public struct BrowserProfileClearOutcome: Sendable {
    /// The profile whose data was cleared.
    public let profile: BrowserProfileDefinition
    /// Sorted list of `WKWebsiteDataStore` data-type identifiers that were removed.
    public let clearedWebsiteDataTypes: [String]
    /// Whether the profile's browsing history was cleared.
    public let clearedHistory: Bool

    /// Creates a clear outcome.
    /// - Parameters:
    ///   - profile: The profile whose data was cleared.
    ///   - clearedWebsiteDataTypes: Sorted website-data-type identifiers that were removed.
    ///   - clearedHistory: Whether history was cleared.
    public init(profile: BrowserProfileDefinition, clearedWebsiteDataTypes: [String], clearedHistory: Bool) {
        self.profile = profile
        self.clearedWebsiteDataTypes = clearedWebsiteDataTypes
        self.clearedHistory = clearedHistory
    }

    /// JSON-shaped dictionary for the browser automation socket reply.
    public var socketPayload: [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.displayName,
            "slug": profile.slug,
            "built_in_default": profile.isBuiltInDefault,
            "cleared_website_data_types": clearedWebsiteDataTypes,
            "cleared_history": clearedHistory,
        ]
    }
}
