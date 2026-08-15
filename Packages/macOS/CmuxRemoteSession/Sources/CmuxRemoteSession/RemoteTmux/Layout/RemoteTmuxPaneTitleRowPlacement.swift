/// The configured window edge where tmux draws pane status rows.
public enum RemoteTmuxPaneTitleRowPlacement: String, Equatable, Sendable {
    /// Status rows occupy the top edge of panes touching the window's top edge.
    case top
    /// Status rows occupy the bottom edge of panes touching the window's bottom edge.
    case bottom

    /// Returns the panes that lose one grid row to this placement.
    public func paneIDs(in layout: RemoteTmuxLayoutNode) -> Set<Int> {
        let leaves = layout.leavesByPaneID
        guard !leaves.isEmpty else { return [] }
        switch self {
        case .top:
            let edge = leaves.values.map(\.y).min()
            return Set(leaves.compactMap { paneID, leaf in
                leaf.y == edge ? paneID : nil
            })
        case .bottom:
            let edge = leaves.values.map { $0.y + $0.height }.max()
            return Set(leaves.compactMap { paneID, leaf in
                leaf.y + leaf.height == edge ? paneID : nil
            })
        }
    }

    /// Infers placement from a patched full-window tree rooted at tmux row zero.
    static func inferred(in layout: RemoteTmuxLayoutNode) -> Self? {
        let leaves = layout.leavesByPaneID.values
        guard let top = leaves.map(\.y).min() else { return nil }
        return top > 0 ? .top : .bottom
    }
}
