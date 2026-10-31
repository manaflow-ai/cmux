import Foundation

/// A function the voice model may call during a Chief call.
public struct VoiceCallTool: Sendable, Equatable {
    public enum Name: String, Sendable, CaseIterable {
        case sendToChief = "send_to_chief"
        case readChiefMessages = "read_chief_messages"
        case listWorkspaces = "list_workspaces"
        case listNeedsAttention = "list_needs_attention"
        case endCall = "end_call"
    }

    public var name: Name
    public var description: String
    /// The JSON Schema of the arguments, as JSON text.
    public var parameters: String

    public init(name: Name, description: String, parameters: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var json: [String: Any] {
        let schema = (try? JSONSerialization.jsonObject(with: Data(parameters.utf8))) ?? [:]
        return ["type": "function", "name": name.rawValue, "description": description, "parameters": schema]
    }

    private static let noArguments = #"{"type":"object","properties":{},"additionalProperties":false}"#

    public static let all: [VoiceCallTool] = [
        VoiceCallTool(
            name: .sendToChief,
            description: "Send a message to Chief's agent on the user's Mac, exactly like typing it in the Chief chat. "
                + "Use it for any real work: changing code, running commands or tests, starting, steering or stopping agents, "
                + "opening pull requests. Its replies come back later as system messages starting with \"Chief replied:\".",
            parameters: #"{"type":"object","properties":{"message":{"type":"string","description":"The instruction, self-contained, in the user's voice."}},"required":["message"],"additionalProperties":false}"#
        ),
        VoiceCallTool(
            name: .readChiefMessages,
            description: "Read the newest messages of the Chief chat, oldest first.",
            parameters: #"{"type":"object","properties":{"count":{"type":"integer","description":"How many messages, 1 to 20.","minimum":1,"maximum":20}},"additionalProperties":false}"#
        ),
        VoiceCallTool(
            name: .listWorkspaces,
            description: "List the user's workspaces on their Macs: name, Mac, folder, branch, and which agents are working or waiting.",
            parameters: noArguments
        ),
        VoiceCallTool(
            name: .listNeedsAttention,
            description: "List the agents waiting on the user (permission requests and questions) and recently finished or failed runs.",
            parameters: noArguments
        ),
        VoiceCallTool(
            name: .endCall,
            description: "Hang up the call. Say goodbye first.",
            parameters: noArguments
        ),
    ]
}

/// What running a tool produced: the output for the model, and a line for
/// the call screen ("Sent to Chief: …"), when the user should see it.
public struct VoiceCallToolResult: Sendable, Equatable {
    /// JSON text returned to the model as the `function_call_output`.
    public var output: String
    public var activity: String?

    public init(output: String, activity: String? = nil) {
        self.output = output
        self.activity = activity
    }

    /// A JSON object as the output.
    public init(object: [String: Any], activity: String? = nil) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.init(output: String(decoding: data, as: UTF8.self), activity: activity)
    }
}

/// The app side of a Chief call: Chief's conversation, the workspaces and the
/// Feed. The call session runs the model's function calls against it.
@MainActor
public protocol VoiceCallToolbox: AnyObject {
    /// What Chief's voice is told when the call starts.
    func briefing() -> VoiceCallBriefing
    func sendToChief(_ message: String) async -> VoiceCallToolResult
    func readChiefMessages(count: Int) -> VoiceCallToolResult
    func listWorkspaces() -> VoiceCallToolResult
    func listNeedsAttention() -> VoiceCallToolResult
}
