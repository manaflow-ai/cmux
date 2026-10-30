import Foundation

/// Only the fields needed for Chief messages. Other tools accept arbitrary JSON inputs;
/// unfamiliar shapes must not prevent the rest of a run (including reports) from decoding.
public struct ConversationRunTool: Decodable, Sendable, Hashable {
    public struct Input: Decodable, Sendable, Hashable {
        public var id: String?
        public var message: String?
        public var isTellEnvelope = false

        private enum CodingKeys: String, CodingKey { case id, message, arguments, server, tool }

        public init(from decoder: any Decoder) throws {
            guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            if fields.contains(.arguments) {
                guard let arguments = try? fields.nestedContainer(keyedBy: CodingKeys.self, forKey: .arguments) else { return }
                id = try? arguments.decode(String.self, forKey: .id)
                message = try? arguments.decode(String.self, forKey: .message)
                let server = try? fields.decode(String.self, forKey: .server)
                let tool = try? fields.decode(String.self, forKey: .tool)
                isTellEnvelope = server == "optchat" && tool == "tell"
            } else {
                id = try? fields.decode(String.self, forKey: .id)
                message = try? fields.decode(String.self, forKey: .message)
            }
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
