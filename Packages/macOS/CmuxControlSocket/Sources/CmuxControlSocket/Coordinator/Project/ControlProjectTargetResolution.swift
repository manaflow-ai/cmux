/// The outcome of `project.set_selected_target` (the legacy
/// `v2ProjectSetSelectedTarget`).
public enum ControlProjectTargetResolution: Sendable, Equatable {
    /// No project surface resolved for the routing/surface selectors.
    case panelNotFound
    /// The target selection was applied. Carries the resolved target
    /// identifier when a named target matched (else the selection was
    /// cleared).
    case updated(targetID: String?)
}
