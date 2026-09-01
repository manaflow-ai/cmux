import Foundation

/// A process-generation-validated owner of one managed Vault session.
///
/// This identity is deliberately independent of terminal scope. A process that
/// escaped through `nohup`, `setsid`, or a daemonized multiplexer can still own
/// its agent session even though it is no longer safe to treat as a child of the
/// original surface for teardown or hibernation.
struct LiveAgentSessionOwner: Sendable {
    let kind: String
    let sessionID: String
    let processID: Int
    let processIdentity: AgentPIDProcessIdentity
    let workspaceID: UUID
    let surfaceID: UUID
    let observedAt: TimeInterval
    let validationSnapshot: SessionRestorableAgentSnapshot
    let hermesSessionValidation: CachedAgentProcessIdentityValidator.HermesSessionValidation
}
