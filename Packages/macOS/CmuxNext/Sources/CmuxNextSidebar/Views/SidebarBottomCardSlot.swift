import AppKit
import CmuxNextDesign

/// UPDATE-CARD + BOTTOM-LEFT-CARDS K1 + cx-7py7: one card slot directly
/// above the footer (the spaces dots and the account row below it), under
/// the R114 card stack: the staged update card first, else the "cmux
/// Updated!" card, else the shared notice card (the update status or the
/// "Did you know" tip; the App picks one), never two. They are
/// the sidebar's own views, not band items, so minimal mode's band fade
/// never hides them. Without a card the slot takes no room; the footer
/// controls never move (Lawrence: controls fixed, the card space above them
/// may appear and disappear).
struct SidebarBottomCardSlot {
    let update: SidebarUpdateCardView
    let updated: SidebarUpdatedCardView
    let notice: SidebarNoticeCardView

    /// Adds the views to `sidebar` and routes their actions to its model.
    func install(in sidebar: SidebarView) {
        update.onInstall = { [weak sidebar] in sidebar?.model.send(.installUpdate) }
        update.onAutomaticUpdates = { [weak sidebar] on in sidebar?.model.send(.setAutomaticUpdates(on)) }
        update.onOpenLink = { [weak sidebar] url in sidebar?.model.send(.openUpdateLink(url)) }
        updated.whatsNewRow.onPress = { [weak sidebar] in sidebar?.model.send(.openWhatsNew) }
        updated.shareRow.onPress = { [weak sidebar] in sidebar?.model.send(.shareCmux) }
        updated.closeButton.onPress = { [weak sidebar] in sidebar?.model.send(.dismissUpdated) }
        notice.onAction = { [weak sidebar] card, action in sidebar?.model.send(.noticeAction(card: card, action: action)) }
        notice.onDismiss = { [weak sidebar] card in sidebar?.model.send(.dismissNotice(card)) }
        sidebar.addSubview(update)
        sidebar.addSubview(updated)
        sidebar.addSubview(notice)
    }

    /// Shows the cards the model holds (the slot picks one).
    func show(_ cards: SidebarBottomCards) {
        update.configure(cards.update)
        updated.configure(cards.updated)
        notice.configure(cards.notice)
    }

    private enum Shown { case update, updated, notice }

    /// The card that has the slot: update, then updated, then the notice.
    private var shown: Shown? {
        if update.card != nil { return .update }
        if updated.card != nil { return .updated }
        return notice.notice != nil ? .notice : nil
    }

    /// The notice card shows only while no other card does.
    var showsNotice: Bool { shown == .notice }

    /// The room the slot takes above the footer: its card and a gap above
    /// and below it; 0 without a card.
    var height: CGFloat {
        switch shown {
        case .update: (update.card.map(SidebarUpdateCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case .updated: SidebarUpdatedCardView.height + 2 * Metrics.space2
        case .notice: (notice.notice.map(SidebarNoticeCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case nil: 0
        }
    }

    /// Lays the card out in the slot, which ends at `bottom`, inset like the
    /// card stack's cards across a sidebar `width` wide.
    func place(above bottom: CGFloat, width sidebarWidth: CGFloat, slotHeight: CGFloat) {
        let inset = Metrics.space3, width = max(0, sidebarWidth - 2 * inset)
        let shown = slotHeight > 0 ? shown : nil
        func frame(_ which: Shown, height: CGFloat) -> NSRect {
            shown == which ? NSRect(x: inset, y: bottom - Metrics.space2 - height, width: width, height: height).integral : .zero
        }
        notice.isHidden = shown != .notice
        updated.isHidden = shown != .updated
        update.frame = frame(.update, height: update.card.map(SidebarUpdateCardView.height(for:)) ?? 0)
        updated.frame = frame(.updated, height: SidebarUpdatedCardView.height)
        notice.frame = frame(.notice, height: notice.notice.map(SidebarNoticeCardView.height(for:)) ?? 0)
    }
}
