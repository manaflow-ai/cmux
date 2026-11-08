/// Axis of a split in the remote tmux layout domain.
public enum RemoteTmuxSplitOrientation: Sendable, Equatable {
    case horizontal
    case vertical

    /// Stable wire/tree spelling used at UI and tmux command boundaries.
    public var treeName: String {
        self == .horizontal ? "horizontal" : "vertical"
    }
}
