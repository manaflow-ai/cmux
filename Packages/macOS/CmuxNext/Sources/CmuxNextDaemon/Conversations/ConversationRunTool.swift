import Foundation

/// Only the fields needed for Chief messages. Other tools accept arbitrary JSON inputs;
/// unfamiliar shapes must not prevent the rest of a run (including reports) from decoding.
public struct ConversationRunTool: Decodable, Sendable, Hashable {
    public struct Input: Decodable, Sendable, Hashable {
        public var id: String?
        public var message: String?
        public var isTellEnvelope = false
        /// The prompt's `_meta.cmux.sender` (`human:<participant>`, `chief:<id>`); nil when it has none.
        public var sender: String?

        private enum CodingKeys: String, CodingKey { case id, message, arguments, server, tool, meta = "_meta" }
        private enum MetaKeys: String, CodingKey { case cmux }
        private enum CmuxKeys: String, CodingKey { case sender }

        public init(from decoder: any Decoder) throws {
            guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            if fields.contains(.arguments) {
                guard let arguments = try? fields.nestedContainer(keyedBy: CodingKeys.self, forKey: .arguments) else { return }
                id = try? arguments.decode(String.self, forKey: .id)
                message = try? arguments.decode(String.self, forKey: .message)
                let server = try? fields.decode(String.self, forKey: .server)
                let tool = try? fields.decode(String.self, forKey: .tool)
                isTellEnvelope = server == "optchat" && tool == "tell"
                sender = Self.sender(in: arguments) ?? Self.sender(in: fields)
            } else {
                id = try? fields.decode(String.self, forKey: .id)
                message = try? fields.decode(String.self, forKey: .message)
                sender = Self.sender(in: fields)
            }
        }

        /// `_meta.cmux.sender` when it is a string; nil otherwise.
        private static func sender(in fields: KeyedDecodingContainer<CodingKeys>) -> String? {
            guard let meta = try? fields.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta),
                  let cmux = try? meta.nestedContainer(keyedBy: CmuxKeys.self, forKey: .cmux) else { return nil }
            return try? cmux.decode(String.self, forKey: .sender)
        }
    }
    public var name = ""
    public var input: Input?
    public var status: String?
    public var output: String?
    public var startedAt: Double?

    private enum CodingKeys: String, CodingKey { case name, tool, input, arguments, status, output, startedAt = "started_at" }

    public init(from decoder: any Decoder) throws {
        guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        let directName = try? fields.decode(String.self, forKey: .name)
        let toolName = try? fields.decode(String.self, forKey: .tool)
        name = directName ?? toolName ?? ""
        let directInput = try? fields.decode(Input.self, forKey: .input)
        let argumentInput = try? fields.decode(Input.self, forKey: .arguments)
        input = directInput ?? argumentInput
        status = try? fields.decode(String.self, forKey: .status)
        output = try? fields.decode(String.self, forKey: .output)
        startedAt = try? fields.decode(Double.self, forKey: .startedAt)
    }
}
