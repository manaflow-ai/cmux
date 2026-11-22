/// Anything that draws cursors for lease sessions: an overlay model, or a
/// window slot (which forwards to its stack once it exists).
@MainActor
public protocol AgentCursorLeaseTarget: AnyObject {
    func leaseDidChange(session: String, state: AgentCursorLeaseState?)
    /// `session` no longer holds `target`'s lease; it may still hold others.
    func leaseEnded(target: String, session: String)
}

extension AgentCursorOverlayModel: AgentCursorLeaseTarget {}
extension AgentCursorWindowSlot: AgentCursorLeaseTarget {}

/// Lease frames to cursor state: one router for all leases of a host, and
/// every overlay model that may draw a session's cursor (each workspace
/// content, shown and parked). A tab close, release, stop or session end is
/// a clear frame, so no cursor stays on screen for a closed tab.
public final class AgentCursorLeaseFanOut {
    private var router = AgentCursorLeaseRouter()
    private let models: () -> [AgentCursorLeaseTarget]

    public init(models: @escaping () -> [AgentCursorLeaseTarget]) {
        self.models = models
    }

    /// One lease frame: `session` nil is a clear.
    public func leaseChanged(target: String, session: String?, wireState: String?) {
        let previous = router.holder(of: target)
        let updates = router.leaseChanged(target: target, session: session, wireState: wireState)
        // The session that held the target may hold other targets still: its cursor leaves
        // this one all the same, so no cursor stays on a tab no agent drives.
        let left = previous.flatMap { $0 != session ? $0 : nil }
        guard !updates.isEmpty || left != nil else { return }
        let all = models()
        if let left {
            for model in all {
                model.leaseEnded(target: target, session: left)
            }
        }
        for update in updates {
            for model in all {
                model.leaseDidChange(session: update.session, state: update.state)
            }
        }
    }
}
