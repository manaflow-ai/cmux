import CMUXAgentLaunch
import Foundation

/// The bounded process-lineage result attached to one hook event.
struct AgentHookSessionLineage: Sendable, Equatable {
    var runId: String
    var pid: Int?
    var processStartedAt: TimeInterval?
    /// The PID currently resolves to this hook provider's executable, including
    /// an allowlisted interpreter entrypoint. Stop events use this with the
    /// process start time so PID reuse cannot manufacture a new root run.
    var processDescribesAgent: Bool = false
    /// Whether the live provider argv is expected to exit after its turn.
    /// Replay safety is a separate axis and never controls Stop completion.
    var processLaunchMode: AgentProcessLaunchMode = .unknown
    /// Exact app-issued claim inherited by a hibernated resume process.
    var hibernationResumeAttemptId: UUID? = nil
    var cmuxRuntime: AgentCmuxRuntimeIdentity? = nil
    var parentRunId: String?
    var parentSessionId: String?
    var relationship: AgentSessionRelationship?
    var restoreAuthority: Bool
    var authorityEvidence: AgentSessionAuthorityEvidence? = nil
}
