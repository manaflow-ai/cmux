import AppKit

extension SidebarView {
    /// The bottom-left card slot over this sidebar's card views.
    var cardSlot: SidebarBottomCardSlot { SidebarBottomCardSlot(update: updateCardView, nowPlaying: nowPlayingCardView, updated: updatedCardView, notice: noticeCardView) }
}
