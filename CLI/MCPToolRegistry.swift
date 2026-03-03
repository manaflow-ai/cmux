// MCPToolRegistry.swift
// Tool registry and execution

import Foundation

// MARK: - MCPTool Protocol

/// Protocol that all MCP tools must implement
public protocol MCPExecutionTool {
    /// Tool name (e.g., "cmux_identify")
    var name: String { get }

    /// Tool description for the schema
    var description: String { get }

    /// Execute the tool with given arguments
    func execute(arguments: [String: Any]) throws -> MCPToolCallResult

    /// Get the input schema for this tool
    var inputSchema: MCPToolInputSchema { get }
}

// MARK: - Tool Registry

/// Registry for all available MCP tools
public final class MCPToolRegistry {

    // MARK: - Properties

    private var tools: [String: MCPExecutionTool] = [:]
    private let backend: MCPBackend

    // MARK: - Initialization

    public init(backend: MCPBackend) {
        self.backend = backend
        registerDefaultTools()
    }

    // MARK: - Registration

    /// Register a tool
    public func register(_ tool: MCPExecutionTool) {
        tools[tool.name] = tool
    }

    /// List all registered tools
    public func listTools() -> [MCPExecutionTool] {
        return Array(tools.values).sorted { $0.name < $1.name }
    }

    /// List all registered tools as definitions
    public func listToolDefinitions() -> [MCPToolDefinition] {
        return Array(tools.values).sorted { $0.name < $1.name }.map { tool in
            MCPToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema
            )
        }
    }

    /// Get a tool by name
    public func getTool(name: String) -> MCPExecutionTool? {
        return tools[name]
    }

    // MARK: - Execution

    /// Execute a tool by name with arguments
    public func executeTool(name: String, arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let tool = tools[name] else {
            throw MCPError.toolNotFound(name)
        }

        return try tool.execute(arguments: arguments)
    }

    // MARK: - Default Tools Registration

    private func registerDefaultTools() {
        // P0 Tools
        register(IdentifyTool(backend: backend))
        register(ListWorkspacesTool(backend: backend))
        register(ListPanesTool(backend: backend))
        register(ListPaneSurfacesTool(backend: backend))
        register(ReadScreenTool(backend: backend))
        register(SendInputTool(backend: backend))
        register(SendKeyTool(backend: backend))

        // P1 Tools
        register(CreateSplitTool(backend: backend))
        register(FocusPaneTool(backend: backend))
        register(NewWorkspaceTool(backend: backend))
        register(TriggerFlashTool(backend: backend))
        register(ListWindowsTool(backend: backend))
    }
}

// MARK: - Base Tool Implementation Helper

/// Base class for simple tools that just call backend commands
public class SimpleMCPTool: MCPExecutionTool {
    public let name: String
    public let description: String
    public let inputSchema: MCPToolInputSchema
    fileprivate let backend: MCPBackend

    public init(name: String, description: String, inputSchema: MCPToolInputSchema, backend: MCPBackend) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.backend = backend
    }

    public func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        fatalError("Subclasses must implement execute")
    }

    /// Override this to provide the cmux command
    fileprivate func buildCommand(arguments: [String: Any]) throws -> String {
        fatalError("Subclasses must implement buildCommand")
    }

    public func executeCommand(_ command: String) throws -> MCPToolCallResult {
        let result = try backend.executeCommand(command)
        return MCPToolCallResult(content: [.text(result)])
    }
}

// MARK: - P0 Tools

/// cmux_identify - Get current context
public final class IdentifyTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_identify",
            description: "Get current cmux context (workspace and surface IDs)",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref"),
                    "surface": MCPToolProperty(type: "string", description: "Surface ID or ref"),
                    "no_caller": MCPToolProperty(type: "boolean", description: "Skip caller context")
                ]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        var command = "identify --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }
        if let surface = arguments["surface"] as? String, !surface.isEmpty {
            command += " --surface \(surface)"
        }
        if let noCaller = arguments["no_caller"] as? Bool, noCaller {
            command += " --no-caller"
        }

        return try executeCommand(command)
    }
}

/// cmux_list_workspaces - List all workspaces
public final class ListWorkspacesTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_list_workspaces",
            description: "List all workspaces in cmux",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Filter by workspace ID or ref")
                ]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        var command = "list-workspaces --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }

        return try executeCommand(command)
    }
}

/// cmux_list_panes - List all panes
public final class ListPanesTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_list_panes",
            description: "List all panes in a workspace",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref")
                ]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        var command = "list-panes --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }

        return try executeCommand(command)
    }
}

/// cmux_list_pane_surfaces - List surfaces in a pane
public final class ListPaneSurfacesTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_list_pane_surfaces",
            description: "List all surfaces in a pane",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref"),
                    "pane": MCPToolProperty(type: "string", description: "Pane ID or ref")
                ]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        var command = "list-pane-surfaces --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }
        if let pane = arguments["pane"] as? String, !pane.isEmpty {
            command += " --pane \(pane)"
        }

        return try executeCommand(command)
    }
}

/// cmux_read_screen - Read terminal output
public final class ReadScreenTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_read_screen",
            description: "Read terminal screen output from a cmux surface",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref"),
                    "surface": MCPToolProperty(type: "string", description: "Surface ID or ref"),
                    "scrollback": MCPToolProperty(type: "boolean", description: "Include scrollback buffer"),
                    "lines": MCPToolProperty(type: "number", description: "Number of lines to read")
                ]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        var command = "read-screen --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }
        if let surface = arguments["surface"] as? String, !surface.isEmpty {
            command += " --surface \(surface)"
        }
        if let scrollback = arguments["scrollback"] as? Bool, scrollback {
            command += " --scrollback"
        }
        if let lines = arguments["lines"] as? Int {
            command += " --lines \(lines)"
        }

        return try executeCommand(command)
    }
}

/// cmux_send_input - Send input to surface
public final class SendInputTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_send_input",
            description: "Send text input to a cmux surface",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref"),
                    "surface": MCPToolProperty(type: "string", description: "Surface ID or ref"),
                    "text": MCPToolProperty(type: "string", description: "Text to send (required)")
                ],
                required: ["text"]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let text = arguments["text"] as? String else {
            throw MCPError.invalidParameters("Missing required parameter: text")
        }

        // Escape special characters
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
                                 .replacingOccurrences(of: "\n", with: "\\n")
                                 .replacingOccurrences(of: "\r", with: "\\r")
                                 .replacingOccurrences(of: "\t", with: "\\t")

        var command = "send --json \"\(escapedText)\""

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }
        if let surface = arguments["surface"] as? String, !surface.isEmpty {
            command += " --surface \(surface)"
        }

        return try executeCommand(command)
    }
}

/// cmux_send_key - Send key press
public final class SendKeyTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_send_key",
            description: "Send a key press to a cmux surface",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref"),
                    "surface": MCPToolProperty(type: "string", description: "Surface ID or ref"),
                    "key": MCPToolProperty(type: "string", description: "Key name (e.g., 'enter', 'ctrl-c', 'escape')")
                ],
                required: ["key"]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let key = arguments["key"] as? String else {
            throw MCPError.invalidParameters("Missing required parameter: key")
        }

        var command = "send-key --json \(key)"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }
        if let surface = arguments["surface"] as? String, !surface.isEmpty {
            command += " --surface \(surface)"
        }

        return try executeCommand(command)
    }
}

// MARK: - P1 Tools

/// cmux_create_split - Create a split
public final class CreateSplitTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_create_split",
            description: "Create a new split in the workspace",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "direction": MCPToolProperty(type: "string", description: "Direction: left, right, up, down"),
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref"),
                    "surface": MCPToolProperty(type: "string", description: "Surface ID or ref"),
                    "panel": MCPToolProperty(type: "string", description: "Panel ID or ref")
                ],
                required: ["direction"]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let direction = arguments["direction"] as? String else {
            throw MCPError.invalidParameters("Missing required parameter: direction")
        }

        var command = "new-split \(direction) --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }
        if let surface = arguments["surface"] as? String, !surface.isEmpty {
            command += " --surface \(surface)"
        }
        if let panel = arguments["panel"] as? String, !panel.isEmpty {
            command += " --panel \(panel)"
        }

        return try executeCommand(command)
    }
}

/// cmux_focus_pane - Focus a pane
public final class FocusPaneTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_focus_pane",
            description: "Focus a specific pane",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "pane": MCPToolProperty(type: "string", description: "Pane ID or ref (required)"),
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref")
                ],
                required: ["pane"]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let pane = arguments["pane"] as? String else {
            throw MCPError.invalidParameters("Missing required parameter: pane")
        }

        var command = "focus-pane --pane \(pane) --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }

        return try executeCommand(command)
    }
}

/// cmux_new_workspace - Create a new workspace
public final class NewWorkspaceTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_new_workspace",
            description: "Create a new workspace",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "command": MCPToolProperty(type: "string", description: "Command to run in the new workspace")
                ]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        var command = "new-workspace --json"

        if let cmd = arguments["command"] as? String, !cmd.isEmpty {
            command += " --command \"\(cmd)\""
        }

        return try executeCommand(command)
    }
}

/// cmux_trigger_flash - Trigger attention flash
public final class TriggerFlashTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_trigger_flash",
            description: "Trigger a visual attention flash on a surface",
            inputSchema: MCPToolInputSchema(
                properties: [
                    "workspace": MCPToolProperty(type: "string", description: "Workspace ID or ref"),
                    "surface": MCPToolProperty(type: "string", description: "Surface ID or ref")
                ]
            ),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        var command = "trigger-flash --json"

        if let workspace = arguments["workspace"] as? String, !workspace.isEmpty {
            command += " --workspace \(workspace)"
        }
        if let surface = arguments["surface"] as? String, !surface.isEmpty {
            command += " --surface \(surface)"
        }

        return try executeCommand(command)
    }
}

/// cmux_list_windows - List all windows
public final class ListWindowsTool: SimpleMCPTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_list_windows",
            description: "List all top-level windows",
            inputSchema: MCPToolInputSchema(),
            backend: backend
        )
    }

    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        return try executeCommand("list-windows --json")
    }
}
