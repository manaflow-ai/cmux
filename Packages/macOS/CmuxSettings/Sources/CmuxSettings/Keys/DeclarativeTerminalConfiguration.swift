import Foundation

/// Value-typed declarations and snapshot decoding for terminal defaults in
/// `cmux.json`.
///
/// These keys are intentionally separate from the legacy UserDefaults catalog.
/// The values are authored in `cmux.json`, and the runtime reads the same file
/// that the Settings UI writes. The type conforms to
/// ``SettingCatalogSection`` so the catalog's reflected key list has one source
/// of truth as well.
public struct DeclarativeTerminalConfiguration: SettingCatalogSection {
    /// Policy used to choose the working directory of ordinary new surfaces.
    public let workingDirectoryPolicy = JSONKey<NewSurfaceWorkingDirectoryPolicy>(
        id: "terminal.newSurfaceWorkingDirectory.policy",
        defaultValue: .inheritActivePane
    )

    /// Fixed path used when ``workingDirectoryPolicy`` is `fixedPath`.
    public let workingDirectoryPath = JSONKey<String>(
        id: "terminal.newSurfaceWorkingDirectory.path",
        defaultValue: ""
    )

    /// Login or non-login mode for ordinary new local shells.
    public let shellStartupMode = JSONKey<ShellStartupMode>(
        id: "terminal.shellStartup.mode",
        defaultValue: .login
    )

    /// Optional input sent after an ordinary new local shell starts.
    public let shellStartupCommand = JSONKey<String>(
        id: "terminal.shellStartup.command",
        defaultValue: ""
    )

    /// Creates the declarative terminal key declarations.
    public init() {}

    /// Reads the current values directly from a configured JSON file.
    ///
    /// This synchronous reader is reserved for package tests and bootstrap
    /// tooling. Interactive creation paths consume the immutable snapshot
    /// published by ``DeclarativeTerminalConfigurationProviding`` instead.
    ///
    /// - Parameter fileURL: Config file to read.
    /// - Returns: A value snapshot using safe defaults for missing or invalid
    ///   values.
    public func snapshot(
        fileURL: URL = CmuxConfigLocation().userConfigFile
    ) -> Snapshot {
        let root = JSONConfigSnapshotDecoder().root(fileURL: fileURL)
        return snapshot(root: root)
    }

    /// Decodes terminal settings from immutable JSON bytes.
    ///
    /// - Parameters:
    ///   - data: JSON or JSONC bytes for a complete configuration root.
    ///   - sanitizer: Sanitizer used for JSONC comments and trailing commas.
    /// - Returns: Safe defaults for missing or invalid values.
    public func snapshot(
        data: Data,
        sanitizer: JSONCSanitizer = JSONCSanitizer()
    ) -> Snapshot {
        snapshot(root: JSONConfigSnapshotDecoder(sanitizer: sanitizer).root(data: data))
    }

    private func snapshot(root: [String: Any]) -> Snapshot {
        // The policy is read as a raw string so an omitted/invalid value can
        // remain distinguishable from the key's compatibility default.
        let rawWorkingDirectoryPolicy = JSONKey<String>(
            id: workingDirectoryPolicy.id,
            defaultValue: ""
        )
        let decoder = JSONConfigSnapshotDecoder()
        return Snapshot(
            workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy(
                rawValue: decoder.value(
                    for: rawWorkingDirectoryPolicy,
                    in: root
                )
            ),
            workingDirectoryPath: decoder.value(
                for: workingDirectoryPath,
                in: root
            ),
            shellStartupMode: decoder.value(
                for: shellStartupMode,
                in: root
            ),
            shellStartupCommand: decoder.value(
                for: shellStartupCommand,
                in: root
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

}
