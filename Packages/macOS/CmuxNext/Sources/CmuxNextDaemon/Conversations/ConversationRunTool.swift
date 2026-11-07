import Foundation

/// Only the fields needed for Chief messages, normalized by the SDK's `run_tool` rule
/// (``ConversationRules``): `name` (or `tool`), `input` (or `arguments`), and an optchat `tell`
/// or `spawn` inside a Codex `mcp_tool_call` envelope. Other tools accept arbitrary JSON inputs;
/// unfamiliar shapes must not prevent the rest of a run (including reports) from decoding.
public struct ConversationRunTool: Decodable, Sendable, Hashable {
    public struct Input: Decodable, Sendable, Hashable {
        public var id: String?
        public var message: String?
        public var isTellEnvelope = false
        /// A `spawn`'s tasks, in order; nil for any other tool.
        public var tasks: [String]?
        /// A Codex `mcp_tool_call` to optchat's `spawn`.
        public var isSpawnEnvelope = false
        /// The prompt's `_meta.cmux.sender` (`human:<participant>`, `chief:<id>`); nil when it has none.
        public var sender: String?

        private enum CodingKeys: String, CodingKey {
            case id, message, tasks, sender
            case isTellEnvelope = "is_tell_envelope"
            case isSpawnEnvelope = "is_spawn_envelope"
        }

        /// The rule's normalized input.
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decodeIfPresent(String.self, forKey: .id)
            message = try fields.decodeIfPresent(String.self, forKey: .message)
            tasks = try fields.decodeIfPresent([String].self, forKey: .tasks)
            sender = try fields.decodeIfPresent(String.self, forKey: .sender)
            isTellEnvelope = try fields.decodeIfPresent(Bool.self, forKey: .isTellEnvelope) ?? false
            isSpawnEnvelope = try fields.decodeIfPresent(Bool.self, forKey: .isSpawnEnvelope) ?? false
        }
    }
    public var name = ""
    public var input: Input?
    public var status: String?
    public var output: String?
    public var startedAt: Double?

    /// The rule's reply.
    private struct Normalized: Decodable {
        var name: String
        var input: Input?
        var status: String?
        var output: String?
        var startedAt: Double?
        enum CodingKeys: String, CodingKey { case name, input, status, output, startedAt = "started_at" }
    }

    /// Any JSON decodes: the step's raw `tool` goes to the rule as it came, and a shape the rule
    /// cannot read (it reads every JSON value) leaves an empty tool.
    public init(from decoder: any Decoder) throws {
        let raw = (try? JSONValue(from: decoder)) ?? .null
        guard let tool = try? ConversationRules().call("run_tool", ["tool": raw], as: Normalized.self) else { return }
        name = tool.name
        input = tool.input
        status = tool.status
        output = tool.output
        startedAt = tool.startedAt
    }
}
