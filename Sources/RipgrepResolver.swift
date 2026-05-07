import Foundation

/// Mirrors `ClaudeCodeIntegrationSettings.customClaudePath` for `rg`. Lets users
/// on Nix / asdf / non-standard installs point cmux at their ripgrep directly,
/// because Dock-launched macOS apps snapshot env at Dock-start time and don't
/// reliably inherit `launchctl setenv PATH` (issue #3657).
enum RipgrepIntegrationSettings {
    static let customRipgrepPathKey = "ripgrepBinaryPath"

    static func customRipgrepPath(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: customRipgrepPathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// Resolves the absolute path to `rg`, honoring `automation.ripgrepBinaryPath`
/// first, then a fallback list of common install locations, then `$PATH`.
/// Re-evaluated on every call so a settings change takes effect without an
/// app restart.
enum RipgrepResolver {
    /// Order matters: Homebrew/MacPorts/system precedence is preserved (existing
    /// behavior), then Nix-darwin profile paths added for #3657. Touching this
    /// order changes which `rg` users with multiple installs end up running.
    static func defaultCommonPaths(userName: String = NSUserName()) -> [String] {
        return [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
            "/opt/local/bin/rg",
            "/etc/profiles/per-user/\(userName)/bin/rg",
            "/run/current-system/sw/bin/rg",
            "/nix/var/nix/profiles/default/bin/rg",
        ]
    }

    /// Resolve the rg binary, or `nil` if none is found.
    ///
    /// - Parameters:
    ///   - customPath: Override for `automation.ripgrepBinaryPath`. Defaults to
    ///     the value persisted in standard `UserDefaults`. Pass `nil` explicitly
    ///     to bypass the setting (used by tests).
    ///   - commonPaths: Override for the hardcoded fallback list (used by tests).
    ///   - environment: Override for the process environment (used by tests).
    ///   - fileManager: Override for the file manager (used by tests).
    static func resolve(
        customPath: String? = RipgrepIntegrationSettings.customRipgrepPath(),
        commonPaths: [String] = RipgrepResolver.defaultCommonPaths(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let customPath {
            if fileManager.isExecutableFile(atPath: customPath) {
                return customPath
            }
            // Configured but not executable. Log and fall through to the
            // common paths so a stale/typo'd setting doesn't completely
            // disable Find when a valid binary still exists in a default
            // location.
            NSLog(
                "[RipgrepResolver] automation.ripgrepBinaryPath '%@' is not executable; falling back to common locations",
                customPath
            )
        }
        for path in commonPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = String(directory) + "/rg"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}
