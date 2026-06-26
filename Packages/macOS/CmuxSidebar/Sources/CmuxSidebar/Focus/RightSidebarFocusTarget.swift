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

extension RightSidebarFocusTarget {
    /// The focus endpoint the right sidebar should drive for `mode`. List-style
    /// modes target their first selectable item when `focusFirstItem` is true,
    /// otherwise the mode's fallback host view.
    public static func forMode(
        _ mode: RightSidebarMode,
        focusFirstItem: Bool
    ) -> RightSidebarFocusTarget {
        switch mode {
        case .files:
            return .outline
        case .find:
            return .searchField
        case .sessions:
            return .host
        case .feed:
            return focusFirstItem ? .firstItem : .host
        case .dock:
            return focusFirstItem ? .firstItem : .host
        }
    }
}
