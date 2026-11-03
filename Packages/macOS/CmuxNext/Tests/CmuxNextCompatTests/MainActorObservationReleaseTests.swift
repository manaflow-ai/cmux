import CmuxNextCompat
import Foundation
import Testing

/// Characterization test (it passes before and after the deinit fixes; it is not a regression guard for
/// any one owner): an owner that holds its observer in a ``MainActorObservation`` needs no cleanup in its
/// deinit, because the observation stops when the owner goes, whichever thread releases the last
/// reference. The App owners whose deinits stopped removing their observers by hand (GlassModeWatch's
/// display observation, ComputerUseSetup's activation and trust observers) rely on this contract.
@MainActor
@Suite struct MainActorObservationReleaseTests {
    private let name = Notification.Name("MainActorObservationReleaseTests.ping")

    /// An App-shaped owner: a main-actor class with the observation in a stored property and an empty
    /// nonisolated deinit (the App's owners are never isolated-deinit, cx-t7hu), so the release runs on
    /// the releasing thread.
    final class Owner {
        private var observation: MainActorObservation?

        init(_ name: Notification.Name, center: NotificationCenter, _ handler: @escaping @MainActor () -> Void) {
            observation = MainActorObservation(name, center: center, handler)
        }

        nonisolated deinit {}
    }

    // crash-allow: the other thread writes `owner` once while the main thread waits on the semaphore, so no two threads touch it at once.
    nonisolated final class Handoff: @unchecked Sendable {
        var owner: Owner?
    }

    @Test func releasingTheOwnerOnMainStopsItsObservation() {
        let center = NotificationCenter()
        var runs = 0
        let handoff = Handoff()
        handoff.owner = Owner(name, center: center) { runs += 1 }
        center.post(name: name, object: nil)
        handoff.owner = nil
        center.post(name: name, object: nil)
        #expect(runs == 1)
    }

    @Test func releasingTheOwnerOffMainStopsItsObservation() {
        let center = NotificationCenter()
        var runs = 0
        let handoff = Handoff()
        handoff.owner = Owner(name, center: center) { runs += 1 }
        center.post(name: name, object: nil)
        Self.releaseOnAnotherThread(handoff)
        center.post(name: name, object: nil)
        #expect(runs == 1, "the observation outlived an owner released off main")
    }

    /// Drops the handoff's owner, its last reference, on a new thread and returns once it is gone.
    nonisolated static func releaseOnAnotherThread(_ handoff: Handoff) {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handoff.owner = nil
            released.signal()
        }
        released.wait()
    }
}
