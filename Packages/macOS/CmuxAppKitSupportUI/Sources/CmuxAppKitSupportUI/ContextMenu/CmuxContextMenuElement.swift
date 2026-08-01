/// One element of an AppKit-backed context menu: a button-style item or a
/// separator. Mirrors the small subset of SwiftUI `Button` / `Divider` that the
/// migrated row menus actually use.
public enum CmuxContextMenuElement {
    /// A button-style item carrying its own action.
    case item(CmuxContextMenuItem)
    /// A divider between groups of items. Leading, trailing, and consecutive
    /// separators are suppressed when the menu is built, matching SwiftUI.
    case separator

    /// Creates a button-style menu element.
    ///
    /// - Parameters:
    ///   - title: The localized title shown for the item.
    ///   - systemImage: Optional SF Symbol name for the leading image.
    ///   - isEnabled: Whether the item is selectable (defaults to `true`).
    ///   - action: Closure invoked on the main actor when the item is chosen.
    public init(
        button title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self = .item(
            CmuxContextMenuItem(
                title: title,
                systemImage: systemImage,
                isEnabled: isEnabled,
                action: action
            )
        )
    }
}
