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
        var env = filter(login ?? base)
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
        var env = terminal(login: login, base: base)
        for key in daemonIdentityKeys { if let value = base[key] { env[key] = value } }
        for (key, value) in overrides { env[key] = value }
        return env
    }

    /// The terminal identity Ghostty exports to every shell it starts
    /// (`ghostty/src/termio/Exec.zig`, `Subprocess.init`), so programs in a
    /// cmux-next terminal choose the same color depth and theme branch as in
    /// Ghostty. The daemon's terminal is ghostty-vt, so the Ghostty names are
    /// truthful. The app passes this as an override, which wins over the
    /// login shell's `TERM`/`COLORTERM`/`TERM_PROGRAM` (those stay excluded).
    ///
    /// - `TERM=xterm-ghostty` with `TERMINFO=<resources>/../terminfo` when
    ///   that entry exists, else `xterm-256color` (Ghostty's own fallback).
    ///   Prompt themes branch on the name: oh-my-zsh `half-life` uses the
    ///   theme palette under `xterm-ghostty` but the fixed 256-color cube
    ///   under `*256color`.
    /// - `COLORTERM=truecolor`: 24-bit SGR is parsed and drawn losslessly.
    /// - `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION`: feature detection
    ///   (neovim and others).
    /// - `GHOSTTY_RESOURCES_DIR`: themes and shell-integration lookups.
    public func ghostty(
        resourcesDirectory: String?,
        version: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        var env = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "ghostty"]
        if let version, !version.isEmpty { env["TERM_PROGRAM_VERSION"] = version }
        guard let resourcesDirectory, !resourcesDirectory.isEmpty else { return env }
        env["GHOSTTY_RESOURCES_DIR"] = resourcesDirectory
        let terminfo = ((resourcesDirectory as NSString).deletingLastPathComponent as NSString).appendingPathComponent("terminfo")
        if fileExists((terminfo as NSString).appendingPathComponent("78/xterm-ghostty")) {
            env["TERM"] = "xterm-ghostty"
            env["TERMINFO"] = terminfo
        }
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
    /// it stays first after the user's startup files.
    public func shared(
        base: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:],
        login: (@Sendable () async -> [String: String]?)? = nil,
        integration: @escaping @Sendable () async -> GhosttyShellIntegration? = { nil },
        cli: BundledCLIEnvironment? = nil
    ) -> @Sendable () async -> [String: String] {
        {
            let captured = if let login { await login() } else { await LoginEnvironmentCache.shared.value() }
            var env = terminal(login: captured, base: base)
            for (key, value) in overrides { env[key] = value }
            if let integration = await integration() { env = integration.apply(to: env) }
            if let cli { env = cli.apply(to: env) }
            return env
        }
    }
}
