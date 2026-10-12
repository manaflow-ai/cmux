public import Foundation

/// Makes `cmux` in this app's terminals this app's bundled CLI.
///
/// A terminal's `CMUX_SOCKET_PATH` and `CMUX_TUI_SOCKET` name this app, so its
/// `cmux` must be this app's CLI (`<Resources>/bin/cmux`), not an older `cmux`
/// that the login `PATH` lists first (`~/.local/bin`, the classic app's CLI).
/// Two things decide which `cmux` a shell runs:
///
/// - the spawn `PATH`: the bundled bin dir goes first, and
///   `CMUX_BUNDLED_CLI_PATH` names the CLI for shims and wrappers that look
///   for it;
/// - the user's startup files, which run after the spawn and often prepend
///   their own directories. `<Resources>/cmux-cli-path` (``pathIntegration``)
///   moves the bundled bin dir back to the front once they have run, before
///   the first prompt: zsh through a `ZDOTDIR` layer over Ghostty's, bash
///   through a wrapper for Ghostty's POSIX-mode `ENV` script, and fish through
///   a `vendor_conf.d` file on `XDG_DATA_DIRS`. Each layer removes its own
///   variables, so programs started in the terminal see none of them.
///
/// Neither depends on a bundled Ghostty CLI helper: the app ships its `cmux`
/// whether or not it ships `ghostty`.
public struct BundledCLIEnvironment: Sendable, Equatable {
    /// The app's `Contents/Resources/bin`.
    public var binDirectory: String
    /// The app's `Contents/Resources/cmux-cli-path`, or nil when the daemon
    /// (not this app) integrates the shell: the layers wrap the integration
    /// the app writes.
    public var pathIntegration: String?

    /// zsh: the `ZDOTDIR` that the layer's `.zshenv` restores (Ghostty's
    /// integration dir or the user's). Absent when `ZDOTDIR` was unset.
    public static let zshNextZDOTDIRKey = "CMUX_CLI_ZSH_ZDOTDIR"
    /// bash: Ghostty's `ENV` script, which the layer sources.
    public static let bashNextEnvKey = "CMUX_CLI_BASH_ENV"
    /// fish: the `XDG_DATA_DIRS` entry the layer removes again.
    public static let fishDataDirKey = "CMUX_CLI_FISH_XDG_DIR"
    static let bashScript = "/bash/cmux-cli-path.bash"

    public init(binDirectory: String, pathIntegration: String?) {
        self.binDirectory = binDirectory
        self.pathIntegration = pathIntegration
    }

    /// `env` with the bundled CLI first on `PATH` and, for the shell in
    /// `env["SHELL"]`, the layer that keeps it first after the startup files.
    /// Unchanged when the bundle has no executable `cmux`.
    public func apply(
        to env: [String: String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        let cli = binDirectory + "/cmux"
        guard !binDirectory.isEmpty, isExecutable(cli) else { return env }
        var env = env
        let rest = (env["PATH"] ?? "").split(separator: ":").filter { !$0.isEmpty && $0 != Substring(binDirectory) }
        env["PATH"] = ([Substring(binDirectory)] + rest).joined(separator: ":")
        env["CMUX_BUNDLED_CLI_PATH"] = cli
        guard let layer = pathIntegration, !layer.isEmpty,
              let shell = env["SHELL"].map({ ($0 as NSString).lastPathComponent }) else { return env }
        switch shell {
        case "zsh":
            guard fileExists(layer + "/zsh/.zshenv") else { break }
            if let next = env["ZDOTDIR"] { env[Self.zshNextZDOTDIRKey] = next }
            env["ZDOTDIR"] = layer + "/zsh"
        case "bash":
            // Only over Ghostty's integration: bash reads `ENV` only in the
            // POSIX mode that integration starts it in.
            guard let next = env["ENV"], next.hasSuffix(GhosttyShellIntegration.bashScript),
                  env["GHOSTTY_BASH_INJECT"] != nil, fileExists(layer + Self.bashScript) else { break }
            env[Self.bashNextEnvKey] = next
            env["ENV"] = layer + Self.bashScript
        case "fish":
            guard fileExists(layer + "/fish/vendor_conf.d/cmux-cli-path.fish") else { break }
            env[Self.fishDataDirKey] = layer
            env["XDG_DATA_DIRS"] = layer + ":" + (env["XDG_DATA_DIRS"] ?? GhosttyShellIntegration.defaultXDGDataDirs)
        default:
            break
        }
        return env
    }

    /// Whether `env["ENV"]` is the bash layer over Ghostty's script.
    static func wrapsGhosttyBash(_ env: [String: String]) -> Bool {
        env["ENV"]?.hasSuffix(bashScript) == true
            && env[bashNextEnvKey]?.hasSuffix(GhosttyShellIntegration.bashScript) == true
    }
}
