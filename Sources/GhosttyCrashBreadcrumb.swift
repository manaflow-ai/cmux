import Foundation

nonisolated enum GhosttyCrashBreadcrumb {
    struct PendingCrash: Equatable, Sendable {
        let fileURL: URL
        let modifiedAt: Date
    }

    static let lastCleanExitDefaultsKey = "ghosttyCrashBreadcrumb.lastCleanExitAt"
    static let lastShownCrashDefaultsKey = "ghosttyCrashBreadcrumb.lastShownCrashAt"
    static let notificationTabId = UUID(uuidString: "00000000-0000-0000-0000-000000003873")!

    static var defaultCrashDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
    }

    @Sendable
    nonisolated static func pendingCrashFromDefaultStorage() async -> PendingCrash? {
        await Task.detached(priority: .utility) {
            pendingCrash()
        }.value
    }

    static func pendingCrash(
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

    static func markShown(_ pendingCrash: PendingCrash, defaults: UserDefaults = .standard) {
        defaults.set(pendingCrash.modifiedAt, forKey: lastShownCrashDefaultsKey)
    }

    static func markCleanExit(defaults: UserDefaults = .standard, date: Date = Date()) {
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
        guard let reportedExecutablePaths = reportedExecutablePaths(in: url) else { return true }
        let currentExecutablePath = normalizedPath(currentExecutableURL.path)
        return reportedExecutablePaths.contains(currentExecutablePath)
    }

    private static func reportedExecutablePaths(in url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let event = sentryEvent(from: data),
              let debugMeta = event["debug_meta"] as? [String: Any],
              let images = debugMeta["images"] as? [[String: Any]]
        else {
            return nil
        }

        let paths = images.compactMap { image -> String? in
            guard let codeFile = image["code_file"] as? String else { return nil }
            let trimmedPath = codeFile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { return nil }
            return normalizedPath(trimmedPath)
        }
        return paths.isEmpty ? nil : Set(paths)
    }

    private static func sentryEvent(from data: Data) -> [String: Any]? {
        guard let envelopeHeaderRange = lineRange(after: data.startIndex, in: data) else {
            return nil
        }
        let itemHeaderStart = data.index(after: envelopeHeaderRange.upperBound)
        guard let itemHeaderRange = lineRange(after: itemHeaderStart, in: data),
              let itemHeader = jsonObject(in: itemHeaderRange, from: data),
              itemHeader["type"] as? String == "event"
        else {
            return nil
        }

        let payloadStart = data.index(after: itemHeaderRange.upperBound)
        if let length = itemHeader["length"] as? Int {
            guard length >= 0,
                  let payloadEnd = data.index(payloadStart, offsetBy: length, limitedBy: data.endIndex)
            else {
                return nil
            }
            return jsonObject(in: payloadStart..<payloadEnd, from: data)
        }

        guard let payloadRange = lineRange(after: payloadStart, in: data) else {
            return nil
        }
        return jsonObject(in: payloadRange, from: data)
    }

    private static func lineRange(after startIndex: Data.Index, in data: Data) -> Range<Data.Index>? {
        guard startIndex < data.endIndex,
              let newlineIndex = data[startIndex...].firstIndex(of: 0x0A)
        else {
            return nil
        }
        return startIndex..<newlineIndex
    }

    private static func jsonObject(in range: Range<Data.Index>, from data: Data) -> [String: Any]? {
        guard range.lowerBound <= range.upperBound else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data.subdata(in: range)) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
