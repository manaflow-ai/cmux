import Foundation

/// Detects whether the previous app run exited cleanly.
///
/// A sentinel file is written early in launch (`markRunning`) and removed on
/// every clean-exit path (`markCleanExit`). If the sentinel is still present at
/// the next launch, the prior run did **not** exit cleanly — a crash, `kill -9`,
/// panic, or power loss. This is the signal that gates the crash-recovery offer
/// (see `CrashRecoveryOfferView`).
///
/// This marker is deliberately independent of the "restore-intended" relaunch
/// marker (`RelaunchIntent`). An intentional relaunch (Sparkle update, Rosetta
/// native relaunch) calls `markCleanExit()` *and* records restore-intent, so it
/// is classified as a clean shutdown here and never triggers the crash offer.
///
/// All filesystem operations fail safe: a missing/unwritable state directory
/// degrades to "treat as clean" and never blocks launch or termination.
enum UncleanShutdownSentinel {
    private static let lifecycleDirectoryName = "lifecycle"
    private static let sentinelFileName = "running.sentinel"
    private static let fallbackLifecycleScope = "com.cmuxterm.app"

    /// The cmux state directory, mirroring `SessionPersistencePolicy` crash
    /// storage: `$XDG_STATE_HOME/cmux` when set, else `~/.local/state/cmux`.
    static func stateDirectoryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let xdgStateHome = environment["XDG_STATE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !xdgStateHome.isEmpty {
            return URL(
                fileURLWithPath: (xdgStateHome as NSString).expandingTildeInPath,
                isDirectory: true
            )
            .appendingPathComponent("cmux", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
    }

    static func lifecycleDirectoryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        stateDirectoryURL(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent(lifecycleDirectoryName, isDirectory: true)
            .appendingPathComponent(lifecycleScope(environment: environment), isDirectory: true)
    }

    static func sentinelURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        lifecycleDirectoryURL(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent(sentinelFileName, isDirectory: false)
    }

    private static func lifecycleScope(environment: [String: String]) -> String {
        let raw = environment["CMUX_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier
            ?? fallbackLifecycleScope
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallbackLifecycleScope : trimmed
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let replacement = UnicodeScalar("_")
        let scalars = source.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? scalar : replacement
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return sanitized.isEmpty ? fallbackLifecycleScope : sanitized
    }

    /// True when a sentinel from a prior run is present — i.e. the prior run did
    /// not exit cleanly. Must be read *before* `markRunning()` overwrites it.
    static func priorRunWasUnclean(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let url = sentinelURL(homeDirectory: homeDirectory, environment: environment)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    /// Records that this run is active. Safe to call repeatedly. Failures
    /// (unwritable directory, sandbox denial) are swallowed so launch proceeds.
    static func markRunning(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = sentinelURL(homeDirectory: homeDirectory, environment: environment)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let contents = "pid=\(ProcessInfo.processInfo.processIdentifier)\n"
            try contents.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            // Treat as best-effort: an unwritable state dir means the next
            // launch simply won't see a sentinel and classifies as clean.
        }
    }

    /// Records that this run is exiting cleanly. Safe to call repeatedly and
    /// safe when no sentinel exists. Failures are swallowed.
    static func markCleanExit(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = sentinelURL(homeDirectory: homeDirectory, environment: environment)
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            // Best-effort: a leftover sentinel only risks a spurious offer next
            // launch, which the user can decline; never block termination.
        }
    }
}
