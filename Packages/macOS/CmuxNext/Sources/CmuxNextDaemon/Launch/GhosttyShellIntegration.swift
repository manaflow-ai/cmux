public import Foundation

/// Ghostty's shell integration for a terminal the daemon spawns, built the
/// way Ghostty builds it for its own shells (`ghostty/src/termio/Exec.zig`
/// `Subprocess.init` and `ghostty/src/termio/shell_integration.zig`).
///
/// It gives prompt marks (OSC 133, jump-to-prompt), cwd reports (OSC 7),
/// cursor shape, title, `sudo` and `ssh` wrappers, from the user's
/// `shell-integration` and `shell-integration-features` config.
///
/// zsh (`ZDOTDIR`), fish and elvish (`XDG_DATA_DIRS`) are integrated through
/// the environment. bash (`ENV` with `--posix`) and nushell (`XDG_DATA_DIRS`
/// with `--execute 'use ghostty *'`) also need arguments: the spawn op writes
/// their environment and `shellArguments(for:)` reads it back into the
/// arguments, which `DaemonConnection` sends as `shell_args`
/// (`terminal-shell-args-v1`; the daemon runs the env's `SHELL` with them).
/// Against a daemon without that capability, bash ignores `ENV` (it reads it
/// only in POSIX mode) and nushell has the module without the `use`, as
/// before. Ghostty itself never integrates Apple's `/bin/bash`.
public struct GhosttyShellIntegration: Sendable, Equatable {
    /// `shell-integration`.
    public enum Mode: String, Sendable, CaseIterable {
        case none, detect, bash, elvish, fish, nushell, zsh
    }

    /// `shell-integration-features`, in Ghostty's packed-struct bit order
    /// (what `ghostty_config_get` returns).
    public struct Features: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let cursor = Features(rawValue: 1 << 0)
        public static let sudo = Features(rawValue: 1 << 1)
        public static let title = Features(rawValue: 1 << 2)
        public static let sshEnv = Features(rawValue: 1 << 3)
        public static let sshTerminfo = Features(rawValue: 1 << 4)
        public static let path = Features(rawValue: 1 << 5)
        /// Ghostty's defaults: cursor, title, path.
        public static let ghosttyDefault: Features = [.cursor, .title, .path]
    }

    public var mode: Mode
    public var features: Features
    /// `cursor-style-blink`; nil (unset) counts as blinking, as in Ghostty.
    public var cursorBlink: Bool?
    /// The Ghostty resources directory (`<Resources>/ghostty`).
    public var resourcesDirectory: String?
    /// The bundled Ghostty CLI (`<Resources>/bin/ghostty`). The `ssh-env`
    /// and `ssh-terminfo` wrappers run `$GHOSTTY_BIN_DIR/ghostty +ssh`;
    /// without a CLI those features are dropped, so plain
    /// `ssh` runs.
    public var ghosttyBinary: String?

    public init(mode: Mode = .detect, features: Features = .ghosttyDefault, cursorBlink: Bool? = nil,
                resourcesDirectory: String?, ghosttyBinary: String?) {
        self.mode = mode
        self.features = features
        self.cursorBlink = cursorBlink
        self.resourcesDirectory = resourcesDirectory
        self.ghosttyBinary = ghosttyBinary
    }

    /// The integration as the launch rules read it (`shell_integration::Integration`,
    /// `terminal_spawn_environment`), which apply it in Rust: `GHOSTTY_SHELL_FEATURES`
    /// (the ssh features only with a Ghostty CLI), `XDG_DATA_DIRS`, `MANPATH`, and zsh
    /// `ZDOTDIR`, fish/elvish/nushell data dirs or bash's POSIX-mode `ENV` for the env's `SHELL`.
    var json: [String: Any] {
        var json: [String: Any] = ["mode": mode.rawValue, "features": features.rawValue]
        if let cursorBlink { json["cursorBlink"] = cursorBlink }
        if let resourcesDirectory { json["resourcesDirectory"] = resourcesDirectory }
        if let ghosttyBinary { json["ghosttyBinary"] = ghosttyBinary }
        return json
    }

    /// The shell arguments Ghostty adds for the integration applied to `env`,
    /// for the shell in `env["SHELL"]` (the one the daemon starts): bash
    /// `--posix`, nushell `--execute 'use ghostty *'`; nil for every other
    /// shell or when no integration was applied (`shell_arguments`).
    public static func shellArguments(for env: [String: String]) -> [String]? {
        DaemonLaunchRules.call("shell_arguments", ["env": env]) as? [String]
    }
}
