import CoreGraphics

/// Frames of the card stack (pure): collapsed, the front card with up to
/// ``maxPeeks`` cards peeking below it, each narrower; expanded (hover),
/// every card in a column. Cards that are not always visible show only
/// while the sidebar is revealed.
nonisolated struct SidebarCardStackLayout: Equatable {
    static let maxPeeks = 2
    /// How far each card behind shows under the one in front.
    static let peek: CGFloat = 4
    /// How much narrower each card behind is, per side.
    static let peekInset: CGFloat = 6
    static let spacing: CGFloat = 6

    struct Placement: Equatable {
        var id: String
        var frame: CGRect
        /// 0 is the front card.
        var depth: Int
        /// Behind the front card while collapsed: no content, no clicks.
        var isPeek: Bool
    }

    var placements: [Placement]
    var height: CGFloat

    static func layout(_ cards: [SidebarCard], revealed: Bool, expanded: Bool, width: CGFloat, cardHeight: CGFloat) -> Self {
        Self(placements: [], height: 0)
    }
}
