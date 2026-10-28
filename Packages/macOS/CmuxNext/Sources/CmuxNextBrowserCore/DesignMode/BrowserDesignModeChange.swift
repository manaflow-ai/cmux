/// What one design mode message changed for a tab's cards (``BrowserDesignModeCards/change(_:pageURL:)``).
public nonisolated struct BrowserDesignModeChange: Sendable, Equatable {
    /// New highlights, and highlights whose edits changed (same id: the chip is replaced).
    public let cards: [BrowserDesignModeCard]
    /// The ids of cards whose highlight left the page.
    public let removed: [String]

    public init(cards: [BrowserDesignModeCard], removed: [String]) {
        self.cards = cards
        self.removed = removed
    }
}
