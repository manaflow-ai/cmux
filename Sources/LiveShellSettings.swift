import CmuxSettings
import Foundation

/// Resolves the configured livesh backend and executable overrides for terminal creation.
enum LiveShellSettings {
    private static let terminal = TerminalCatalogSection()

    static let key = terminal.shellBackend.userDefaultsKey
    static let liveshExecutableKey = terminal.liveshExecutablePath.userDefaultsKey
    static let liveshctlExecutableKey = terminal.liveshctlExecutablePath.userDefaultsKey
    static let defaultBackend = terminal.shellBackend.defaultValue

    static func current(defaults: UserDefaults = .standard) -> TerminalShellBackend {
        guard let raw = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let backend = TerminalShellBackend(rawValue: raw) else {
            return defaultBackend
        }
        return backend
    }

    static func set(_ backend: TerminalShellBackend, defaults: UserDefaults = .standard) {
        defaults.set(backend.rawValue, forKey: key)
    }

    /// Resolved absolute path to the `livesh` binary, or nil if the binary cannot be located.
    /// Order: explicit override in defaults → `$HOME/.local/bin/livesh` → first match on PATH.
    static func resolvedLiveshExecutable(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        resolveConfiguredExecutable(
            overrideKey: liveshExecutableKey,
            name: "livesh",
            defaults: defaults,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    static func resolvedLiveshctlExecutable(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        resolveConfiguredExecutable(
            overrideKey: liveshctlExecutableKey,
            name: "liveshctl",
            defaults: defaults,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    /// Returns true when the user has selected the livesh backend AND a livesh binary is
    /// resolvable. This is the gate used by pane spawn paths to switch behavior.
    static func isAvailable(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        guard current(defaults: defaults) == .livesh else { return false }
        return resolvedLiveshExecutable(
            defaults: defaults,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        ) != nil
    }

    private static func resolveConfiguredExecutable(
        overrideKey: String,
        name: String,
        defaults: UserDefaults,
        fileManager: FileManager,
        environment: [String: String],
        homeDirectory: String
    ) -> String? {
        if let override = defaults.string(forKey: overrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }

        let searchDirectories = [
            (homeDirectory as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
        ] + (environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        var seen = Set<String>()
        for directory in searchDirectories where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
