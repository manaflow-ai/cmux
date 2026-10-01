public import Foundation

/// Filesystem locations for app extension plugins.
///
/// Installs sit beside the cmux-tui sidebar and agent plugins, under
/// `~/.local/share/cmux/mux-plugins/extension/<name>`. The app and the CLI
/// must agree on these paths even though a GUI app does not inherit shell
/// variables, so `XDG_*` overrides are deliberately not consulted.
public struct CmuxPluginPaths: Equatable, Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Directory holding one subdirectory (or `link` symlink) per plugin.
    public var installRoot: URL {
        homeDirectory.appendingPathComponent(".local/share/cmux/mux-plugins/extension", isDirectory: true)
    }

    /// Which plugins the user enabled, and the manifest fingerprint they saw.
    public var enablementFile: URL {
        homeDirectory.appendingPathComponent(".config/cmux/plugins.json", isDirectory: false)
    }

    public func installDirectory(for name: String) -> URL {
        installRoot.appendingPathComponent(validatedName(name), isDirectory: true)
    }

    /// Writable per-plugin state, exported as `CMUX_PLUGIN_STATE_DIR`.
    public func stateDirectory(for name: String) -> URL {
        homeDirectory.appendingPathComponent(".local/state/cmux/plugins/\(validatedName(name))", isDirectory: true)
    }

    /// Per-plugin user configuration, exported as `CMUX_PLUGIN_CONFIG_DIR`.
    public func configDirectory(for name: String) -> URL {
        homeDirectory.appendingPathComponent(".config/cmux/plugins/\(validatedName(name))", isDirectory: true)
    }

    private func validatedName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        precondition(
            !name.isEmpty && name.utf8.count <= 64 && name.unicodeScalars.allSatisfy(allowed.contains),
            "plugin names must match [a-z0-9_-]+ and be at most 64 bytes"
        )
        return name
    }
}
