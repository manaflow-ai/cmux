/// The outcome of the simple project-state setters (`project.set_scheme`,
/// `project.set_configuration`, `project.set_selected_file`,
/// `project.set_settings_filter`).
public enum ControlProjectUpdateResolution: Sendable, Equatable {
    /// No project surface resolved for the routing/surface selectors.
    case panelNotFound
    /// The value was applied.
    case updated
}
