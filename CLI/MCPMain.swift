// MCPMain.swift
// MCP Server main entry point: stdio loop and CLI integration

import Foundation

// MARK: - MCP Server Mode

/// MCP Server mode entry point
public func runMCPServer(socketPath: String = "/tmp/cmux.sock", password: String? = nil, idFormat: String = "refs") {
    // Initialize backend
    let backend = MCPBackend(socketPath: socketPath, password: password, idFormat: idFormat)

    // Initialize tool registry
    let toolRegistry = MCPToolRegistry(backend: backend)

    // Initialize protocol handler
    let protocolHandler = MCPProtocol(toolRegistry: toolRegistry)

    // Run stdio loop
    runStdIOLoop(protocolHandler: protocolHandler)
}

// MARK: - stdio Loop

/// Run the stdio message loop
private func runStdIOLoop(protocolHandler: MCPProtocol) {
    let outputStream = FileHandle.standardOutput
    let errorStream = FileHandle.standardError

    // Use Swift stdlib readLine() for line-buffered stdin reading
    while let line = Swift.readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        guard let data = trimmed.data(using: .utf8) else {
            continue
        }

        do {
            if let responseData = try protocolHandler.processMessage(data) {
                var output = responseData
                output.append(contentsOf: "\n".utf8)
                outputStream.write(output)
            }
        } catch {
            // Return a JSON-RPC error response so the client doesn't hang.
            // Also log to stderr for debugging.
            errorStream.write("MCP error: \(error)\n".data(using: .utf8) ?? Data())
            let errResp = JSONRPCErrorResponse(
                id: .number(0),
                error: JSONRPCError(
                    code: JSONRPCErrorCode.internalError.rawValue,
                    message: "Internal error: \(error.localizedDescription)"
                )
            )
            if let errData = try? JSONEncoder().encode(errResp) {
                var output = errData
                output.append(contentsOf: "\n".utf8)
                outputStream.write(output)
            }
        }
    }
}

// MARK: - CLI Integration

/// Main entry point when running as `cmux --mcp`
public struct MCMain {
    public static func main(args: [String] = CommandLine.arguments) {
        // Parse arguments
        var socketPath = "/tmp/cmux.sock"
        var password: String? = nil
        var idFormat = "refs"
        var debug = false

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--socket":
                if i + 1 < args.count {
                    socketPath = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--password":
                if i + 1 < args.count {
                    password = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--id-format":
                if i + 1 < args.count {
                    idFormat = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--debug":
                debug = true
                i += 1
            default:
                i += 1
            }
        }

        if debug {
            // Write debug messages to stderr
            let stderr = FileHandle.standardError
            let debugMsg = "cmux MCP Server starting...\n"
            stderr.write(debugMsg.data(using: .utf8)!)
        }

        // Run MCP server
        runMCPServer(socketPath: socketPath, password: password, idFormat: idFormat)
    }
}
