public import CmuxNextDaemon
public import CmuxNextLayout

/// A new pane opened at a split's divider (Insert New, cmux-layout-reducer `divider_insert`): the split
/// request names the divider's first side's last pane, wraps that whole side when it is more than one
/// pane (`split-around-v1`), and the divider moves so the three panes share its old extent. The split
/// goes through the same path as Split Right and Split Down; only its target, `around` and sizing differ.
public struct DividerInsertion: Sendable, Hashable {
    /// The split the new pane wraps whole (the daemon's handle), or nil to split the target pane alone.
    public let around: CmuxNextDaemon.SplitID?
    /// The sizes the window shows with the new pane (``LayoutModel/showSplitSizing(_:)``) in place of a
    /// split's even sizing; sent once the daemon made the pane.
    public let sizing: [SplitRatioChange]

    public init(around: CmuxNextDaemon.SplitID?, sizing: [SplitRatioChange]) {
        self.around = around
        self.sizing = sizing
    }
}
