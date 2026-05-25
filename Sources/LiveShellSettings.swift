import Foundation

enum LiveShellBackend: String, CaseIterable, Identifiable, Sendable {
    case direct
    case livesh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct:
            return String(
                localized: "settings.terminal.shellBackend.direct",
                defaultValue: "Direct"
            )
        case .livesh:
            return String(
                localized: "settings.terminal.shellBackend.livesh",
                defaultValue: "Live Shell (livesh)"
            )
        }
    }
}

/// User-facing setting for choosing whether new terminal panes wrap their shell in livesh
/// (a daemon-owned PTY layer that outlives cmux) or run the shell directly (current behavior).
///
/// Reads/writes UserDefaults under `LiveShellSettings.key`. Defaults to `.direct` so existing
/// users see no behavior change until they opt in.
enum LiveShellSettings {
    static let key = "terminalShellBackend"
    static let liveshExecutableKey = "terminalLiveshExecutablePath"
    static let liveshctlExecutableKey = "terminalLiveshctlExecutablePath"

    static let defaultBackend: LiveShellBackend = .direct

    static func current(defaults: UserDefaults = .standard) -> LiveShellBackend {
        guard let raw = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let backend = LiveShellBackend(rawValue: raw) else {
            return defaultBackend
        }
        return backend
    }

    static func set(_ backend: LiveShellBackend, defaults: UserDefaults = .standard) {
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
        if let override = defaults.string(forKey: liveshExecutableKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        return resolveExecutable(
            name: "livesh",
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
        if let override = defaults.string(forKey: liveshctlExecutableKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        return resolveExecutable(
            name: "liveshctl",
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

    private static func resolveExecutable(
        name: String,
        fileManager: FileManager,
        environment: [String: String],
        homeDirectory: String
    ) -> String? {
        let localBin = (homeDirectory as NSString).appendingPathComponent(".local/bin/\(name)")
        if fileManager.isExecutableFile(atPath: localBin) {
            return localBin
        }
        let pathEnv = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for segment in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(segment) as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
