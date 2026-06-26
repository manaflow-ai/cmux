import CmuxSettings
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

/// Presence-aware values decoded from the `inlineVSCode` block of `cmux.json`.
///
/// `nil` means the key was absent from the file, which lets
/// ``InlineVSCodeServeWebOptionsResolver`` fall back to the environment and then
/// internal defaults. Distinguishing "absent" from "set to the default value" is
/// exactly why this type carries optionals instead of reusing
/// ``InlineVSCodeServeWebOptions``.
struct InlineVSCodeConfigFileValues: Equatable, Sendable {
    var port: Int?
    var serverDataDir: String?
    var persistServeWebState: Bool?
    var extraArgs: [String]?

    static let empty = InlineVSCodeConfigFileValues(
        port: nil,
        serverDataDir: nil,
        persistServeWebState: nil,
        extraArgs: nil
    )
}

/// Resolves ``InlineVSCodeServeWebOptions`` from cmux.json values, environment
/// variables, and internal defaults.
///
/// The environment and home directory are constructor-injected so resolution is
/// deterministic and testable. Precedence per field: cmux.json (`inlineVSCode.*`,
/// also written by the Settings UI) overrides the environment variable, which
/// overrides the internal default. The environment layer is a debugging escape
/// hatch; the Settings UI / `cmux.json` is the supported user-facing story.
struct InlineVSCodeServeWebOptionsResolver {
    /// Environment-variable names forming the fallback layer below cmux.json.
    static let portEnvironmentKey = "CMUX_INLINE_VSCODE_PORT"
    static let serverDataDirEnvironmentKey = "CMUX_INLINE_VSCODE_SERVER_DATA_DIR"
    static let persistStateEnvironmentKey = "CMUX_INLINE_VSCODE_PERSIST_STATE"
    static let extraArgsEnvironmentKey = "CMUX_INLINE_VSCODE_EXTRA_ARGS"

    let environment: [String: String]
    let homeDirectoryPath: String

    init(environment: [String: String], homeDirectoryPath: String) {
        self.environment = environment
        self.homeDirectoryPath = homeDirectoryPath
    }

    func resolve(file: InlineVSCodeConfigFileValues) -> InlineVSCodeServeWebOptions {
        InlineVSCodeServeWebOptions(
            port: resolvedPort(file: file.port),
            serverDataDir: resolvedServerDataDir(file: file.serverDataDir),
            persistServeWebState: file.persistServeWebState
                ?? Self.parseBool(environment[Self.persistStateEnvironmentKey])
                ?? InlineVSCodeServeWebOptions.default.persistServeWebState,
            extraArgs: resolvedExtraArgs(file: file.extraArgs)
        )
    }

    private func resolvedPort(file: Int?) -> Int {
        if let candidate = file ?? Self.parseInt(environment[Self.portEnvironmentKey]),
           (0...65535).contains(candidate) {
            return candidate
        }
        return InlineVSCodeServeWebOptions.default.port
    }

    private func resolvedServerDataDir(file: String?) -> String? {
        let raw = file ?? environment[Self.serverDataDirEnvironmentKey]
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return Self.expandingTilde(trimmed, homeDirectoryPath: homeDirectoryPath)
    }

    private func resolvedExtraArgs(file: [String]?) -> [String] {
        let raw: [String]
        if let file {
            raw = file
        } else if let env = environment[Self.extraArgsEnvironmentKey] {
            raw = env.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        } else {
            raw = []
        }
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Expands a leading `~` / `~/` against `homeDirectoryPath`. Other paths are
    /// returned unchanged. Implemented against an injected home directory rather
    /// than `NSString.expandingTildeInPath` so resolution is deterministic in
    /// tests.
    static func expandingTilde(_ path: String, homeDirectoryPath: String) -> String {
        if path == "~" {
            return homeDirectoryPath
        }
        guard path.hasPrefix("~/") else {
            return path
        }
        let home = homeDirectoryPath.hasSuffix("/")
            ? String(homeDirectoryPath.dropLast())
            : homeDirectoryPath
        return home + String(path.dropFirst(1))
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return Int(value)
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

/// Loads Inline VS Code `serve-web` launch options from the live cmux.json,
/// environment, and home directory.
///
/// All inputs are constructor-injected (config file URL, environment, home
/// directory, file reader, JSONC sanitizer) so the loader is fully testable and
/// carries no ambient global state. The macOS launcher constructs one on the
/// background launch queue at process-spawn time so the latest configuration
/// wins on every (re)start.
struct InlineVSCodeServeWebConfigurationLoader {
    let configFileURL: URL
    let environment: [String: String]
    let homeDirectoryPath: String
    let dataReader: (URL) -> Data?
    let sanitizer: JSONCSanitizer

    init(
        configFileURL: URL = CmuxConfigLocation().userConfigFile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        dataReader: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) },
        sanitizer: JSONCSanitizer = JSONCSanitizer()
    ) {
        self.configFileURL = configFileURL
        self.environment = environment
        self.homeDirectoryPath = homeDirectoryPath
        self.dataReader = dataReader
        self.sanitizer = sanitizer
    }

    /// Reads cmux.json and resolves it (with environment + default fallbacks)
    /// into launch options.
    func loadOptions() -> InlineVSCodeServeWebOptions {
        InlineVSCodeServeWebOptionsResolver(
            environment: environment,
            homeDirectoryPath: homeDirectoryPath
        ).resolve(file: readFileValues())
    }

    /// Reads the presence-aware `inlineVSCode` block from the configured
    /// cmux.json. JSONC (comments / trailing commas) is tolerated. A missing or
    /// unparseable file resolves to ``InlineVSCodeConfigFileValues/empty``.
    ///
    /// Each field is decoded independently: a single bad value (e.g. a quoted
    /// `"port"`) leaves that one field `nil` and falls back to environment +
    /// defaults for it, without discarding the sibling fields. That keeps
    /// hand-edited config robust and, crucially, a typo elsewhere can never
    /// silently drop a valid `persistServeWebState: false` privacy choice.
    func readFileValues() -> InlineVSCodeConfigFileValues {
        guard let data = dataReader(configFileURL), !data.isEmpty,
              let sanitized = try? sanitizer.sanitize(data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
              let block = root["inlineVSCode"] as? [String: Any] else {
            return .empty
        }
        return InlineVSCodeConfigFileValues(
            port: Self.integerValue(block["port"]),
            serverDataDir: block["serverDataDir"] as? String,
            persistServeWebState: Self.booleanValue(block["persistServeWebState"]),
            extraArgs: (block["extraArgs"] as? [Any])?.compactMap { $0 as? String }
        )
    }

    /// Creates a fresh throwaway `serve-web` data directory for non-persistent
    /// launches. Always returns a unique per-launch temp path (never the
    /// persistent default location). It does NOT delete the shared parent, so it
    /// can never recursively remove a data directory another cmux instance's
    /// running `serve-web` is using; the OS reclaims the temp tree. `serve-web`
    /// creates the directory if missing, so this never falls back to persistent
    /// storage. A fresh UUID per launch is what makes the mode non-persistent.
    func makeEphemeralServerDataDir() -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-vscode-serve-web-ephemeral", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    /// Extracts an integer JSON value, rejecting booleans (JSON `true`/`false`
    /// bridge to `NSNumber` and would otherwise read as `1`/`0`), non-numbers,
    /// and non-integral numbers. Truncating a fractional `port` like `1.9` to `1`
    /// would silently bind a different port than the schema (`type: integer`)
    /// permits, so a fractional value is treated as absent (falls back to the
    /// default random port) instead.
    private static func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBooleanNumber(number) else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else { return nil }
        return number.intValue
    }

    /// Extracts a boolean JSON value, accepting only real JSON booleans (not a
    /// numeric `1`/`0`).
    private static func booleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBooleanNumber(number) else { return nil }
        return number.boolValue
    }

    private static func isBooleanNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }
}
