public import Foundation

/// Immutable snapshot of the feed's keyboard-focus state that the main-window
/// focus controller publishes to the feed host view: which item is selected and
/// whether the feed currently owns keyboard focus.
public struct FeedFocusSnapshot: Equatable {
    /// The selected feed item, or `nil` when no feed item is selected.
    public var selectedItemId: UUID?
    /// Whether the feed currently owns active keyboard focus.
    public var isKeyboardActive: Bool

    /// Creates a feed focus snapshot.
    /// - Parameters:
    ///   - selectedItemId: The selected feed item, or `nil` for no selection.
    ///   - isKeyboardActive: Whether the feed owns active keyboard focus.
    public init(selectedItemId: UUID? = nil, isKeyboardActive: Bool = false) {
        self.selectedItemId = selectedItemId
        self.isKeyboardActive = isKeyboardActive
    }
}
