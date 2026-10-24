import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// A glass backdrop feed with a frame pending takes that frame client off its scheduler when
/// released, on any thread. Its nonisolated deinit used to return early off the main thread
/// (`guard Thread.isMainThread else { return }`), so a feed released off main left its client
/// active on its scheduler until the next tick.
///
/// The feeds tick on a scheduler whose link never fires and whose stall deadline waits on a clock
/// that never moves, so no frame can end the client by itself before the check. The on-main case
/// is the control; only the off-main case is red before the fix.
///
/// It lives in CmuxNextAppTests (not CmuxNextDesignTests, with the other Design release tests)
/// because it builds a ``FrameScheduler`` and this target already links CmuxNextWakeups.
@MainActor @Suite
struct GlassBackdropFeedReleaseTests {
    /// A display link that never fires: a ``FrameScheduler`` built on it ticks only when told.
    private final class StillFrameLink: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    @Test func aReleasedGlassBackdropFeedEndsItsPendingFrameOnAnyThread() async {
        let scheduler = FrameScheduler.testing(clock: ManualClock()) { _ in StillFrameLink() }
        func pending() -> GlassBackdropFeed {
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let feed = GlassBackdropFeed(host: host, zoom: { 1 }, images: GlassBackdropImages(), mode: { .plain },
                                         frames: { _ in scheduler }) { _ in }
            feed.setNeedsUpdate()
            return feed
        }
        // Reads the feed's frame client after the feed is gone.
        func activity(of feed: GlassBackdropFeed) -> () -> Bool? {
            let client = feed.nextFrame
            return { client?.isActive }
        }
        var feed: GlassBackdropFeed? = pending()
        let onMain = feed.map(activity) ?? { nil }
        #expect(onMain() == true)
        #expect(scheduler.activeClients == ["glass.backdrop"])
        feed = nil
        #expect(onMain() == false, "a feed released on main left its frame client active")
        #expect(scheduler.activeClients.isEmpty, "a feed released on main left its frame client on its scheduler")

        var offMain: () -> Bool? = { nil }
        await Self.releaseOffMain {
            let feed = pending()
            offMain = activity(of: feed)
            return feed
        }
        #expect(offMain() == false, "a feed released off main left its frame client active")
        #expect(scheduler.activeClients.isEmpty, "a feed released off main left its frame client on its scheduler")
    }

    /// Drops the only reference to the object `make` returns on a background thread, then returns
    /// on the main actor after the main queue ran everything the deinit queued there.
    ///
    /// The object is retained once, unmanaged, before `make`'s own reference goes, so the
    /// background release is the last one and the deinit runs off main. The deinit hands its
    /// main-thread work to the main queue (`MainDelivery`) before the release returns; the resume
    /// is queued after it on the same serial queue from the same thread, so it runs after that
    /// work and the test reads the result with no wait. (CmuxNextDesignTests has the same helper,
    /// `releaseOffMain`; test targets share no sources.)
    private static func releaseOffMain(_ make: () -> AnyObject) async {
        let bits = UInt(bitPattern: Unmanaged.passRetained(make()).toOpaque())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                if let pointer = UnsafeRawPointer(bitPattern: bits) { Unmanaged<AnyObject>.fromOpaque(pointer).release() }
                // main-async-allow: the barrier is the main queue itself, FIFO after the deinit's own hop
                DispatchQueue.main.async { done.resume() }
            }
        }
    }
}
