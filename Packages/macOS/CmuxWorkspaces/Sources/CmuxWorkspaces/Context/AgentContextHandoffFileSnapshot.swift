import Foundation

/// Metadata and bounded bytes read from one handoff-file descriptor.
struct AgentContextHandoffFileSnapshot: Sendable {
    /// Metadata captured from the descriptor that produced ``data``.
    let metadata: AgentContextHandoffFileMetadata
    /// Bytes read from that same descriptor. The adapter may include one
    /// sentinel byte beyond the requested limit so the verifier can reject
    /// growth instead of silently accepting a truncated file.
    let data: Data
}
