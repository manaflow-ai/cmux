import AppKit
import CmuxNextDesign

/// UPDATE-CARD + BOTTOM-LEFT-CARDS K1 + cx-7py7: one card slot directly
/// above the footer (the spaces dots and the account row below it), under
/// the R114 card stack: the staged update card first, else the answer to
/// something the person just asked for (an update check's notice,
/// ``SidebarNoticeCard/userAsked``), else the Now Playing
/// card (cx-ouoxo), else the shared notice card (the update status or the
/// "Did you know" tip; the App picks one), never two. They are
/// the sidebar's own views, not band items, so minimal mode's band fade
/// never hides them. Without a card the slot takes no room; the footer
/// controls never move (Lawrence: controls fixed, the card space above them
/// may appear and disappear).
struct SidebarBottomCardSlot {
    let update: SidebarUpdateCardView
    let nowPlaying: SidebarNowPlayingCardView
    let notice: SidebarNoticeCardView

    /// Adds the views to `sidebar` and routes their actions to its model.
    func install(in sidebar: SidebarView) {
        update.onInstall = { [weak sidebar] in sidebar?.model.send(.installUpdate) }
        update.onAutomaticUpdates = { [weak sidebar] on in sidebar?.model.send(.setAutomaticUpdates(on)) }
        update.onOpenChanges = { [weak sidebar] in sidebar?.model.send(.openUpdateChanges) }
        update.onCloseAction = { [weak sidebar] card, action in sidebar?.model.send(.noticeAction(card: card, action: action)) }
        // The highlights show in the app's one hover card window (one card at a time).
        update.hoverCards = { [weak sidebar] in sidebar?.list.hoverCards }
        notice.onAction = { [weak sidebar] card, action in
            // The restoring card's Details opens app health's card.
            if card == "restoring", action == SidebarNoticeCard.detailsAction, let open = sidebar?.onHealthDetails {
                open()
                return
            }
            sidebar?.model.send(.noticeAction(card: card, action: action))
        }
        notice.onDismiss = { [weak sidebar] card in sidebar?.model.send(.dismissNotice(card)) }
        nowPlaying.onCommand = { [weak sidebar] command in sidebar?.model.send(.nowPlaying(command)) }
        nowPlaying.onClose = { [weak sidebar] in sidebar?.model.send(.hideNowPlayingCard) }
        nowPlaying.menuProvider = { [weak sidebar] in sidebar?.contextMenuProvider?(.nowPlaying) }
        sidebar.addSubview(update)
        sidebar.addSubview(nowPlaying)
        sidebar.addSubview(notice)
    }

    /// Shows the cards the model holds (the slot picks one).
    func show(_ cards: SidebarBottomCards) {
        update.configure(cards.update)
        nowPlaying.configure(cards.nowPlaying)
        notice.configure(cards.notice)
    }

    private enum Shown { case update, nowPlaying, notice }

    /// The card that has the slot: a question waiting on the person, then update, then an asked-for notice,
    /// then Now Playing, then any other notice.
    private var shown: Shown? {
        // An agent waiting on the person's answer never hides behind another card.
        if notice.notice?.awaitsAnswer == true { return .notice }
        if update.card != nil { return .update }
        // "Is it checking?" must never hide behind a song (Lawrence 2026-10-19).
        if notice.notice?.userAsked == true { return .notice }
        if nowPlaying.nowPlaying != nil { return .nowPlaying }
        return notice.notice != nil ? .notice : nil
    }

    /// The notice card shows only while no other card does.
    var showsNotice: Bool { shown == .notice }

    /// The card's width in a sidebar `width` wide: inset like the card stack's cards.
    static func cardWidth(in sidebarWidth: CGFloat) -> CGFloat { max(0, sidebarWidth - 2 * Metrics.space3) }

    /// The room the slot takes above the footer in a sidebar `width` wide: its card and a gap above
    /// and below it; 0 without a card.
    func height(width sidebarWidth: CGFloat) -> CGFloat {
        switch shown {
        case .update: (update.card.map(SidebarUpdateCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case .nowPlaying: (nowPlaying.nowPlaying.map(SidebarNowPlayingCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case .notice: (notice.notice.map { notice.height(for: $0, width: Self.cardWidth(in: sidebarWidth)) } ?? 0) + 2 * Metrics.space2
        case nil: 0
        }
    }

    /// Lays the card out in the slot, which ends at `bottom`, inset like the
    /// card stack's cards across a sidebar `width` wide.
    func place(above bottom: CGFloat, width sidebarWidth: CGFloat, slotHeight: CGFloat) {
        let inset = Metrics.space3, width = Self.cardWidth(in: sidebarWidth)
        let shown = slotHeight > 0 ? shown : nil
        // The card keeps its own height (on the half-point grid, the 2x pixel): `integral` on a half-point origin grew it
        // a whole point, and the room went under its buttons (the tip card's bottom padding, Lawrence msg 40504).
        func frame(_ which: Shown, height: CGFloat) -> NSRect {
            guard shown == which else { return .zero }
            let across = NSRect(x: inset, y: 0, width: width, height: 1).integral
            return NSRect(x: across.minX, y: (2 * (bottom - Metrics.space2 - height)).rounded(.down) / 2, width: across.width, height: height)
        }
        nowPlaying.isHidden = shown != .nowPlaying
        nowPlaying.frame = frame(.nowPlaying, height: nowPlaying.nowPlaying.map(SidebarNowPlayingCardView.height(for:)) ?? 0)
        // A card playing its exit (``SidebarCardPresence``) keeps its place until it has gone.
        if shown == .update || !update.isLeaving {
            update.frame = frame(.update, height: update.card.map(SidebarUpdateCardView.height(for:)) ?? 0)
        }
        notice.presence.setShown(shown == .notice)
        if shown == .notice || !notice.isLeaving {
            notice.frame = frame(.notice, height: notice.notice.map { notice.height(for: $0, width: width) } ?? 0)
        }
    }
}
