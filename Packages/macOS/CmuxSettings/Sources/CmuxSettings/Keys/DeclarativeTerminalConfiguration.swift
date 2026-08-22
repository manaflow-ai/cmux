import Foundation

/// The working-directory source used when cmux creates a terminal surface.
public enum NewSurfaceWorkingDirectoryPolicy: String, CaseIterable, Sendable, SettingCodable {
    /// Use the currently selected pane's reported working directory.
    case inheritActivePane
    /// Use the directory captured when the workspace was created.
    case workspaceRoot
    /// Use ``terminal.newSurfaceWorkingDirectory.path``.
    case fixedPath
}

/// The shell invocation mode used for ordinary newly-created local surfaces.
public enum ShellStartupMode: String, CaseIterable, Sendable, SettingCodable {
    /// Start the user's shell as an interactive login shell.
    case login
    /// Start the user's shell as an interactive, non-login shell.
    case nonLogin
}

/// Main-actor owner for memoized declarative terminal snapshots.
///
/// The owner is deliberately constructable and instance-scoped. App wiring can
/// share one owner across workspace, tab, Dock, and runtime-spawn paths, while
/// tests can create a fresh owner (or call ``reset()``) without touching
/// process-wide mutable state.
@MainActor
public final class DeclarativeTerminalConfigurationCache {
    private struct CachedSnapshot {
        let signature: SnapshotSignature
        let value: DeclarativeTerminalConfiguration.Snapshot
    }

    private struct SnapshotSignature: Equatable {
        let resolvedPath: String
        let exists: Bool
        let modificationTime: TimeInterval?
        let byteCount: Int64?
        let inode: UInt64?
    }

    private var snapshots: [String: CachedSnapshot] = [:]

    /// Creates an empty snapshot cache.
    public init() {}

    deinit {}

    /// Returns the current snapshot, re-reading the file when its resolved
    /// path or filesystem signature changes.
    public func snapshot(
        configuration: DeclarativeTerminalConfiguration = DeclarativeTerminalConfiguration(),
        fileURL: URL = CmuxConfigLocation().userConfigFile
    ) -> DeclarativeTerminalConfiguration.Snapshot {
        let configuredPath = fileURL.standardizedFileURL.path
        let signature = Self.snapshotSignature(for: fileURL)
        if let cached = snapshots[configuredPath], cached.signature == signature {
            return cached.value
        }
        let value = configuration.snapshot(fileURL: fileURL)
        snapshots[configuredPath] = CachedSnapshot(signature: signature, value: value)
        return value
    }

    /// Drops every memoized file snapshot.
    public func reset() {
        snapshots.removeAll(keepingCapacity: true)
    }

    private static func snapshotSignature(for fileURL: URL) -> SnapshotSignature {
        let resolvedURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        let modificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value
        let inode = (attributes?[.systemFileNumber] as? NSNumber).map { $0.uint64Value }
        return SnapshotSignature(
            resolvedPath: resolvedURL.path,
            exists: attributes != nil,
            modificationTime: modificationTime,
            byteCount: byteCount,
            inode: inode
        )
    }
}

/// Value-typed declarations and snapshot reader for terminal defaults in `cmux.json`.
///
/// These keys are intentionally separate from the legacy UserDefaults catalog.
/// The values are authored in `cmux.json`, and the runtime reads the same file
/// that the Settings UI writes. The type conforms to ``SettingCatalogSection``
/// so the catalog's reflected key list has one source of truth as well.
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

    /// Reads the current values directly from the configured JSON file.
    ///
    /// This is deliberately a synchronous, lock-free snapshot for creation
    /// paths that must choose a cwd or shell command before their first
    /// suspension point. Settings UI writes still go through the actor-backed
    /// ``JSONConfigStore``.
    ///
    /// - Parameter fileURL: Config file to read. Defaults to the active
    ///   per-user `cmux.json` location.
    /// - Returns: A value snapshot using safe defaults for missing or invalid
    ///   values.
    public func snapshot(
        fileURL: URL = CmuxConfigLocation().userConfigFile
    ) -> Snapshot {
        let root = JSONConfigStore.snapshotRoot(fileURL: fileURL)
        let rawWorkingDirectoryPolicy = JSONKey<String>(
            id: workingDirectoryPolicy.id,
            defaultValue: ""
        )
        let rawPolicy = JSONConfigStore.snapshotValue(
            for: rawWorkingDirectoryPolicy,
            in: root
        )
        return Snapshot(
            workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy(rawValue: rawPolicy),
            workingDirectoryPath: JSONConfigStore.snapshotValue(
                for: workingDirectoryPath,
                in: root
            ),
            shellStartupMode: JSONConfigStore.snapshotValue(
                for: shellStartupMode,
                in: root
            ),
            shellStartupCommand: JSONConfigStore.snapshotValue(
                for: shellStartupCommand,
                in: root
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Immutable values read from the declarative terminal configuration.
    public struct Snapshot: Equatable, Sendable {
        /// `nil` means the new policy key is absent or invalid.
        public let workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy?

        /// Configured fixed path, or an empty string when absent.
        public let workingDirectoryPath: String

        /// Configured shell invocation mode, defaulting to login.
        public let shellStartupMode: ShellStartupMode

        /// Trimmed startup command, or an empty string when absent.
        public let shellStartupCommand: String

        /// Creates a snapshot of declarative terminal values.
        ///
        /// - Parameters:
        ///   - workingDirectoryPolicy: Parsed working-directory policy, or
        ///     `nil` when the file omitted or invalidated it.
        ///   - workingDirectoryPath: Raw fixed path value.
        ///   - shellStartupMode: Parsed shell startup mode.
        ///   - shellStartupCommand: Raw startup command value.
        public init(
            workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy?,
            workingDirectoryPath: String,
            shellStartupMode: ShellStartupMode,
            shellStartupCommand: String
        ) {
            self.workingDirectoryPolicy = workingDirectoryPolicy
            self.workingDirectoryPath = workingDirectoryPath
            self.shellStartupMode = shellStartupMode
            self.shellStartupCommand = shellStartupCommand
        }

        /// Resolves the new policy while preserving the legacy boolean when a
        /// user has not yet authored the declarative key.
        ///
        /// - Parameter legacyInheritanceEnabled: The pre-JSON inheritance
        ///   setting used only when the declarative policy is absent.
        /// - Returns: The declarative policy, or its compatibility fallback.
        public func effectiveWorkingDirectoryPolicy(
            legacyInheritanceEnabled: Bool
        ) -> NewSurfaceWorkingDirectoryPolicy {
            workingDirectoryPolicy
                ?? (legacyInheritanceEnabled ? .inheritActivePane : .workspaceRoot)
        }
    }
}
