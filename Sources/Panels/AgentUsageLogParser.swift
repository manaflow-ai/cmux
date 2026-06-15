import Foundation

/// Line-level parsers for the JSONL transcript formats written by Claude Code
/// and the Codex CLI. Pure functions over strings; no file I/O.
enum AgentUsageLogParser {
    private nonisolated(unsafe) static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plainISO8601 = ISO8601DateFormatter()

    /// Parses an ISO-8601 timestamp with or without fractional seconds.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractionalISO8601.date(from: raw) ?? plainISO8601.date(from: raw)
    }

    /// Reads an integer out of a loosely typed JSON value.
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

    /// Decodes one JSONL line into a dictionary, tolerating non-JSON lines.
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
                delta = cumulativeDelta(total: total, previousTotal: previousTotal)
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

    /// Per-request usage derived from cumulative session totals. When the
    /// cumulative counter went backwards (the CLI reset it, e.g. on context
    /// compaction or a sub-session restart), the new total is itself the
    /// uncounted usage — clamping each field to zero would undercount.
    private static func cumulativeDelta(total: AgentUsageTokens, previousTotal: AgentUsageTokens?) -> AgentUsageTokens {
        guard let previousTotal else { return total }
        if total.total < previousTotal.total {
            return total
        }
        return AgentUsageTokens(
            input: max(0, total.input - previousTotal.input),
            output: max(0, total.output - previousTotal.output),
            cacheRead: max(0, total.cacheRead - previousTotal.cacheRead),
            cacheWrite: max(0, total.cacheWrite - previousTotal.cacheWrite)
        )
    }

    /// Decodes one window of a Codex `rate_limits` payload.
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

    /// Converts a Codex usage dictionary into the dashboard's token breakdown,
    /// splitting cached input out of the raw input figure.
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

    // MARK: - OpenCode (~/.local/share/opencode/storage/message/**/*.json)

    /// Parses one OpenCode message file. Only assistant messages carry token
    /// usage; the schema nests counts under `tokens` with a `cache` sub-object
    /// (`tokens.{input,output,reasoning,cache.{read,write}}`), records `cost`
    /// (often `0`, in which case it is estimated from the price table later),
    /// identifies the model via `modelID`, and timestamps via `time.completed`
    /// or `time.created` in epoch milliseconds. Reasoning tokens are folded into
    /// output to match how the other sources report generated tokens.
    static func parseOpenCodeMessage(_ contents: String) -> AgentUsageEvent? {
        guard let object = jsonObject(contents) else { return nil }
        guard (object["role"] as? String) == "assistant" else { return nil }
        guard let tokensDict = object["tokens"] as? [String: Any] else { return nil }

        let cache = tokensDict["cache"] as? [String: Any]
        let tokens = AgentUsageTokens(
            input: intValue(tokensDict["input"]),
            output: intValue(tokensDict["output"]) + intValue(tokensDict["reasoning"]),
            cacheRead: intValue(cache?["read"]),
            cacheWrite: intValue(cache?["write"])
        )
        guard !tokens.isEmpty else { return nil }

        guard let timestamp = openCodeTimestamp(object["time"]) else { return nil }

        let model = (object["modelID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "opencode"
        let cost = (object["cost"] as? NSNumber)?.doubleValue
        return AgentUsageEvent(
            source: .openCode,
            timestamp: timestamp,
            model: model,
            tokens: tokens,
            // OpenCode writes cost: 0 when it cannot price a model; treat only a
            // positive recorded cost as authoritative and estimate otherwise.
            recordedCostUSD: (cost ?? 0) > 0 ? cost : nil
        )
    }

    /// Reads OpenCode's `time` object (`completed` preferred over `created`),
    /// interpreting the value as epoch milliseconds, but tolerating a seconds
    /// value in case the format changes.
    private static func openCodeTimestamp(_ any: Any?) -> Date? {
        guard let time = any as? [String: Any] else { return nil }
        let raw = (time["completed"] as? NSNumber)?.doubleValue
            ?? (time["created"] as? NSNumber)?.doubleValue
        guard let raw, raw > 0 else { return nil }
        // Epoch milliseconds are ~1e12; a value below that is already in seconds.
        let seconds = raw >= 1_000_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
