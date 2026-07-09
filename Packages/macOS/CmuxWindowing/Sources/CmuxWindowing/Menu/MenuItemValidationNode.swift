/// A Sendable, value-tree snapshot of one node in a live `NSMenu`, used by
/// ``AppMenuCoordinator`` to make menu-validation and shortcut-disable decisions
/// without reaching into AppKit. Each node carries the item's action selector
/// name (`item.action` rendered via `NSStringFromSelector`, or `nil` when the
/// item has no action) and, when the item has a submenu, the recursively
/// snapshotted child nodes (`nil` for a leaf item).
///
/// The app-side witness builds this tree from the live menu before each
/// decision, then maps the coordinator's returned `IndexPath`s back onto the
/// concrete `NSMenuItem`s to perform the live mutation. Keeping the projection a
/// plain value tree means the decision logic carries no AppKit dependency and is
/// directly testable.
public struct MenuItemValidationNode: Sendable, Equatable {
    /// The item's action selector rendered as a string (`NSStringFromSelector`),
    /// or `nil` when the item has no action. Compared by string because selector
    /// name equality matches selector equality for registered selectors.
    public let actionSelectorName: String?

    /// The recursively snapshotted child nodes when the item has a submenu, or
    /// `nil` for a leaf item with no submenu.
    public let submenu: [MenuItemValidationNode]?

    public init(actionSelectorName: String?, submenu: [MenuItemValidationNode]?) {
        self.actionSelectorName = actionSelectorName
        self.submenu = submenu
    }
}
