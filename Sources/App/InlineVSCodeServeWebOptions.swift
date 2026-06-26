import CmuxSettings
import Foundation

/// Resolved Inline VS Code `serve-web` launch options.
///
/// Produced by ``InlineVSCodeServeWebOptionsResolver`` from, in precedence
/// order, the user's `~/.config/cmux/cmux.json` `inlineVSCode` block (which the
/// Settings UI also writes), then environment-variable fallbacks, then internal
/// defaults. Consumed by ``InlineVSCodeServeWebSupport/serveWebArguments(argumentsPrefix:options:connectionTokenFilePath:makeEphemeralServerDataDir:)``
/// to build the `code-tunnel serve-web` argument list.
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
    /// arguments. For advanced upstream VS Code `serve-web` options.
    var extraArgs: [String]

    static let `default` = InlineVSCodeServeWebOptions(
        port: 0,
        serverDataDir: nil,
        persistServeWebState: true,
        extraArgs: []
    )
}

/// Presence-aware values decoded from the `inlineVSCode` block of `cmux.json`.
///
/// `nil` means the key was absent from the file, which lets
/// ``InlineVSCodeServeWebOptionsResolver`` fall back to the environment and then
/// internal defaults. Distinguishing "absent" from "set to the default value"
/// is exactly why this type carries optionals instead of reusing
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
/// Precedence per field: cmux.json (`inlineVSCode.*`, also written by the
/// Settings UI) overrides the environment variable, which overrides the
/// internal default. The environment layer is a debugging escape hatch; the
/// Settings UI / `cmux.json` is the supported user-facing configuration story.
enum InlineVSCodeServeWebOptionsResolver {
    /// Environment-variable names forming the fallback layer below cmux.json.
    enum EnvironmentKey {
        static let port = "CMUX_INLINE_VSCODE_PORT"
        static let serverDataDir = "CMUX_INLINE_VSCODE_SERVER_DATA_DIR"
        static let persistState = "CMUX_INLINE_VSCODE_PERSIST_STATE"
        static let extraArgs = "CMUX_INLINE_VSCODE_EXTRA_ARGS"
    }

    static func resolve(
        file: InlineVSCodeConfigFileValues,
        environment: [String: String],
        homeDirectoryPath: String
    ) -> InlineVSCodeServeWebOptions {
        InlineVSCodeServeWebOptions(
            port: resolvedPort(file: file.port, environment: environment),
            serverDataDir: resolvedServerDataDir(
                file: file.serverDataDir,
                environment: environment,
                homeDirectoryPath: homeDirectoryPath
            ),
            persistServeWebState: file.persistServeWebState
                ?? environmentBool(environment[EnvironmentKey.persistState])
                ?? InlineVSCodeServeWebOptions.default.persistServeWebState,
            extraArgs: resolvedExtraArgs(file: file.extraArgs, environment: environment)
        )
    }

    private static func resolvedPort(file: Int?, environment: [String: String]) -> Int {
        if let candidate = file ?? environmentInt(environment[EnvironmentKey.port]),
           isValidPort(candidate) {
            return candidate
        }
        return InlineVSCodeServeWebOptions.default.port
    }

    private static func resolvedServerDataDir(
        file: String?,
        environment: [String: String],
        homeDirectoryPath: String
    ) -> String? {
        let raw = file ?? environment[EnvironmentKey.serverDataDir]
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return expandingTilde(trimmed, homeDirectoryPath: homeDirectoryPath)
    }

    private static func resolvedExtraArgs(file: [String]?, environment: [String: String]) -> [String] {
        let raw: [String]
        if let file {
            raw = file
        } else if let env = environment[EnvironmentKey.extraArgs] {
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

    static func isValidPort(_ port: Int) -> Bool {
        (0...65535).contains(port)
    }

    private static func environmentInt(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return Int(value)
    }

    private static func environmentBool(_ value: String?) -> Bool? {
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

/// Glue between cmux.json / environment configuration and the running
/// `serve-web` process.
///
/// Holds the presence-aware cmux.json reader, the pure `serve-web` argument
/// builder, the ephemeral-data-directory helper, and the
/// ``resolveOptions(configFileURL:environment:homeDirectoryPath:)`` composition
/// the launcher calls at process-spawn time.
enum InlineVSCodeServeWebSupport {
    /// Reads the presence-aware `inlineVSCode` block from a cmux.json file.
    ///
    /// JSONC (comments / trailing commas) is tolerated via ``JSONCSanitizer``.
    /// Any read, sanitize, or decode failure resolves to ``InlineVSCodeConfigFileValues/empty``
    /// so a missing or malformed file simply falls back to environment + defaults
    /// rather than breaking the launch.
    static func readFileValues(
        configFileURL: URL,
        dataReader: (URL) -> Data? = { try? Data(contentsOf: $0) },
        sanitizer: JSONCSanitizer = JSONCSanitizer()
    ) -> InlineVSCodeConfigFileValues {
        guard let data = dataReader(configFileURL), !data.isEmpty,
              let sanitized = try? sanitizer.sanitize(data),
              let wrapper = try? JSONDecoder().decode(ConfigWrapper.self, from: sanitized),
              let block = wrapper.inlineVSCode else {
            return .empty
        }
        return InlineVSCodeConfigFileValues(
            port: block.port,
            serverDataDir: block.serverDataDir,
            persistServeWebState: block.persistServeWebState,
            extraArgs: block.extraArgs
        )
    }

    /// Builds the full `serve-web` argument list.
    ///
    /// The cmux-managed flags (`--accept-server-license-terms`, loopback host,
    /// resolved port, connection-token file) always come first, then an optional
    /// `--server-data-dir`, then the user's ``InlineVSCodeServeWebOptions/extraArgs``
    /// appended verbatim. `makeEphemeralServerDataDir` is invoked only when state
    /// persistence is disabled and no explicit directory is configured.
    static func serveWebArguments(
        argumentsPrefix: [String],
        options: InlineVSCodeServeWebOptions,
        connectionTokenFilePath: String,
        makeEphemeralServerDataDir: () -> String?
    ) -> [String] {
        var arguments = argumentsPrefix + [
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", String(options.port),
            "--connection-token-file", connectionTokenFilePath,
        ]
        if let dataDir = effectiveServerDataDir(
            options: options,
            makeEphemeralServerDataDir: makeEphemeralServerDataDir
        ) {
            arguments += ["--server-data-dir", dataDir]
        }
        arguments += options.extraArgs
        return arguments
    }

    /// Decides the concrete `--server-data-dir` value (or `nil` to omit it).
    ///
    /// An explicit configured directory always wins. Otherwise, persistent state
    /// (the default) omits the flag so `serve-web` uses its own default location,
    /// while non-persistent state uses a throwaway directory.
    static func effectiveServerDataDir(
        options: InlineVSCodeServeWebOptions,
        makeEphemeralServerDataDir: () -> String?
    ) -> String? {
        if let explicit = options.serverDataDir, !explicit.isEmpty {
            return explicit
        }
        if options.persistServeWebState {
            return nil
        }
        return makeEphemeralServerDataDir()
    }

    /// Resolves the launch options from the live cmux.json, environment, and home
    /// directory. Called on the launch queue at process-spawn time so the latest
    /// configuration wins on every (re)start.
    static func resolveOptions(
        configFileURL: URL = CmuxConfigLocation().userConfigFile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> InlineVSCodeServeWebOptions {
        InlineVSCodeServeWebOptionsResolver.resolve(
            file: readFileValues(configFileURL: configFileURL),
            environment: environment,
            homeDirectoryPath: homeDirectoryPath
        )
    }

    /// Creates (or re-creates) the throwaway `serve-web` data directory used when
    /// state persistence is disabled. Wiped on each call so non-persistent
    /// launches always start clean. Returns `nil` on failure, in which case the
    /// caller omits `--server-data-dir` (falling back to persistent behavior).
    static func makeEphemeralServerDataDir() -> String? {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-vscode-serve-web-ephemeral", isDirectory: true)
        try? FileManager.default.removeItem(at: baseURL)
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return baseURL.path
    }

    /// Codable shape used to decode just the `inlineVSCode` block, ignoring every
    /// other cmux.json key. Optional fields give presence-aware decoding and
    /// strict type checking (so a JSON `true` never silently reads as a port).
    private struct ConfigWrapper: Decodable {
        let inlineVSCode: Block?

        struct Block: Decodable {
            let port: Int?
            let serverDataDir: String?
            let persistServeWebState: Bool?
            let extraArgs: [String]?
        }
    }
}
