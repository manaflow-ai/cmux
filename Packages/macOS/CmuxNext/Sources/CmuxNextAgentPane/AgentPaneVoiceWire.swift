import Foundation
import CmuxNextSettings

/// Recognizes only newly delivered assistant text notifications. History/attach replies, tool
/// results, user messages and thought chunks cannot become speech. Rust owns text filtering.
nonisolated struct AgentPaneVoiceWire: Sendable {
    struct Text: Equatable, Sendable { var id: String; var text: String; var done: Bool }
    private var lastSequence = 0
    private var current: String?
    private var part = 0
    private var stream = UUID().uuidString

    mutating func receive(_ frame: String, session: String) -> [Text] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8)),
              root["id"] == nil, let params = root["params"],
              params["sessionId"]?.stringValue == session else { return [] }
        let update: JSONValue?
        let kind: String
        let sequence: Int
        switch root["method"]?.stringValue {
        case "_acpmux/event":
            sequence = params["seq"]?.intValue ?? 0
            kind = params["kind"]?.stringValue ?? ""
            update = params["msg"]?["params"]?["update"]
        case "session/update":
            sequence = params["_meta"]?["acpmux"]?["seq"]?.intValue ?? 0
            update = params["update"]
            kind = update?["sessionUpdate"]?.stringValue ?? ""
        default: return []
        }
        if sequence > 0 {
            guard sequence > lastSequence else { return [] }
            lastSequence = sequence
        }
        switch kind {
        case "agent_message_chunk":
            guard let content = update?["content"], content["type"]?.stringValue == "text",
                  let text = content["text"]?.stringValue, !text.isEmpty else { return [] }
            let id = (update?["messageId"]?.stringValue ?? stream) + ":" + String(part)
            var result: [Text] = []
            if let current, current != id { result.append(Text(id: current, text: "", done: true)) }
            current = id
            result.append(Text(id: id, text: text, done: false))
            return result
        case "tool_call", "turn_result", "turn_end", "turn_error":
            guard let id = current else { return [] }
            current = nil; stream = UUID().uuidString; part += 1
            return [Text(id: id, text: "", done: true)]
        default: return []
        }
    }

    /// Parsing a long tool notification must not block the pane's main actor.
    @concurrent nonisolated static func receive(_ frames: [String], session: String, state: Self) async -> (Self, [Text]) {
        var next = state
        var result: [Text] = []
        for frame in frames { result += next.receive(frame, session: session) }
        return (next, result)
    }

    static func prompt(session: String, id: String, text: String) -> String {
        let promptID = "voice-" + id
        let value: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .string(promptID), "method": .string("session/prompt"),
            "params": .object(["sessionId": .string(session),
                "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "_meta": .object(["acpmux": .object(["promptId": .string(promptID)])])])])
        return value.compactText
    }
}
