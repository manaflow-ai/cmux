/// The local GitHub connection, using the user's existing GitHub CLI login.
///
/// The connection is opt-in. Its feed items belong to the existing local feed
/// owner; cmux never copies or stores the GitHub CLI's credentials.
public nonisolated struct FeedGitHubSettings: Sendable, Equatable {
    // Paths, defaults and the interval range: schemas/settings/source/feed.json
    // (SettingsSchema+Feed.generated.swift, cx-d5b5d).
    /// Whether this Mac reads GitHub notifications and review requests.
    public var enabled: Bool
    /// Seconds between background refreshes. Manual refresh runs immediately.
    public var pollIntervalSeconds: Double

    /// Creates local GitHub preferences.
    ///
    /// - Parameters:
    ///   - enabled: Defaults to false until the user enables the connection.
    ///   - pollIntervalSeconds: Defaults to two minutes and is clamped to the supported range.
    public init(enabled: Bool = FeedGitHubSettings.enabledDefault, pollIntervalSeconds: Double = FeedGitHubSettings.pollIntervalDefault) {
        self.enabled = enabled
        self.pollIntervalSeconds = min(max(pollIntervalSeconds, Self.pollIntervalRange.lowerBound), Self.pollIntervalRange.upperBound)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["feed", "github"], diagnostics: &diagnostics) else { return settings }
        if let enabled = reader.bool("enabled") { settings.enabled = enabled }
        if let interval = reader.number("pollIntervalSeconds", range: pollIntervalRange) { settings.pollIntervalSeconds = interval }
        diagnostics = reader.diagnostics
        return settings
    }
}
