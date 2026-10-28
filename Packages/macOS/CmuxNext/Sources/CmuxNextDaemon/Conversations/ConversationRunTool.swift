import Foundation

/// The portion of a tool step needed to show a Chief's message without truncating its input.
public struct ConversationRunTool: Decodable, Sendable, Hashable {
    public struct Input: Decodable, Sendable, Hashable {
        public var id: String?
        public var message: String?

        private enum CodingKeys: String, CodingKey { case id, message, arguments }

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let directID = try fields.decodeIfPresent(String.self, forKey: .id)
            let directMessage = try fields.decodeIfPresent(String.self, forKey: .message)
            if directID == nil && directMessage == nil, let arguments = try fields.decodeIfPresent(Input.self, forKey: .arguments) {
                id = arguments.id
                message = arguments.message
            } else {
                id = directID
                message = directMessage
            }
        }
    }
    public var name: String
    public var input: Input?
    public var status: String?
    public var output: String?
    public var startedAt: Double?

    private enum CodingKeys: String, CodingKey { case name, tool, input, arguments, status, output, startedAt = "started_at" }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let directName = try fields.decodeIfPresent(String.self, forKey: .name)
        let toolName = try fields.decodeIfPresent(String.self, forKey: .tool)
        name = directName ?? toolName ?? ""
        let directInput = try fields.decodeIfPresent(Input.self, forKey: .input)
        let argumentInput = try fields.decodeIfPresent(Input.self, forKey: .arguments)
        input = directInput ?? argumentInput
        status = try fields.decodeIfPresent(String.self, forKey: .status)
        output = try fields.decodeIfPresent(String.self, forKey: .output)
        startedAt = try fields.decodeIfPresent(Double.self, forKey: .startedAt)
    }
}
