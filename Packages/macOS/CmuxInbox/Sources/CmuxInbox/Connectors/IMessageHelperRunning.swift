public import Foundation

/// Runs the `cmux-imsg` helper process.
public protocol IMessageHelperRunning: Sendable {
    /// Runs a helper command.
    /// - Parameters:
    ///   - helperURL: Executable URL.
    ///   - arguments: Process arguments.
    ///   - stdin: Optional stdin bytes.
    func run(helperURL: URL, arguments: [String], stdin: Data?) async throws -> Data
}
