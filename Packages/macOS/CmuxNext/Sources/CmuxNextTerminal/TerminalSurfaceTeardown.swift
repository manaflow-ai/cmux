import CmuxNextWakeups
import GhosttyNextKit

/// The one owner of a closed pane's Ghostty surface: it frees the surface, ends the bridge's trace
/// registration, then releases the bridge, on the main thread, after the surface's output lane has
/// stopped (``TerminalOutputLane/close(then:)``). The view's deinit hands this on and does not wait,
/// so closing a pane never blocks the main thread on the lane (Chrome's `DeleteSoon`: the UI thread
/// never waits on another thread). Main-actor isolated, so it is `Sendable`: the lane only posts it
/// back to the main thread.
@MainActor final class TerminalSurfaceTeardown {
    /// SAFETY: the view's surface, nil when it made none. Freed once, by ``run()``.
    @safe private let surface: ghostty_surface_t?
    /// SAFETY: the view's +1 on the bridge. Released once, by ``run()``, after the free.
    @safe private let bridge: Unmanaged<SurfaceBridge>
    /// The free's class on the main thread: `visible`, as Chrome's `DeleteSoon` posts at the default
    /// (user-visible) priority.
    private nonisolated let delivery: MainDelivery

    init(surface: ghostty_surface_t?, bridge: Unmanaged<SurfaceBridge>, delivery: MainDelivery) {
        // SAFETY: the view hands over its surface and its retain on the bridge (the notes above).
        self.surface = unsafe surface
        self.bridge = unsafe bridge
        self.delivery = delivery
    }

    /// Posts ``run()`` to the main thread. Called on the output lane as its last block.
    nonisolated func post() {
        delivery.run { self.run() }
    }

    /// Frees the surface. Ghostty no longer needs its view here: the Metal renderer read the
    /// `nsview` only when it created its layer, and callbacks reach the view through the bridge's
    /// weak target, which is nil by now.
    func run() {
        // SAFETY: the one free of the view's surface (`surface`'s note); the lane that reached it off the
        // main thread ran its last block before this was posted.
        if let surface = unsafe surface { unsafe ghostty_surface_free(surface) }
        // SAFETY: the bridge is alive until the release below (`bridge`'s note).
        unsafe bridge.takeUnretainedValue().surfaceFreed() // free joined every thread that reads the bridge
        // Released after free: free joins the IO thread that reads the bridge.
        // SAFETY: the one release of the view's retain (`bridge`'s note), after the free.
        unsafe bridge.release()
    }
}
