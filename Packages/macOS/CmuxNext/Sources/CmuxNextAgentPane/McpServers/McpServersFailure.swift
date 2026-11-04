import Foundation

/// Why an MCP Servers request did not happen.
public nonisolated enum McpServersFailure: Error, Equatable, Sendable {
    /// No acpmux answered, or it did not accept this app as the person.
    case unavailable
    /// acpmux refused or failed the request (an unknown id, a bad policy, a failed sign-in).
    case refused
}
