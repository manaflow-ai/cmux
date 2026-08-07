/// Last fully or partially persisted artifact-capture state for one chat session.
struct AgentArtifactCompletedCaptureState: Sendable {
    let revision: UInt64?
    let checkpoint: AgentArtifactCaptureCheckpoint?
}
