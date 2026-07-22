/// Completed transcript position for one session's automatic artifact capture.
struct AgentArtifactCaptureCheckpoint: Sendable {
    let transcriptLineage: String
    let transcriptExtent: UInt64
    let referenceCursor: AgentArtifactReferenceCursor?
}
