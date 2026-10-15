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
    /// Sorted `<engine>.<kind>` identifiers another engine cleared (e.g.
    /// `chromium.cookies`); empty when no other engine is available.
    public let clearedEngineDataKinds: [String]

    /// Creates a clear outcome.
    /// - Parameters:
    ///   - profile: The profile whose data was cleared.
    ///   - clearedWebsiteDataTypes: Sorted website-data-type identifiers that were removed.
    ///   - clearedHistory: Whether history was cleared.
    ///   - clearedEngineDataKinds: Sorted `<engine>.<kind>` identifiers another engine cleared.
    public init(
        profile: BrowserProfileDefinition,
        clearedWebsiteDataTypes: [String],
        clearedHistory: Bool,
        clearedEngineDataKinds: [String] = []
    ) {
        self.profile = profile
        self.clearedWebsiteDataTypes = clearedWebsiteDataTypes
        self.clearedHistory = clearedHistory
        self.clearedEngineDataKinds = clearedEngineDataKinds
    }

    /// JSON-shaped dictionary for the browser automation socket reply.
    /// `cleared_engine_data` appears only when another engine cleared data, so
    /// the reply is unchanged when the Chromium engine is not available.
    public var socketPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": profile.id.uuidString,
            "name": profile.displayName,
            "slug": profile.slug,
            "built_in_default": profile.isBuiltInDefault,
            "cleared_website_data_types": clearedWebsiteDataTypes,
            "cleared_history": clearedHistory,
        ]
        if !clearedEngineDataKinds.isEmpty {
            payload["cleared_engine_data"] = clearedEngineDataKinds
        }
        return payload
    }
}
