@testable import CmuxNextDesign
import Foundation
import Testing

/// A ``GlassModeWatch`` cancels its observation loop when its last reference goes, on any thread.
/// Its nonisolated deinit used to return early off the main thread (`guard Thread.isMainThread else
/// { return }`), so a watch released off main left its `ObservationStream` loop waiting for the app's
/// life. The watch stands for the owners fixed with it (ComputerUseSetup, DaemonPaletteUsageStore,
/// PaneToolbar, the dock and machine section hosts, TopHomePageView and
/// TitlebarToolbarBand): each cancels its Sendable task handles in a nonisolated deinit of the same
/// shape. The on-main case is the control; only the off-main case is red before the fix.
@MainActor @Suite(.serialized)
struct GlassModeWatchReleaseTests {
    // crash-allow: the other thread writes `watch` once while the main thread waits on the semaphore, so no two threads touch it at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var watch: GlassModeWatch?
    }

    @Test func releasingTheWatchOnMainCancelsItsObservation() throws {
        let handoff = Handoff()
        handoff.watch = GlassModeWatch {}
        let loop = try #require(handoff.watch?.settings)
        handoff.watch = nil
        #expect(loop.isCancelled, "releasing the watch on main left its observation loop running")
    }

    @Test func releasingTheWatchOffMainCancelsItsObservation() throws {
        let handoff = Handoff()
        handoff.watch = GlassModeWatch {}
        let loop = try #require(handoff.watch?.settings)
        Self.releaseOnAnotherThread(handoff)
        #expect(loop.isCancelled, "releasing the watch off main left its observation loop running")
    }

    /// Drops the handoff's watch, its last reference, on a new thread and returns once it is gone.
    /// The main thread waits meanwhile, so a deinit that needs the main thread cannot clean up first.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handoff.watch = nil
            released.signal()
        }
        released.wait()
    }
}
