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
    private var snapshots: [String: DeclarativeTerminalConfiguration.Snapshot] = [:]
    private let initialSnapshotReadyStream: AsyncStream<Void>
    private let initialSnapshotReadyContinuation: AsyncStream<Void>.Continuation
    private var hasInitialSnapshot = false
    /// The configuration URL used when callers omit an explicit URL.
    public let fileURL: URL

    /// Creates a cache, optionally primed with an already-decoded snapshot.
    ///
    /// Spawn paths only read the in-memory value. File I/O and JSON parsing flow
    /// through the long-lived ``DeclarativeTerminalConfigurationModel``
    /// observation stream; callers may provide a pre-decoded snapshot in tests.
    ///
    /// - Parameters:
    ///   - initialSnapshot: Immutable values to publish immediately.
    ///   - fileURL: File identity associated with ``initialSnapshot``.
    public init(
        initialSnapshot: DeclarativeTerminalConfiguration.Snapshot? = nil,
        fileURL: URL = CmuxConfigLocation().userConfigFile
    ) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.initialSnapshotReadyStream = stream
        self.initialSnapshotReadyContinuation = continuation
        self.fileURL = fileURL.standardizedFileURL
        if let initialSnapshot {
            snapshots[self.fileURL.path] = initialSnapshot
            hasInitialSnapshot = true
        }
    }

    deinit {
        initialSnapshotReadyContinuation.finish()
    }

    /// Waits until the app-lifetime observer has published its first snapshot.
    ///
    /// The readiness signal lets composition roots defer creation of surfaces
    /// that synchronously consume the cache without putting file I/O back on
    /// the main actor. A cache constructed with an initial snapshot is ready
    /// immediately.
    public func waitForInitialSnapshot() async {
        guard !hasInitialSnapshot else { return }
        var iterator = initialSnapshotReadyStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    /// Returns the last published snapshot without touching the filesystem.
    ///
    /// A cache that has not been primed yet returns the safe schema defaults.
    /// Runtime configuration updates arrive through ``replace(_:fileURL:)``
    /// from the app-lifetime JSON observation owner.
    public func snapshot(
        fileURL: URL? = nil
    ) -> DeclarativeTerminalConfiguration.Snapshot {
        let key = (fileURL ?? self.fileURL).standardizedFileURL.path
        return snapshots[key] ?? .init()
    }

    /// Publishes an authoritative value delivered by the actor-backed JSON store.
    public func replace(
        _ value: DeclarativeTerminalConfiguration.Snapshot,
        fileURL: URL? = nil
    ) {
        let key = (fileURL ?? self.fileURL).standardizedFileURL.path
        snapshots[key] = value
        if !hasInitialSnapshot {
            hasInitialSnapshot = true
            initialSnapshotReadyContinuation.yield(())
        }
    }

    /// Drops every memoized file snapshot.
    public func reset() {
        snapshots.removeAll(keepingCapacity: true)
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
    /// This synchronous reader is reserved for bootstrap and test seams.
    /// Interactive creation paths consume the injected
    /// ``DeclarativeTerminalConfigurationCache`` instead, while Settings UI
    /// writes and external edits flow through the actor-backed
    /// ``JSONConfigStore`` observation stream.
    ///
    /// - Parameter fileURL: Config file to read. Defaults to the active
    ///   per-user `cmux.json` location.
    /// - Returns: A value snapshot using safe defaults for missing or invalid
    ///   values.
    public func snapshot(
        fileURL: URL = CmuxConfigLocation().userConfigFile
    ) -> Snapshot {
        let root = JSONConfigStore.snapshotRoot(fileURL: fileURL)
        return Self.snapshot(root: root)
    }

    /// Decodes terminal settings from one immutable JSON store revision.
    ///
    /// - Parameters:
    ///   - data: JSON or JSONC bytes for a complete configuration root.
    ///   - sanitizer: Sanitizer used for JSONC comments and trailing commas.
    /// - Returns: Safe defaults for missing or invalid values.
    public static func snapshot(
        data: Data,
        sanitizer: JSONCSanitizer = JSONCSanitizer()
    ) -> Snapshot {
        snapshot(root: JSONConfigStore.snapshotRoot(data: data, sanitizer: sanitizer))
    }

    private static func snapshot(root: [String: Any]) -> Snapshot {
        let configuration = DeclarativeTerminalConfiguration()
        let rawWorkingDirectoryPolicy = JSONKey<String>(
            id: configuration.workingDirectoryPolicy.id,
            defaultValue: ""
        )
        let rawPolicy = JSONConfigStore.snapshotValue(
            for: rawWorkingDirectoryPolicy,
            in: root
        )
        return Snapshot(
            workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy(rawValue: rawPolicy),
            workingDirectoryPath: JSONConfigStore.snapshotValue(
                for: configuration.workingDirectoryPath,
                in: root
            ),
            fixedPathIsUsable: false,
            shellStartupMode: JSONConfigStore.snapshotValue(
                for: configuration.shellStartupMode,
                in: root
            ),
            shellStartupCommand: JSONConfigStore.snapshotValue(
                for: configuration.shellStartupCommand,
                in: root
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Immutable values read from the declarative terminal configuration.
    public struct Snapshot: Equatable, Sendable {
        /// `nil` means the new policy key is absent or invalid.
        public var workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy?

        /// Configured fixed path, or an empty string when absent.
        public var workingDirectoryPath: String

        /// Whether an actor-backed reader confirmed the fixed path is usable.
        /// A false value is fail-closed until a fresh validation result arrives.
        public var fixedPathIsUsable: Bool

        /// Configured shell invocation mode, defaulting to login.
        public var shellStartupMode: ShellStartupMode

        /// Trimmed startup command, or an empty string when absent.
        public var shellStartupCommand: String

        /// Creates a snapshot of declarative terminal values.
        ///
        /// - Parameters:
        ///   - workingDirectoryPolicy: Parsed working-directory policy, or
        ///     `nil` when the file omitted or invalidated it.
        ///   - workingDirectoryPath: Raw fixed path value.
        ///   - fixedPathIsUsable: Off-main validation result for the fixed path.
        ///   - shellStartupMode: Parsed shell startup mode.
        ///   - shellStartupCommand: Raw startup command value.
        public init(
            workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy? = nil,
            workingDirectoryPath: String = "",
            fixedPathIsUsable: Bool = false,
            shellStartupMode: ShellStartupMode = .login,
            shellStartupCommand: String = ""
        ) {
            self.workingDirectoryPolicy = workingDirectoryPolicy
            self.workingDirectoryPath = workingDirectoryPath
            self.fixedPathIsUsable = fixedPathIsUsable
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
