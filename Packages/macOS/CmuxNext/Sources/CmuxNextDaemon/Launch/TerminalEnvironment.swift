public import Foundation
public import CmuxNextCompat

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
    /// Exact keys taken from the login environment.
    public let allowedKeys: Set<String> = [
        "PATH", "MANPATH", "INFOPATH", "LANG", "SHELL", "TERMINFO_DIRS",
        "HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY",
    ]

    /// Key prefixes taken from the login environment. `CMUX_` keys that name
    /// a socket, session, or placement are still dropped
    /// (`LoginEnvironment.shared.excludedKeys`).
    public let allowedPrefixes: [String] = ["LC_", "XDG_", "CMUX_"]

    /// Process identity the daemon itself needs (state root, temp dir, ssh
    /// agent). Taken from the app process, never from the login shell, and
    /// only for the daemon process: terminals inherit them from it.
    public let daemonIdentityKeys: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"]

    public func isAllowed(_ key: String) -> Bool {
        guard !LoginEnvironment.shared.excludedKeys.contains(key), !isCredential(key) else { return false }
        return allowedKeys.contains(key) || allowedPrefixes.contains { key.hasPrefix($0) }
    }

    /// Name parts that mark a credential. A key is allowed by prefix
    /// (`CMUX_`, `XDG_`, `LC_`), so a secret under an allowed prefix
    /// (`CMUX_DOGFOOD_STACK_PASSWORD`, `CMUX_SOCKET_PASSWORD`, a token or
    /// a credentials file) would otherwise reach every program in every
    /// terminal and the daemon's persisted terminal env.
    let credentialParts: Set<String> = [
        "PASSWORD", "PASSWD", "PASS", "TOKEN", "SECRET", "CREDENTIAL", "CREDENTIALS", "APIKEY", "PRIVATE",
    ]

    /// Whether `key` names a credential: one of its `_`-separated parts is
    /// a credential word, or it ends in `_KEY` (`API_KEY`, `ACCESS_KEY`).
    func isCredential(_ key: String) -> Bool {
        let parts = key.uppercased().split(separator: "_").map(String.init)
        return parts.contains(where: credentialParts.contains) || parts.last == "KEY"
    }

    /// The allowlisted subset of `environment`.
    public func filter(_ environment: [String: String]) -> [String: String] {
        environment.filter { isAllowed($0.key) }
    }

    /// Per-terminal `env` for `new-tab`, `split`, and `create-terminal`: the
    /// allowlisted login environment (or the app's, when capture failed),
    /// plus the app's own `CMUX_*` keys. The app's `CMUX_NEXT_*` launch knobs
    /// (`CMUX_NEXT_SOCKET_PATH`, `CMUX_NEXT_NO_ACTIVATE`) configure this
    /// process only and are not forwarded, so a cmux-next started from one of
    /// its terminals does not inherit them.
    public func terminal(login: [String: String]?, base: [String: String]) -> [String: String] {
        var env: [String: String] = filter(login ?? base)
        for (key, value) in base where key.hasPrefix("CMUX_") && !key.hasPrefix("CMUX_NEXT_") && isAllowed(key) && env[key] == nil {
            env[key] = value
        }
        if login == nil, let path = env["PATH"], !path.contains("/opt/homebrew/bin") {
            // Best effort when capture failed: add the common tool prefixes.
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        return env
    }

    /// Environment for the daemon process: `terminal(login:base:)` plus the
    /// app's process identity keys, plus `overrides`.
    public func daemon(login: [String: String]?, base: [String: String], overrides: [String: String]) -> [String: String] {
        var env: [String: String] = terminal(login: login, base: base)
        for key in daemonIdentityKeys { if let value = base[key] { env[key] = value } }
        for (key, value) in overrides { env[key] = value }
        return env
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
    ///   (`hasInstalledGhosttyTerminfo`). `TERMINFO` is not set. Ghostty's
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
    /// Whether `xterm-ghostty` is in a terminfo directory ncurses searches by default.
    public static func hasInstalledGhosttyTerminfo(
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }
    ) -> Bool {
        let roots = [home + "/.terminfo", "/usr/share/terminfo", "/usr/lib/terminfo", "/etc/terminfo", "/lib/terminfo",
                     "/opt/homebrew/share/terminfo", "/usr/local/share/terminfo"]
        return roots.contains { fileExists($0 + "/78/xterm-ghostty") || fileExists($0 + "/x/xterm-ghostty") }
    }

    /// The `TERM` a new terminal starts with: `xterm-256color`, or `xterm-ghostty`
    /// when the user opted in (`prefersGhosttyTerm`) and its entry is installed here.
    public func term(
        prefersGhosttyTerm: Bool,
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }
    ) -> String {
        prefersGhosttyTerm && Self.hasInstalledGhosttyTerminfo(home: home, fileExists: fileExists) ? "xterm-ghostty" : "xterm-256color"
    }

    public func ghostty(
        resourcesDirectory: String?,
        version _: String?,
        prefersGhosttyTerm: Bool = false,
        fileExists: (String) -> Bool = { FileManager.checked.fileExists(atPath: $0) }
    ) -> [String: String] {
        var env = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "cmux"]
        env["TERM"] = term(prefersGhosttyTerm: prefersGhosttyTerm, fileExists: fileExists)
        if let resourcesDirectory, !resourcesDirectory.isEmpty { env["GHOSTTY_RESOURCES_DIR"] = resourcesDirectory }
        return env
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
    /// (`terminal.term`, read per terminal) picks `TERM` (``term(prefersGhosttyTerm:home:fileExists:)``).
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
            var env: [String: String] = terminal(login: captured, base: base)
            for (key, value) in overrides { env[key] = value }
            env["TERM"] = term(prefersGhosttyTerm: await prefersGhosttyTerm())
            if let integration = await integration() { env = integration.apply(to: env) }
            if let cli { env = cli.apply(to: env) }
            return env
        }
    }
}
