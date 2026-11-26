import Foundation

/// Result of a subprocess launched in a dedicated, parent-supervised process group.
public struct SimulatorOwnedCommandResult: Sendable, Equatable {
    /// The child process exit status, or the synthesized timeout status.
    public let status: Int32
    /// Bounded stderr text captured from the child process.
    public let standardError: String
    /// Whether the command exceeded its execution deadline.
    public let timedOut: Bool

    /// Creates the bounded result of one owned subprocess.
    public init(
        status: Int32,
        standardError: String,
        timedOut: Bool
    ) {
        self.status = status
        self.standardError = standardError
        self.timedOut = timedOut
    }
}
