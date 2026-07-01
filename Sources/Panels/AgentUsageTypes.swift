import Foundation

/// Which local coding-agent installation a usage event came from.
enum AgentUsageSource: String, CaseIterable, Identifiable, Sendable {
    /// Usage parsed from Claude Code transcripts (`~/.claude/projects`).
    case claudeCode
    /// Usage parsed from Codex CLI rollout files (`~/.codex/sessions`).
    case codex
    /// Usage parsed from OpenCode message files (`~/.local/share/opencode`).
    case openCode
    /// Usage fetched from the OpenRouter account-activity API (server-reported,
    /// not a local transcript scan).
    case openRouter

    /// Stable identity for SwiftUI lists.
    var id: String { rawValue }

    /// Product name shown in the UI. Product names are intentionally not localized.
    var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .openCode:
            return "OpenCode"
        case .openRouter:
            return "OpenRouter"
        }
    }

    /// True when the source's usage comes from a remote API rather than from
    /// locally scanned transcript files.
    var isServerReported: Bool { self == .openRouter }
}

/// Token counts for one event or rollup, broken down the way providers bill them.
struct AgentUsageTokens: Equatable, Sendable {
    /// Non-cached input tokens.
    var input: Int = 0
    /// Output tokens (includes reasoning output where providers fold it in).
    var output: Int = 0
    /// Tokens served from the provider's prompt cache.
    var cacheRead: Int = 0
    /// Tokens written into the provider's prompt cache.
    var cacheWrite: Int = 0

    /// Sum of all four buckets.
    var total: Int { input + output + cacheRead + cacheWrite }

    /// True when no tokens were recorded at all.
    var isEmpty: Bool { total == 0 }

    /// Accumulates another token breakdown into this one.
    mutating func add(_ other: AgentUsageTokens) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }
}

/// One token-consuming request parsed from an agent transcript file.
struct AgentUsageEvent: Equatable, Sendable {
    /// Which agent installation produced the request.
    var source: AgentUsageSource
    /// When the request happened (transcript timestamp).
    var timestamp: Date
    /// Provider model ID (e.g. `claude-opus-4-8`), or the source's generic
    /// fallback name when the transcript did not record a model.
    var model: String
    /// Token breakdown for this request.
    var tokens: AgentUsageTokens
    /// Cost recorded directly in the transcript (Claude Code `costUSD`), when present.
    var recordedCostUSD: Double?
}

/// Aggregated usage for one (source, model) pair.
struct AgentUsageModelRollup: Equatable, Sendable, Identifiable {
    /// Which agent installation the usage belongs to.
    var source: AgentUsageSource
    /// Provider model ID the usage is attributed to.
    var model: String
    /// Summed token breakdown.
    var tokens: AgentUsageTokens
    /// Summed estimated cost in USD; nil when no event was estimable.
    var costUSD: Double?
    /// Number of requests aggregated into this rollup.
    var requestCount: Int

    /// Stable identity for SwiftUI lists: source + model.
    var id: String { "\(source.rawValue)|\(model)" }
}

/// Aggregated usage for one calendar day, with a per-model breakdown.
struct AgentUsageDayRollup: Equatable, Sendable, Identifiable {
    /// Start of the day in the aggregating calendar.
    var day: Date
    /// Summed token breakdown across all models that day.
    var tokens: AgentUsageTokens
    /// Summed estimated cost in USD; nil when no event was estimable.
    var costUSD: Double?
    /// Per-model rollups for the day, largest first.
    var models: [AgentUsageModelRollup]

    /// Stable identity for SwiftUI lists: the day itself.
    var id: Date { day }
}

/// One provider rate-limit window in the dashboard (5-hour or weekly).
/// `usedPercent` is only set when the provider reported it (Codex CLI writes
/// its real rate-limit state into rollout files); Claude Code windows are
/// estimated from local transcripts and carry tokens/cost only.
struct AgentUsageRateWindow: Equatable, Sendable, Identifiable {
    /// The two plan-limit window shapes providers use.
    enum Kind: String, Sendable {
        /// The rolling ~5-hour session window.
        case fiveHour
        /// The weekly window.
        case weekly
    }

    /// Which agent installation the window belongs to.
    var source: AgentUsageSource
    /// Whether this is the 5-hour or the weekly window.
    var kind: Kind
    /// Tokens attributed to the window from local transcripts.
    var tokens: AgentUsageTokens
    /// Estimated cost of the window's tokens in USD; nil when not estimable.
    var costUSD: Double?
    /// When the window opened, if known.
    var windowStart: Date?
    /// When the window resets, if known.
    var windowEnd: Date?
    /// Provider-reported used percentage (0–100), if available.
    var usedPercent: Double?
    /// True when `usedPercent`/`windowEnd` come from provider-reported
    /// rate-limit data instead of local estimation.
    var isProviderReported: Bool

    /// Stable identity for SwiftUI lists: source + kind.
    var id: String { "\(source.rawValue)|\(kind.rawValue)" }
}

/// One rate-limit window as reported by the Codex CLI inside `token_count` events.
struct CodexRateLimitWindow: Equatable, Sendable {
    /// Percentage of the window's quota already used (0–100).
    var usedPercent: Double
    /// Window length in minutes (300 ≈ 5-hour, 10080 ≈ weekly), if reported.
    var windowMinutes: Int?
    /// Seconds until the window resets, relative to the observation time.
    var resetsInSeconds: Int?
}

/// A timestamped rate-limit snapshot from one Codex rollout event.
struct CodexRateLimitsObservation: Equatable, Sendable {
    /// Timestamp of the rollout event that carried the rate-limit data.
    var observedAt: Date
    /// The short (~5-hour) window, if reported.
    var primary: CodexRateLimitWindow?
    /// The long (weekly) window, if reported.
    var secondary: CodexRateLimitWindow?
}

/// Result of parsing one Codex rollout file: its usage events plus the newest
/// rate-limit observation found in the file, if any.
struct CodexSessionParseResult: Equatable, Sendable {
    /// Per-request usage events in file order.
    var events: [AgentUsageEvent]
    /// Newest rate-limit observation in the file, if any event carried one.
    var rateLimits: CodexRateLimitsObservation?
}

/// Immutable result of one scan: everything the dashboard renders.
struct AgentUsageSnapshot: Equatable, Sendable {
    /// When the scan producing this snapshot ran.
    var generatedAt: Date
    /// Daily rollups, newest day first.
    var days: [AgentUsageDayRollup]
    /// Per-model rollups across the whole window, largest first.
    var modelTotals: [AgentUsageModelRollup]
    /// Token totals across the whole window.
    var totals: AgentUsageTokens
    /// Estimated cost total in USD; nil when no event was estimable.
    var totalCostUSD: Double?
    /// Which sources contributed at least one event.
    var sourcesFound: Set<AgentUsageSource>
    /// Number of transcript files read during the scan.
    var scannedFileCount: Int
    /// Plan-limit windows (5-hour and weekly per source).
    var rateWindows: [AgentUsageRateWindow] = []
    /// OpenRouter account balance, when an API key is configured and the fetch
    /// succeeded; nil otherwise.
    var openRouterCredits: OpenRouterCredits? = nil

    /// A snapshot with no data, timestamped at the epoch.
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
