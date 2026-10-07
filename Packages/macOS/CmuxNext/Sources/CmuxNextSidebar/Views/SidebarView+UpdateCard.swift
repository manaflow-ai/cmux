import AppKit
import CmuxNextDesign

// UPDATE-CARD + BOTTOM-LEFT-CARDS K1: one card slot directly above the
// footer (the spaces dots and the account row below it), under the R114
// card stack: the staged update card first, else the "Did you know" tip
// card, never both. They are the sidebar's own views, not band items, so
// minimal mode's band fade never hides them. Without a card the slot takes
// no room; the footer controls never move (Lawrence: controls fixed, the
// card space above them may appear and disappear).
extension SidebarView {
    func installUpdateCard() {
        let card = updateCardView
        card.onInstall = { [weak self] in self?.model.send(.installUpdate) }
        card.onAutomaticUpdates = { [weak self] on in self?.model.send(.setAutomaticUpdates(on)) }
        card.onOpenLink = { [weak self] url in self?.model.send(.openUpdateLink(url)) }
        addSubview(card)
        tipCardView.onTry = { [weak self] id in self?.model.send(.tryTip(id)) }
        tipCardView.onDismiss = { [weak self] id in self?.model.send(.dismissTip(id)) }
        addSubview(tipCardView)
    }

    /// The tip card shows only while no update card does.
    var showsTipCard: Bool { false }  // red: K1 not implemented

    /// The room the card takes above the footer: the card and a gap above
    /// and below it; 0 without a staged update.
    var updateCardSlotHeight: CGFloat {
        if updateCardView.card != nil { return SidebarUpdateCardView.height + 2 * Metrics.space2 }
        return showsTipCard ? SidebarTipCardView.height + 2 * Metrics.space2 : 0
    }

    /// Lays the card out in its slot, which ends at `bottom`, inset like the
    /// card stack's cards.
    func placeUpdateCard(above bottom: CGFloat, slotHeight: CGFloat) {
        let inset = Metrics.space3, width = max(0, bounds.width - 2 * inset)
        let showsUpdate = slotHeight > 0 && updateCardView.card != nil
        let showsTip = slotHeight > 0 && !showsUpdate && showsTipCard
        tipCardView.isHidden = !showsTip
        updateCardView.frame = showsUpdate
            ? NSRect(x: inset, y: bottom - Metrics.space2 - SidebarUpdateCardView.height, width: width,
                     height: SidebarUpdateCardView.height).integral
            : .zero
        tipCardView.frame = showsTip
            ? NSRect(x: inset, y: bottom - Metrics.space2 - SidebarTipCardView.height, width: width,
                     height: SidebarTipCardView.height).integral
            : .zero
    }
}
