import Foundation

/// Pure aggregation over parsed usage events: daily/model rollups, totals,
/// and plan-limit windows. No file I/O and no main-actor dependencies.
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
            .filter { $0.source == source }
            .sorted { $0.timestamp < $1.timestamp }
        return currentFiveHourWindow(sortedSourceEvents: sourceEvents, source: source, calendar: calendar, now: now)
    }

    /// Same as `currentFiveHourWindow(events:source:calendar:now:)` but assumes
    /// the events are already filtered to `source` and sorted ascending by
    /// timestamp, so callers that aggregate several windows sort only once.
    private static func currentFiveHourWindow(
        sortedSourceEvents: [AgentUsageEvent],
        source: AgentUsageSource,
        calendar: Calendar,
        now: Date
    ) -> AgentUsageRateWindow? {
        var blockStart: Date?
        var blockEnd = Date.distantPast
        var tokens = AgentUsageTokens()
        var costUSD: Double?

        for event in sortedSourceEvents {
            guard event.timestamp <= now else { break }
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

    /// Sums a source's usage over the trailing 7 days. Returns nil when the
    /// source had no events in that span.
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
    /// secondary ≈ weekly window). Events are grouped and sorted once per call.
    static func rateWindows(
        events: [AgentUsageEvent],
        codexRateLimits: CodexRateLimitsObservation? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [AgentUsageRateWindow] {
        let eventsBySource = Dictionary(grouping: events, by: \.source)
            .mapValues { $0.sorted { $0.timestamp < $1.timestamp } }
        var windows: [AgentUsageRateWindow] = []

        for source in AgentUsageSource.allCases {
            let sortedSourceEvents = eventsBySource[source] ?? []
            var fiveHour = currentFiveHourWindow(
                sortedSourceEvents: sortedSourceEvents,
                source: source,
                calendar: calendar,
                now: now
            )
            var weekly = rollingWeeklyWindow(events: sortedSourceEvents, source: source, now: now)

            if source == .codex, let observation = codexRateLimits {
                overlayReported(observation.primary, observedAt: observation.observedAt, now: now, kind: .fiveHour, onto: &fiveHour)
                overlayReported(observation.secondary, observedAt: observation.observedAt, now: now, kind: .weekly, onto: &weekly)
            }

            if let fiveHour { windows.append(fiveHour) }
            if let weekly { windows.append(weekly) }
        }

        return windows
    }

    /// Applies a Codex-reported rate-limit window onto a locally estimated one.
    /// A reset time that already elapsed means the reported percent is stale;
    /// the locally estimated window is kept untouched in that case.
    private static func overlayReported(
        _ reported: CodexRateLimitWindow?,
        observedAt: Date,
        now: Date,
        kind: AgentUsageRateWindow.Kind,
        onto window: inout AgentUsageRateWindow?
    ) {
        guard let reported else { return }
        let resetsAt = reported.resetsInSeconds.map {
            observedAt.addingTimeInterval(TimeInterval($0))
        }
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

    /// Aggregates parsed events into the snapshot the dashboard renders:
    /// per-day and per-model rollups inside the trailing `windowDays` window,
    /// overall totals, and plan-limit windows.
    static func aggregate(
        events: [AgentUsageEvent],
        codexRateLimits: CodexRateLimitsObservation? = nil,
        calendar: Calendar = .current,
        now: Date = Date(),
        windowDays: Int = 30,
        scannedFileCount: Int = 0
    ) -> AgentUsageSnapshot {
        let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: calendar.startOfDay(for: now)) ?? now

        /// Mutable accumulator for one rollup bucket.
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

        /// Grouping key: per-day buckets carry the day; window-wide buckets don't.
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
