internal import Foundation

/// A `simctl` invocation that launched but exited with a non-zero status.
public struct SimctlCommandFailure: Error, Sendable, CustomStringConvertible {
    /// The `simctl` arguments that were run (without the `xcrun simctl` prefix).
    public let arguments: [String]
    /// The process's termination status.
    public let exitCode: Int32
    /// The process's stderr, trimmed, for diagnostics.
    public let standardErrorText: String

    /// Creates a failure record.
    ///
    /// - Parameters:
    ///   - arguments: The `simctl` arguments that were run.
    ///   - exitCode: The process's termination status.
    ///   - standardErrorText: The process's stderr, trimmed.
    public init(arguments: [String], exitCode: Int32, standardErrorText: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardErrorText = standardErrorText
    }

    public var description: String {
        let detail = standardErrorText.isEmpty ? "" : ": \(standardErrorText)"
        return "simctl \(arguments.joined(separator: " ")) exited \(exitCode)\(detail)"
    }
}
