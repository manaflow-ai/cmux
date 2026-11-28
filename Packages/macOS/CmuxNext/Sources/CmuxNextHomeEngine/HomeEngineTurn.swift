import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// One `turn.end` of the trace: a line of this Mac's trace file, or a turn the brain summarized
/// (`chief.engine.get` `recent`). Fields an older trace or brain does not write stay nil.
/// The parsing and the derived numbers are `chief_brain.engine_turn_*` in cmux-home-rules.
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
        guard let reply: LineReply = try? HomeRules.chiefBrain("engine_turn_from_line", ["line": line]),
              let turn = reply.turn else { return nil }
        self.init(turn)
    }

    /// A turn end the brain summarized (`chief.engine.get` `recent`). A failed rules call keeps
    /// the fields the summary names as they are, with nothing derived from them.
    init(report turn: ChiefEngineReport.Turn) {
        let usage = turn.usage.map {
            ReportTurn.Usage(cacheRead: $0.cacheRead, cacheWrite: $0.cacheWrite, input: $0.input, output: $0.output)
        }
        let request = ReportRequest(turns: [ReportTurn(
            harness: turn.harness, model: turn.model, effort: turn.effort, status: turn.status, ts: turn.ts, ms: turn.ms,
            tools: turn.tools, toolErrors: turn.toolErrors, costUSD: turn.costUSD, usage: usage, reply: turn.reply,
            error: turn.error)])
        let derived = (try? HomeRules.chiefBrain("engine_turns_from_report", request) as ReportReply)?.turns.first
        self.init(derived ?? Wire(
            harness: turn.harness ?? "?", model: turn.model, effort: turn.effort, status: turn.status, endedSecs: nil,
            seconds: 0, tools: turn.tools ?? 0, toolErrors: turn.toolErrors ?? 0, hitRate: nil, cost: turn.costUSD,
            tokens: nil, reply: turn.reply, error: turn.error))
    }

    private init(_ turn: Wire) {
        harness = turn.harness
        model = turn.model
        effort = turn.effort
        status = turn.status
        ended = turn.endedSecs.map(Date.init(timeIntervalSince1970:))
        seconds = turn.seconds
        tools = turn.tools
        toolErrors = turn.toolErrors
        hitRate = turn.hitRate
        cost = turn.cost
        tokens = turn.tokens
        reply = turn.reply
        error = turn.error
    }

    /// `chief_brain::turn::EngineTurn`.
    private nonisolated struct Wire: Decodable {
        var harness: String
        var model: String?
        var effort: String?
        var status: String?
        var endedSecs: Double?
        var seconds: Double
        var tools: Int
        var toolErrors: Int
        var hitRate: Double?
        var cost: Double?
        var tokens: Double?
        var reply: String?
        var error: String?
    }

    private nonisolated struct LineReply: Decodable {
        var turn: Wire?
    }

    /// `chief_brain::turn::ReportTurn` (it takes these camelCase keys as aliases).
    private nonisolated struct ReportTurn: Encodable {
        nonisolated struct Usage: Encodable {
            var cacheRead: Double?
            var cacheWrite: Double?
            var input: Double?
            var output: Double?
        }

        var harness: String?
        var model: String?
        var effort: String?
        var status: String?
        var ts: Double?
        var ms: Double?
        var tools: Int?
        var toolErrors: Int?
        var costUSD: Double?
        var usage: Usage?
        var reply: String?
        var error: String?
    }

    private nonisolated struct ReportRequest: Encodable {
        var turns: [ReportTurn]
    }

    private nonisolated struct ReportReply: Decodable {
        var turns: [Wire]
    }
}
