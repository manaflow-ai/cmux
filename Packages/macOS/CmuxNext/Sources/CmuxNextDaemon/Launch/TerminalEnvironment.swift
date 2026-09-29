public import Foundation

/// The environment the app hands the daemon and its terminals.
///
/// `terminal-env-v1` persists a terminal's `env` with its creation receipt in
/// the daemon state directory, and the daemon process passes its own
/// environment to every PTY. So neither gets the full login environment,
/// which can hold tokens and keys. Both get only what a correct shell needs
/// before its rc files run; the login shell in each terminal sources the
/// user's rc files for everything else.
public enum TerminalEnvironment {
    /// Exact keys taken from the login environment.
    public static let allowedKeys: Set<String> = [
        "PATH", "MANPATH", "INFOPATH", "LANG", "SHELL", "TERMINFO_DIRS",
        "HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY",
    ]

    /// Key prefixes taken from the login environment. `CMUX_` keys that name
    /// a socket, session, or placement are still dropped
    /// (`LoginEnvironment.excludedKeys`).
    public static let allowedPrefixes: [String] = ["LC_", "XDG_", "CMUX_"]

    /// Process identity the daemon itself needs (state root, temp dir, ssh
    /// agent). Taken from the app process, never from the login shell, and
    /// only for the daemon process: terminals inherit them from it.
    public static let daemonIdentityKeys: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"]

    public static func isAllowed(_ key: String) -> Bool {
        guard !LoginEnvironment.excludedKeys.contains(key) else { return false }
        return allowedKeys.contains(key) || allowedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The allowlisted subset of `environment`.
    public static func filter(_ environment: [String: String]) -> [String: String] {
        environment.filter { isAllowed($0.key) }
    }

    /// Per-terminal `env` for `new-tab`, `split`, and `create-terminal`: the
    /// allowlisted login environment (or the app's, when capture failed),
    /// plus the app's own `CMUX_*` keys.
    public static func terminal(login: [String: String]?, base: [String: String]) -> [String: String] {
        var env = filter(login ?? base)
        for (key, value) in base where key.hasPrefix("CMUX_") && isAllowed(key) && env[key] == nil { env[key] = value }
        if login == nil, let path = env["PATH"], !path.contains("/opt/homebrew/bin") {
            // Best effort when capture failed: add the common tool prefixes.
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        return env
    }

    /// Environment for the daemon process: `terminal(login:base:)` plus the
    /// app's process identity keys, plus `overrides`.
    public static func daemon(login: [String: String]?, base: [String: String], overrides: [String: String]) -> [String: String] {
        var env = terminal(login: login, base: base)
        for key in daemonIdentityKeys { if let value = base[key] { env[key] = value } }
        for (key, value) in overrides { env[key] = value }
        return env
    }

    /// Shared per-launch provider for terminal `env`: the login environment
    /// captured once (the launcher's capture) and filtered.
    public static func shared(base: [String: String] = ProcessInfo.processInfo.environment) -> @Sendable () async -> [String: String] {
        { terminal(login: await LoginEnvironmentCache.shared.value(), base: base) }
    }
}
