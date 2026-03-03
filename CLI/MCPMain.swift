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
    let inputStream = FileHandle.standardInput
    let outputStream = FileHandle.standardOutput
    let errorStream = FileHandle.standardError

    // Read input line by line
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 65536)
    defer { buffer.deallocate() }

    // Use FileHandle to read lines
    while true {
        // Read a line from stdin
        guard let line = readLine() else {
            // EOF or error
            break
        }

        // Skip empty lines
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        // Convert to Data
        guard let data = trimmed.data(using: .utf8) else {
            continue
        }

        // Process message
        if let responseData = try? protocolHandler.processMessage(data) {
            // Write response with newline
            var output = responseData
            output.append(contentsOf: "\n".utf8)
            outputStream.write(output)
            outputStream.synchronizeFile()
        }
    }
}

/// Read a line from stdin (simple implementation)
private func readLine() -> String? {
    var buffer = [UInt8]()
    let stdin = FileHandle.standardInput

    while true {
        let data = stdin.availableData
        if data.isEmpty {
            // EOF
            return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8)
        }

        buffer.append(contentsOf: data)

        // Check for newline
        if let newlineIndex = buffer.firstIndex(of: 10) { // \n
            let line = Data(buffer[0..<newlineIndex])
            buffer.removeSubrange(0...newlineIndex)

            // Remove \r if present
            if let crIndex = line.lastIndex(of: 13), line[crIndex] == 13 { // \r
                return String(bytes: line[0..<crIndex], encoding: .utf8)
            }

            return String(bytes: line, encoding: .utf8)
        }

        // If buffer is too large, return what we have
        if buffer.count > 65536 {
            let line = Data(buffer)
            buffer.removeAll()
            return String(bytes: line, encoding: .utf8)
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
