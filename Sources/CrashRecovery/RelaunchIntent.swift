import Foundation

/// Records that the app is relaunching *intentionally* (a Sparkle update or the
/// Rosetta native relaunch) and that the next launch should restore the prior
/// session — distinct from a crash.
///
/// An intentional relaunch writes this marker AND clears the unclean-shutdown
/// sentinel (`UncleanShutdownSentinel.markCleanExit`). On the next launch the
/// marker is consumed exactly once:
///   - it suppresses the crash offer (the relaunch was deliberate, not a crash);
///   - it signals that window restore must happen even if launch heuristics would
///     otherwise skip it — the "I clicked Update, don't lose my windows" guarantee.
///
/// Single-use: `consumeRestoreIntent()` reads and deletes the marker so a later
/// real crash is still classified as unclean. All filesystem operations fail safe
/// (a missing/unwritable marker simply means "not an intentional relaunch").
enum RelaunchIntent {
    private static let markerFileName = "restore-intended.marker"

    static func markerURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        UncleanShutdownSentinel.lifecycleDirectoryURL(homeDirectory: homeDirectory, environment: environment)
            .appendingPathComponent(markerFileName, isDirectory: false)
    }

    /// Marks the imminent relaunch as intentional + restore-intended. Call this
    /// from the relaunch hook *together with* `UncleanShutdownSentinel.markCleanExit`.
    static func markRestoreIntended(
        reason: String = "relaunch",
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = markerURL(homeDirectory: homeDirectory, environment: environment)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "reason=\(reason)\n".data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            // Best-effort: without the marker the next launch just treats the
            // relaunch as an ordinary cold start (windows still restore via the
            // normal reopen path; only the explicit guarantee is lost).
        }
    }

    /// Returns whether the prior exit set restore-intent, and clears the marker so
    /// the next launch starts fresh. Must be called once, early in launch.
    static func consumeRestoreIntent(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let url = markerURL(homeDirectory: homeDirectory, environment: environment)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}
