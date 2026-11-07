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
/// with `--execute 'use ghostty *'`) also need arguments: `apply` writes
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
    /// without a CLI those features are dropped (`featuresValue`), so plain
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

    private struct Request: Encodable {
        var integration: GhosttyShellIntegration
        var env: [String: String] = [:]
        var shell: String?
        var home: String = NSHomeDirectory()
    }

    /// `GHOSTTY_SHELL_FEATURES`: enabled names sorted, `cursor` with its
    /// blink state; nil when none is enabled (`setupFeatures`). The ssh
    /// features need the Ghostty CLI and are left out without one
    /// (cmux-daemon-launch-core `shell_integration_features`).
    public var featuresValue: String? {
        DaemonLaunchRules.call("shell_integration_features", Request(integration: self), as: String?.self) ?? nil
    }

    /// The shell Ghostty would integrate for `shell` (a path or name), or
    /// nil (`detectShell`). A forced mode wins; `none` never integrates; Apple's
    /// `/bin/bash` is never detected (cmux-daemon-launch-core `shell_integration_shell`).
    public func shell(for shell: String?) -> Mode? {
        let name = DaemonLaunchRules.call("shell_integration_shell", Request(integration: self, shell: shell), as: String?.self) ?? nil
        return name.flatMap(Mode.init(rawValue:))
    }

    /// `env` plus the integration for a terminal running `shell` (nil:
    /// `env["SHELL"]`, the shell the daemon starts): Ghostty's CLI on `PATH`,
    /// `XDG_DATA_DIRS`, `MANPATH`, the features, then zsh through `ZDOTDIR`, fish,
    /// elvish and nushell through `XDG_DATA_DIRS`, bash through `ENV` in POSIX mode
    /// (cmux-daemon-launch-core `shell_integration_apply`, which reads the bundle's
    /// integration directories). Unchanged when the library does not answer.
    public func apply(to env: [String: String], shell: String? = nil) -> [String: String] {
        DaemonLaunchRules.call("shell_integration_apply", Request(integration: self, env: env, shell: shell), as: [String: String].self)
            ?? env
    }

    /// The shell arguments Ghostty adds for the integration `apply` wrote
    /// into `env`, for the shell in `env["SHELL"]` (the one the daemon
    /// starts): bash `--posix`, nushell `--execute 'use ghostty *'`; nil for
    /// every other shell or when no integration was applied (cmux-daemon-launch-core `shell_arguments`).
    public static func shellArguments(for env: [String: String]) -> [String]? {
        struct Request: Encodable { var env: [String: String] }
        return DaemonLaunchRules.call("shell_arguments", Request(env: env), as: [String]?.self) ?? nil
    }
}

/// `{mode, features, cursorBlink, resourcesDirectory, ghosttyBinary}`, as the launch rules read it.
extension GhosttyShellIntegration: Encodable {
    private enum CodingKeys: String, CodingKey { case mode, features, cursorBlink, resourcesDirectory, ghosttyBinary }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(features.rawValue, forKey: .features)
        try container.encodeIfPresent(cursorBlink, forKey: .cursorBlink)
        try container.encodeIfPresent(resourcesDirectory, forKey: .resourcesDirectory)
        try container.encodeIfPresent(ghosttyBinary, forKey: .ghosttyBinary)
    }
}
