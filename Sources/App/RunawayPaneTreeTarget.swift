import CmuxMemoryPressure

/// A pane whose terminal session was selected as the runaway consumer.
struct RunawayPaneTreeTarget: Equatable, Sendable {
    let key: PaneMemoryPaneKey
    let selection: RunawaySessionSelection
}
