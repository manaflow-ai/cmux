/// A typed, non-shell command that callers may run as a long-lived process.
///
/// Video recording and live log streaming need explicit cancellation signals,
/// so the one-shot ``SimulatorControlService`` returns their exact executable
/// and argument vector instead of hiding them behind a capture timeout.
public struct SimulatorCommandDescriptor: Equatable, Sendable {
    /// The absolute executable path.
    public let executable: String
    /// Arguments passed verbatim to the executable.
    public let arguments: [String]

    /// Creates a command descriptor.
    /// - Parameters:
    ///   - executable: The absolute executable path.
    ///   - arguments: Arguments passed verbatim to the executable.
    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}
