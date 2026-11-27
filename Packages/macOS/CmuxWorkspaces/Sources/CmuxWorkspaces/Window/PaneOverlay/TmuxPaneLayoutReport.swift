/// A tmux pane layout report: the full set of panes tmux reported for a surface.
public struct TmuxPaneLayoutReport: Codable, Equatable, Sendable {
    /// All panes tmux reported, in tmux's order.
    public let panes: [TmuxPaneLayoutPane]

    /// Creates a layout report.
    /// - Parameter panes: the reported panes.
    public init(panes: [TmuxPaneLayoutPane]) {
        self.panes = panes
    }

    /// The active pane, or the first pane when none is marked active.
    public var activePane: TmuxPaneLayoutPane? {
        panes.first(where: \.isActive) ?? panes.first
    }
}
