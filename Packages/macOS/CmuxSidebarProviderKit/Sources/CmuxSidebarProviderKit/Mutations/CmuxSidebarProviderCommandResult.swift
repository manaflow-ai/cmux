import Foundation

/// Result returned after CMUX handles a provider mutation.
public struct CmuxSidebarProviderCommandResult: Codable, Equatable, Sendable {
    /// Whether CMUX accepted and completed the command.
    public var ok: Bool

    /// Creates a command result.
    public init(ok: Bool) {
        self.ok = ok
    }
}
