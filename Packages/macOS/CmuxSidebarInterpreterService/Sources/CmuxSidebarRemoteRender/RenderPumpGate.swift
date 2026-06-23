/// The pure decision core of the render worker's display-refresh pump.
///
/// The worker's window is never ordered onto the screen, so AppKit/SwiftUI
/// have no display-link driver of their own: every visible change must be
/// pushed through an explicit pump (layout + `CATransaction.flush`). Host
/// messages pump synchronously, but invalidations that arrive *outside* a
/// host message (SwiftUI scheduling a re-render from its own state, AppKit
/// marking views dirty for scroller chrome, deferred display work) would
/// otherwise sit uncommitted until the next 1 s scene tick.
///
/// The gate turns those invalidations into at-most-one pump per display
/// refresh, and idles at zero cost: dirtiness arms it (resuming the paused
/// display link), a tick pumps while armed, and the first clean tick pauses
/// the link again — no timers, no polling, no per-frame work while idle.
struct RenderPumpGate {
    /// What a display-link tick should do.
    enum TickAction: Equatable {
        /// Something was invalidated since the last pump: pump now (and call
        /// ``pumpCompleted()`` once the commit lands).
        case pump
        /// Nothing dirty since the last frame: pause the display link.
        case pause
    }

    /// Whether an invalidation is awaiting a pump.
    private(set) var isDirty = false

    /// Records an invalidation. Returns `true` when the gate transitioned
    /// from clean to dirty, meaning the (paused) display link must be
    /// resumed; `false` when a pump is already scheduled.
    mutating func markDirty() -> Bool {
        let wasClean = !isDirty
        isDirty = true
        return wasClean
    }

    /// Decides one display-link tick.
    func tickAction() -> TickAction {
        isDirty ? .pump : .pause
    }

    /// A pump committed the layer tree (explicitly from a host message, or
    /// from a tick). Everything marked dirty before or during that pump was
    /// flushed by its commit, so the gate returns to clean.
    mutating func pumpCompleted() {
        isDirty = false
    }
}
