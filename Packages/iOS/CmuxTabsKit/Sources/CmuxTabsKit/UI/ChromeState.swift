#if os(iOS)
import Observation
import SwiftUI

/// The toolbar's local state: expanded or collapsed, address editing, page
/// menu, toolbar swipe.
@MainActor
@Observable
final class ChromeState {
    enum Bar: Equatable { case expanded, collapsed }

    var bar: Bar = .expanded
    /// Side circles (and capsule glyphs); animated on their own ramp.
    var sidesVisible = true
    var editing = false
    var editText = ""
    var menuOpen = false
    /// Horizontal finger offset of a toolbar tab swipe.
    var swipeOffset: CGFloat = 0
    var swiping = false

    /// Accumulated finger travel for the current drag direction.
    @ObservationIgnored private var dragTravel: CGFloat = 0

    func collapse(_ theme: TabsKitTheme) {
        guard bar == .expanded, !editing, !menuOpen else { return }
        withAnimation(theme.motion.resolve(theme.motion.collapse)) { bar = .collapsed }
        withAnimation(theme.motion.sideOut) { sidesVisible = false }
    }

    func expand(tap: Bool, _ theme: TabsKitTheme) {
        guard bar == .collapsed else { return }
        withAnimation(theme.motion.resolve(tap ? theme.motion.expandTap : theme.motion.expandScroll)) { bar = .expanded }
        withAnimation(theme.motion.sideIn) { sidesVisible = true }
    }

    /// Finger travel on the page (positive = finger moving down). Not
    /// scroll-linked: crossing the threshold starts a time-based spring, as
    /// in Safari.
    func pageDragged(_ dy: CGFloat, _ theme: TabsKitTheme) {
        if (dy > 0) != (dragTravel > 0) { dragTravel = 0 }
        dragTravel += dy
        if dragTravel < -theme.metrics.collapseThreshold { collapse(theme) }
        if dragTravel > theme.metrics.expandThreshold { expand(tap: false, theme) }
    }
}
#endif
