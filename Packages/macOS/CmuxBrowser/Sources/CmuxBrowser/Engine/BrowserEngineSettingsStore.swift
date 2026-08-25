@preconcurrency public import Foundation

/// Reads and writes the persisted defaults used when a browser pane is created.
///
/// The store owns no global state: callers inject the `UserDefaults` suite at
/// the composition boundary, and tests can use an isolated suite. Existing
/// panes retain the values captured at creation time.
public struct BrowserEngineSettingsStore: Sendable {
    /// The `UserDefaults` key for the engine used by newly created panes.
    public static let defaultEngineKey = "browser.defaultEngine"

    /// The key used by the first Chromium-engine prototype. Read once during
    /// migration so an existing opt-in survives the key rename.
    private static let legacyDefaultEngineKey = "browser.engine"

    /// The `UserDefaults` key for the optional loopback CDP listener.
    public static let remoteDebuggingPortKey = "browser.remoteDebuggingPort"

    /// The `UserDefaults` key for unpacked Chromium extension directories,
    /// stored as newline-separated absolute paths.
    public static let chromiumExtensionDirectoriesKey = "browser.chromiumExtensionDirectories"

    /// The preference used when nothing has been persisted: follow the
    /// system default browser.
    public static let defaultEngineChoice: BrowserEngineDefaultChoice = .auto

    /// The default remote-debugging setting. Zero means disabled.
    public static let defaultRemoteDebuggingPort: ChromiumRemoteDebuggingPort = .disabled

    // UserDefaults is documented thread-safe. The escape hatch is scoped to
    // this immutable dependency instead of making the whole store unchecked.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a browser settings repository backed by an explicit defaults suite.
    ///
    /// - Parameter defaults: The suite to read and write.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the persisted engine preference for newly created browser panes.
    ///
    /// - Returns: The persisted choice, falling back to `.auto`.
    public func defaultEngineChoice() -> BrowserEngineDefaultChoice {
        if let rawValue = defaults.string(forKey: Self.defaultEngineKey),
           !rawValue.isEmpty {
            return BrowserEngineDefaultChoice(persistedRawValue: rawValue)
        }
        guard let legacyValue = defaults.string(forKey: Self.legacyDefaultEngineKey),
              !legacyValue.isEmpty else {
            return Self.defaultEngineChoice
        }
        let choice = BrowserEngineDefaultChoice(persistedRawValue: legacyValue)
        defaults.set(choice.rawValue, forKey: Self.defaultEngineKey)
        return choice
    }

    /// Resolves the concrete engine for a newly created browser pane.
    ///
    /// - Parameter systemDefaultBrowserIsChromium: Whether the system default
    ///   browser is Chromium-family. Evaluated only when the choice is `.auto`.
    /// - Returns: The engine a new pane should run.
    public func defaultEngineValue(
        systemDefaultBrowserIsChromium: @autoclosure () -> Bool = false
    ) -> BrowserEngineKind {
        defaultEngineChoice().resolvedEngine(
            systemDefaultBrowserIsChromium: systemDefaultBrowserIsChromium()
        )
    }

    /// Persists the engine preference for newly created browser panes.
    ///
    /// - Parameter choice: The preference to persist.
    public func setDefaultEngine(_ choice: BrowserEngineDefaultChoice) {
        defaults.set(choice.rawValue, forKey: Self.defaultEngineKey)
    }

    /// Returns validated unpacked-extension directories for Chromium panes.
    ///
    /// Entries are newline-separated paths. A directory is included only when
    /// it exists and contains a `manifest.json`, so a stale or mistyped path
    /// can never add an unexpected `--load-extension` argument. Paths that
    /// contain a comma are skipped because Chromium's flag value is
    /// comma-separated and cannot express them.
    ///
    /// - Parameter fileManager: Filesystem used for validation.
    /// - Returns: Existing extension directories in configured order.
    public func chromiumExtensionDirectories(
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let rawValue = defaults.string(forKey: Self.chromiumExtensionDirectoriesKey),
              !rawValue.isEmpty else {
            return []
        }
        var seen = Set<String>()
        var directories: [URL] = []
        for line in rawValue.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.contains(",") else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { continue }
            let directory = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            guard seen.insert(directory.path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(
                    atPath: directory.appendingPathComponent("manifest.json").path
                  ) else {
                continue
            }
            directories.append(directory)
        }
        return directories
    }

    /// Returns a validated loopback remote-debugging configuration.
    ///
    /// - Returns: The persisted port, or disabled when the stored value is invalid.
    public func remoteDebuggingPort() -> ChromiumRemoteDebuggingPort {
        guard let number = defaults.object(forKey: Self.remoteDebuggingPortKey) as? NSNumber else {
            return Self.defaultRemoteDebuggingPort
        }
        return ChromiumRemoteDebuggingPort(rawValue: number.intValue) ?? Self.defaultRemoteDebuggingPort
    }

    /// Persists a validated loopback remote-debugging configuration.
    ///
    /// - Parameter port: The port value to persist, including zero to disable it.
    public func setRemoteDebuggingPort(_ port: ChromiumRemoteDebuggingPort) {
        defaults.set(port.rawValue, forKey: Self.remoteDebuggingPortKey)
    }
}
