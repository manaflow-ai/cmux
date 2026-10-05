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

    /// `GHOSTTY_SHELL_FEATURES`: enabled names sorted, `cursor` with its
    /// blink state; nil when none is enabled (`setupFeatures`). The ssh
    /// features need the Ghostty CLI and are left out without one.
    public var featuresValue: String? {
        var features = features
        if (ghosttyBinary ?? "").isEmpty { features.subtract([.sshEnv, .sshTerminfo]) }
        var names: [String] = []
        if features.contains(.cursor) { names.append((cursorBlink ?? true) ? "cursor:blink" : "cursor:steady") }
        if features.contains(.path) { names.append("path") }
        if features.contains(.sshEnv) { names.append("ssh-env") }
        if features.contains(.sshTerminfo) { names.append("ssh-terminfo") }
        if features.contains(.sudo) { names.append("sudo") }
        if features.contains(.title) { names.append("title") }
        return names.isEmpty ? nil : names.joined(separator: ",")
    }

    /// The shell Ghostty would integrate for `shell` (a path or name), or
    /// nil (`detectShell`). A forced mode wins; `none` never integrates.
    public func shell(for shell: String?) -> Mode? {
        switch mode {
        case .none: return nil
        case .detect: break
        default: return mode
        }
        guard let shell, !shell.isEmpty else { return nil }
        switch (shell as NSString).lastPathComponent {
        case "bash": return shell == "/bin/bash" ? nil : .bash
        case "elvish": return .elvish
        case "fish": return .fish
        case "nu": return .nushell
        case "zsh": return .zsh
        default: return nil
        }
    }

    /// `env` plus the integration for a terminal running `shell` (nil:
    /// `env["SHELL"]`, the shell the daemon starts).
    public func apply(
        to env: [String: String],
        shell: String? = nil,
        isDirectory: (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    ) -> [String: String] {
        var env = env
        if let ghosttyBinary, !ghosttyBinary.isEmpty {
            let binDirectory = (ghosttyBinary as NSString).deletingLastPathComponent
            env["GHOSTTY_BIN"] = ghosttyBinary
            env["GHOSTTY_BIN_DIR"] = binDirectory
            let path = env["PATH"] ?? ""
            if path.isEmpty {
                env["PATH"] = binDirectory
            } else if !path.split(separator: ":").contains(Substring(binDirectory)) {
                env["PATH"] = path + ":" + binDirectory
            }
        }
        if let resources = resourcesDirectory, !resources.isEmpty {
            env["XDG_DATA_DIRS"] = Self.append(env["XDG_DATA_DIRS"] ?? Self.defaultXDGDataDirs, resources + "/..")
            // Always with a leading colon: an empty MANPATH element keeps the
            // system man path.
            env["MANPATH"] = (env["MANPATH"] ?? "") + ":" + resources + "/../man"
        }
        if let features = featuresValue { env["GHOSTTY_SHELL_FEATURES"] = features }

        guard let resources = resourcesDirectory, !resources.isEmpty,
              let integrated = self.shell(for: shell ?? env["SHELL"]) else { return env }
        let integration = resources + "/shell-integration"
        switch integrated {
        case .zsh:
            let zsh = integration + "/zsh"
            guard isDirectory(zsh) else { break }
            if let old = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = old }
            env["ZDOTDIR"] = zsh
        case .fish, .elvish, .nushell:
            guard isDirectory(integration) else { break }
            env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration
            env["XDG_DATA_DIRS"] = integration + ":" + (env["XDG_DATA_DIRS"] ?? Self.defaultXDGDataDirs)
        case .bash:
            // `setupBash`: POSIX mode reads the integration from `ENV`, which
            // restores the user's `ENV`, rc files and history afterwards.
            guard isDirectory(integration + "/bash") else { break }
            if let old = env["ENV"] { env["GHOSTTY_BASH_ENV"] = old }
            env["ENV"] = integration + Self.bashScript
            env["GHOSTTY_BASH_INJECT"] = "1"
            // POSIX mode defaults HISTFILE to ~/.sh_history.
            if env["HISTFILE"] == nil {
                let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
                env["HISTFILE"] = home + "/.bash_history"
                env["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
        case .none, .detect:
            break
        }
        return env
    }

    /// The shell arguments Ghostty adds for the integration `apply` wrote
    /// into `env`, for the shell in `env["SHELL"]` (the one the daemon
    /// starts): bash `--posix`, nushell `--execute 'use ghostty *'`; nil for
    /// every other shell or when no integration was applied.
    public static func shellArguments(for env: [String: String]) -> [String]? {
        guard let shell = env["SHELL"], !shell.isEmpty else { return nil }
        switch (shell as NSString).lastPathComponent {
        case "bash":
            guard shell != "/bin/bash", env["GHOSTTY_BASH_INJECT"] != nil,
                  env["ENV"]?.hasSuffix(bashScript) == true else { return nil }
            return ["--posix"]
        case "nu":
            guard env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] != nil else { return nil }
            return ["--execute", "use ghostty *"]
        default:
            return nil
        }
    }

    /// Ghostty's bash integration script, relative to `shell-integration`.
    static let bashScript = "/bash/ghostty.bash"

    /// The XDG base-directory default when `XDG_DATA_DIRS` is unset.
    static let defaultXDGDataDirs = "/usr/local/share:/usr/share"

    private static func append(_ current: String, _ value: String) -> String {
        current.isEmpty ? value : current + ":" + value
    }
}
