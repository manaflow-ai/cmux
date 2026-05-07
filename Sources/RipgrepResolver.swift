import Foundation
import os

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

// `nonisolated` is required for file-scoped state under MainActor-by-default
// isolation (project rule `.github/review-bot-rules/swift-logging.md`); without
// it, `RipgrepResolver.resolve()` — which is nonisolated — would cross the
// actor boundary on every read.
nonisolated private let ripgrepResolverLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "RipgrepResolver"
)

/// Per-process dedupe so a stuck-misconfigured `automation.ripgrepBinaryPath`
/// can't spam unified logging once per Find keystroke. Each unique invalid
/// path is logged at most once per process launch.
private final class InvalidPathLogTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var loggedPaths: Set<String> = []

    func recordIfFirstSeen(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loggedPaths.insert(path).inserted
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        loggedPaths.removeAll()
    }
}

nonisolated private let ripgrepInvalidPathTracker = InvalidPathLogTracker()

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

    static func resolve(
        customPath: String? = RipgrepIntegrationSettings.customRipgrepPath(),
        commonPaths: [String] = RipgrepResolver.defaultCommonPaths(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let customPath {
            if isExecutableRegularFile(atPath: customPath, fileManager: fileManager) {
                return customPath
            }
            // Configured-but-not-executable falls through to the common paths
            // so a stale/typo'd setting doesn't completely disable Find when a
            // valid binary still exists in a default location.
            if ripgrepInvalidPathTracker.recordIfFirstSeen(customPath) {
                ripgrepResolverLogger.warning(
                    "automation.ripgrepBinaryPath '\(customPath, privacy: .public)' is not executable; falling back to common locations"
                )
            }
        }
        for path in commonPaths where isExecutableRegularFile(atPath: path, fileManager: fileManager) {
            return path
        }
        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = String(directory) + "/rg"
                if isExecutableRegularFile(atPath: candidate, fileManager: fileManager) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// `FileManager.isExecutableFile(atPath:)` returns true for directories with
    /// the search/execute bit set (it's `access(X_OK)` under the hood). A user
    /// could plausibly point `automation.ripgrepBinaryPath` at a directory named
    /// `rg/`, or have one of the common locations expand to a directory in some
    /// future install layout. Filter those out so the resolver returns only real
    /// executable files.
    private static func isExecutableRegularFile(
        atPath path: String,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    /// Reset the dedupe tracker. Tests use this to assert per-call logging
    /// behavior; production callers don't need it.
    static func resetInvalidPathLogTrackerForTesting() {
        ripgrepInvalidPathTracker.reset()
    }
}
