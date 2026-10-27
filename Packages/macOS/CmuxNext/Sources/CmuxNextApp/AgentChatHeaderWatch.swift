import CmuxNextAgentPane
import CmuxNextWakeups

/// Pushes a chat header's state to its page whenever it changes (cx-00n1): a split the user closes
/// from its own tab or the strip turns its header button off at once, not on the next pointer move.
/// Observes the store reads `state` makes with one ``FrameObservation``: the changes before one
/// delivery push once; nothing polls.
@MainActor
final class AgentChatHeaderWatch {
    private let state: @MainActor () -> AgentPaneHeaderState
    private let push: (AgentPaneHeaderState) -> Void
    private let work: MainWorkScheduler
    private var observation: FrameObservation<AgentPaneHeaderState>?
    /// The state the page was last given or read.
    private(set) var current = AgentPaneHeaderState()
    /// The last version given out, shared by every chat's watch: a chat rewired with a new watch
    /// (its tab rekeyed) never goes back below what its page already has.
    private static var versions = 0

    init(state: @escaping @MainActor () -> AgentPaneHeaderState, push: @escaping (AgentPaneHeaderState) -> Void,
         on work: MainWorkScheduler) {
        self.state = state
        self.push = push
        self.work = work
    }

    /// The state now, watched from here: the header's wiring starts the watch, and the page's reads
    /// (`pane.tabState`) start it again, so a read made before the store listed the chat still
    /// starts the pushes once it does.
    @discardableResult
    func read() -> AgentPaneHeaderState {
        observation?.cancel()
        // node-free: the header belongs to a page with no visibility node here, and a hidden chat's header must be
        // current when it shows; a change costs one apply.
        let observation = FrameObservation(owner: "agent-chat.header", delivery: .visible(nil), on: work, track: state) { [weak self] next in
            self?.changed(to: next)
        }
        self.observation = observation
        adopt(observation.value)
        return current
    }

    private func changed(to next: AgentPaneHeaderState) {
        let before = current
        adopt(next)
        if current != before { push(current) }
    }

    /// Makes `next` the current state, with the version of the state it shows (a new one when it differs).
    private func adopt(_ next: AgentPaneHeaderState) {
        var next = next
        if next.shows(current) {
            next.version = current.version
        } else {
            Self.versions += 1
            next.version = Self.versions
        }
        current = next
    }
}
