import Foundation

enum GhosttyCrashBreadcrumb {
    struct PendingCrash: Equatable, Sendable {
        let fileURL: URL
        let modifiedAt: Date
    }

    static let lastCleanExitDefaultsKey = "ghosttyCrashBreadcrumb.lastCleanExitAt"
    static let lastShownCrashDefaultsKey = "ghosttyCrashBreadcrumb.lastShownCrashAt"
    static let notificationTabId = UUID(uuidString: "00000000-0000-0000-0000-000000003873")!

    private static let sessionLifecycleDirectoryName = "lifecycle"
    private static let sessionLaunchSentinelFileName = "running.sentinel"
    private static let fallbackBundleIdentifier = "com.cmuxterm.app"

    nonisolated static var defaultCrashDirectoryURL: URL {
        SessionPersistencePolicy.defaultCmuxCrashDirectoryURL()
    }

    nonisolated static var defaultCrashDirectoryURLs: [URL] {
        SessionPersistencePolicy.cmuxCrashDirectoryURLs()
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func pendingCrashFromDefaultStorage() async -> PendingCrash? {
        await Task.detached(priority: .utility) {
            pendingCrash(in: defaultCrashDirectoryURLs)
        }.value
    }

    nonisolated static func pendingCrash(
        in crashDirectoryURL: URL = defaultCrashDirectoryURL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        currentExecutableURL: URL? = Bundle.main.executableURL
    ) -> PendingCrash? {
        pendingCrash(
            in: [crashDirectoryURL],
            defaults: defaults,
            fileManager: fileManager,
            currentExecutableURL: currentExecutableURL
        )
    }

    nonisolated static func pendingCrash(
        in crashDirectoryURLs: [URL],
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        currentExecutableURL: URL? = Bundle.main.executableURL
    ) -> PendingCrash? {
        let latest = crashDirectoryURLs.compactMap {
            latestCrashFile(
                in: $0,
                fileManager: fileManager,
                currentExecutableURL: currentExecutableURL
            )
        }
        .max { lhs, rhs in lhs.modifiedAt < rhs.modifiedAt }
        guard let latest else {
            return nil
        }

        let lastCleanExit = defaults.object(forKey: lastCleanExitDefaultsKey) as? Date ?? .distantPast
        let lastShownCrash = defaults.object(forKey: lastShownCrashDefaultsKey) as? Date ?? .distantPast
        guard latest.modifiedAt > lastCleanExit, latest.modifiedAt > lastShownCrash else {
            return nil
        }
        return latest
    }

    private static func latestCrashFile(
        in crashDirectoryURL: URL,
        fileManager: FileManager,
        currentExecutableURL: URL?
    ) -> PendingCrash? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: crashDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter { $0.pathExtension == "ghosttycrash" }
            .filter { crashReportMatchesCurrentExecutable($0, currentExecutableURL: currentExecutableURL) }
            .compactMap { url -> PendingCrash? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modifiedAt = values.contentModificationDate else {
                    return nil
                }
                return PendingCrash(fileURL: url, modifiedAt: modifiedAt)
            }
            .max { lhs, rhs in lhs.modifiedAt < rhs.modifiedAt }
    }

    nonisolated static func markShown(_ pendingCrash: PendingCrash, defaults: UserDefaults = .standard) {
        defaults.set(pendingCrash.modifiedAt, forKey: lastShownCrashDefaultsKey)
    }

    nonisolated static func markCleanExit(defaults: UserDefaults = .standard, date: Date = Date()) {
        defaults.set(date, forKey: lastCleanExitDefaultsKey)
    }

    /// Captures whether the previous app process reached its clean-shutdown
    /// tail, then arms a sentinel for the current process. The read must happen
    /// before the sentinel is written; callers use the returned value to decide
    /// whether a missing primary session snapshot may recover its backup.
    nonisolated static func captureSessionLaunchState(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let wasUnclean = priorSessionLaunchWasUnclean(
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            environment: environment
        )
        markSessionLaunchRunning(
            fileManager: fileManager,
            homeDirectory: homeDirectory,
            environment: environment
        )
        return wasUnclean
    }

    /// Returns true when a prior process left its launch sentinel behind. The
    /// sentinel is scoped by bundle identifier so tagged development builds do
    /// not classify one another's exits as crashes.
    nonisolated static func priorSessionLaunchWasUnclean(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let url = sessionLaunchSentinelURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Marks this process as running. Failure is deliberately ignored: launch
    /// must continue even when the state directory is unavailable.
    nonisolated static func markSessionLaunchRunning(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = sessionLaunchSentinelURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            guard let data = "pid=\(ProcessInfo.processInfo.processIdentifier)\n".data(using: .utf8) else {
                return
            }
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort. An unwritable state directory simply means the next
            // launch cannot classify this run and falls back conservatively.
        }
    }

    /// Removes the current process sentinel after all clean-termination work
    /// has completed. A teardown crash therefore remains classified as unclean.
    nonisolated static func markSessionCleanExit(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = sessionLaunchSentinelURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            // Never block termination on sentinel cleanup.
        }
    }

    /// Returns the per-bundle sentinel location. Exposed internally for
    /// deterministic lifecycle tests; production callers use the methods above.
    nonisolated static func sessionLaunchSentinelURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let stateRoot: URL
        if let xdgStateHome = environment["XDG_STATE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgStateHome.isEmpty {
            stateRoot = URL(
                fileURLWithPath: (xdgStateHome as NSString).expandingTildeInPath,
                isDirectory: true
            )
            .appendingPathComponent("cmux", isDirectory: true)
        } else {
            stateRoot = homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent("cmux", isDirectory: true)
        }

        return stateRoot
            .appendingPathComponent(sessionLifecycleDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionLifecycleScope(environment: environment), isDirectory: true)
            .appendingPathComponent(sessionLaunchSentinelFileName, isDirectory: false)
    }

    private static func sessionLifecycleScope(environment: [String: String]) -> String {
        let rawBundleIdentifier = environment["CMUX_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier
            ?? fallbackBundleIdentifier
        let trimmedBundleIdentifier = rawBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedBundleIdentifier.isEmpty ? fallbackBundleIdentifier : trimmedBundleIdentifier
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let replacement = UnicodeScalar("_")
        let scalars = source.unicodeScalars.map { allowed.contains($0) ? $0 : replacement }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return sanitized.isEmpty ? fallbackBundleIdentifier : sanitized
    }

    private static func crashReportMatchesCurrentExecutable(_ url: URL, currentExecutableURL: URL?) -> Bool {
        guard let currentExecutableURL else { return true }
        guard let reportedExecutablePaths = GhosttyCrashReportMetadata.reportedExecutablePaths(in: url) else { return true }
        let currentExecutablePath = GhosttyCrashReportMetadata.normalizedPath(currentExecutableURL.path)
        return reportedExecutablePaths.contains(currentExecutablePath)
    }
}
