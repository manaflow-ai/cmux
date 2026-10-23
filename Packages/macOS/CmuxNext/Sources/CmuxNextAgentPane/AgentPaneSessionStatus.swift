import CmuxNextCompat
import CmuxNextDesign
import Observation

/// The in-session status cards (Claude Code desktop's live plan card and recap card) behind the
/// `agent.sessionStatus` Debug Settings toggle (``AgentPaneTunables/sessionStatus``): each agent
/// view follows the tunable and pushes each change to its page, without a reload. A page that loads
/// again gets the value with the rest of the view's state (``AgentPanePageHost/currentEvents(_:)``,
/// and the old host's load and `ready` replays). Kept off ``AgentPaneView``, whose type is at its size limit.
enum AgentPaneSessionStatus {
    /// The script that tells a loaded page on the old host whether the cards show.
    static func script(_ on: Bool) -> String {
        "window.cmuxAcpmuxBridge?.applySessionStatus?.(\(on));"
    }

    /// Pushes `view`'s ``AgentPaneView/sessionStatus`` to its page.
    @MainActor static func push(to view: AgentPaneView) {
        view.deliver([.sessionStatus(view.sessionStatus)], scripts: [script(view.sessionStatus)])
    }

    /// Follows the tunable for `view` for as long as the view lives.
    @MainActor static func follow(_ view: AgentPaneView) -> Task<Void, Never> {
        // task-owner: the view (stored on it as an OwnedTask); cancelled in its close() and on its release; event-driven (Observation)
        Task { [weak view] in
            for await on in ObservationStream({ AgentPaneTunables.sessionStatus.value }) {
                guard let view else { return }
                view.sessionStatus = on
            }
        }
    }
}
