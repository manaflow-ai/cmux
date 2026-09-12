import Foundation

/// Settings under the dotted-id prefix `links.*`.
public struct LinksCatalogSection: SettingCatalogSection {
    /// Whether terminal-emitted links are captured into the workspace Links pane.
    public let enabled = DefaultsKey<Bool>(
        id: "links.enabled",
        defaultValue: true,
        userDefaultsKey: "links.enabled"
    )

    /// Comma-separated hosts ignored during link ingest.
    public let ignoreHosts = DefaultsKey<String>(
        id: "links.ignoreHosts",
        defaultValue: "localhost:31034",
        userDefaultsKey: "links.ignoreHosts"
    )

    /// Whether `file://` URLs are retained in link history.
    public let includeFilePaths = DefaultsKey<Bool>(
        id: "links.includeFilePaths",
        defaultValue: false,
        userDefaultsKey: "links.includeFilePaths"
    )

    /// Maximum captured links retained per workspace.
    public let retentionLimit = DefaultsKey<Int>(
        id: "links.retentionLimit",
        defaultValue: 500,
        userDefaultsKey: "links.retentionLimit"
    )

    /// Whether cmux fetches remote page titles for captured links.
    public let fetchTitles = DefaultsKey<Bool>(
        id: "links.fetchTitles",
        defaultValue: false,
        userDefaultsKey: "links.fetchTitles"
    )

    /// Creates the links settings section with its default keys.
    public init() {}
}
