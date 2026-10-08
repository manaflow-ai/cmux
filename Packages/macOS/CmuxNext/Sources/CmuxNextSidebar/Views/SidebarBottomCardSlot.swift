import AppKit
import CmuxNextDesign

/// UPDATE-CARD + BOTTOM-LEFT-CARDS K1: one card slot directly above the
/// footer (the spaces dots and the account row below it), under the R114
/// card stack: the staged update card first, else the "Did you know" tip
/// card, never both. They are the sidebar's own views, not band items, so
/// minimal mode's band fade never hides them. Without a card the slot takes
/// no room; the footer controls never move (Lawrence: controls fixed, the
/// card space above them may appear and disappear).
struct SidebarBottomCardSlot {
    let update: SidebarUpdateCardView
    let tip: SidebarTipCardView

    /// Adds both views to `sidebar` and routes their actions to its model.
    func install(in sidebar: SidebarView) {
        update.onInstall = { [weak sidebar] in sidebar?.model.send(.installUpdate) }
        update.onAutomaticUpdates = { [weak sidebar] on in sidebar?.model.send(.setAutomaticUpdates(on)) }
        update.onOpenLink = { [weak sidebar] url in sidebar?.model.send(.openUpdateLink(url)) }
        tip.onTry = { [weak sidebar] id in sidebar?.model.send(.tryTip(id)) }
        tip.onDismiss = { [weak sidebar] id in sidebar?.model.send(.dismissTip(id)) }
        sidebar.addSubview(update)
        sidebar.addSubview(tip)
    }

    /// Shows the cards the model holds (the slot picks one).
    func show(_ cards: SidebarBottomCards) {
        update.configure(cards.update)
        tip.configure(cards.tip)
    }

    /// The tip card shows only while no update card does.
    var showsTip: Bool { update.card == nil && tip.tip != nil }

    /// The room the slot takes above the footer: its card and a gap above
    /// and below it; 0 without a card.
    var height: CGFloat {
        if update.card != nil { return SidebarUpdateCardView.height + 2 * Metrics.space2 }
        return showsTip ? SidebarTipCardView.height + 2 * Metrics.space2 : 0
    }

    /// Lays the card out in the slot, which ends at `bottom`, inset like the
    /// card stack's cards across a sidebar `width` wide.
    func place(above bottom: CGFloat, width sidebarWidth: CGFloat, slotHeight: CGFloat) {
        let inset = Metrics.space3, width = max(0, sidebarWidth - 2 * inset)
        let showsUpdate = slotHeight > 0 && update.card != nil
        let showsTipCard = slotHeight > 0 && !showsUpdate && showsTip
        tip.isHidden = !showsTipCard
        update.frame = showsUpdate
            ? NSRect(x: inset, y: bottom - Metrics.space2 - SidebarUpdateCardView.height, width: width,
                     height: SidebarUpdateCardView.height).integral
            : .zero
        tip.frame = showsTipCard
            ? NSRect(x: inset, y: bottom - Metrics.space2 - SidebarTipCardView.height, width: width,
                     height: SidebarTipCardView.height).integral
            : .zero
    }
}
