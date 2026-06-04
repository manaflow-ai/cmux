import Foundation

/// Bridges libghostty's per-surface C callbacks (which run on the IO read
/// thread or other Ghostty-internal threads) into the surface's
/// ``GhosttySurfaceHostEvent`` stream.
///
/// This replaces the pre-actor `GhosttySurfaceBridge` and its `NSLock`: the
/// only state is an `AsyncStream.Continuation` (thread-safe by contract) and
/// a surface-identity stamp written once before any callback can observe it.
/// An `Unmanaged` reference to this bridge is the `userdata` for `io_write`
/// and `close_surface`; the backend retains it until the surface is freed.
final class GhosttySurfaceCallbackBridge: Sendable {
    private let events: AsyncStream<GhosttySurfaceHostEvent>.Continuation
    /// The system-clipboard seam, carried here so libghostty's per-surface
    /// clipboard callbacks reach it without recovering the engine.
    let clipboard: GhosttyEngineClipboard

    /// The owning surface's identity (pointer bit-pattern), used to route
    /// app-level callbacks (clipboard completion) back to the surface.
    ///
    /// `nonisolated(unsafe)` justification: written exactly once on the main
    /// thread immediately after `ghostty_surface_new` returns and before the
    /// session or registry hand out the identity; all later reads see that
    /// single write.
    nonisolated(unsafe) private(set) var surfaceIdentity: UInt = 0

    init(
        events: AsyncStream<GhosttySurfaceHostEvent>.Continuation,
        clipboard: GhosttyEngineClipboard
    ) {
        self.events = events
        self.clipboard = clipboard
    }

    /// Stamps the owning surface's identity (see `surfaceIdentity`).
    func stampSurfaceIdentity(_ identity: UInt) {
        surfaceIdentity = identity
    }

    /// Forwards bytes libghostty wrote toward the PTY.
    func handleWrite(_ bytes: Data) {
        events.yield(.outboundBytes(bytes))
    }

    /// Forwards a close request from libghostty.
    func handleCloseSurface(processAlive: Bool) {
        events.yield(.closeRequested(processAlive: processAlive))
    }

    /// Recovers a bridge from a C `userdata` pointer.
    static func fromOpaque(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackBridge? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackBridge>.fromOpaque(userdata).takeUnretainedValue()
    }
}
