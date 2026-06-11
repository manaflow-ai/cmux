import Foundation

/// Which local coding-agent installation a usage event came from.
enum AgentUsageSource: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        }
    }
}

struct AgentUsageTokens: Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    var total: Int { input + output + cacheRead + cacheWrite }
    var isEmpty: Bool { total == 0 }

    mutating func add(_ other: AgentUsageTokens) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }
}

/// One token-consuming request parsed from an agent transcript file.
struct AgentUsageEvent: Equatable, Sendable {
    var source: AgentUsageSource
    var timestamp: Date
    var model: String
    var tokens: AgentUsageTokens
    /// Cost recorded directly in the transcript (Claude Code `costUSD`), when present.
    var recordedCostUSD: Double?
}

/// One provider rate-limit window in the dashboard (5-hour or weekly).
/// `usedPercent` is only set when the provider reported it (Codex CLI writes
/// its real rate-limit state into rollout files); Claude Code windows are
/// estimated from local transcripts and carry tokens/cost only.
struct AgentUsageRateWindow: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case fiveHour
        case weekly
    }

    var source: AgentUsageSource
    var kind: Kind
    var tokens: AgentUsageTokens
    var costUSD: Double?
    var windowStart: Date?
    var windowEnd: Date?
    var usedPercent: Double?
    /// True when `usedPercent`/`windowEnd` come from provider-reported
    /// rate-limit data instead of local estimation.
    var isProviderReported: Bool

    var id: String { "\(source.rawValue)|\(kind.rawValue)" }
}

/// Rate-limit state reported by the Codex CLI inside `token_count` events.
struct CodexRateLimitWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsInSeconds: Int?
}

struct CodexRateLimitsObservation: Equatable, Sendable {
    var observedAt: Date
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
}

struct CodexSessionParseResult: Equatable, Sendable {
    var events: [AgentUsageEvent]
    var rateLimits: CodexRateLimitsObservation?
}

struct AgentUsageModelRollup: Equatable, Sendable, Identifiable {
    var source: AgentUsageSource
    var model: String
    var tokens: AgentUsageTokens
    var costUSD: Double?
    var requestCount: Int

    var id: String { "\(source.rawValue)|\(model)" }
}

struct AgentUsageDayRollup: Equatable, Sendable, Identifiable {
    var day: Date
    var tokens: AgentUsageTokens
    var costUSD: Double?
    var models: [AgentUsageModelRollup]

    var id: Date { day }
}

struct AgentUsageSnapshot: Equatable, Sendable {
    var generatedAt: Date
    /// Newest day first.
    var days: [AgentUsageDayRollup]
    var modelTotals: [AgentUsageModelRollup]
    var totals: AgentUsageTokens
    var totalCostUSD: Double?
    var sourcesFound: Set<AgentUsageSource>
    var scannedFileCount: Int
    var rateWindows: [AgentUsageRateWindow] = []

    static let empty = AgentUsageSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        days: [],
        modelTotals: [],
        totals: AgentUsageTokens(),
        totalCostUSD: nil,
        sourcesFound: [],
        scannedFileCount: 0
    )
}

/// Published per-MTok prices for the models most commonly seen in local
/// Claude Code / Codex transcripts. Matching is by substring so dated model
/// IDs (e.g. `claude-sonnet-4-20250514`) resolve without an exact table hit.
/// Unknown models yield no estimate rather than a wrong one.
struct AgentUsagePricing: Equatable, Sendable {
    var inputPerMTok: Double
    var outputPerMTok: Double
    var cacheReadPerMTok: Double
    var cacheWritePerMTok: Double

    func cost(for tokens: AgentUsageTokens) -> Double {
        let mTok = 1_000_000.0
        return (Double(tokens.input) * inputPerMTok
            + Double(tokens.output) * outputPerMTok
            + Double(tokens.cacheRead) * cacheReadPerMTok
            + Double(tokens.cacheWrite) * cacheWritePerMTok) / mTok
    }

    static func pricing(forModel model: String) -> AgentUsagePricing? {
        let normalized = model.lowercased()
        if normalized.contains("opus") {
            return AgentUsagePricing(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.5, cacheWritePerMTok: 18.75)
        }
        if normalized.contains("sonnet") {
            return AgentUsagePricing(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
        }
        if normalized.contains("haiku") {
            return AgentUsagePricing(inputPerMTok: 1, outputPerMTok: 5, cacheReadPerMTok: 0.1, cacheWritePerMTok: 1.25)
        }
        if normalized.contains("gpt-5") || normalized.contains("codex") {
            return AgentUsagePricing(inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125, cacheWritePerMTok: 0)
        }
        return nil
    }

    static func estimatedCost(for event: AgentUsageEvent) -> Double? {
        if let recorded = event.recordedCostUSD {
            return recorded
        }
        return pricing(forModel: event.model)?.cost(for: event.tokens)
    }
}

enum AgentUsageLogParser {
    private nonisolated(unsafe) static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainISO8601 = ISO8601DateFormatter()

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractionalISO8601.date(from: raw) ?? plainISO8601.date(from: raw)
    }

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let number as NSNumber:
            return number.intValue
        case let value as Int:
            return value
        default:
            return 0
        }
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

    /// Parses one Claude Code transcript line. `seenRequestKeys` deduplicates
    /// the same assistant message replayed across multiple transcript files
    /// (continued/forked sessions), keyed by message id + request id.
    static func parseClaudeLine(_ line: String, seenRequestKeys: inout Set<String>) -> AgentUsageEvent? {
        guard let object = jsonObject(line),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        let tokens = AgentUsageTokens(
            input: intValue(usage["input_tokens"]),
            output: intValue(usage["output_tokens"]),
            cacheRead: intValue(usage["cache_read_input_tokens"]),
            cacheWrite: intValue(usage["cache_creation_input_tokens"])
        )
        guard !tokens.isEmpty else { return nil }
        guard let timestamp = parseTimestamp(object["timestamp"] as? String) else { return nil }

        let model = (message["model"] as? String) ?? ""
        if model == "<synthetic>" { return nil }

        if let messageId = message["id"] as? String,
           let requestId = object["requestId"] as? String {
            let key = "\(messageId):\(requestId)"
            guard seenRequestKeys.insert(key).inserted else { return nil }
        }

        return AgentUsageEvent(
            source: .claudeCode,
            timestamp: timestamp,
            model: model.isEmpty ? "claude" : model,
            tokens: tokens,
            recordedCostUSD: (object["costUSD"] as? NSNumber)?.doubleValue
        )
    }

    // MARK: - Codex (~/.codex/sessions/**/*.jsonl)

    /// Parses one Codex CLI rollout file. `token_count` events carry cumulative
    /// `total_token_usage` for the session plus `last_token_usage` for the most
    /// recent request; the per-request delta is attributed to the model from the
    /// preceding `turn_context` line. Events also carry the CLI's reported
    /// `rate_limits` state (primary ≈ 5-hour window, secondary ≈ weekly); the
    /// newest observation in the file is returned alongside the events.
    static func parseCodexSession<Lines: Sequence>(lines: Lines) -> CodexSessionParseResult where Lines.Element: StringProtocol {
        var events: [AgentUsageEvent] = []
        var currentModel = "codex"
        var previousTotal: AgentUsageTokens?
        var latestRateLimits: CodexRateLimitsObservation?

        for line in lines {
            guard let object = jsonObject(String(line)),
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            if type == "turn_context" {
                if let model = payload["model"] as? String, !model.isEmpty {
                    currentModel = model
                }
                continue
            }

            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let timestamp = parseTimestamp(object["timestamp"] as? String) else {
                continue
            }

            if let rateLimits = payload["rate_limits"] as? [String: Any] {
                let observation = CodexRateLimitsObservation(
                    observedAt: timestamp,
                    primary: codexRateLimitWindow(rateLimits["primary"]),
                    secondary: codexRateLimitWindow(rateLimits["secondary"])
                )
                if observation.primary != nil || observation.secondary != nil,
                   latestRateLimits.map({ $0.observedAt <= timestamp }) ?? true {
                    latestRateLimits = observation
                }
            }

            guard let info = payload["info"] as? [String: Any] else { continue }

            let total = (info["total_token_usage"] as? [String: Any]).map(codexTokens)
            var delta: AgentUsageTokens?
            if let last = info["last_token_usage"] as? [String: Any] {
                delta = codexTokens(last)
            } else if let total {
                var difference = total
                if let previousTotal {
                    difference.input = max(0, total.input - previousTotal.input)
                    difference.output = max(0, total.output - previousTotal.output)
                    difference.cacheRead = max(0, total.cacheRead - previousTotal.cacheRead)
                    difference.cacheWrite = max(0, total.cacheWrite - previousTotal.cacheWrite)
                }
                delta = difference
            }
            if let total {
                previousTotal = total
            }

            guard let delta, !delta.isEmpty else { continue }
            events.append(
                AgentUsageEvent(
                    source: .codex,
                    timestamp: timestamp,
                    model: currentModel,
                    tokens: delta,
                    recordedCostUSD: nil
                )
            )
        }

        return CodexSessionParseResult(events: events, rateLimits: latestRateLimits)
    }

    private static func codexRateLimitWindow(_ any: Any?) -> CodexRateLimitWindow? {
        guard let window = any as? [String: Any],
              let usedPercent = (window["used_percent"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: (window["window_minutes"] as? NSNumber)?.intValue,
            resetsInSeconds: (window["resets_in_seconds"] as? NSNumber)?.intValue
        )
    }

    private static func codexTokens(_ usage: [String: Any]) -> AgentUsageTokens {
        let cached = intValue(usage["cached_input_tokens"])
        let input = intValue(usage["input_tokens"])
        return AgentUsageTokens(
            input: max(0, input - cached),
            output: intValue(usage["output_tokens"]),
            cacheRead: cached,
            cacheWrite: 0
        )
    }
}

enum AgentUsageAggregator {
    /// Length of the provider session window (Claude Code and Codex both use
    /// rolling ~5-hour windows).
    static let sessionWindowDuration: TimeInterval = 5 * 60 * 60

    /// Reconstructs the currently active 5-hour billing window for a source
    /// from transcript timestamps: a window opens at the first request (floored
    /// to the hour) and closes 5 hours later; a request after that opens a new
    /// window. Returns nil when no window is active at `now`.
    static func currentFiveHourWindow(
        events: [AgentUsageEvent],
        source: AgentUsageSource,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> AgentUsageRateWindow? {
        let sourceEvents = events
            .filter { $0.source == source && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        guard !sourceEvents.isEmpty else { return nil }

        var blockStart: Date?
        var blockEnd = Date.distantPast
        var tokens = AgentUsageTokens()
        var costUSD: Double?

        for event in sourceEvents {
            if blockStart == nil || event.timestamp >= blockEnd {
                let flooredStart = calendar.dateInterval(of: .hour, for: event.timestamp)?.start ?? event.timestamp
                blockStart = flooredStart
                blockEnd = flooredStart.addingTimeInterval(sessionWindowDuration)
                tokens = AgentUsageTokens()
                costUSD = nil
            }
            tokens.add(event.tokens)
            if let cost = AgentUsagePricing.estimatedCost(for: event) {
                costUSD = (costUSD ?? 0) + cost
            }
        }

        guard let blockStart, now < blockEnd else { return nil }
        return AgentUsageRateWindow(
            source: source,
            kind: .fiveHour,
            tokens: tokens,
            costUSD: costUSD,
            windowStart: blockStart,
            windowEnd: blockEnd,
            usedPercent: nil,
            isProviderReported: false
        )
    }

    static func rollingWeeklyWindow(
        events: [AgentUsageEvent],
        source: AgentUsageSource,
        now: Date = Date()
    ) -> AgentUsageRateWindow? {
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var tokens = AgentUsageTokens()
        var costUSD: Double?
        var sawEvent = false
        for event in events where event.source == source && event.timestamp >= weekStart && event.timestamp <= now {
            sawEvent = true
            tokens.add(event.tokens)
            if let cost = AgentUsagePricing.estimatedCost(for: event) {
                costUSD = (costUSD ?? 0) + cost
            }
        }
        guard sawEvent else { return nil }
        return AgentUsageRateWindow(
            source: source,
            kind: .weekly,
            tokens: tokens,
            costUSD: costUSD,
            windowStart: weekStart,
            windowEnd: nil,
            usedPercent: nil,
            isProviderReported: false
        )
    }

    /// Builds the dashboard's plan-limit windows: estimated 5-hour and rolling
    /// 7-day windows per source, overlaid with Codex's own reported rate-limit
    /// percentages when a fresh observation exists (primary ≈ 5-hour window,
    /// secondary ≈ weekly window).
    static func rateWindows(
        events: [AgentUsageEvent],
        codexRateLimits: CodexRateLimitsObservation? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [AgentUsageRateWindow] {
        var windows: [AgentUsageRateWindow] = []

        for source in AgentUsageSource.allCases {
            var fiveHour = currentFiveHourWindow(events: events, source: source, calendar: calendar, now: now)
            var weekly = rollingWeeklyWindow(events: events, source: source, now: now)

            if source == .codex, let observation = codexRateLimits {
                func apply(_ reported: CodexRateLimitWindow?, to window: inout AgentUsageRateWindow?, kind: AgentUsageRateWindow.Kind) {
                    guard let reported else { return }
                    let resetsAt = reported.resetsInSeconds.map {
                        observation.observedAt.addingTimeInterval(TimeInterval($0))
                    }
                    // A reset that already elapsed means the reported percent
                    // is stale; keep the locally estimated window instead.
                    if let resetsAt, resetsAt <= now { return }
                    var updated = window ?? AgentUsageRateWindow(
                        source: .codex,
                        kind: kind,
                        tokens: AgentUsageTokens(),
                        costUSD: nil,
                        windowStart: nil,
                        windowEnd: nil,
                        usedPercent: nil,
                        isProviderReported: false
                    )
                    updated.usedPercent = reported.usedPercent
                    if let resetsAt {
                        updated.windowEnd = resetsAt
                    }
                    updated.isProviderReported = true
                    window = updated
                }
                apply(observation.primary, to: &fiveHour, kind: .fiveHour)
                apply(observation.secondary, to: &weekly, kind: .weekly)
            }

            if let fiveHour { windows.append(fiveHour) }
            if let weekly { windows.append(weekly) }
        }

        return windows
    }

    static func aggregate(
        events: [AgentUsageEvent],
        codexRateLimits: CodexRateLimitsObservation? = nil,
        calendar: Calendar = .current,
        now: Date = Date(),
        windowDays: Int = 30,
        scannedFileCount: Int = 0
    ) -> AgentUsageSnapshot {
        let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: calendar.startOfDay(for: now)) ?? now

        struct Bucket {
            var tokens = AgentUsageTokens()
            var costUSD: Double?
            var requestCount = 0

            mutating func add(_ event: AgentUsageEvent) {
                tokens.add(event.tokens)
                requestCount += 1
                if let cost = AgentUsagePricing.estimatedCost(for: event) {
                    costUSD = (costUSD ?? 0) + cost
                }
            }
        }

        struct ModelKey: Hashable {
            var day: Date?
            var source: AgentUsageSource
            var model: String
        }

        var perDayModel: [ModelKey: Bucket] = [:]
        var perModel: [ModelKey: Bucket] = [:]
        var sourcesFound: Set<AgentUsageSource> = []

        for event in events {
            guard event.timestamp >= cutoff, event.timestamp <= now.addingTimeInterval(86_400) else { continue }
            sourcesFound.insert(event.source)
            let day = calendar.startOfDay(for: event.timestamp)
            perDayModel[ModelKey(day: day, source: event.source, model: event.model), default: Bucket()].add(event)
            perModel[ModelKey(day: nil, source: event.source, model: event.model), default: Bucket()].add(event)
        }

        func modelRollups(_ buckets: [ModelKey: Bucket]) -> [AgentUsageModelRollup] {
            buckets
                .map { key, bucket in
                    AgentUsageModelRollup(
                        source: key.source,
                        model: key.model,
                        tokens: bucket.tokens,
                        costUSD: bucket.costUSD,
                        requestCount: bucket.requestCount
                    )
                }
                .sorted { ($0.tokens.total, $0.model) > ($1.tokens.total, $1.model) }
        }

        let dayGroups = Dictionary(grouping: perDayModel, by: { $0.key.day ?? Date.distantPast })
        let days: [AgentUsageDayRollup] = dayGroups
            .map { day, entries in
                var tokens = AgentUsageTokens()
                var costUSD: Double?
                for (_, bucket) in entries {
                    tokens.add(bucket.tokens)
                    if let cost = bucket.costUSD {
                        costUSD = (costUSD ?? 0) + cost
                    }
                }
                return AgentUsageDayRollup(
                    day: day,
                    tokens: tokens,
                    costUSD: costUSD,
                    models: modelRollups(Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) }))
                )
            }
            .sorted { $0.day > $1.day }

        var totals = AgentUsageTokens()
        var totalCostUSD: Double?
        for day in days {
            totals.add(day.tokens)
            if let cost = day.costUSD {
                totalCostUSD = (totalCostUSD ?? 0) + cost
            }
        }

        return AgentUsageSnapshot(
            generatedAt: now,
            days: days,
            modelTotals: modelRollups(perModel),
            totals: totals,
            totalCostUSD: totalCostUSD,
            sourcesFound: sourcesFound,
            scannedFileCount: scannedFileCount,
            rateWindows: rateWindows(
                events: events,
                codexRateLimits: codexRateLimits,
                calendar: calendar,
                now: now
            )
        )
    }
}

/// Scans local Claude Code and Codex transcript directories and aggregates
/// token usage. Safe to run off the main actor; performs file I/O only.
struct AgentUsageScanner: Sendable {
    var claudeRoots: [URL]
    var codexRoots: [URL]
    var windowDays: Int

    /// Files larger than this are skipped to keep refreshes bounded.
    private static let maxFileSizeBytes = 64 * 1024 * 1024

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
