/// Whether a pane-content query respects case.
public enum PaneContentCaseMode: String, Sendable, CaseIterable {
    /// Ignore case unless the query contains an uppercase letter.
    case smart
    /// Always ignore case, like tmux `find-window -i`.
    case ignore
    /// Always respect case, like tmux `find-window` without `-i`.
    case respect
}
