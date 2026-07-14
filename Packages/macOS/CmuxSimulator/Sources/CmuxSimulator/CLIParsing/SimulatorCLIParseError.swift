/// A user-correctable `cmux simulator` argument error.
public struct SimulatorCLIParseError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The message to print, phrased like the CLI's other usage errors.
    public let message: String

    /// Creates a parse error.
    ///
    /// - Parameter message: The message to print.
    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}
