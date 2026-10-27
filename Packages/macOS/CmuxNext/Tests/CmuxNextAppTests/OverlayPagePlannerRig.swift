import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextWakeupsTestSupport

/// The App's overlay page planner (``OverlayPageDiscards`` over an ``ContentKind/overlayPage`` scheduler, as
/// `AppServices.overlayPageDiscards` builds it) on a manual clock and a hand-driven memory level, so a test moves
/// time and pressure itself and runs each look the planner's deadline would.
@MainActor
final class OverlayPagePlannerRig {
    let clock = ManualClock()
    let memory = ManualMemoryLevelRegistry()
    let discards: OverlayPageDiscards
    var scheduler: ContentDiscardScheduler { discards.scheduler }

    /// - Parameter level: The memory pressure the planner starts at.
    init(level: MemoryPressureLevel = .normal) {
        memory.send(level)
        discards = OverlayPageDiscards(scheduler: ContentDiscardScheduler(kind: .overlayPage, memory: memory, urgentAtWarning: true,
                                                                          clock: clock))
    }

    /// The terms an owner gets from the composition root.
    func terms(releaseAfter: Duration = OverlayPageRelease.defaultReleaseAfter) -> OverlayPageReleaseTerms {
        discards.terms(releaseAfter: releaseAfter)
    }

    /// `seconds` pass; the planner looks, as its deadline would, and the releases it starts end.
    func pass(_ seconds: Int64) async {
        clock.advance(by: .seconds(seconds))
        scheduler.replan()
        await scheduler.settled()
    }
}
