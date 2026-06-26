/// The outcome of preparing a hibernated agent panel for resume.
///
/// Returned by the live panel's `prepareAgentHibernationResume()` and flattened by the
/// `AgentHibernationHosting` seam into the `(didResume:queuedStartupInput:)` tuple the
/// `AgentHibernationCoordinator` resume body consumes. The enum encodes the subset
/// relationship structurally: a queued-startup-input flag only exists once a resume has
/// actually proceeded, so `queuedStartupInput` is an associated value of `.resumed` rather
/// than a separate field that could be set without a resume.
public enum AgentHibernationResumePreparation: Sendable, Equatable {
    /// No hibernation state was present, so nothing was resumed.
    case unavailable

    /// The panel's hibernation resume proceeded.
    ///
    /// - Parameter queuedStartupInput: whether the resume queued startup input to replay
    ///   into the freshly resumed surface.
    case resumed(queuedStartupInput: Bool)

    /// Whether the resume actually proceeded (`true` only for `.resumed`).
    public var didResume: Bool {
        if case .resumed = self { return true }
        return false
    }

    /// Whether the resume queued startup input (`false` unless `.resumed` carried a queued flag).
    public var queuedStartupInput: Bool {
        if case .resumed(let queuedStartupInput) = self { return queuedStartupInput }
        return false
    }
}
