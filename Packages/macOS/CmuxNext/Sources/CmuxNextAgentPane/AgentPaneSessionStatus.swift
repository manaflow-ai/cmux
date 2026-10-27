import CmuxNextDesign
import CmuxNextWakeups
import Observation

/// The in-session status cards (Claude Code desktop's live plan card and recap card) behind the
/// `agent.sessionStatus` Debug Settings toggle (``AgentPaneTunables/sessionStatus``): each agent
/// view follows the tunable and pushes each change to its page, without a reload. A page that loads
/// again gets the value with the rest of the view's state (``AgentPanePageHost/currentEvents(_:)``).
/// Kept off ``AgentPaneView``, whose type is at its size limit.
enum AgentPaneSessionStatus {
    /// Pushes `view`'s ``AgentPaneView/sessionStatus`` to its page.
    @MainActor static func push(to view: AgentPaneView) {
        view.deliver([.sessionStatus(view.sessionStatus)])
    }

    /// Follows the tunable for `view` while the view holds the token (cancelled in its close() and deinit). A
    /// service observation, not a view one: the push goes to the page's own process, which applies it shown or
    /// hidden, so a page shown later draws the current cards (Chrome sends preference changes to every renderer,
    /// `WebContentsImpl::OnWebPreferencesChanged`).
    @MainActor static func follow(_ view: AgentPaneView) -> ServiceObservation<Bool> {
        ServiceObservation(.visible, owner: "AgentPaneSessionStatus.tunable", on: view.model.deadlines.work) {
            AgentPaneTunables.sessionStatus.value
        } apply: { [weak view] on in
            view?.sessionStatus = on
        }
    }
}
