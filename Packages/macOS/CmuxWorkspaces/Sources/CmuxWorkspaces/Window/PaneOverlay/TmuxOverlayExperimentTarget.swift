/// Which overlay surface the tmux pane-overlay experiment drives when enabled.
///
/// A pure value enum persisted by raw value in `UserDefaults` (read by
/// ``TmuxOverlayExperimentSettings``). `surface` is the inert default used when
/// the experiment is off; the other cases select between the workspace
/// pane-overlay and the tmux-active-pane overlay rendering paths.
public enum TmuxOverlayExperimentTarget: String, CaseIterable, Codable, Sendable {
    /// No experimental overlay; the legacy per-surface rendering path.
    case surface
    /// Render through the workspace pane overlay (``usesWorkspacePaneOverlay``).
    case bonsplitPane
    /// Render through the tmux-active-pane overlay (``usesTmuxActivePaneOverlay``).
    case tmuxActivePane

    /// True only for ``bonsplitPane``: the workspace pane-overlay path is active.
    public var usesWorkspacePaneOverlay: Bool {
        self == .bonsplitPane
    }

    /// True only for ``tmuxActivePane``: the tmux-active-pane overlay path is active.
    public var usesTmuxActivePaneOverlay: Bool {
        self == .tmuxActivePane
    }
}
