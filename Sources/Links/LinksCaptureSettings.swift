import Foundation

struct LinksCaptureSettings {
    static let enabledKey = "links.enabled"
    static let ignoreHostsKey = "links.ignoreHosts"
    static let includeFilePathsKey = "links.includeFilePaths"
    static let retentionLimitKey = "links.retentionLimit"
    static let fetchTitlesKey = "links.fetchTitles"

    static let defaultEnabled = true
    static let defaultIgnoreHosts = "localhost:31034"
    static let defaultIncludeFilePaths = false
    static let defaultRetentionLimit = 500
    static let defaultFetchTitles = false

    // UserDefaults is documented thread-safe but is not SDK-annotated Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot() -> LinkCaptureSettingsSnapshot {
        LinkCaptureSettingsSnapshot(
            enabled: defaults.object(forKey: Self.enabledKey) as? Bool ?? Self.defaultEnabled,
            includeFilePaths: defaults.object(forKey: Self.includeFilePathsKey) as? Bool ?? Self.defaultIncludeFilePaths,
            ignoreHosts: parseIgnoreHosts(
                defaults.string(forKey: Self.ignoreHostsKey) ?? Self.defaultIgnoreHosts
            ),
            retentionLimit: WorkspaceLinksIngestConfiguration.clampedRetentionLimit(
                defaults.object(forKey: Self.retentionLimitKey) as? Int ?? Self.defaultRetentionLimit
            ),
            fetchTitles: defaults.object(forKey: Self.fetchTitlesKey) as? Bool ?? Self.defaultFetchTitles
        )
    }

    private func parseIgnoreHosts(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
