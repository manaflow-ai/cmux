/// `appearance.paneBackgrounds`: one background behind the whole window, or a copy in every pane
/// (plans/cmux-next/pane-backgrounds-DESIGN.md).
public nonisolated enum PaneBackgroundMode: String, CaseIterable, Sendable {
    /// One background behind everything (the default, R48's one backdrop).
    case shared
    /// Each pane draws its own copy of the background, framed to the pane.
    case perPane
}
