@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

extension AppServices {
    /// Waits until the personal placement queue is through and the store has
    /// applied every daemon event sent before it was: the sidebar order the
    /// queued placements wrote is then the order the store reads. A live-daemon
    /// test reads order only after this; the queue can trail a run on a loaded
    /// runner (#26153), well past any quiet window.
    @MainActor func placementsSettled(timeout: Duration = .seconds(60)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            while !personalPlacements.isIdle, clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            if let barrier = await daemon.connection?.eventSequence() {
                while daemon.store.appliedSequence < barrier, clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            }
            // A store event can enqueue another placement; settled only once both are through.
            if personalPlacements.isIdle { return }
        }
    }
}
