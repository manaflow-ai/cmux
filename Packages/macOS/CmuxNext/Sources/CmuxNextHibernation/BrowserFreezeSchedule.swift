import CmuxNextCompat
package import CmuxNextSettings
import CmuxNextWakeups

/// The freeze probe's backoff and one-shot deadline, separate from the App's page ownership.
/// A page kept awake is asked again after `freezeSeconds`; an ineligible page waits for an event.
@MainActor
package final class BrowserFreezeSchedule {
    private var keptAt: [String: ContinuousClock.Instant] = [:]
    private let deadline = DemandTimer(owner: "BrowserFreeze")

    package init() {}

    package func keep(_ key: String, at now: ContinuousClock.Instant) { keptAt[key] = now }
    package func forget(_ key: String) { keptAt[key] = nil }
    package func cancel() { deadline.cancel() }

    /// Combines hidden-time deadlines with probe backoff, retaining only eligible pages.
    package func plan(_ setting: BrowserHibernationSetting, hidden: [HibernationPlanner.Candidate],
                      now: ContinuousClock.Instant, eligible: (String) -> Bool) -> HibernationPlanner.Plan {
        let threshold = setting.freezeSeconds
        var recheck: Double?
        let candidates = hidden.filter { candidate in
            guard eligible(candidate.key) else { return false }
            if let kept = keptAt[candidate.key], let threshold {
                let left = threshold - (now - kept).seconds
                if left > 0 { recheck = min(recheck ?? left, left); return false }
                keptAt[candidate.key] = nil
            }
            return true
        }
        var plan = HibernationPlanner.freezePlan(setting, candidates: candidates)
        plan.nextCheck = [plan.nextCheck, recheck].compactMap(\.self).min()
        return plan
    }

    /// Freezes due pages and replaces the deadline. No repeating timer runs while a page loads.
    package func replan(_ setting: BrowserHibernationSetting, hidden: [HibernationPlanner.Candidate],
                        now: ContinuousClock.Instant, eligible: (String) -> Bool, freeze: (String) -> Void,
                        onDeadline: @escaping @MainActor @Sendable () -> Void) {
        let plan = plan(setting, hidden: hidden, now: now, eligible: eligible)
        for key in plan.due { freeze(key) }
        if let next = plan.nextCheck {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor in onDeadline() }
        } else {
            deadline.cancel()
        }
    }
}
