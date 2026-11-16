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
        notice.onAction = { [weak sidebar] card, action in
            // The restoring card's Details opens what the footer's health line opens (app health's popover).
            if card == "restoring", action == SidebarNoticeCard.detailsAction, sidebar?.healthIndicator?.accessibilityPerformPress() == true { return }
            sidebar?.model.send(.noticeAction(card: card, action: action))
        }
        notice.onDismiss = { [weak sidebar] card in sidebar?.model.send(.dismissNotice(card)) }
        nowPlaying.onCommand = { [weak sidebar] command in sidebar?.model.send(.nowPlaying(command)) }
        nowPlaying.onClose = { [weak sidebar] in sidebar?.model.send(.hideNowPlayingCard) }
        nowPlaying.menuProvider = { [weak sidebar] in sidebar?.contextMenuProvider?(.nowPlaying) }
        updated.onDismiss = { [weak sidebar] in sidebar?.model.send(.dismissUpdated) }
        updated.notes.hoverCards = { [weak sidebar] in sidebar?.list.hoverCards }
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

    /// The Updated card has the slot and its height lands without the spring (its first frame, the
    /// page's first report): ``SidebarUpdatedCardHost/landsAtOnce``.
    var updatedLandsAtOnce: Bool { shown == .updated && updated.landsAtOnce }

    /// The notice card shows only while no other card does.
    var showsNotice: Bool { shown == .notice }

    /// The card's width in a sidebar `width` wide: inset like the card stack's cards.
    static func cardWidth(in sidebarWidth: CGFloat) -> CGFloat { max(0, sidebarWidth - 2 * Metrics.space3) }

    /// The room the slot takes above the footer in a sidebar `width` wide: its card and a gap above
    /// and below it; 0 without a card. The Updated card's height before its page reports is the one
    /// it last had at its width.
    func height(width sidebarWidth: CGFloat) -> CGFloat {
        updated.slotWidth = Self.cardWidth(in: sidebarWidth)
        updated.holdFirstFrame()
        return switch shown {
        case .update: (update.card.map(SidebarUpdateCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case .nowPlaying: (nowPlaying.nowPlaying.map(SidebarNowPlayingCardView.height(for:)) ?? 0) + 2 * Metrics.space2
        case .updated: updated.height + 2 * Metrics.space2
        case .notice: (notice.notice.map { notice.height(for: $0, width: Self.cardWidth(in: sidebarWidth)) } ?? 0) + 2 * Metrics.space2
        case nil: 0
        }
    }

    /// The Updated card has the slot and rests at the top of the list (``SidebarUpdatedCardHost/anchor``).
    var updatedAtTop: Bool { shown == .updated && updated.anchor == .top }

    /// Lays the card out in the slot, which ends at `bottom`, inset like the
    /// card stack's cards across a sidebar `width` wide. The Updated card dropped at the top rests
    /// under `top` instead (the list's top edge), and may be dragged anywhere between the two;
    /// `sidebar` runs its settle.
    func place(above bottom: CGFloat, top: CGFloat = 0, width sidebarWidth: CGFloat, slotHeight: CGFloat, in sidebar: NSView? = nil) {
        let inset = Metrics.space3, width = Self.cardWidth(in: sidebarWidth)
        let shown = slotHeight > 0 ? shown : nil
        func frame(_ which: Shown, height: CGFloat) -> NSRect {
            shown == which ? NSRect(x: inset, y: bottom - Metrics.space2 - height, width: width, height: height).integral : .zero
        }
        nowPlaying.isHidden = shown != .nowPlaying
        nowPlaying.frame = frame(.nowPlaying, height: nowPlaying.nowPlaying.map(SidebarNowPlayingCardView.height(for:)) ?? 0)
        updated.isHidden = shown != .updated
        if shown == .updated {
            placeUpdated(area: (top + Metrics.space2)...max(top + Metrics.space2, bottom - Metrics.space2), x: inset, width: width,
                         in: sidebar ?? updated)
        } else {
            updated.frame = .zero
        }
        // A card playing its exit (``SidebarCardPresence``) keeps its place until it has gone.
        if shown == .update || !update.isLeaving {
            update.frame = frame(.update, height: update.card.map(SidebarUpdateCardView.height(for:)) ?? 0)
        }
        notice.presence.setShown(shown == .notice)
        if shown == .notice || !notice.isLeaving {
            notice.frame = frame(.notice, height: notice.notice.map { notice.height(for: $0, width: width) } ?? 0)
        }
    }

    /// The Updated card at its anchor's end of `area`. Its open hover preview stands over the list
    /// (above the bottom slot, below the top place) and the slot's room stays the card's own.
    private func placeUpdated(area: ClosedRange<CGFloat>, x: CGFloat, width: CGFloat, in sidebar: NSView) {
        let height = updated.height, atTop = updated.anchor == .top
        let rest = NSRect(x: x, y: atTop ? area.lowerBound : area.upperBound - height, width: width, height: height).integral
        updated.report(rest: rest, area: area)
        let extra = max(0, updated.frameHeight - rest.height)
        // Downward from the top place, never past the area; upward from the slot, never past the sidebar's top.
        let grow = atTop ? min(extra, max(0, area.upperBound - rest.maxY)) : min(extra, max(0, rest.minY - Metrics.space2))
        let grown = NSRect(x: rest.minX, y: atTop ? rest.minY : rest.minY - grow, width: rest.width, height: rest.height + grow)
        updated.frame = updated.displaced(grown, in: sidebar)
    }
}
