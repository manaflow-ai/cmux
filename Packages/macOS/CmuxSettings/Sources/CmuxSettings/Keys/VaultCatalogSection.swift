import Foundation

/// Settings under the dotted-id prefix `vault.*`.
public struct VaultCatalogSection: SettingCatalogSection {
    /// Extra Claude config directories scanned by the Vault in addition to the
    /// built-in Claude roots. Each entry normally points at a Claude config
    /// directory such as `~/.claude`; a direct `projects` directory is also
    /// accepted by the app-side scanner.
    public let claudeSessionRoots = JSONKey<[String]>(
        id: "vault.claudeSessionRoots",
        defaultValue: []
    )

    /// Remote/local path-prefix equivalences used when the Vault compares an
    /// agent transcript cwd against the local workspace folder.
    public let pathMappings = JSONKey<[VaultPathMapping]>(
        id: "vault.pathMappings",
        defaultValue: []
    )

    public init() {}
}
