import Foundation

/// One `turn.end` of the trace.
nonisolated struct HomeEngineTurn: Equatable, Sendable {
    var harness: String
    var model: String?
    var seconds: Double
    var tools: Int
    var toolErrors: Int
    var hitRate: Double?
    var cost: Double?
    /// The reply's first characters (the trace keeps no more).
    var reply: String?

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ev"] as? String == "turn.end" else { return nil }
        harness = object["harness"] as? String ?? "?"
        model = object["model"] as? String
        seconds = (object["ms"] as? Double ?? 0) / 1000
        tools = object["tools"] as? Int ?? 0
        toolErrors = object["tool_errors"] as? Int ?? 0
        cost = object["cost_usd"] as? Double
        reply = (object["reply"] as? [String: Any])?["prefix"] as? String
        if let usage = object["usage"] as? [String: Any] {
            let read = usage["cache_read"] as? Double ?? 0
            let total = read + (usage["cache_write"] as? Double ?? 0) + (usage["input"] as? Double ?? 0)
            hitRate = total > 0 ? read / total : nil
        } else {
            hitRate = nil
        }
    }
}

nonisolated enum HomeEngineStrings {
    static var title: String { String(localized: "home.engine.title", defaultValue: "Chief Settings", table: "Home", bundle: .module) }
    static var pillHelp: String { String(localized: "home.engine.pillHelp", defaultValue: "Shows or hides this Chief's settings", table: "Home", bundle: .module) }
    static var nextTurn: String { String(localized: "home.engine.nextTurn", defaultValue: "Changes apply from the next turn.", table: "Home", bundle: .module) }
    static var openTraces: String { String(localized: "home.engine.openTraces", defaultValue: "Show Traces", table: "Home", bundle: .module) }
    static var showMemory: String { String(localized: "home.engine.showMemory", defaultValue: "Show Memory", table: "Home", bundle: .module) }
    static var brainFormat: String {
        String(localized: "home.engine.brain", defaultValue: "Runs on this Mac (%@). Tools: zoom, date, spawn, tell and the harness's own.", table: "Home", bundle: .module)
    }
    static var runsElsewhere: String {
        String(localized: "home.engine.runsElsewhere",
               defaultValue: "This Chief runs on a paired server, not on this Mac. Its harness and model are set on that server.",
               table: "Home", bundle: .module)
    }
    static var harness: String { String(localized: "home.engine.harness", defaultValue: "Harness", table: "Home", bundle: .module) }
    static var model: String { String(localized: "home.engine.model", defaultValue: "Model", table: "Home", bundle: .module) }
    static var effort: String { String(localized: "home.engine.effort", defaultValue: "Effort", table: "Home", bundle: .module) }
    static var defaultValue: String { String(localized: "home.engine.default", defaultValue: "Default", table: "Home", bundle: .module) }
    static var name: String { String(localized: "home.engine.name", defaultValue: "Name", table: "Home", bundle: .module) }
    static var avatar: String { String(localized: "home.engine.avatar", defaultValue: "Avatar", table: "Home", bundle: .module) }
    static var answeredBy: String { String(localized: "home.engine.answeredBy", defaultValue: "Recent replies, answered by:", table: "Home", bundle: .module) }

    /// "“Both subagents are done…” claude-sr, claude-opus-5-5".
    static func reply(_ turn: HomeEngineTurn) -> String {
        let engine = [turn.harness, turn.model].compactMap { $0 }.joined(separator: ", ")
        return "\u{201C}\(turn.reply ?? "")\u{201D} \(engine)"
    }

    static var noTurn: String { String(localized: "home.engine.noTurn", defaultValue: "No turn yet", table: "Home", bundle: .module) }

    /// "Last turn: claude-sr, claude-opus-5-5, 7.8 s, 1 tool call, 50% cached, $0.144".
    static func lastTurn(_ turn: HomeEngineTurn) -> String {
        let engine = [turn.harness, turn.model].compactMap { $0 }.joined(separator: ", ")
        let hit = turn.hitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "-"
        let cost = turn.cost.map { String(format: "$%.3f", $0) } ?? "-"
        let format = String(localized: "home.engine.lastTurn",
                            defaultValue: "Last turn: %1$@, %2$@ s, %3$lld tool calls (%4$lld failed), %5$@ cached, %6$@",
                            table: "Home", bundle: .module)
        return String(format: format, engine, String(format: "%.1f", turn.seconds), turn.tools, turn.toolErrors, hit, cost)
    }
}
