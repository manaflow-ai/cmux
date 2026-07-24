/// A cmux UI surface whose visibility gates subrouter polling.
///
/// The store polls at panel cadence while ``agentsPanel`` is visible, at the
/// slower background cadence while only ``footerSwitcher`` is visible, and
/// not at all while the set is empty.
public enum SubrouterVisibleSurface: Sendable, Hashable, CaseIterable {
    /// The right-sidebar Agents panel (fast cadence).
    case agentsPanel
    /// The left-sidebar footer account switcher (slow cadence). The app
    /// registers it only while the app itself is active.
    case footerSwitcher
}
