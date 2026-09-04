import Foundation

/// Canonical settings under the `artifacts.*` prefix.
///
/// The older `links.*` keys remain accepted as a decode/migration alias; both
/// prefixes feed the same capture configuration and repository.
public struct ArtifactsCatalogSection: SettingCatalogSection {
    /// Whether automatic artifact producers may capture records.
    public let enabled = DefaultsKey<Bool>(id: "artifacts.enabled", defaultValue: true, userDefaultsKey: "artifacts.enabled", legacyUserDefaultsKeys: ["links.enabled"])
    /// Comma-separated URL hosts ignored during terminal capture.
    public let ignoreHosts = DefaultsKey<String>(id: "artifacts.ignoreHosts", defaultValue: "localhost:31034", userDefaultsKey: "artifacts.ignoreHosts", legacyUserDefaultsKeys: ["links.ignoreHosts"])
    /// Whether terminal-emitted file paths are retained.
    public let includeFilePaths = DefaultsKey<Bool>(id: "artifacts.includeFilePaths", defaultValue: false, userDefaultsKey: "artifacts.includeFilePaths", legacyUserDefaultsKeys: ["links.includeFilePaths"])
    /// Maximum records retained per workspace.
    /// The URL/history default remains the shipped Links limit; richer file
    /// payloads have independent byte bounds in ``CmuxArtifacts``.
    public let retentionLimit = DefaultsKey<Int>(id: "artifacts.retentionLimit", defaultValue: 500, userDefaultsKey: "artifacts.retentionLimit", legacyUserDefaultsKeys: ["links.retentionLimit"])
    /// Whether public URL titles may be fetched.
    public let fetchTitles = DefaultsKey<Bool>(id: "artifacts.fetchTitles", defaultValue: false, userDefaultsKey: "artifacts.fetchTitles", legacyUserDefaultsKeys: ["links.fetchTitles"])

    /// Creates the canonical Artifacts settings section.
    public init() {}
}
