import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups

/// Freezes hidden cmux pages in Chromium (Settings, Diff, Files, History, Stats, Cloud, Home
/// channels, Keybindings, agent chats) by the rule that freezes hidden browser tabs:
/// `browser.freezeHiddenTabs` seconds hidden (30 by default; `off` never), through
/// ``HibernationPlanner/freezePlan(_:candidates:)`` (perf-lead.md F3). A page you switched away
/// from then stops its timers, React effects and 1 Hz clocks, so it costs no CPU and no wakeups.
///
/// Events only, no polling: a page reports when it hides or the host reaches it while hidden
/// (``PageFreezePolicy``), and one deadline runs for the next page to come due. The page itself
/// thaws before it shows and before any host call or push, and reports again, so its grace
/// restarts (a chat that streams while hidden never freezes). Releasing a hidden chat's page
/// after the hibernation threshold stays with ``AgentPageHibernation``.
@MainActor
final class CmuxPageFreezing: PageFreezePolicy {
    private final class Hidden {
        weak var page: PageWebView?
        var since: ContinuousClock.Instant

        init(_ page: PageWebView, since: ContinuousClock.Instant) {
            self.page = page
            self.since = since
        }
    }

    private(set) var setting: BrowserHibernationSetting = .fallback
    private var hidden: [ObjectIdentifier: Hidden] = [:]
    private let deadline: DemandTimer
    /// The clock (tests set it).
    var now: () -> ContinuousClock.Instant = { .now }
    /// Pages frozen so far (`debug.surfaces`, tests).
    private(set) var frozenCount = 0

    /// - Parameter clock: The deadline's clock (tests pass one they step).
    init(clock: any Clock<Duration> = ContinuousClock()) {
        deadline = DemandTimer(owner: "CmuxPageFreeze", clock: clock)
    }

    /// Hidden pages the policy waits on (tests).
    var waitingCount: Int { hidden.values.filter { $0.page != nil }.count }
    /// A page is due later and the timer for it runs (tests).
    var hasDeadline: Bool { deadline.isScheduled }

    func update(setting: BrowserHibernationSetting) {
        guard setting != self.setting else { return }
        self.setting = setting
        replan()
    }

    /// O(1) on the push path (a hidden chat that streams reports every push): a later `since`
    /// only moves a page's deadline later, so a pending deadline stays right (it may fire early,
    /// and that pass arms the next); a new page's grace is the longest, so it needs a pass only
    /// when no deadline runs.
    func hiddenPageWoke(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        if let entry = hidden[key] {
            entry.since = now()
            return
        }
        hidden[key] = Hidden(page, since: now())
        if !deadline.isScheduled { replan() }
    }

    func pageIsNoLongerHidden(_ page: PageWebView) {
        guard hidden.removeValue(forKey: ObjectIdentifier(page)) != nil else { return }
        if hidden.isEmpty { deadline.cancel() }
    }

    /// Freezes every hidden page past its grace and arms one deadline for the next.
    func replan() {
        hidden = hidden.filter { $0.value.page != nil }
        let current = now()
        let candidates = hidden.map { key, entry in
            HibernationPlanner.Candidate(key: Self.name(key), hiddenFor: (current - entry.since).seconds)
        }
        let plan = HibernationPlanner.freezePlan(setting, candidates: candidates)
        let due = Set(plan.due)
        for (key, entry) in hidden where due.contains(Self.name(key)) {
            // Frozen, or not freezable now (it still boots: it reports again at its first message).
            if entry.page?.freezeWhileHidden() == true { frozenCount += 1 }
            hidden[key] = nil
        }
        if let next = plan.nextCheck {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
    }

    /// The planner's key of a live page: its object address, unique while the page lives.
    private static func name(_ key: ObjectIdentifier) -> String { String(UInt(bitPattern: key)) }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
