import Foundation

/// Scans local Claude Code and Codex transcript directories and aggregates
/// token usage. Safe to run off the main actor; performs file I/O only.
struct AgentUsageScanner: Sendable {
    /// Claude Code transcript roots (`~/.claude/projects`, `~/.config/claude/projects`).
    var claudeRoots: [URL]
    /// Codex CLI rollout roots (`~/.codex/sessions`).
    var codexRoots: [URL]
    /// Trailing window, in days, that the snapshot covers.
    var windowDays: Int

    /// Files larger than this are skipped to keep refreshes bounded.
    private static let maxFileSizeBytes = 64 * 1024 * 1024

    /// Creates a scanner rooted at `homeDirectory` (the real home by default).
    init(homeDirectory: URL? = nil, windowDays: Int = 30) {
        let home = homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
        self.claudeRoots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
        self.codexRoots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
        ]
        self.windowDays = windowDays
    }

    /// Reads every recent transcript file under the configured roots, parses
    /// usage events, and aggregates them into a dashboard snapshot.
    func scan(now: Date = Date(), calendar: Calendar = .current) -> AgentUsageSnapshot {
        // Transcript files can be appended to after creation, so use the
        // modification date (with one extra day of slack) as the freshness gate.
        let startOfToday = calendar.startOfDay(for: now)
        let modificationCutoff = calendar.date(byAdding: .day, value: -(windowDays + 1), to: startOfToday) ?? now

        var events: [AgentUsageEvent] = []
        var scannedFileCount = 0
        var seenClaudeRequestKeys: Set<String> = []
        var latestCodexRateLimits: CodexRateLimitsObservation?

        for root in claudeRoots {
            for fileURL in jsonlFiles(under: root, modifiedAfter: modificationCutoff) {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                scannedFileCount += 1
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    if let event = AgentUsageLogParser.parseClaudeLine(String(line), seenRequestKeys: &seenClaudeRequestKeys) {
                        events.append(event)
                    }
                }
            }
        }

        for root in codexRoots {
            for fileURL in jsonlFiles(under: root, modifiedAfter: modificationCutoff) {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                scannedFileCount += 1
                let result = AgentUsageLogParser.parseCodexSession(
                    lines: content.split(separator: "\n", omittingEmptySubsequences: true)
                )
                events.append(contentsOf: result.events)
                if let observation = result.rateLimits,
                   latestCodexRateLimits.map({ $0.observedAt <= observation.observedAt }) ?? true {
                    latestCodexRateLimits = observation
                }
            }
        }

        return AgentUsageAggregator.aggregate(
            events: events,
            codexRateLimits: latestCodexRateLimits,
            calendar: calendar,
            now: now,
            windowDays: windowDays,
            scannedFileCount: scannedFileCount
        )
    }

    /// Lists `.jsonl` files under `root` that were modified after `cutoff`,
    /// skipping oversized files.
    private func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            if let modified = values.contentModificationDate, modified < cutoff { continue }
            if let size = values.fileSize, size > Self.maxFileSizeBytes { continue }
            files.append(fileURL)
        }
        return files
    }
}
