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

public nonisolated enum HomeEngineStrings {
    static var title: String { String(localized: "home.engine.title", defaultValue: "Chief Settings", table: "Home", bundle: .module) }
    public static var pillHelp: String { String(localized: "home.engine.pillHelp", defaultValue: "Shows or hides this Chief's settings", table: "Home", bundle: .module) }
    static var nextTurn: String { String(localized: "home.engine.nextTurn", defaultValue: "Changes apply from the next turn.", table: "Home", bundle: .module) }
    static var openTraces: String { String(localized: "home.engine.openTraces", defaultValue: "Show Traces", table: "Home", bundle: .module) }
    static var showMemory: String { String(localized: "home.engine.showMemory", defaultValue: "Show Memory", table: "Home", bundle: .module) }
    static var brainFormat: String {
        String(localized: "home.engine.brain", defaultValue: "Runs on this Mac (%@). Tools: zoom, date, spawn, tell and the harness's own.", table: "Home", bundle: .module)
    }
    /// "Runs on the paired server cmux-lawrence."
    static var runsOnServerFormat: String {
        String(localized: "home.engine.runsOnServer", defaultValue: "Runs on the paired server %@.", table: "Home", bundle: .module)
    }
    static var errorUnreachable: String {
        String(localized: "home.engine.error.unreachable", defaultValue: "The server with this Chief is not connected.", table: "Home", bundle: .module)
    }
    /// This Mac's Chief: its owner daemon or brain host is not running.
    static var errorLocalUnreachable: String {
        String(localized: "home.engine.error.localUnreachable", defaultValue: "This Mac's Chief is not running.", table: "Home", bundle: .module)
    }
    /// This Mac's brain was not running; the panel has just started it.
    static var errorLocalStarting: String {
        String(localized: "home.engine.error.localStarting", defaultValue: "This Mac's Chief was not running. It is starting now; try again in a moment.", table: "Home", bundle: .module)
    }
    static var errorForbidden: String {
        String(localized: "home.engine.error.forbidden", defaultValue: "This server does not let this connection change its Chief.", table: "Home", bundle: .module)
    }
    static var errorNotConfigured: String {
        String(localized: "home.engine.error.notConfigured", defaultValue: "This daemon does not reach its Chief's brain. Restart the Chief's daemon.", table: "Home", bundle: .module)
    }
    static var errorUnsupported: String {
        String(localized: "home.engine.error.unsupported", defaultValue: "This server's cmux is too old to change its Chief from here.", table: "Home", bundle: .module)
    }
    /// "The change failed: acpmux on this host has no harness x"
    static var errorRefusedFormat: String {
        String(localized: "home.engine.error.refused", defaultValue: "The change failed: %@", table: "Home", bundle: .module)
    }
    static var harness: String { String(localized: "home.engine.harness", defaultValue: "Harness", table: "Home", bundle: .module) }
    static var model: String { String(localized: "home.engine.model", defaultValue: "Model", table: "Home", bundle: .module) }
    static var effort: String { String(localized: "home.engine.effort", defaultValue: "Effort", table: "Home", bundle: .module) }
    static var defaultValue: String { String(localized: "home.engine.default", defaultValue: "Default", table: "Home", bundle: .module) }
    /// A picker's "Default" item naming what it runs: "Default (claude)", "Default (Opus 5.5)".
    static var defaultNamedFormat: String {
        String(localized: "home.engine.defaultNamed", defaultValue: "Default (%@)", table: "Home", bundle: .module)
    }
    static var agentSection: String { String(localized: "home.engine.section.agent", defaultValue: "Agent", table: "Home", bundle: .module) }
    static var appearanceSection: String {
        String(localized: "home.engine.section.appearance", defaultValue: "Appearance", table: "Home", bundle: .module)
    }
    static var diagnostics: String { String(localized: "home.engine.section.diagnostics", defaultValue: "Diagnostics", table: "Home", bundle: .module) }
    /// Under the name, for a Chief whose brain runs here.
    static var runsHere: String { String(localized: "home.engine.runsHere", defaultValue: "Runs on this Mac", table: "Home", bundle: .module) }
    /// The Hosted Chief's place line.
    public static var runsInCloud: String {
        String(localized: "home.engine.runsInCloud", defaultValue: "Runs in the cloud", table: "Home", bundle: .module)
    }
    /// A paired server's place line, by its name.
    public static var runsOnFormat: String {
        String(localized: "home.engine.runsOn", defaultValue: "Runs on %@", table: "Home", bundle: .module)
    }
    /// The card's link to the same Chief on its other host.
    static var switchHostFormat: String {
        String(localized: "home.engine.switchHost", defaultValue: "Switch to %@", table: "Home", bundle: .module)
    }
    /// The avatar's tooltip and VoiceOver label: a click opens its menu.
    static var changePicture: String {
        String(localized: "home.engine.changePicture", defaultValue: "Change Picture", table: "Home", bundle: .module)
    }
    static var name: String { String(localized: "home.engine.name", defaultValue: "Name", table: "Home", bundle: .module) }
    static var choosePicture: String {
        String(localized: "home.engine.choosePicture", defaultValue: "Choose Picture…", table: "Home", bundle: .module)
    }
    static var useDefaultPicture: String {
        String(localized: "home.engine.useDefaultPicture", defaultValue: "Use Default Picture", table: "Home", bundle: .module)
    }
    /// "%@ did not pass its check…" (the harness's name).
    static var harnessCheckFailedFormat: String {
        String(localized: "home.engine.harnessCheckFailed", defaultValue: "%@ did not answer its check, so the Chief stays on what it runs now.",
               table: "Home", bundle: .module)
    }
    static var renameRefused: String {
        String(localized: "home.engine.renameRefused", defaultValue: "The Chief's name could not be changed. Try again in a moment.",
               table: "Home", bundle: .module)
    }
    static var pictureUnreadable: String {
        String(localized: "home.engine.pictureUnreadable", defaultValue: "That picture could not be used. Choose a PNG, JPEG, HEIC, WebP, or a GIF up to 1 MB.",
               table: "Home", bundle: .module)
    }
    static var answeredBy: String { String(localized: "home.engine.answeredBy", defaultValue: "Recent replies, answered by:", table: "Home", bundle: .module) }

    /// "“Both subagents are done…” claude-sr, claude-opus-5-5", or the engine
    /// alone for a turn whose reply the trace kept no text of (no empty quotes).
    static func reply(_ turn: HomeEngineTurn) -> String {
        let engine = [turn.harness, turn.model].compactMap { $0 }.joined(separator: ", ")
        let text = turn.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? engine : "\u{201C}\(text)\u{201D} \(engine)"
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
