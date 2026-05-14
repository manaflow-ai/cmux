import Foundation

enum CodexTranscriptPathResolver {
    static func findTranscriptPath(sessionId: String, codexHome: String?) -> String? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }
        let codexHome = CodexTranscriptMonitorParser.normalizedValue(codexHome) ?? "~/.codex"
        let sessionsURL = URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let fileManager = FileManager.default
        var newest: URL?
        var newestModificationDate: Date?
        for directoryURL in recentSessionDirectories(sessionsURL: sessionsURL, fileManager: fileManager) {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in urls {
                guard url.pathExtension == "jsonl",
                      url.lastPathComponent.contains(normalizedSessionId) else {
                    continue
                }
                let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newest == nil || modificationDate > (newestModificationDate ?? .distantPast) {
                    newest = url
                    newestModificationDate = modificationDate
                }
            }
        }
        return newest?.path
    }

    private static func recentSessionDirectories(sessionsURL: URL, fileManager: FileManager) -> [URL] {
        var directories: [URL] = []
        var seenPaths = Set<String>()

        func appendIfDirectory(_ url: URL) {
            guard seenPaths.insert(url.path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            directories.append(url)
        }

        appendIfDirectory(sessionsURL)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        for calendar in [Calendar.current, utcCalendar] {
            for dayOffset in -14...1 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: Date.now) else { continue }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day else {
                    continue
                }
                appendIfDirectory(
                    sessionsURL
                        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
                )
            }
        }
        return directories
    }
}
