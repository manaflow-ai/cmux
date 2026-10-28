package import CmuxNextSettings

/// Why a hidden page does not freeze now, reported by its raw value.
///
/// Chrome's `CannotFreezeReason` (components/performance_manager/freezing/freezing_policy.cc): a page
/// with the notification permission, a held Web Lock, a held IndexedDB lock or a load in progress
/// never freezes. The planner knows the notification permission and the load; the page probe finds
/// the locks right before the freeze (`FreezeEligibility.keeps`). The other cases are cmux's own (the
/// person's choices, DevTools, capture, agents).
package nonisolated enum CannotFreezeReason: String, Hashable, Sendable, CaseIterable {
    case devTools = "devtools", capturing, agentLease = "agent_lease", excluded, pinned
    /// It changed its title or icon while hidden (`PageBackgroundActivity`): its updates stay live.
    case backgroundActivity = "background_activity"
    /// Its site may show notifications (Chrome's kNotificationPermission): a frozen page shows none.
    case notifications
    /// It still loads (Chrome's kLoading); its load end plans it again.
    case loading
    /// A member of its opener group cannot freeze yet: Chrome freezes a browsing instance (an opener
    /// and the pages it opened, which can script each other) only as a whole.
    case openerGroup = "opener_group"
}

/// Which hidden pages freeze now (`HibernationPlanner.freezePlan`).
package nonisolated struct FreezePlan: Hashable, Sendable {
    /// Keys to freeze now (after the page probe, which also checks Web Locks and IndexedDB).
    package var due: [String] = []
    /// Seconds until the next page reaches the freeze delay; nil when none will.
    package var nextCheck: Double?
    /// Why each page that is not due stays awake; a page that only waits for its delay has none.
    package var kept: [String: CannotFreezeReason] = [:]
    /// The opener group of each due page that has others (itself included): they freeze and thaw together.
    package var groups: [String: Set<String>] = [:]

    package init(due: [String] = [], nextCheck: Double? = nil, kept: [String: CannotFreezeReason] = [:], groups: [String: Set<String>] = [:]) {
        self.due = due
        self.nextCheck = nextCheck
        self.kept = kept
        self.groups = groups
    }
}

nonisolated extension HibernationPlanner {
    /// Which hidden pages freeze now, and when the next one will: after `freezeSeconds` hidden,
    /// whatever the hibernation mode, unless ``freezeRefusal(_:setting:chromeReasons:)`` keeps it, and
    /// only when every other page of its opener group is frozen or due too.
    ///
    /// - Parameters:
    ///   - setting: `browser.hibernation`; `freezeSeconds` nil never freezes.
    ///   - candidates: The hidden pages that could freeze (not frozen, not being asked).
    ///   - groups: A page's opener group, itself included (`BrowserScriptOpeners`); asked only for due pages.
    ///   - frozen: The pages frozen now: they count as due members of a group.
    ///   - chromeReasons: Chrome's reasons (notifications, loading) keep a page; off, only cmux's own do
    ///     (feature `memoryFreezeEligibility` off).
    package static func freezePlan(_ setting: BrowserHibernationSetting, candidates: [Candidate], groups: (String) -> Set<String> = { [$0] },
                                   frozen: Set<String> = [], chromeReasons: Bool = true) -> FreezePlan {
        var plan = FreezePlan()
        guard let threshold = setting.freezeSeconds else { return plan }
        var due: [String] = []
        for candidate in candidates {
            if let reason = freezeRefusal(candidate, setting: setting, chromeReasons: chromeReasons) {
                plan.kept[candidate.key] = reason
                continue
            }
            let remaining = threshold - candidate.hiddenFor
            if remaining <= 0 {
                due.append(candidate.key)
            } else {
                plan.nextCheck = min(plan.nextCheck ?? remaining, remaining)
            }
        }
        let ready = frozen.union(due)
        var known: [String: Set<String>] = [:]
        for key in due {
            let group = known[key] ?? groups(key).union([key])
            if known[key] == nil { for member in group { known[member] = group } }
            if group.count > 1 {
                guard group.isSubset(of: ready) else {
                    plan.kept[key] = .openerGroup
                    continue
                }
                plan.groups[key] = group
            }
            plan.due.append(key)
        }
        return plan
    }

    /// Why hidden page `candidate` does not freeze, or nil when its delay alone decides: pinned tabs
    /// (unless they hibernate too), excluded hosts, open DevTools, capture, an agent's lease, a page
    /// with background activity (the timeout keeps it for its updates, so they stay live), and
    /// with `chromeReasons` Chrome's reasons the planner knows (notifications, loading).
    package static func freezeRefusal(_ candidate: Candidate, setting: BrowserHibernationSetting,
                                      chromeReasons: Bool = true) -> CannotFreezeReason? {
        if candidate.hasDevTools { return .devTools }
        if candidate.isCapturing { return .capturing }
        if candidate.hasAgentLease { return .agentLease }
        if candidate.hasBackgroundActivity { return .backgroundActivity }
        if setting.excludes(host: candidate.host) { return .excluded }
        if candidate.isPinned && !setting.includesPinnedTabs { return .pinned }
        guard chromeReasons else { return nil }
        if candidate.allowsNotifications { return .notifications }
        if candidate.isLoading { return .loading }
        return nil
    }
}
