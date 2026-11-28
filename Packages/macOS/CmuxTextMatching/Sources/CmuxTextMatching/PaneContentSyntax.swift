/// How a pane-content query is read.
public enum PaneContentSyntax: String, Sendable, CaseIterable {
    /// A literal substring.
    case text
    /// A shell glob that may match anywhere in the line, as tmux `find-window` reads it.
    case glob
    /// A regular expression, as tmux `find-window -r` reads it.
    case regex
}
