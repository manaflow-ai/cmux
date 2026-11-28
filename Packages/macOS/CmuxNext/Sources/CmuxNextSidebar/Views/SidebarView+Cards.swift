import AppKit

/// The R114 card stack fills the sidebar lead's `footerCards` slot: from
/// the bottom up the Settings band, the spaces dots (R112), then the cards.
extension SidebarView {
    func installCardStack() {
        let model = model
        cardStack.onAction = { id, action in model.onCardAction?(id, action) }
        cardStack.onHeightChange = { [weak self] in self?.needsLayout = true }
        cardStack.follow(model)
        footerCards = cardStack
    }
}
