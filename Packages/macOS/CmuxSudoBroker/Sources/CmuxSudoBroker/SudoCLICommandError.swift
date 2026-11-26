/// A localized command-line failure with a stable process exit code.
public struct SudoCLICommandError: Error, CustomStringConvertible, Sendable {
    /// The localized diagnostic written to standard error.
    public let message: String

    /// The process exit code used by the `cmux` CLI.
    public let exitCode: Int32

    /// Creates a command-line failure.
    ///
    /// - Parameters:
    ///   - message: The localized diagnostic written to standard error.
    ///   - exitCode: The stable process exit code, defaulting to general failure.
    public init(message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    /// The localized diagnostic.
    public var description: String { message }
}
