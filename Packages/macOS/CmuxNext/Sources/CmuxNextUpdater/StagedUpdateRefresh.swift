import CmuxNextWakeups
import CmuxUpdater
import Foundation

/// Lets a staged update give way to a newer build of the followed ring.
@MainActor
final class StagedUpdateRefresh {
    /// Whether this app's driver holds the staged installer and found updates download by
    /// themselves (``UpdateController/canCancelStagedUpdate``, `downloadsUpdatesInBackground`).
    var replaceable: () -> Bool = { false }
    /// Sparkle's scheduled background check, now (``UpdateController/checkInBackground()``).
    var checkInBackground: () -> Void = {}
    /// `updates.checkAutomatically` and `updates.checkIntervalSeconds`.
    var schedule: (automatic: Bool, interval: TimeInterval) = (true, 3600)
    /// How long a fresh update that lists no deltas waits for them (``UpdateController/pendingDeltaWindow``).
    var deltaWindow: TimeInterval?
    /// The probe in flight, if any.
    private(set) var task: Task<Void, Never>?
    weak var updater: UpdaterService?
    let timer: DemandTimer

    init(clock: any Clock<Duration>) {
        timer = DemandTimer(owner: "UpdaterService.stagedRefresh", clock: clock)
    }
}
