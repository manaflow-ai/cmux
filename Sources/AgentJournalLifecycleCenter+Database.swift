import Foundation

extension AgentJournalLifecycleCenter {
    /// Resolves the app-specific journal location without opening the store.
    static func defaultDatabaseURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        if let override = ProcessInfo.processInfo.environment["CMUX_AGENT_JOURNAL_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard !isRunningUnderAutomatedTests else { return nil }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleID = bundleID?.isEmpty == false ? bundleID! : "com.cmuxterm.app"
        let safeBundleID = resolvedBundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-journal-\(safeBundleID).sqlite3", isDirectory: false)
    }
}
