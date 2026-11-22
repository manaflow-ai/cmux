import AppKit

extension SidebarViewComponents {
    /// The bottom-left card slot over this sidebar's card views.
    var cardSlot: SidebarBottomCardSlot { SidebarBottomCardSlot(update: updateCardView, nowPlaying: nowPlayingCardView, notice: noticeCardView) }
}

/// The bottom-left cards the sidebar renders (`SidebarModel.updateCard`,
/// `.nowPlaying`, `.noticeCard`): one at a time, in that order.
nonisolated struct SidebarBottomCards: Hashable, Sendable {
    var update: SidebarUpdateCard?
    var nowPlaying: SidebarNowPlaying?
    var notice: SidebarNoticeCard?
}
