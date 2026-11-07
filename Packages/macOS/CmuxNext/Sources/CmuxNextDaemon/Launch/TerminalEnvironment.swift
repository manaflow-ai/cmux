public import Foundation

/// The environment the app hands the daemon and its terminals.
///
/// `terminal-env-v1` persists a terminal's `env` with its creation receipt in
/// the daemon state directory, and the daemon process passes its own
/// environment to every PTY. So neither gets the full login environment,
/// which can hold tokens and keys. Both get only what a correct shell needs
/// before its rc files run; the login shell in each terminal sources the
/// user's rc files for everything else.
///
/// The allowlist (exact keys, `LC_`/`XDG_`/`CMUX_` prefixes, never an identity, session or credential key),
/// the terminal and daemon environments, `TERM` and Ghostty's identity are cmux-daemon-launch-core's
/// (`terminal_env`); this type reads the disk only through it. Each answers an empty environment when the
/// library does not answer: nothing leaks, and the daemon's own environment applies.
public struct TerminalEnvironment: Sendable {
    public static let instance = Self()

    /// Process identity the daemon itself needs (state root, temp dir, ssh
    /// agent). Taken from the app process, never from the login shell, and
    /// only for the daemon process: terminals inherit them from it.
    public var daemonIdentityKeys: Set<String> {
        Set(DaemonLaunchRules.call("daemon_identity_keys", [String: String](), as: [String].self) ?? [])
    }

    /// The allowlisted subset of `environment`.
    public func filter(_ environment: [String: String]) -> [String: String] {
        DaemonLaunchRules.call("terminal_filter", DaemonLaunchRules.Environment(environment: environment), as: [String: String].self) ?? [:]
    }

    private struct LoginRequest: Encodable {
        var login: [String: String]?
        var base: [String: String]
        var overrides: [String: String] = [:]
    }

    /// Per-terminal `env` for `new-tab`, `split`, and `create-terminal`: the
    /// allowlisted login environment (or the app's, when capture failed, with the
    /// common tool prefixes first on `PATH`), plus the app's own `CMUX_*` keys. No
    /// `CMUX_NEXT_*` launch knob is forwarded, so a cmux-next started from one of
    /// its terminals does not inherit them.
    public func terminal(login: [String: String]?, base: [String: String]) -> [String: String] {
        DaemonLaunchRules.call("terminal_environment", LoginRequest(login: login, base: base), as: [String: String].self) ?? [:]
    }

    /// Environment for the daemon process: `terminal(login:base:)` plus the
    /// app's process identity keys, plus `overrides`.
    public func daemon(login: [String: String]?, base: [String: String], overrides: [String: String]) -> [String: String] {
        DaemonLaunchRules.call("daemon_environment", LoginRequest(login: login, base: base, overrides: overrides),
                               as: [String: String].self) ?? overrides
    }

    private struct TermRequest: Encodable {
        var prefersGhosttyTerm: Bool
        var home: String
        var resourcesDirectory: String?
    }

    /// The `TERM` a new terminal starts with: `xterm-256color`, the entry every ssh target,
    /// VM and container has, or `xterm-ghostty` when the user opted in (`prefersGhosttyTerm`,
    /// `terminal.term`) and its entry is installed in a terminfo directory ncurses searches here:
    /// ssh carries `TERM` to hosts that lack it (user, 2026-11-05).
    public func term(prefersGhosttyTerm: Bool, home: String = NSHomeDirectory()) -> String {
        DaemonLaunchRules.call("term", TermRequest(prefersGhosttyTerm: prefersGhosttyTerm, home: home), as: String.self)
            ?? "xterm-256color"
    }

    /// The terminal identity Ghostty exports to every shell it starts
    /// (`ghostty/src/termio/Exec.zig`, `Subprocess.init`): `TERM` (``term(prefersGhosttyTerm:home:)``),
    /// `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty` and `GHOSTTY_RESOURCES_DIR`. `TERM_PROGRAM_VERSION`
    /// stays unset: advertising a Ghostty version makes Codex disable its copy-on-select fallback. The app
    /// passes this as an override, which wins over the login shell's `TERM`/`COLORTERM`/`TERM_PROGRAM`.
    public func ghostty(resourcesDirectory: String?, version _: String?, prefersGhosttyTerm: Bool = false) -> [String: String] {
        let request = TermRequest(prefersGhosttyTerm: prefersGhosttyTerm, home: NSHomeDirectory(), resourcesDirectory: resourcesDirectory)
        return DaemonLaunchRules.call("ghostty_identity", request, as: [String: String].self)
            ?? ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "ghostty"]
    }

    /// Shared per-launch provider for terminal `env` (cmux-daemon-launch-core `terminal_spawn_environment`):
    /// the login environment (`LoginEnvironmentCache.value()`: this launch's capture, else the one remembered
    /// from the last launch, else a wait for the capture), filtered. `overrides` (the app's `CMUX_SOCKET_PATH`,
    /// `CMUX_BUNDLE_ID`, `CMUX_TAG`, Ghostty's terminal identity) win, so terminals created in a daemon that an
    /// older launch started still reach this app. `integration` (read per terminal, so a config reload applies to
    /// the next one) adds Ghostty's shell integration last, over the login `PATH`, `SHELL` and data dirs. `cli`
    /// (`BundledCLIEnvironment`) then puts the bundled `cmux` first on `PATH` and wraps that integration so it
    /// stays first after the user's startup files. `prefersGhosttyTerm` (`terminal.term`, read per terminal)
    /// picks `TERM`.
    public func shared(
        base: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:],
        login: (@Sendable () async -> [String: String]?)? = nil,
        integration: @escaping @Sendable () async -> GhosttyShellIntegration? = { nil },
        cli: BundledCLIEnvironment? = nil,
        prefersGhosttyTerm: @escaping @MainActor @Sendable () -> Bool = { false }
    ) -> @Sendable () async -> [String: String] {
        struct Request: Encodable {
            var login: [String: String]?, base: [String: String], overrides: [String: String], prefersGhosttyTerm: Bool
            var home: String, integration: GhosttyShellIntegration?, cli: BundledCLIEnvironment?
        }
        return {
            let captured = if let login { await login() } else { await LoginEnvironmentCache.shared.value() }
            let request = Request(login: captured, base: base, overrides: overrides, prefersGhosttyTerm: await prefersGhosttyTerm(),
                                  home: NSHomeDirectory(), integration: await integration(), cli: cli)
            return DaemonLaunchRules.call("terminal_spawn_environment", request, as: [String: String].self) ?? overrides
        }
    }
}
