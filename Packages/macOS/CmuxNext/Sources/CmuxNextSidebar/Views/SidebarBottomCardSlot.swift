import AppKit
import CmuxNextDesign

/// UPDATE-CARD + BOTTOM-LEFT-CARDS K1 + cx-7py7: one card slot directly
/// above the footer (the spaces dots and the account row below it), under
/// the R114 card stack: the staged update card first, else the answer to
/// something the person just asked for (an update check's notice,
/// ``SidebarNoticeCard/userAsked``), else the Now Playing
/// card (cx-ouoxo), else the "cmux Updated!" card, else the shared notice card (the update status or the
/// "Did you know" tip; the App picks one), never two. They are
/// the sidebar's own views, not band items, so minimal mode's band fade
/// never hides them. Without a card the slot takes no room; the footer
/// controls never move (Lawrence: controls fixed, the card space above them
/// may appear and disappear).
struct SidebarBottomCardSlot {
    let update: SidebarUpdateCardView
    let nowPlaying: SidebarNowPlayingCardView
    let updated: SidebarUpdatedCardHost
    let notice: SidebarNoticeCardView

    /// Adds the views to `sidebar` and routes their actions to its model.
    func install(in sidebar: SidebarView) {
        update.onInstall = { [weak sidebar] in sidebar?.model.send(.installUpdate) }
        update.onAutomaticUpdates = { [weak sidebar] on in sidebar?.model.send(.setAutomaticUpdates(on)) }
        update.onOpenChanges = { [weak sidebar] in sidebar?.model.send(.openUpdateChanges) }
        update.onCloseAction = { [weak sidebar] card, action in sidebar?.model.send(.noticeAction(card: card, action: action)) }
        // The highlights show in the app's one hover card window (one card at a time).
        update.hoverCards = { [weak sidebar] in sidebar?.list.hoverCards }
        notice.onAction = { [weak sidebar] card, action in sidebar?.model.send(.noticeAction(card: card, action: action)) }
        notice.onDismiss = { [weak sidebar] card in sidebar?.model.send(.dismissNotice(card)) }
        nowPlaying.onCommand = { [weak sidebar] command in sidebar?.model.send(.nowPlaying(command)) }
        nowPlaying.onClose = { [weak sidebar] in sidebar?.model.send(.hideNowPlayingCard) }
        nowPlaying.menuProvider = { [weak sidebar] in sidebar?.contextMenuProvider?(.nowPlaying) }
        updated.onDismiss = { [weak sidebar] in sidebar?.model.send(.dismissUpdated) }
        sidebar.addSubview(update)
        sidebar.addSubview(nowPlaying)
        sidebar.addSubview(updated)
        sidebar.addSubview(notice)
    }

    /// Shows the cards the model holds (the slot picks one).
    func show(_ cards: SidebarBottomCards) {
        update.configure(cards.update)
        nowPlaying.configure(cards.nowPlaying)
        updated.configure(cards.updated)
        notice.configure(cards.notice)
    }

    private enum Shown { case update, nowPlaying, updated, notice }

    /// The card that has the slot: a question waiting on the person, then update, then an asked-for notice,
    /// then Now Playing, then updated, then any other notice.
    private var shown: Shown? {
        // An agent waiting on the person's answer never hides behind another card.
        if notice.notice?.awaitsAnswer == true { return .notice }
        if update.card != nil { return .update }
        // "Is it checking?" must never hide behind a song (Lawrence 2026-10-19).
        if notice.notice?.userAsked == true { return .notice }
        if nowPlaying.nowPlaying != nil { return .nowPlaying }
        // The React card's actions go to the App through its page; it shows once it has drawn.
        if updated.card != nil, updated.height > 0 { return .updated }
        return notice.notice != nil ? .notice : nil
    }

    /// The notice card shows only while no other card does.
    var showsNotice: Bool { shown == .notice }

    /// The room the slot takes above the footer: its card and a gap above
    /// and below it; 0 without a card.
    var height: CGFloat {
        switch shown {
        case .update: (update.card.map(SidebarUpdateCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case .nowPlaying: (nowPlaying.nowPlaying.map(SidebarNowPlayingCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case .updated: updated.height + 2 * Metrics.space2
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
        nowPlaying.isHidden = shown != .nowPlaying
        nowPlaying.frame = frame(.nowPlaying, height: nowPlaying.nowPlaying.map(SidebarNowPlayingCardView.height(for:)) ?? 0)
        updated.isHidden = shown != .updated
        updated.frame = frame(.updated, height: updated.height)
        // A card playing its exit (``SidebarCardPresence``) keeps its place until it has gone.
        if shown == .update || !update.isLeaving {
            update.frame = frame(.update, height: update.card.map(SidebarUpdateCardView.height(for:)) ?? 0)
        }
        notice.presence.setShown(shown == .notice)
        if shown == .notice || !notice.isLeaving {
            notice.frame = frame(.notice, height: notice.notice.map(SidebarNoticeCardView.height(for:)) ?? 0)
        }
    }
}
