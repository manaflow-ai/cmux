import CmuxNextDaemon
import Foundation

/// One `turn.end` of the trace: a line of this Mac's trace file, or a turn the brain summarized
/// (`chief.engine.get` `recent`). Fields an older trace or brain does not write stay nil.
nonisolated struct HomeEngineTurn: Equatable, Sendable {
    var harness: String
    var model: String?
    /// The effort the turn ran at (`high`).
    var effort: String?
    /// How the turn ended (`ok`, `error`, `stopped`).
    var status: String?
    /// When the turn ended.
    var ended: Date?
    var seconds: Double
    var tools: Int
    var toolErrors: Int
    /// The share of the prompt read from the cache: read / (read + written + uncached input).
    var hitRate: Double?
    var cost: Double?
    /// Every token the turn used: input, output, and the cache's reads and writes.
    var tokens: Double?
    /// The reply's first characters (the trace keeps no more).
    var reply: String?
    /// The first characters of the error a failed turn ended with.
    var error: String?

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ev"] as? String == "turn.end" else { return nil }
        harness = object["harness"] as? String ?? "?"
        model = object["model"] as? String
        effort = object["effort"] as? String
        status = object["status"] as? String
        ended = (object["ts"] as? Double).map(Self.date)
        seconds = (object["ms"] as? Double ?? 0) / 1000
        tools = object["tools"] as? Int ?? 0
        toolErrors = object["tool_errors"] as? Int ?? 0
        cost = object["cost_usd"] as? Double
        reply = (object["reply"] as? [String: Any])?["prefix"] as? String
        error = (object["error"] as? [String: Any])?["prefix"] as? String
        let counts = object["usage"] as? [String: Any]
        let usage = Self.usage(read: counts?["cache_read"] as? Double, written: counts?["cache_write"] as? Double,
                               input: counts?["input"] as? Double, output: counts?["output"] as? Double, present: counts != nil)
        hitRate = usage.hitRate
        tokens = usage.tokens
    }

    /// A turn end the brain summarized (`chief.engine.get` `recent`).
    init(report turn: ChiefEngineReport.Turn) {
        harness = turn.harness ?? "?"
        model = turn.model
        effort = turn.effort
        status = turn.status
        ended = turn.ts.map(Self.date)
        seconds = (turn.ms ?? 0) / 1000
        tools = turn.tools ?? 0
        toolErrors = turn.toolErrors ?? 0
        cost = turn.costUSD
        reply = turn.reply
        error = turn.error
        let counts = turn.usage
        let usage = Self.usage(read: counts?.cacheRead, written: counts?.cacheWrite, input: counts?.input,
                               output: counts?.output, present: counts != nil)
        hitRate = usage.hitRate
        tokens = usage.tokens
    }

    /// The cache hit rate and the token total of a turn's usage (nil, nil with no usage; a nil
    /// rate when nothing was read or written, which says nothing about the cache).
    static func usage(read: Double?, written: Double?, input: Double?, output: Double?,
                      present: Bool) -> (hitRate: Double?, tokens: Double?) {
        guard present else { return (nil, nil) }
        let read = read ?? 0
        let prompt = read + (written ?? 0) + (input ?? 0)
        let total = prompt + (output ?? 0)
        return (prompt > 0 ? read / prompt : nil, total > 0 ? total : nil)
    }

    /// A trace time (milliseconds since 1970) as a date.
    static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
