import Foundation

/// One validated argument that can be typed in a readable `cmux restore` command.
public struct AgentRestoreCLIArgument: RawRepresentable, Equatable, Sendable {
    /// The validated shell-token-safe argument.
    public let rawValue: String

    /// Validates a restore kind or checkpoint identifier for unquoted shell transport.
    ///
    /// Leading hyphens and characters requiring shell quoting are rejected so
    /// startup input cannot be reinterpreted as options or multiple tokens.
    ///
    /// - Parameter rawValue: An already normalized binding kind or checkpoint identifier.
    /// - Returns: `nil` when the value is empty or unsafe for unquoted shell transport.
    public init?(rawValue: String) {
        guard rawValue.range(
            of: "^[A-Za-z0-9._:+][A-Za-z0-9._:+-]*$",
            options: .regularExpression
        ) != nil else {
            return nil
        }
        self.rawValue = rawValue
    }
}
