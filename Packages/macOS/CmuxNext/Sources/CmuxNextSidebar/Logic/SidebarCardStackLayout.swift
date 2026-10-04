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
        let visible = cards.filter { $0.alwaysVisible || revealed }
        guard !visible.isEmpty else { return Self(placements: [], height: 0) }
        if expanded {
            let placements = visible.enumerated().map { index, card in
                Placement(id: card.id, frame: CGRect(x: 0, y: CGFloat(index) * (cardHeight + spacing), width: width, height: cardHeight),
                          depth: index, isPeek: false)
            }
            return Self(placements: placements, height: CGFloat(visible.count) * cardHeight + CGFloat(visible.count - 1) * spacing)
        }
        let shown = visible.prefix(maxPeeks + 1)
        let placements = shown.enumerated().map { depth, card in
            let inset = CGFloat(depth) * peekInset
            return Placement(id: card.id, frame: CGRect(x: inset, y: CGFloat(depth) * peek, width: max(0, width - 2 * inset), height: cardHeight),
                             depth: depth, isPeek: depth > 0)
        }
        return Self(placements: placements, height: cardHeight + CGFloat(shown.count - 1) * peek)
    }
}
