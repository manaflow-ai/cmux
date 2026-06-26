/// The specific endpoint the right sidebar should drive keyboard focus to when a
/// focus request is honored for a given ``RightSidebarMode``.
public enum RightSidebarFocusTarget: Equatable {
    /// The mode's fallback keyboard-focus host view.
    case host
    /// The files outline view.
    case outline
    /// The search text field.
    case searchField
    /// The mode's first selectable item.
    case firstItem
}
