import Foundation

/// Resolved Inline VS Code `serve-web` launch options.
///
/// Produced by ``InlineVSCodeServeWebOptionsResolver`` from, in precedence
/// order, the user's `~/.config/cmux/cmux.json` `inlineVSCode` block (which the
/// Settings UI also writes), then environment-variable fallbacks, then internal
/// defaults. Rendered into the `code-tunnel serve-web` argument list by
/// ``serveWebArguments(argumentsPrefix:connectionTokenFilePath:makeEphemeralServerDataDir:)``.
///
/// Defaults preserve the historical cmux behavior: a random port and the
/// upstream VS Code default data location (no `--server-data-dir`). Users opt in
/// to a pinned port, a specific server data directory, ephemeral state, or extra
/// upstream flags entirely through configuration.
struct InlineVSCodeServeWebOptions: Equatable, Sendable {
    /// Local port `serve-web` binds. `0` lets `serve-web` pick a random free port.
    var port: Int
    /// Concrete `--server-data-dir` path, or `nil` to omit the flag and use the
    /// upstream VS Code default location. Always already tilde-expanded.
    var serverDataDir: String?
    /// Whether `serve-web` keeps its state (sign-in, Settings Sync, …) across
    /// launches. When `false` and no explicit ``serverDataDir`` is set, a
    /// throwaway data directory is used so nothing persists.
    var persistServeWebState: Bool
    /// Extra raw flags appended verbatim after the cmux-managed `serve-web`
    /// arguments. cmux-owned flags are stripped before use (see ``reservedValueFlags``).
    var extraArgs: [String]

    static let `default` = InlineVSCodeServeWebOptions(
        port: 0,
        serverDataDir: nil,
        persistServeWebState: true,
        extraArgs: []
    )

    /// serve-web flags cmux owns and that `extraArgs` must never override. These
    /// take a value (either `--flag value` or `--flag=value`).
    static let reservedValueFlags: Set<String> = [
        "--host",
        "--port",
        "--connection-token",
        "--connection-token-file",
        "--server-data-dir",
    ]

    /// cmux-owned serve-web flags that take no value and that `extraArgs` must
    /// not toggle (e.g. disabling the connection token).
    static let reservedFlagsWithoutValue: Set<String> = [
        "--without-connection-token",
        "--accept-server-license-terms",
    ]

    /// Builds the full `serve-web` argument list.
    ///
    /// The cmux-managed flags (`--accept-server-license-terms`, loopback host,
    /// resolved port, connection-token file) always come first, then an optional
    /// `--server-data-dir`, then the user's ``extraArgs``. `extraArgs` are
    /// sanitized via ``sanitizedExtraArgs(_:)`` so a configured flag can never
    /// re-bind the host, change the port, or disable the connection token —
    /// preserving cmux's loopback + token invariants regardless of append order.
    /// `makeEphemeralServerDataDir` is invoked only when state persistence is
    /// disabled and no explicit directory is configured; it must return a usable
    /// throwaway path so non-persistent mode never leaks state.
    func serveWebArguments(
        argumentsPrefix: [String],
        connectionTokenFilePath: String,
        makeEphemeralServerDataDir: () -> String
    ) -> [String] {
        var arguments = argumentsPrefix + [
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--connection-token-file", connectionTokenFilePath,
        ]
        if let dataDir = effectiveServerDataDir(makeEphemeralServerDataDir: makeEphemeralServerDataDir) {
            arguments += ["--server-data-dir", dataDir]
        }
        arguments += Self.sanitizedExtraArgs(extraArgs)
        return arguments
    }

    /// Decides the concrete `--server-data-dir` value (or `nil` to omit it).
    ///
    /// An explicit configured directory always wins. Otherwise, persistent state
    /// (the default) omits the flag so `serve-web` uses its own default location,
    /// while non-persistent state always uses a throwaway directory and never
    /// falls back to the persistent default — a filesystem hiccup must not turn a
    /// "don't persist" choice into persisted sign-in/state.
    func effectiveServerDataDir(makeEphemeralServerDataDir: () -> String) -> String? {
        if let explicit = serverDataDir, !explicit.isEmpty {
            return explicit
        }
        if persistServeWebState {
            return nil
        }
        return makeEphemeralServerDataDir()
    }

    /// Removes any cmux-owned flags from user-supplied `extraArgs` so they cannot
    /// override the managed host/port/token/data-dir arguments. Handles both the
    /// `--flag value` and `--flag=value` forms.
    static func sanitizedExtraArgs(_ args: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index]
            let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if reservedValueFlags.contains(name) {
                // Drop the flag, and in the space-separated form also drop its value token.
                if !token.contains("=") {
                    index += 1
                }
                index += 1
                continue
            }
            if reservedFlagsWithoutValue.contains(name) {
                index += 1
                continue
            }
            result.append(token)
            index += 1
        }
        return result
    }
}
