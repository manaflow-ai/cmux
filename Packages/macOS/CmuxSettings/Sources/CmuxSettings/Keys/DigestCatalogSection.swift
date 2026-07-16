import Foundation

/// Retained settings under `digest.ghpr.*` for configuration compatibility
/// after the digest feature itself was removed.
public struct DigestCatalogSection: SettingCatalogSection {
    public let ghprEnabled = DefaultsKey<Bool>(
        id: "digest.ghpr.enabled",
        defaultValue: false,
        userDefaultsKey: "digest.ghpr.enabled"
    )

    /// Empty selects PRDashboard's per-user default socket path.
    public let ghprSocketPath = DefaultsKey<String>(
        id: "digest.ghpr.socketPath",
        defaultValue: "",
        userDefaultsKey: "digest.ghpr.socketPath"
    )

    /// Comma-separated badge names. Empty selects the built-in default set.
    public let ghprDisplayItems = DefaultsKey<String>(
        id: "digest.ghpr.displayItems",
        defaultValue: "",
        userDefaultsKey: "digest.ghpr.displayItems"
    )

    /// Optional Jira base URL or a URL template containing `{ticket}`.
    public let ghprJiraBaseURL = DefaultsKey<String>(
        id: "digest.ghpr.jiraBaseURL",
        defaultValue: "",
        userDefaultsKey: "digest.ghpr.jiraBaseURL"
    )

    public init() {}
}
