import Foundation

/// Metadata and bounded bytes read from one handoff-file descriptor.
struct AgentContextHandoffFileSnapshot: Sendable {
    /// Metadata captured from the descriptor that produced ``data``.
    let metadata: AgentContextHandoffFileMetadata
    /// Bytes read from that same descriptor, bounded by the verifier.
    let data: Data
}
