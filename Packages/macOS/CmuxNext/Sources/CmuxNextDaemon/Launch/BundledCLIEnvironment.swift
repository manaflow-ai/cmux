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
/// The same bin dir holds the URL opener: `BROWSER` names it (`cmux-open-url`) unless set,
/// and its `open` and `xdg-open` shims send an http(s) URL to it, so a program's browser opens
/// in cmux (`TerminalLinkOpener`).
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

    public init(binDirectory: String, pathIntegration: String?) {
        self.binDirectory = binDirectory
        self.pathIntegration = pathIntegration
    }

    /// `env` with the bundled CLI first on `PATH` and, for the shell in
    /// `env["SHELL"]`, the layer that keeps it first after the startup files
    /// (cmux-daemon-launch-core `bundled_cli_apply`, which reads the bundle).
    /// Unchanged when the bundle has no executable `cmux` or the library does not answer.
    public func apply(to env: [String: String]) -> [String: String] {
        struct Request: Encodable { var cli: BundledCLIEnvironment, env: [String: String] }
        return DaemonLaunchRules.call("bundled_cli_apply", Request(cli: self, env: env), as: [String: String].self) ?? env
    }
}

/// `{binDirectory, pathIntegration}`, as the launch rules read it.
extension BundledCLIEnvironment: Encodable {}
