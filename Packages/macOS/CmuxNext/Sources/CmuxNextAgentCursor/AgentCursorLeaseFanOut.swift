/// Lease frames to cursor state: one router for all leases of a host, and
/// every overlay model that may draw a session's cursor (each workspace
/// content, shown and parked). A tab close, release, stop or session end is
/// a clear frame, so no cursor stays on screen for a closed tab.
public final class AgentCursorLeaseFanOut {
    private var router = AgentCursorLeaseRouter()
    private let models: () -> [AgentCursorOverlayModel]

    public init(models: @escaping () -> [AgentCursorOverlayModel]) {
        self.models = models
    }

    /// One lease frame: `session` nil is a clear.
    public func leaseChanged(target: String, session: String?, wireState: String?) {
        let updates = router.leaseChanged(target: target, session: session, wireState: wireState)
        guard !updates.isEmpty else { return }
        let all = models()
        for update in updates {
            for model in all {
                model.leaseDidChange(session: update.session, state: update.state)
            }
        }
    }
}
