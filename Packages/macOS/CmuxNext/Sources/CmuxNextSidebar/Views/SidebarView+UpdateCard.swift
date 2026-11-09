import AppKit

extension SidebarViewComponents {
    /// The bottom-left card slot over this sidebar's card views.
    var cardSlot: SidebarBottomCardSlot { SidebarBottomCardSlot(update: updateCardView, nowPlaying: nowPlayingCardView, updated: updatedCardView, notice: noticeCardView, setup: setupCardView) }
}

/// The bottom-left cards the sidebar renders (`SidebarModel.updateCard`,
/// `.nowPlaying`, `.updatedCard`, `.noticeCard`, `.setupCard`): one at a time (``SidebarBottomCardSlot``).
nonisolated struct SidebarBottomCards: Hashable, Sendable {
    var update: SidebarUpdateCard?
    var nowPlaying: SidebarNowPlaying?
    var updated: SidebarUpdatedCard?
    var notice: SidebarNoticeCard?
    var setup: SidebarSetupCard?
}
