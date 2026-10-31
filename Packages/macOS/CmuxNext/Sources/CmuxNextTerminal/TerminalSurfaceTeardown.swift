import GhosttyNextKit

/// The one owner of a closed pane's Ghostty surface: it frees the surface and then releases its
/// bridge, on the main thread, after the surface's output lane has stopped
/// (``TerminalOutputLane/close(then:)``). The view's deinit hands this on and does not wait,
/// so closing a pane never blocks the main thread on the lane. Main-actor isolated, so it is
/// `Sendable`: the lane only carries it back to the main thread.
@MainActor final class TerminalSurfaceTeardown {
    private let surface: ghostty_surface_t
    private let bridge: Unmanaged<SurfaceBridge>

    init(surface: ghostty_surface_t, bridge: Unmanaged<SurfaceBridge>) {
        self.surface = surface
        self.bridge = bridge
    }

    /// Frees the surface. Ghostty no longer needs its view here: the Metal renderer read the
    /// `nsview` only when it created its layer, and callbacks reach the view through the bridge's
    /// weak reference, which is nil by now.
    func run() {
        ghostty_surface_free(surface)
        // Released after free: free joins the IO thread that reads the bridge.
        bridge.release()
    }
}
