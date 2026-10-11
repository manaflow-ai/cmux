/// The local GitHub connection, using the user's existing GitHub CLI login.
///
/// The connection is opt-in. Its feed items belong to the existing local feed
/// owner; cmux never copies or stores the GitHub CLI's credentials.
public nonisolated struct FeedGitHubSettings: Sendable, Equatable {
    /// The opt-in connection setting in cmux.json.
    public static let enabledPath = ["feed", "github", "enabled"]
    /// The polling interval setting in cmux.json, in seconds.
    public static let pollIntervalPath = ["feed", "github", "pollIntervalSeconds"]
    /// Allowed polling intervals, bounded to protect GitHub's API quota.
    public static let pollIntervalRange: ClosedRange<Double> = 60...900
    /// Whether this Mac reads GitHub notifications and review requests.
    public var enabled: Bool
    /// Seconds between background refreshes. Manual refresh runs immediately.
    public var pollIntervalSeconds: Double

    /// Creates local GitHub preferences.
    ///
    /// - Parameters:
    ///   - enabled: Defaults to false until the user enables the connection.
    ///   - pollIntervalSeconds: Defaults to two minutes and is clamped to the supported range.
    public init(enabled: Bool = false, pollIntervalSeconds: Double = 120) {
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
