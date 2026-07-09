public import Bonsplit

/// Where a dropped tab should split an existing browser pane: the split
/// orientation and whether the dropped tab takes the first (leading/top) slot.
/// `nil` at the action level means "insert into the pane" rather than split it.
public struct BrowserPaneSplitTarget: Equatable {
    public let orientation: SplitOrientation
    public let insertFirst: Bool

    public init(orientation: SplitOrientation, insertFirst: Bool) {
        self.orientation = orientation
        self.insertFirst = insertFirst
    }
}
