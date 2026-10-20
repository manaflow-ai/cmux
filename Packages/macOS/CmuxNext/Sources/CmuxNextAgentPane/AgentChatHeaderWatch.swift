import Observation

/// Pushes a chat header's state to its page whenever it changes (cx-00n1): a split the user closes
/// from its own tab or the strip turns its header button off at once, not on the next pointer move.
/// Observes the store reads `state` makes, re-armed after each change; nothing polls.
@MainActor
package final class AgentChatHeaderWatch {
    private let state: @MainActor () -> AgentPaneHeaderState
    private let push: @MainActor (AgentPaneHeaderState) -> Void
    /// Each arming's number: a change seen by an older one (the page read again meanwhile) is
    /// dropped, so reads never add watchers.
    private var generation = 0
    /// The state the page was last given or read.
    private(set) var current = AgentPaneHeaderState()
    /// The last version given out, shared by every chat's watch: a chat rewired with a new watch
    /// (its tab rekeyed) never goes back below what its page already has.
    private static var versions = 0

    package init(state: @escaping @MainActor () -> AgentPaneHeaderState,
                 push: @escaping @MainActor (AgentPaneHeaderState) -> Void) {
        self.state = state
        self.push = push
    }

    /// The state now, watched from here: the header's wiring arms it, and the page's reads
    /// (`pane.tabState`) re-arm it, so a read made before the store listed the chat still starts
    /// the pushes once it does.
    @discardableResult
    package func read() -> AgentPaneHeaderState {
        arm()
        return current
    }

    private func arm() {
        generation += 1
        let armed = generation
        let state = state
        var next = withObservationTracking { state() } onChange: { [weak self] in
            // task-owner: one hop per observed change, re-arms itself; ends with the watch
            Task { @MainActor [weak self] in
                guard let self, generation == armed else { return }
                changed()
            }
        }
        if next.shows(current) {
            next.version = current.version
        } else {
            Self.versions += 1
            next.version = Self.versions
        }
        current = next
    }

    private func changed() {
        let before = current
        arm()
        if current != before { push(current) }
    }
}
