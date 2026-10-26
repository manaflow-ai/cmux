import CmuxNextSettings

/// Diff Colors (`diff.colors`, Settings > Diff Viewer) reaches the page as the `diffColors` event,
/// read by the page's diffColors.ts, so the Changes view colors added and removed lines as the
/// diff tabs do.
extension AgentPageEvent {
    /// `"theme"`, `"muted"` or `"standard"`.
    public static func diffColors(_ colors: String) -> AgentPageEvent {
        AgentPageEvent(kind: "diffColors", value: .string(colors))
    }
}

extension AgentPaneView {
    /// Gives the page Diff Colors (a change only); the model keeps it for a new page.
    public func pushDiffColors(_ colors: String) {
        guard colors != model.diffColors else { return }
        model.diffColors = colors
        deliver([.diffColors(colors)])
    }
}
