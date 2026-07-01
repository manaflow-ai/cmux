import Foundation

/// Result of reading one source's files during a scan.
struct AgentUsageCollectionResult: Sendable {
    /// Usage events parsed from the source's files.
    var events: [AgentUsageEvent] = []
    /// Newest Codex rate-limit observation, when the source reports one.
    var codexRateLimits: CodexRateLimitsObservation? = nil
}

/// Accumulates usage from a single source's files during one scan. Created
/// fresh per scan and used on one thread, so it need not be `Sendable`.
protocol AgentUsageFileCollector: AnyObject {
    /// Feeds one file's full contents into the collector.
    func ingest(fileContents: String)
    /// Returns everything collected after all files have been ingested.
    func finish() -> AgentUsageCollectionResult
}

/// A locally-installed agent whose usage is read from transcript files on disk.
/// Conform a new type and add it to `AgentUsageScanner.defaultSources` to make
/// the dashboard cover another tool — no other code needs to change.
protocol AgentUsageLocalSource: Sendable {
    /// The source identity used throughout the dashboard.
    var source: AgentUsageSource { get }
    /// Directories to scan, derived from the user's home directory.
    func roots(forHome home: URL) -> [URL]
    /// File extension this source's transcripts use (without the dot).
    var fileExtension: String { get }
    /// Builds a fresh accumulator for one scan.
    func makeCollector() -> AgentUsageFileCollector
}

// MARK: - Claude Code

/// Claude Code transcripts: append-only JSONL under `~/.claude/projects`.
struct ClaudeCodeLocalSource: AgentUsageLocalSource {
    var source: AgentUsageSource { .claudeCode }
    var fileExtension: String { "jsonl" }

    func roots(forHome home: URL) -> [URL] {
        [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
    }

    func makeCollector() -> AgentUsageFileCollector { Collector() }

    /// Deduplicates assistant messages replayed across continued/forked
    /// transcripts, keyed by message id + request id.
    private final class Collector: AgentUsageFileCollector {
        private var events: [AgentUsageEvent] = []
        private var seenRequestKeys: Set<String> = []

        func ingest(fileContents: String) {
            for line in fileContents.split(separator: "\n", omittingEmptySubsequences: true) {
                if let event = AgentUsageLogParser.parseClaudeLine(String(line), seenRequestKeys: &seenRequestKeys) {
                    events.append(event)
                }
            }
        }

        func finish() -> AgentUsageCollectionResult {
            AgentUsageCollectionResult(events: events)
        }
    }
}

// MARK: - Codex

/// Codex CLI rollout sessions: JSONL under `~/.codex/sessions`, also carrying
/// provider-reported rate-limit state.
struct CodexLocalSource: AgentUsageLocalSource {
    var source: AgentUsageSource { .codex }
    var fileExtension: String { "jsonl" }

    func roots(forHome home: URL) -> [URL] {
        [home.appendingPathComponent(".codex/sessions", isDirectory: true)]
    }

    func makeCollector() -> AgentUsageFileCollector { Collector() }

    private final class Collector: AgentUsageFileCollector {
        private var events: [AgentUsageEvent] = []
        private var latestRateLimits: CodexRateLimitsObservation?

        func ingest(fileContents: String) {
            let result = AgentUsageLogParser.parseCodexSession(
                lines: fileContents.split(separator: "\n", omittingEmptySubsequences: true)
            )
            events.append(contentsOf: result.events)
            if let observation = result.rateLimits,
               latestRateLimits.map({ $0.observedAt <= observation.observedAt }) ?? true {
                latestRateLimits = observation
            }
        }

        func finish() -> AgentUsageCollectionResult {
            AgentUsageCollectionResult(events: events, codexRateLimits: latestRateLimits)
        }
    }
}

// MARK: - OpenCode

/// OpenCode sessions: one JSON file per message under
/// `~/.local/share/opencode/storage/message`. `OPENCODE_DATA_DIR` may relocate
/// the data directory (comma-separated list); both it and the default are scanned.
struct OpenCodeLocalSource: AgentUsageLocalSource {
    var source: AgentUsageSource { .openCode }
    var fileExtension: String { "json" }

    func roots(forHome home: URL) -> [URL] {
        var dataDirs: [URL] = []
        if let override = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"], !override.isEmpty {
            for part in override.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    dataDirs.append(URL(fileURLWithPath: trimmed, isDirectory: true))
                }
            }
        }
        dataDirs.append(home.appendingPathComponent(".local/share/opencode", isDirectory: true))
        return dataDirs.map { $0.appendingPathComponent("storage/message", isDirectory: true) }
    }

    func makeCollector() -> AgentUsageFileCollector { Collector() }

    private final class Collector: AgentUsageFileCollector {
        private var events: [AgentUsageEvent] = []

        func ingest(fileContents: String) {
            if let event = AgentUsageLogParser.parseOpenCodeMessage(fileContents) {
                events.append(event)
            }
        }

        func finish() -> AgentUsageCollectionResult {
            AgentUsageCollectionResult(events: events)
        }
    }
}

/// Raw result of a local scan: parsed events plus the metadata the aggregator
/// needs. Kept separate from `AgentUsageSnapshot` so callers can merge in
/// server-reported events (e.g. OpenRouter) before aggregating.
struct RawAgentUsageScan: Sendable {
    /// Every event parsed from local transcripts.
    var events: [AgentUsageEvent]
    /// Newest Codex rate-limit observation found, if any.
    var codexRateLimits: CodexRateLimitsObservation?
    /// Number of files read during the scan.
    var scannedFileCount: Int
}

/// Scans local agent transcript directories. Safe to run off the main actor;
/// performs file I/O only. The set of sources is pluggable via `sources`.
struct AgentUsageScanner: Sendable {
    /// The user's home directory (the real home by default).
    var homeDirectory: URL
    /// Trailing window, in days, that the snapshot covers.
    var windowDays: Int
    /// The local sources this scanner reads.
    var sources: [any AgentUsageLocalSource]

    /// Files larger than this are skipped to keep refreshes bounded.
    private static let maxFileSizeBytes = 64 * 1024 * 1024

    /// The default registry of local sources. Append a new `AgentUsageLocalSource`
    /// here to add coverage for another locally-installed agent.
    static let defaultSources: [any AgentUsageLocalSource] = [
        ClaudeCodeLocalSource(),
        CodexLocalSource(),
        OpenCodeLocalSource(),
    ]

    /// Creates a scanner rooted at `homeDirectory` (the real home by default).
    init(
        homeDirectory: URL? = nil,
        windowDays: Int = 30,
        sources: [any AgentUsageLocalSource] = AgentUsageScanner.defaultSources
    ) {
        self.homeDirectory = homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
        self.windowDays = windowDays
        self.sources = sources
    }

    /// Reads every recent transcript file under the configured sources and
    /// returns the parsed events without aggregating them.
    func collectLocalUsage(now: Date = Date(), calendar: Calendar = .current) -> RawAgentUsageScan {
        // Transcript files can be appended to after creation, so use the
        // modification date (with one extra day of slack) as the freshness gate.
        let startOfToday = calendar.startOfDay(for: now)
        let modificationCutoff = calendar.date(byAdding: .day, value: -(windowDays + 1), to: startOfToday) ?? now

        var events: [AgentUsageEvent] = []
        var scannedFileCount = 0
        var codexRateLimits: CodexRateLimitsObservation?

        for source in sources {
            let collector = source.makeCollector()
            for root in source.roots(forHome: homeDirectory) {
                for fileURL in files(under: root, extension: source.fileExtension, modifiedAfter: modificationCutoff) {
                    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    scannedFileCount += 1
                    collector.ingest(fileContents: content)
                }
            }
            let result = collector.finish()
            events.append(contentsOf: result.events)
            if let observation = result.codexRateLimits {
                codexRateLimits = observation
            }
        }

        return RawAgentUsageScan(
            events: events,
            codexRateLimits: codexRateLimits,
            scannedFileCount: scannedFileCount
        )
    }

    /// Convenience: scan locally and aggregate, with no server-reported events.
    func scan(now: Date = Date(), calendar: Calendar = .current) -> AgentUsageSnapshot {
        let raw = collectLocalUsage(now: now, calendar: calendar)
        return AgentUsageAggregator.aggregate(
            events: raw.events,
            codexRateLimits: raw.codexRateLimits,
            calendar: calendar,
            now: now,
            windowDays: windowDays,
            scannedFileCount: raw.scannedFileCount
        )
    }

    /// Lists files with `fileExtension` under `root` that were modified after
    /// `cutoff`, skipping oversized files.
    private func files(under root: URL, extension fileExtension: String, modifiedAfter cutoff: Date) -> [URL] {
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
            guard fileURL.pathExtension == fileExtension else { continue }
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