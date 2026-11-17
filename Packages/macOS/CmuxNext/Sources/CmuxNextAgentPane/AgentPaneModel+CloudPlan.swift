import Foundation

/// The pricing card's Subscribe (`cloud.plan.subscribe {plan}`, webviews CloudStartView.tsx): Pro or Max, through the one
/// upgrade path, on the person's click.
extension AgentPaneModel {
    /// The plans `cloud.plan.subscribe` takes.
    static let subscribablePlans: Set<String> = Set(AgentPaneCloudPlanRefusal.plans)

    /// `cloud.plan.subscribe {plan}`: the pricing card's Subscribe runs the one upgrade path (`palette.pro.upgrade`,
    /// its checkout opening in the browser) with that plan, on the person's click. Any plan but `pro` or `max` is refused.
    func subscribeToCloudPlan(_ plan: String) -> [String: Any] {
        guard Self.subscribablePlans.contains(plan), let onRunAction else { return Self.unsupported("cloud.plan.subscribe") }
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        switch onRunAction("palette.pro.upgrade", ["source": "cloudRefusal", "plan": plan]) {
        case .ran: return AgentPaneReply.success(["opened": true])
        case .refused(let reason): return Self.refused(reason)
        case .notRun: return AgentPaneReply.failure(code: "unavailable", message: "The app did not open the plan's checkout.")
        }
    }
}
