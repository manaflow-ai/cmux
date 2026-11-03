import CmuxNextDesignTokens
import Foundation
import Testing

/// A Low Power Mode observation stops its calls when its last reference goes, on any thread.
/// `LowPowerModeObservation`'s nonisolated deinit used to return early off the main thread
/// (`guard Thread.isMainThread else { return }`), so an owner released off main (GlassModeWatch,
/// WebKitEngine, BrowserHibernation) left its handler in `LowPowerMode.system` for the app's life.
@MainActor @Suite(.serialized)
struct LowPowerModeObservationReleaseTests {
    /// Counts handler calls (main actor).
    final class Calls {
        var count = 0
    }

    // crash-allow: the other thread writes `observation` once while the main thread waits on the semaphore, so no two threads touch it at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var observation: LowPowerModeObservation?
    }

    @Test func releasingTheObservationOnMainStopsItsCalls() {
        let mode = LowPowerMode(enabled: false)
        let calls = Calls()
        let handoff = Handoff()
        handoff.observation = mode.observe { _ in calls.count += 1 }
        mode.override = true
        #expect(calls.count == 1)
        handoff.observation = nil
        mode.override = false
        #expect(calls.count == 1, "an observation released on main still got a call")
    }

    @Test func releasingTheObservationOffMainStopsItsCalls() {
        let mode = LowPowerMode(enabled: false)
        let calls = Calls()
        let handoff = Handoff()
        handoff.observation = mode.observe { _ in calls.count += 1 }
        mode.override = true
        #expect(calls.count == 1)
        Self.releaseOnAnotherThread(handoff)
        mode.override = false
        #expect(calls.count == 1, "an observation released off main still got a call")
    }

    /// Drops the handoff's observation, its last reference, on a new thread and returns once it is
    /// gone. The main thread waits meanwhile, so a deinit that needs the main thread cannot clean up first.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handoff.observation = nil
            released.signal()
        }
        released.wait()
    }
}
