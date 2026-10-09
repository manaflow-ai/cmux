import AppKit

extension SidebarView {
    /// The bottom-left card slot over this sidebar's two card views.
    var cardSlot: SidebarBottomCardSlot { SidebarBottomCardSlot(update: updateCardView, updated: updatedCardView, tip: tipCardView) }
}

/// The bottom-left cards the sidebar renders (`SidebarModel.updateCard`,
/// `.updatedCard`, `.tipCard`): one at a time, in that order.
nonisolated struct SidebarBottomCards: Hashable, Sendable {
    var update: SidebarUpdateCard?
    var updated: SidebarUpdatedCard?
    var tip: SidebarTipCard?
}
