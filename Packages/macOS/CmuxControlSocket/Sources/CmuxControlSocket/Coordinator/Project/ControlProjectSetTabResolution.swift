/// The outcome of `project.set_tab` (the legacy `v2ProjectSetTab`).
public enum ControlProjectSetTabResolution: Sendable, Equatable {
    /// No project surface resolved for the routing/surface selectors.
    case panelNotFound
    /// The `tab` param did not name a known project tab.
    case invalidTab
    /// The tab was set. Carries the resolved tab's raw value.
    case set(tab: String)
}
