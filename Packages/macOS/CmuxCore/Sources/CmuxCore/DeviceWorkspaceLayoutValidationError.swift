/// A layout cannot safely describe a single workspace's existing terminals.
public enum DeviceWorkspaceLayoutValidationError: Error, Equatable, Sendable {
    /// A pane is empty, unnamed, or selects a terminal outside that pane.
    case invalidPane
    /// A divider is non-finite or would leave a child with no space.
    case invalidSplitRatio
    /// A terminal appears more than once in the proposed tree.
    case duplicateSurface
    /// A local panel has no corresponding terminal on the owning Mac.
    case unmappedSurface
    /// The tree exceeds the bounded depth or terminal count.
    case limitExceeded
}
