import Foundation

// MARK: - Schema types

struct VoiceToolSchema: Codable {
    var type: String
    var properties: [String: VoiceToolProperty]?
    var required: [String]?
}

struct VoiceToolProperty: Codable {
    var type: String
    var description: String?
}

// MARK: - Tool definition

struct VoiceToolDefinition: Codable {
    let type: String
    let name: String
    let description: String
    let parameters: VoiceToolSchema

    init(name: String, description: String, parameters: VoiceToolSchema) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Tool call from server

struct VoiceToolCall: Decodable {
    let callId: String
    let name: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case name
        case arguments
    }
}

// MARK: - All tools

enum VoiceToolDefinitions {
    static let all: [VoiceToolDefinition] = [
        VoiceToolDefinition(
            name: "get_app_state",
            description: "Returns the list of open workspaces and tabs. Call this before any navigation action.",
            parameters: VoiceToolSchema(type: "object", properties: [:], required: [])
        ),
        VoiceToolDefinition(
            name: "switch_workspace",
            description: "Switch to a workspace by its id.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["id": VoiceToolProperty(type: "string", description: "Workspace UUID from get_app_state")],
                required: ["id"]
            )
        ),
        VoiceToolDefinition(
            name: "switch_tab",
            description: "Switch to a tab by its id in the current workspace.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["id": VoiceToolProperty(type: "string", description: "Tab UUID from get_app_state")],
                required: ["id"]
            )
        ),
        VoiceToolDefinition(
            name: "type_text",
            description: "Inject text into the active terminal without pressing Enter.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["text": VoiceToolProperty(type: "string", description: "Text to inject")],
                required: ["text"]
            )
        ),
        VoiceToolDefinition(
            name: "execute_command",
            description: "Inject text into the active terminal and press Enter to run it.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["command": VoiceToolProperty(type: "string", description: "Command to run")],
                required: ["command"]
            )
        ),
        VoiceToolDefinition(
            name: "create_workspace",
            description: "Create a new workspace (tab), optionally with a custom name.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["name": VoiceToolProperty(type: "string", description: "Optional name for the new workspace")],
                required: []
            )
        ),
        VoiceToolDefinition(
            name: "close_workspace",
            description: "Close a workspace by its id. Omit id to close the currently active workspace.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: ["id": VoiceToolProperty(type: "string", description: "Workspace UUID from get_app_state, or omit for current")],
                required: []
            )
        ),
        VoiceToolDefinition(
            name: "rename_workspace",
            description: "Set a custom name on a workspace.",
            parameters: VoiceToolSchema(
                type: "object",
                properties: [
                    "id": VoiceToolProperty(type: "string", description: "Workspace UUID from get_app_state"),
                    "name": VoiceToolProperty(type: "string", description: "New name for the workspace"),
                ],
                required: ["id", "name"]
            )
        ),
    ]
}
