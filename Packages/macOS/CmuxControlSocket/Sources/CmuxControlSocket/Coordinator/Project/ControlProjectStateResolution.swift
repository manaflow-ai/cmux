/// The outcome of `project.get_state` (the legacy `v2ProjectGetState`).
public enum ControlProjectStateResolution: Sendable, Equatable {
    /// No project surface resolved for the routing/surface selectors.
    case panelNotFound
    /// The state snapshot.
    case state(ControlProjectStateSnapshot)
}
