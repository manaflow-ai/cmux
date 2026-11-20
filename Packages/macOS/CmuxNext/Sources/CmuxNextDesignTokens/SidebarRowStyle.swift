/// `experiments.sidebarRowStyle` in cmux.json: an off-by-default sidebar row restyle under
/// Settings > Experimental (taste build 7, 2026-11-19). Off draws today's rows. Every other
/// style draws the rows on one rule set and differs only in how the selected row reads:
///
/// - full-width hover and selection band at any indent (the content indents, the band does not);
/// - project group headers semibold with one leading chevron, workspace rows regular weight;
/// - pin and close on hover; a tooltip for a truncated title on hover and keyboard focus;
/// - one "+ New workspace" row at the top of the list.
///
/// - `capsule`: the selected row is an accent capsule with a light label.
/// - `bar`: a leading accent bar and a semibold label, no fill.
/// - `soft`: a quiet soft fill, the label unchanged.
public nonisolated enum SidebarRowStyle: String, Sendable, CaseIterable, Codable {
    case off
    case capsule
    case bar
    case soft

    /// Whether the restyle is on (any style but `off`).
    public var isOn: Bool { self != .off }
}
