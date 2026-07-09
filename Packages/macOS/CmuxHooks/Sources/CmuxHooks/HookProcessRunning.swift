public import Foundation

/// Runs one configured hook process.
public protocol HookProcessRunning: Sendable {
    /// Executes a hook process.
    /// - Parameters:
    ///   - command: Absolute path or command name to execute.
    ///   - arguments: Arguments passed to the command.
    ///   - stdin: Bytes written to the hook's stdin.
    ///   - timeout: Deadline for the hook process.
    /// - Returns: Captured process output and terminal status.
    func run(command: String, arguments: [String], stdin: Data, timeout: Duration) async -> HookProcessResult
}
