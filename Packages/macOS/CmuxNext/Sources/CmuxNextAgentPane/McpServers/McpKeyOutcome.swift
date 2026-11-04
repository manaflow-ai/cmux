import Foundation

/// What acpmux did with a key the person gave a connection (`_acpmux/mcp_set_key`).
public nonisolated enum McpKeyOutcome: Equatable, Sendable {
    /// The server took the key and listed its tools: the key is in the secret store.
    case connected
    /// The server did not take the key; acpmux kept nothing.
    case refused
}
