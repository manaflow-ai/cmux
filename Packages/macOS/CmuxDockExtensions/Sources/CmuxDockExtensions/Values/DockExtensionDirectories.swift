import Foundation

/// The on-disk layout for TUI extensions, mirroring herdr's separation of
/// managed checkout, user config, and durable state:
///
/// - `<home>/.config/cmux/extensions.json` — the lockfile (user-visible dotfile).
/// - `<home>/.config/cmux/extensions/<id>/` — user config (`CMUX_EXTENSION_CONFIG_DIR`).
/// - `<home>/.local/state/cmux/extensions/checkouts/<id>/` — the pinned git
///   checkout (`CMUX_EXTENSION_ROOT`); replaceable, never a place for state.
/// - `<home>/.local/state/cmux/extensions/state/<id>/` — durable state
///   (`CMUX_EXTENSION_STATE_DIR`).
/// - `<home>/.local/state/cmux/extensions/logs/<id>/` — build logs.
/// - `<home>/.local/state/cmux/extensions/staging/` — in-flight downloads.
///
/// State lives under `~/.local/state/cmux` (not Application Support) for the
/// same TCC reasons as `CmuxStateDirectory`. The home directory is injected so
/// tests can point the whole layout at a temporary directory.
public struct DockExtensionDirectories: Equatable, Sendable {
    /// `<home>/.config/cmux`.
    public let configRoot: URL

    /// `<home>/.local/state/cmux/extensions`.
    public let stateRoot: URL

    /// The standard layout for a user home directory. Composition roots pass
    /// `FileManager.default.homeDirectoryForCurrentUser`.
    public init(homeDirectory: URL) {
        self.configRoot = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
        self.stateRoot = homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
    }

    /// The `extensions.json` lockfile location.
    public var lockFileURL: URL {
        configRoot.appendingPathComponent("extensions.json", isDirectory: false)
    }

    /// The managed pinned checkout for an extension.
    public func checkoutDirectory(id: String) -> URL {
        stateRoot
            .appendingPathComponent("checkouts", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// The durable state directory exposed as `CMUX_EXTENSION_STATE_DIR`.
    public func stateDirectory(id: String) -> URL {
        stateRoot
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// The user config directory exposed as `CMUX_EXTENSION_CONFIG_DIR`.
    public func configDirectory(id: String) -> URL {
        configRoot
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Build/launch log directory for an extension.
    public func logsDirectory(id: String) -> URL {
        stateRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Root for in-flight staged checkouts (one random subdirectory per
    /// preview); safe to clear when no install is running.
    public var stagingRoot: URL {
        stateRoot.appendingPathComponent("staging", isDirectory: true)
    }

    /// A fresh unique staging directory for one preview/install attempt.
    public func makeStagingDirectory() -> URL {
        stagingRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }
}
