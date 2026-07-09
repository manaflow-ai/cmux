/// The value description of the application dock menu the app delegate returns
/// from `applicationDockMenu(_:)`. The witness materializes `items` in order
/// into an `NSMenu`.
public struct DockMenuSpec: Sendable, Equatable {
    /// The dock-menu items, in display order.
    public var items: [AppMenuItemSpec]

    public init(items: [AppMenuItemSpec]) {
        self.items = items
    }
}
