import Foundation

nonisolated enum GhosttyCrashBreadcrumb {
    struct PendingCrash: Equatable, Sendable {
        let fileURL: URL
        let modifiedAt: Date
    }

    static let lastCleanExitDefaultsKey = "ghosttyCrashBreadcrumb.lastCleanExitAt"
    static let lastShownCrashDefaultsKey = "ghosttyCrashBreadcrumb.lastShownCrashAt"
    static let notificationTabId = UUID(uuidString: "00000000-0000-0000-0000-000000003873")!

    nonisolated static var defaultCrashDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
    }

    @Sendable
    nonisolated static func pendingCrashFromDefaultStorage() async -> PendingCrash? {
        await Task.detached(priority: .utility) {
            pendingCrash()
        }.value
    }

    nonisolated static func pendingCrash(
        in crashDirectoryURL: URL = defaultCrashDirectoryURL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        currentExecutableURL: URL? = Bundle.main.executableURL
    ) -> PendingCrash? {
        guard let latest = latestCrashFile(
            in: crashDirectoryURL,
            fileManager: fileManager,
            currentExecutableURL: currentExecutableURL
        ) else {
            return nil
        }

        let lastCleanExit = defaults.object(forKey: lastCleanExitDefaultsKey) as? Date ?? .distantPast
        let lastShownCrash = defaults.object(forKey: lastShownCrashDefaultsKey) as? Date ?? .distantPast
        guard latest.modifiedAt > lastCleanExit, latest.modifiedAt > lastShownCrash else {
            return nil
        }
        return latest
    }

    nonisolated static func markShown(_ pendingCrash: PendingCrash, defaults: UserDefaults = .standard) {
        defaults.set(pendingCrash.modifiedAt, forKey: lastShownCrashDefaultsKey)
    }

    nonisolated static func markCleanExit(defaults: UserDefaults = .standard, date: Date = Date()) {
        defaults.set(date, forKey: lastCleanExitDefaultsKey)
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

    private static func crashReportMatchesCurrentExecutable(_ url: URL, currentExecutableURL: URL?) -> Bool {
        guard let currentExecutableURL else { return true }
        guard let reportedExecutablePaths = GhosttyCrashReportMetadata.reportedExecutablePaths(in: url) else { return true }
        let currentExecutablePath = GhosttyCrashReportMetadata.normalizedPath(currentExecutableURL.path)
        return reportedExecutablePaths.contains(currentExecutablePath)
    }
}
