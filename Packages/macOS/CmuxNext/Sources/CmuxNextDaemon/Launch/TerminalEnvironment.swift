public import Foundation

/// The environment the app hands the daemon and its terminals.
///
/// `terminal-env-v1` persists a terminal's `env` with its creation receipt in
/// the daemon state directory, and the daemon process passes its own
/// environment to every PTY. So neither gets the full login environment,
/// which can hold tokens and keys. Both get only what a correct shell needs
/// before its rc files run; the login shell in each terminal sources the
/// user's rc files for everything else.
public struct TerminalEnvironment: Sendable {
    public static let instance = Self()
    /// Process identity the daemon itself needs (state root, temp dir, ssh
    /// agent). Taken from the app process, never from the login shell, and
    /// only for the daemon process: terminals inherit them from it.
    public var daemonIdentityKeys: Set<String> {
        Set(DaemonLaunchRules.call("daemon_identity_keys") as? [String] ?? [])
    }

    /// Per-terminal `env` for `new-tab`, `split`, and `create-terminal`: the
    /// allowlisted login environment (or the app's, when capture failed),
    /// plus the app's own `CMUX_*` keys. The app's `CMUX_NEXT_*` launch knobs
    /// (`CMUX_NEXT_SOCKET_PATH`, `CMUX_NEXT_NO_ACTIVATE`) configure this
    /// process only and are not forwarded, so a cmux-next started from one of
    /// its terminals does not inherit them.
    public func terminal(login: [String: String]?, base: [String: String]) -> [String: String] {
        var request: [String: Any] = ["base": base]
        if let login { request["login"] = login }
        return DaemonLaunchRules.call("terminal_environment", request) as? [String: String] ?? [:]
    }

    /// Environment for the daemon process: `terminal(login:base:)` plus the
    /// app's process identity keys, plus `overrides`.
    public func daemon(login: [String: String]?, base: [String: String], overrides: [String: String]) -> [String: String] {
        var request: [String: Any] = ["base": base, "overrides": overrides]
        if let login { request["login"] = login }
        return DaemonLaunchRules.call("daemon_environment", request) as? [String: String] ?? overrides
    }

    /// The terminal identity the app hands every shell, modeled on what
    /// Ghostty exports (`ghostty/src/termio/Exec.zig`, `Subprocess.init`), so
    /// programs in a cmux-next terminal choose the same color depth and theme
    /// branch as in Ghostty. The app passes this as an override, which wins
    /// over the login shell's `TERM`/`COLORTERM`/`TERM_PROGRAM` (those stay
    /// excluded).
    ///
    /// - `TERM=xterm-256color`, the entry every ssh target, VM and container
    ///   has. An installed `xterm-ghostty` on this Mac does not select it:
    ///   ssh carries `TERM` to hosts that lack it, where `clear`/`htop` fail
    ///   with "cannot initialize terminal type" (user, 2026-11-05). Only
    ///   `prefersGhosttyTerm` (`terminal.term` = `xterm-ghostty`) selects
    ///   it, and then only when it is installed here
    ///   (``term(prefersGhosttyTerm:home:fs:)``). `TERMINFO` is not set. Ghostty's
    ///   features need no terminfo name: programs find the kitty keyboard
    ///   protocol, synchronized output and graphics by querying the terminal
    ///   and `TERM_PROGRAM`, and truecolor by `COLORTERM`.
    /// - `COLORTERM=truecolor`: 24-bit SGR is parsed and drawn losslessly.
    /// - `TERM_PROGRAM=cmux` names the terminal (user, 2026-11-11). The daemon
    ///   sets it again with cmux's `TERM_PROGRAM_VERSION` on every terminal
    ///   child (`cmux_pty::TERMINAL_IDENTITY`), so no libghostty version goes
    ///   out here: a Ghostty version makes Codex and Claude turn off their
    ///   copy-on-select fallback (cmux#22585). Claude Code and Codex key
    ///   Ghostty features on `TERM_PROGRAM=ghostty`, so the `claude`/`codex`
    ///   wrappers start them with that name (`agent_terminal_identity`).
    /// - `GHOSTTY_RESOURCES_DIR`: themes and shell-integration lookups.
    ///
    /// `fs` (`{files, dirs, executables}`) stands in for the disk in tests; nil reads it.
    public func ghostty(
        resourcesDirectory: String?,
        version _: String?,
        prefersGhosttyTerm: Bool = false,
        home: String = NSHomeDirectory(),
        fs: [String: [String]]? = nil
    ) -> [String: String] {
        var request: [String: Any] = ["prefersGhosttyTerm": prefersGhosttyTerm, "home": home]
        if let resourcesDirectory { request["resourcesDirectory"] = resourcesDirectory }
        if let fs { request["fs"] = fs }
        return DaemonLaunchRules.call("ghostty_identity", request) as? [String: String]
            ?? ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "cmux"]
    }

    /// The `TERM` a new terminal starts with: `xterm-256color`, or `xterm-ghostty`
    /// when the user opted in (`prefersGhosttyTerm`) and its entry is installed in a
    /// terminfo directory ncurses searches by default.
    public func term(prefersGhosttyTerm: Bool, home: String = NSHomeDirectory(), fs: [String: [String]]? = nil) -> String {
        var request: [String: Any] = ["prefersGhosttyTerm": prefersGhosttyTerm, "home": home]
        if let fs { request["fs"] = fs }
        return DaemonLaunchRules.call("term", request) as? String ?? "xterm-256color"
    }

    /// Shared per-launch provider for terminal `env`: the login environment
    /// (`LoginEnvironmentCache.value()`: this launch's capture, else the
    /// one remembered from the last launch, else a wait for the capture),
    /// filtered.
    /// `overrides` (the app's `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`,
    /// `CMUX_TAG`, Ghostty's terminal identity) win, so terminals created in
    /// a daemon that an older launch started still reach this app.
    /// `integration` (read per terminal, so a config reload applies to the
    /// next one) adds Ghostty's shell integration last, over the login
    /// `PATH`, `SHELL` and data dirs. `cli` (`BundledCLIEnvironment`) then
    /// puts the bundled `cmux` first on `PATH` and wraps that integration so
    /// it stays first after the user's startup files. `prefersGhosttyTerm`
    /// (`terminal.term`, read per terminal) picks `TERM` (``term(prefersGhosttyTerm:home:fs:)``). One `terminal_spawn_environment`
    /// op builds it in Rust (`terminal_env::spawn`).
    public func shared(
        base: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:],
        login: (@Sendable () async -> [String: String]?)? = nil,
        integration: @escaping @Sendable () async -> GhosttyShellIntegration? = { nil },
        cli: BundledCLIEnvironment? = nil,
        prefersGhosttyTerm: @escaping @MainActor @Sendable () -> Bool = { false }
    ) -> @Sendable () async -> [String: String] {
        {
            let captured = if let login { await login() } else { await LoginEnvironmentCache.shared.value() }
            let prefers = await prefersGhosttyTerm()
            var request: [String: Any] = ["base": base, "overrides": overrides, "prefersGhosttyTerm": prefers, "home": NSHomeDirectory()]
            if let captured { request["login"] = captured }
            if let integration = await integration() { request["integration"] = integration.json }
            if let cli { request["cli"] = cli.json }
            return DaemonLaunchRules.call("terminal_spawn_environment", request) as? [String: String]
                ?? overrides
        }
    }
}
