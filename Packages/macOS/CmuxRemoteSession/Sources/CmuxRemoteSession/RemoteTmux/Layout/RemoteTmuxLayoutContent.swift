public enum RemoteTmuxLayoutContent: Sendable, Equatable {
    /// A leaf pane, identified by its numeric tmux pane id (the `%N` without the
    /// leading `%`).
    case pane(Int)

    /// A left-to-right split of child nodes.
    case horizontal([RemoteTmuxLayoutNode])

    /// A top-to-bottom split of child nodes.
    case vertical([RemoteTmuxLayoutNode])
}
