package import CmuxNextSettings
package import CmuxNextWakeups

/// Which hidden browser pages may freeze, after Chrome's
/// components/performance_manager/freezing/freezing_policy.cc.
///
/// With Chrome's rules on (feature `memoryFreezeEligibility`), a page whose site may show
/// notifications, that holds a Web Lock or an IndexedDB connection, or that still loads does not
/// freeze, and an opener and the pages it opened (Chrome's browsing instance) freeze and thaw
/// together. Off, the plan is the one from before: the delay and cmux's own reasons decide, and every
/// page freezes and thaws alone. Either way it remembers the pages that could not freeze lately, which
/// are asked again after the delay.
///
/// Event-driven: a page kept for its load is watched (a background `ServiceObservation`) until the
/// load ends, then its owner plans again; there is no timer.
///
/// ```swift
/// let rules = FreezeEligibility()
/// rules.configure(isEnabled: true, work: mainWork, isLoading: { key in tabs[key]?.state.isLoading }) { replan() }
/// let plan = rules.plan(setting, candidates: hidden, frozen: frozen, groups: openerGroup)
/// for member in rules.thaw("shown") { thaw(member) }   // its opener group thaws with it
/// ```
@MainActor
package final class FreezeEligibility {
    /// Whether Chrome's reasons and the opener groups apply.
    package private(set) var isEnabled = false
    /// Whether page `key` still loads; nil once it is gone. Read with observation tracking, so the
    /// watch of a loading page wakes when the load ends.
    private var isLoading: @MainActor @Sendable (String) -> Bool? = { _ in nil }
    /// Runs when a page kept for its load stopped loading: its owner plans again.
    private var onLoaded: @MainActor @Sendable () -> Void = {}
    /// The app's main-thread scheduler, where a load's end applies.
    private var work: MainWorkScheduler?

    /// The opener group of each page planned to freeze with others, until one of them thaws.
    private var groups: [String: Set<String>] = [:]
    /// Pages whose opener group thawed: a freeze probe still out for one of them does not freeze it.
    /// A plan that finds the page due again (its whole group ready) clears it.
    private var held: Set<String> = []
    /// The load watch of each loading page a plan kept.
    private var loads: [String: ServiceObservation<Bool>] = [:]
    /// When each page last could not freeze (its probe kept it, the engine refused, a capture thawed it).
    private var keptAt: [String: ContinuousClock.Instant] = [:]

    package init() {}

    /// Turns Chrome's rules on or off and sets where page facts come from.
    ///
    /// - Parameters:
    ///   - isEnabled: Feature `memoryFreezeEligibility`.
    ///   - work: The app's main-thread scheduler: a load's end applies there as background work.
    ///   - isLoading: Whether a page still loads (nil once it is gone), read with observation tracking.
    ///   - onLoaded: Runs when a page kept for its load stopped loading.
    package func configure(isEnabled: Bool, work: MainWorkScheduler, isLoading: @escaping @MainActor @Sendable (String) -> Bool?,
                           onLoaded: @escaping @MainActor @Sendable () -> Void) {
        self.isEnabled = isEnabled
        self.work = work
        self.isLoading = isLoading
        self.onLoaded = onLoaded
    }

    /// Which hidden pages freeze now (`HibernationPlanner.freezePlan`), with Chrome's reasons when on.
    ///
    /// - Parameters:
    ///   - setting: `browser.hibernation`.
    ///   - candidates: The hidden pages that could freeze.
    ///   - frozen: The pages frozen now or being asked before a freeze: they count as ready members of a group.
    ///   - groups: A page's opener group, itself included (`BrowserScriptOpeners`); asked only for due pages.
    package func plan(_ setting: BrowserHibernationSetting, candidates: [HibernationPlanner.Candidate],
                      frozen: Set<String>, groups openers: (String) -> Set<String>) -> FreezePlan {
        guard isEnabled else { return HibernationPlanner.freezePlan(setting, candidates: candidates, chromeReasons: false) }
        let facts = candidates.map { candidate in
            var facts = candidate
            facts.isLoading = isLoading(candidate.key) == true
            return facts
        }
        let plan = HibernationPlanner.freezePlan(setting, candidates: facts, groups: openers, frozen: frozen)
        held.subtract(plan.due)
        for group in plan.groups.values {
            for member in group { groups[member] = group }
        }
        for (key, reason) in plan.kept where reason == .loading { watchLoad(key) }
        return plan
    }

    /// Whether what probed page `probe` said keeps it awake: what a freeze stops, and with the rules
    /// on, storage its site's other pages may wait for.
    package func keeps(_ probe: PageProbe) -> Bool {
        probe.stopsWhenFrozen || (isEnabled && probe.holdsSharedStorage)
    }

    /// Whether page `key` may still freeze: its opener group did not thaw since its plan.
    package func mayFreeze(_ key: String) -> Bool {
        !held.contains(key)
    }

    /// Page `key` could not freeze now (its probe kept it, the engine refused, a capture thawed it): it
    /// is asked again after the delay (``keptLeft(_:threshold:now:)``).
    ///
    /// - Returns: The other pages of its opener group, which thaw with it (``thaw(_:)``).
    @discardableResult
    package func keep(_ key: String, at now: ContinuousClock.Instant) -> Set<String> {
        keptAt[key] = now
        return thaw(key)
    }

    /// Seconds until kept page `key` is asked again, or nil when it is not kept (a keep that ended is dropped).
    ///
    /// - Parameters:
    ///   - threshold: The freeze delay (`freezeSeconds`); nil keeps no page.
    ///   - now: The clock reading of this plan.
    package func keptLeft(_ key: String, threshold: Double?, now: ContinuousClock.Instant) -> Double? {
        guard let kept = keptAt[key], let threshold else { return nil }
        let left = threshold - (now - kept) / .seconds(1)
        if left > 0 { return left }
        keptAt[key] = nil
        return nil
    }

    /// Page `key` showed: it is asked a whole delay after its next hide, not after its last keep.
    package func shown(_ key: String) {
        keptAt[key] = nil
    }

    /// Page `key` thaws or must stay awake (shown, driven, kept by its probe): the other pages of its
    /// opener group, which thaw with it. Each group is returned once.
    package func thaw(_ key: String) -> Set<String> {
        guard let group = groups[key] else { return [] }
        for member in group { groups[member] = nil }
        held.formUnion(group)
        return group.subtracting([key])
    }

    /// Page `key` closed or was discarded.
    package func forget(_ key: String) {
        groups[key] = nil
        held.remove(key)
        keptAt[key] = nil
        loads[key] = nil
    }

    /// Ends every load watch (the owner stops).
    package func stop() {
        loads.removeAll()
    }

    /// Watches loading page `key` until its load ends, then plans again (once per load). A plan keeps
    /// only a page it just read as loading, so the value the observation applies in this turn is true.
    private func watchLoad(_ key: String) {
        guard loads[key] == nil, let work else { return }
        let isLoading = isLoading
        loads[key] = ServiceObservation(.background, owner: "hibernation.freezeLoad", on: work, read: { isLoading(key) == true }) { [weak self] loading in
            guard !loading, let self, self.loads.removeValue(forKey: key) != nil else { return }
            self.onLoaded()
        }
    }
}
