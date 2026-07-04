import CmuxSettings
import Foundation

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
