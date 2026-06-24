public import Bonsplit

/// Describes the split a browser-pane drop should create relative to the target
/// pane: the split orientation and whether the dragged tab lands first.
public struct BrowserPaneSplitTarget: Equatable, Sendable {
    /// The orientation of the split to create.
    public let orientation: SplitOrientation
    /// Whether the dropped pane is inserted before the existing pane.
    public let insertFirst: Bool

    /// Creates a split target descriptor.
    public init(orientation: SplitOrientation, insertFirst: Bool) {
        self.orientation = orientation
        self.insertFirst = insertFirst
    }
}
