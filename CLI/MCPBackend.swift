// MCPBackend.swift
// Backend for executing cmux commands via Unix Socket

import Foundation

/// Backend for communicating with cmux daemon
public final class MCPBackend {

    // MARK: - Properties

    private let socketPath: String
    private let password: String?
    private let idFormat: String

    // MARK: - Initialization

    public init(socketPath: String = "/tmp/cmux.sock", password: String? = nil, idFormat: String = "refs") {
        self.socketPath = socketPath
        self.password = password
        self.idFormat = idFormat
    }

    // MARK: - Command Execution

    /// Execute a cmux command and return the result
    public func executeCommand(_ command: String) throws -> String {
        // Build command arguments
        var args = command.split(separator: " ").map(String.init)

        // Add common flags
        args.append("--socket")
        args.append(socketPath)
        args.append("--id-format")
        args.append(idFormat)

        // Add password if provided
        if let password = password, !password.isEmpty {
            args.append("--password")
            args.append(password)
        }

        // Execute via Process
        let result = try runProcess("/Applications/cmux.app/Contents/Resources/bin/cmux", arguments: args)

        return result
    }

    // MARK: - Process Execution

    private func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Set up environment
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        if let password = password {
            environment["CMUX_SOCKET_PASSWORD"] = password
        }
        process.environment = environment

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MCPError.executionFailed("Failed to run cmux: \(error.localizedDescription)")
        }

        // Get output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        // Check exit code
        if process.terminationStatus != 0 {
            // Try to extract error message from JSON output
            if let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                throw MCPError.executionFailed(error)
            }

            let message = errorOutput.isEmpty ? "Command failed with exit code \(process.terminationStatus)" : errorOutput
            throw MCPError.executionFailed(message)
        }

        return output
    }

    // MARK: - Utility Methods

    /// Test connection to cmux daemon
    public func ping() throws -> Bool {
        let result = try executeCommand("ping")
        return result.contains("pong")
    }

    /// Get cmux version
    public func version() throws -> String {
        return try executeCommand("version")
    }
}

// MARK: - Command Builder

/// Helper for building cmux commands
public final class CMUXCommandBuilder {
    private var components: [String] = []

    public init() {}

    public func add(_ component: String) -> CMUXCommandBuilder {
        components.append(component)
        return self
    }

    public func addFlag(_ flag: String, value: String?) -> CMUXCommandBuilder {
        if let v = value, !v.isEmpty {
            components.append(flag)
            components.append(v)
        }
        return self
    }

    public func addFlag(_ flag: String, value: Bool) -> CMUXCommandBuilder {
        if value {
            components.append(flag)
        }
        return self
    }

    public func build() -> String {
        return components.joined(separator: " ")
    }
}
