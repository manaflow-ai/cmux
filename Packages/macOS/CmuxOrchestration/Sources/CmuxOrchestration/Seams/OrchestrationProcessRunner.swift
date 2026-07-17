import Foundation

/// Result of one external process run.
public struct OrchestrationProcessResult: Sendable, Hashable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Process seam for substrate provisioning (git worktree/clone commands and
/// template provision scripts), so the provisioner is unit-testable with a
/// recording fake.
public protocol OrchestrationProcessRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        environment: [String: String]?
    ) throws -> OrchestrationProcessResult
}

/// Foundation `Process`-backed runner resolving executables through
/// `/usr/bin/env`.
public struct DefaultOrchestrationProcessRunner: OrchestrationProcessRunner {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        environment: [String: String]?
    ) throws -> OrchestrationProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return OrchestrationProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
