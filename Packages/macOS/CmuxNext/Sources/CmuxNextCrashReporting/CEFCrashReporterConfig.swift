import CmuxNextCompat
public import Foundation

/// The app bundle's `crash_reporter.cfg` (p09-observability-105), which turns Crashpad on in every Chromium
/// process: CEF reads it from the main bundle's Resources (libcef/common/crash_reporter_client.cc,
/// GetCrashConfigPath and ReadCrashConfigFile) and, when it is there, starts Crashpad
/// (libcef/common/crash_reporting.cc, InitCrashReporter). `scripts/cmux-next/write-crash-reporter-cfg.sh` writes it
/// only for a build that asks for it (`CMUX_NEXT_CEF_CRASHPAD=1`: nightly-next builds), with no `ServerURL`:
/// Crashpad then keeps reports in its local database and never uploads, and cmux forwards each crash
/// (`ChromiumMinidumpForwarder`: the redacted dump with hang report consent, a crash summary without it).
///
/// ```swift
/// let database = CEFCrashReporterConfig.minidumpDatabase(resources: Bundle.main.resourceURL,
///                                                       chromiumRoot: CEFProfileStorage.forApplication(...).root)
/// ```
public nonisolated struct CEFCrashReporterConfig: Sendable, Equatable {
    /// The file name CEF looks for.
    public static let fileName = "crash_reporter.cfg"
    /// CEF's override of the dump folder (CefCrashReporterClient::GetCrashDumpLocation).
    public static let dumpLocationKey = "BREAKPAD_DUMP_LOCATION"

    /// The `[Config]` section's values, by name.
    public let config: [String: String]
    /// The `[CrashKeys]` section: each key and its size (`small`, `medium`, `large`).
    public let crashKeys: [String: String]

    /// Crashpad's upload address; nil when reports stay on disk.
    public var serverURL: String? { config["ServerURL"].flatMap { $0.isEmpty ? nil : $0 } }

    /// Parses a config as CEF does: one `name=value` per line with whitespace trimmed, `#` comment lines,
    /// `[Config]` and `[CrashKeys]` sections, every other section ignored.
    public init(text: String) {
        var config: [String: String] = [:], crashKeys: [String: String] = [:]
        var section: Section = .other
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line == "[Config]" ? .config : line == "[CrashKeys]" ? .crashKeys : .other
                continue
            }
            guard section != .other, let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if section == .config { config[name] = value } else { crashKeys[name] = value }
        }
        self.config = config
        self.crashKeys = crashKeys
    }

    private nonisolated enum Section { case other, config, crashKeys }

    /// The config in `resources` (the main bundle's Resources folder); nil when the build has none. Reads a file.
    public static func load(resources: URL?) -> CEFCrashReporterConfig? {
        guard let url = resources?.appending(path: fileName),
              let text = try? String(blockingContentsOf: url, encoding: .utf8) else { return nil }
        return CEFCrashReporterConfig(text: text)
    }

    /// Where Crashpad keeps this app's reports, or nil when cmux must not forward them: no config (no Crashpad),
    /// or a config with a `ServerURL` (Crashpad would upload unredacted dumps itself). Reads a file.
    ///
    /// On macOS CEF points `chrome::DIR_CRASH_DUMPS` at the user data folder, which is
    /// `CefSettings.root_cache_path` (libcef/common/resource_util.cc, OverrideUserDataDir), so the database is
    /// `chromiumRoot` (CmuxNextBrowser's `CEFProfileStorage` root), unless `BREAKPAD_DUMP_LOCATION` names another
    /// folder.
    public static func minidumpDatabase(resources: URL?, chromiumRoot: URL,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let config = load(resources: resources), config.serverURL == nil else { return nil }
        if let override = environment[dumpLocationKey], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return chromiumRoot
    }
}
