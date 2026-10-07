import AppKit

extension SidebarView {
    /// The bottom-left card slot over this sidebar's two card views.
    var cardSlot: SidebarBottomCardSlot { SidebarBottomCardSlot(update: updateCardView, tip: tipCardView) }
}

/// The bottom-left cards the sidebar renders (`SidebarModel.updateCard`,
/// `.tipCard`): `updateCardView` and `tipCardView`, one at a time.
nonisolated struct SidebarBottomCards: Hashable, Sendable {
    var update: SidebarUpdateCard?
    var tip: SidebarTipCard?
}
