import CmuxSidebar
import SwiftUI

extension ContentView {
    /// The invisible leading-edge strip that arms the hover-reveal.
    ///
    /// Mounted only while the sidebar is collapsed and floating: a docked
    /// sidebar already occupies the leading edge, and a collapsed docked
    /// sidebar is a deliberate choice the pointer should not undo. The strip
    /// removes its tracking area entirely when disabled rather than ignoring
    /// callbacks, so the common case costs nothing.
    @ViewBuilder
    var sidebarPeekEdgeStrip: some View {
        let isArmed = sidebarState.presentationMode == .floating && !sidebarState.isVisible
        SidebarPeekEdgeTrackingView(
            width: sidebarPeek.policy.edgeWidth,
            isEnabled: isArmed,
            onEnter: { sidebarPeek.pointerEnteredEdge() },
            onExit: { sidebarPeek.pointerExitedEdge() }
        )
        .frame(width: sidebarPeek.policy.edgeWidth)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .zIndex(1)
    }
}
