/// A single button-style item in an AppKit-backed context menu.
///
/// Holds value-typed presentation data plus a `@MainActor` action closure, so a
/// row can describe its menu with immutable snapshots and closures only. This
/// keeps adopters compatible with the snapshot-boundary / `Equatable` row
/// contracts used by churny list views.
public struct CmuxContextMenuItem {
    /// The localized title shown for the menu item.
    public let title: String
    /// Optional SF Symbol name shown as the item's leading image.
    public let systemImage: String?
    /// Whether the item is selectable; disabled items carry no action.
    public let isEnabled: Bool
    /// Invoked on the main actor when the item is chosen.
    public let action: @MainActor () -> Void

    /// Creates a context-menu item.
    /// - Parameters:
    ///   - title: The localized title shown for the item.
    ///   - systemImage: Optional SF Symbol name for the leading image.
    ///   - isEnabled: Whether the item is selectable (defaults to `true`).
    ///   - action: Closure invoked on the main actor when the item is chosen.
    public init(
        title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }
}
