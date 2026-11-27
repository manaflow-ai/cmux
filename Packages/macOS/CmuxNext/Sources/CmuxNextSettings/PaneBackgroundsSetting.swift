/// `appearance.paneBackgrounds`: one background behind the whole window (`shared`, the default)
/// or a copy in each pane (`perPane`); plans/cmux-next/pane-backgrounds-DESIGN.md. A missing key
/// is the default; a bad value is the default plus a diagnostic.
public nonisolated struct PaneBackgroundsSetting: Sendable {
    public init() {}
}
