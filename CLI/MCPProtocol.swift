// MCPProtocol.swift
// MCP protocol handling: initialize, tools/list, tools/call

import Foundation

/// Protocol version supported by cmux MCP Server
public let mcpProtocolVersion = "2025-06-18"

/// MCP Protocol Handler
public final class MCPProtocol {

    // MARK: - Properties

    private var isInitialized = false
    private let toolRegistry: MCPToolRegistry
    private let serverInfo: MCPServerInfo

    // MARK: - Initialization

    public init(toolRegistry: MCPToolRegistry, serverInfo: MCPServerInfo = MCPServerInfo(name: "cmux", version: "0.15.0")) {
        self.toolRegistry = toolRegistry
        self.serverInfo = serverInfo
    }

    // MARK: - Message Handling

    /// Process an incoming JSON-RPC message and return the response
    public func processMessage(_ messageData: Data) throws -> Data? {
        // Try to decode as request first
        if let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: messageData) {
            return try handleRequest(request)
        }

        // Try to decode as notification (no response needed)
        if let notification = try? JSONDecoder().decode(JSONRPCNotification.self, from: messageData) {
            handleNotification(notification)
            return nil
        }

        // Invalid JSON
        let error = JSONRPCErrorResponse(
            id: .number(0),
            error: JSONRPCError(code: JSONRPCErrorCode.parseError.rawValue, message: "Parse error")
        )
        return try encodeResponse(error)
    }

    // MARK: - Request Handling

    private func handleRequest(_ request: JSONRPCRequest) throws -> Data {
        // Handle initialize specially (must be first)
        if request.method == "initialize" {
            return try handleInitialize(request)
        }

        // Other methods require initialization
        guard isInitialized else {
            let error = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.serverError.rawValue, message: "Server not initialized. Call initialize first.")
            )
            return try encodeResponse(error)
        }

        // Route to appropriate handler
        switch request.method {
        case "tools/list":
            return try handleToolsList(request)
        case "tools/call", "tools/invoke":
            return try handleToolsCall(request)
        default:
            let error = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.methodNotFound.rawValue, message: "Method not found: \(request.method)")
            )
            return try encodeResponse(error)
        }
    }

    // MARK: - Initialize

    private func handleInitialize(_ request: JSONRPCRequest) throws -> Data {
        // Parse parameters
        guard let params = request.params,
              let protocolVersion = params["protocolVersion"]?.value as? String else {
            let error = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.invalidParams.rawValue, message: "Missing protocolVersion")
            )
            return try encodeResponse(error)
        }

        // Mark as initialized
        isInitialized = true

        // Return capabilities
        let capabilities = MCPCapabilities(
            tools: MCPToolsCapability(listChanged: true),
            resources: nil,
            prompts: nil
        )

        let result = MCPInitializeResult(
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            serverInfo: serverInfo
        )

        let response = try JSONRPCResponse(id: request.id, result: result)
        return try encodeResponse(response)
    }

    // MARK: - Tools List

    private func handleToolsList(_ request: JSONRPCRequest) throws -> Data {
        let tools = toolRegistry.listToolDefinitions()
        let result = MCPToolsListResult(tools: tools)
        let response = try JSONRPCResponse(id: request.id, result: result)
        return try encodeResponse(response)
    }

    // MARK: - Tools Call

    private func handleToolsCall(_ request: JSONRPCRequest) throws -> Data {
        guard let params = request.params else {
            let error = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.invalidParams.rawValue, message: "Missing params")
            )
            return try encodeResponse(error)
        }

        // Extract tool name
        guard let toolName = params["name"]?.value as? String else {
            let error = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.invalidParams.rawValue, message: "Missing tool name")
            )
            return try encodeResponse(error)
        }

        // Extract arguments
        var arguments: [String: Any] = [:]
        if let args = params["arguments"]?.value as? [String: Any] {
            arguments = args
        }

        // Execute tool
        do {
            let result = try toolRegistry.executeTool(name: toolName, arguments: arguments)
            let response = try JSONRPCResponse(id: request.id, result: result)
            return try encodeResponse(response)
        } catch MCPError.toolNotFound(let name) {
            let error = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.methodNotFound.rawValue, message: "Tool not found: \(name)")
            )
            return try encodeResponse(error)
        } catch MCPError.invalidParameters(let message) {
            let error = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.invalidParams.rawValue, message: message)
            )
            return try encodeResponse(error)
        } catch {
            let errResp = JSONRPCErrorResponse(
                id: request.id,
                error: JSONRPCError(code: JSONRPCErrorCode.internalError.rawValue, message: error.localizedDescription)
            )
            return try encodeResponse(errResp)
        }
    }

    // MARK: - Notification Handling

    private func handleNotification(_ notification: JSONRPCNotification) {
        // Handle initialized notification
        if notification.method == "initialized" {
            // Server side doesn't need to do anything special
            return
        }

        // Ignore other notifications
    }

    // MARK: - Encoding

    private func encodeResponse<T: Encodable>(_ response: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(response)
    }
}

// MARK: - MCP Errors

public enum MCPError: Error, LocalizedError {
    case toolNotFound(String)
    case invalidParameters(String)
    case executionFailed(String)
    case transportError(String)
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .invalidParameters(let message):
            return "Invalid parameters: \(message)"
        case .executionFailed(let message):
            return "Execution failed: \(message)"
        case .transportError(let message):
            return "Transport error: \(message)"
        case .notInitialized:
            return "Server not initialized"
        }
    }
}
