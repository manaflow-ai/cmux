/// Evidence captured immediately before a preservation request.
public enum AgentContextHandoffVerificationBaseline: Equatable, Sendable {
    /// No handoff file existed at the pre-request snapshot boundary.
    case missing
    /// A file existed; the post-request snapshot must differ from this exact
    /// identity/content fingerprint before clear can proceed.
    case existing(AgentContextHandoffFileFingerprint)
    /// The pre-request path could not be inspected safely, so verification must
    /// fail closed.
    case unavailable
}
