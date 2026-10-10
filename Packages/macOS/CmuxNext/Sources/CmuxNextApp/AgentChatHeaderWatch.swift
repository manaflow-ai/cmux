import CmuxNextAgentPane
import Observation

/// Pushes a chat header's state to its page whenever it changes (cx-00n1): a split the user closes
/// from its own tab or the strip turns its header button off at once, not on the next pointer move.
/// Observes the store reads `state` makes, re-armed after each change; nothing polls.
@MainActor
final class AgentChatHeaderWatch {
    private let state: () -> AgentPaneHeaderState
    private let push: (AgentPaneHeaderState) -> Void
    /// Each arming's number: a change seen by an older one (the page read again meanwhile) is
    /// dropped, so reads never add watchers.
    private var generation = 0
    /// The state the page was last given or read.
    private(set) var current = AgentPaneHeaderState()

    init(state: @escaping () -> AgentPaneHeaderState, push: @escaping (AgentPaneHeaderState) -> Void) {
        self.state = state
        self.push = push
    }

    /// The page's read (`pane.tabState`, when a chat opens): the state now, watched from here, so
    /// a read made before the store listed the chat still starts the pushes once it does.
    func read() -> AgentPaneHeaderState {
        arm()
        return current
    }

    private func arm() {
        generation += 1
        let armed = generation
        let state = state
        current = withObservationTracking { state() } onChange: { [weak self] in
            // task-owner: one hop per observed change, re-arms itself; ends with the watch
            Task { @MainActor [weak self] in
                guard let self, generation == armed else { return }
                changed()
            }
        }
    }

    private func changed() {
        let before = current
        arm()
        if current != before { push(current) }
    }
}
