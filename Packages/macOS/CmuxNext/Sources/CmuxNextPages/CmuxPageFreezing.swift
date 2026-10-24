public import CmuxNextSettings
import CmuxNextWakeups

/// Freezes hidden cmux pages in Chromium (Settings, Diff, Files, History, Stats, Cloud, Home
/// channels, Keybindings, agent chats) by the rule that freezes hidden browser tabs:
/// `browser.freezeHiddenTabs` seconds hidden (30 by default; `off` never) (perf-lead.md F3). A page
/// you switched away from then stops its timers, React effects and 1 Hz clocks, so it costs no CPU
/// and no wakeups.
///
/// Events only, no polling: a page reports when it hides or the host reaches it while hidden
/// (``PageFreezePolicy``), and one deadline runs for the next page to come due. The page itself
/// thaws before it shows and before any host call or push, and reports again, so its grace
/// restarts (a chat that streams while hidden never freezes). Releasing a hidden chat's page
/// after the hibernation threshold stays with the app's agent page hibernation.
///
/// The app makes one policy at its composition root, hands it to its Chromium page host (every
/// started page reports to it) and keeps it on the browser hibernation's setting:
///
/// ```swift
/// let cmuxPages = CmuxPageFreezing()
/// cmuxPages.update(setting: hibernationSetting)
/// ```
///
/// Tests pass a clock whose time they step (`init(clock:)`).
@MainActor
public final class CmuxPageFreezing: PageFreezePolicy {
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
    /// The injected clock's time: how long each page has been hidden, on the deadline's clock.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// Pages frozen so far (tests).
    private(set) var frozenCount = 0

    /// The policy on the continuous clock, with the default setting until ``update(setting:)``.
    public convenience init() {
        self.init(clock: ContinuousClock())
    }

    /// - Parameter clock: The one time source: the hidden times and the deadline (tests pass a clock
    ///   whose time they step and whose sleeps they end).
    init<C: Clock>(clock: C) where C.Instant == ContinuousClock.Instant {
        deadline = DemandTimer(owner: "CmuxPageFreeze", clock: clock)
        now = { clock.now }
    }

    /// Hidden pages the policy waits on (tests).
    var waitingCount: Int { hidden.values.filter { $0.page != nil }.count }
    /// A page is due later and the timer for it runs (tests).
    var hasDeadline: Bool { deadline.isScheduled }

    /// Applies `browser.freezeHiddenTabs`. Off forgets every hidden page and its deadline; after an
    /// on, a page counts from its next hide, call or push.
    ///
    /// - Parameter setting: The browser hibernation's setting; only its `freezeSeconds` counts.
    public func update(setting: BrowserHibernationSetting) {
        guard setting != self.setting else { return }
        self.setting = setting
        guard setting.freezeSeconds != nil else {
            hidden.removeAll()
            deadline.cancel()
            return
        }
        replan()
    }

    /// O(1) on the push path (a hidden chat that streams reports every push): a later `since`
    /// only moves a page's deadline later, so a pending deadline stays right (it may fire early,
    /// and that pass arms the next); a new page's grace is the longest, so it needs a pass only
    /// when no deadline runs.
    /// Off (`browser.freezeHiddenTabs` off): nothing is recorded, so a hide costs no pass.
    public func hiddenPageWoke(_ page: PageWebView) {
        guard setting.freezeSeconds != nil else { return }
        let key = ObjectIdentifier(page)
        if let entry = hidden[key] {
            entry.since = now()
            return
        }
        hidden[key] = Hidden(page, since: now())
        if !deadline.isScheduled { replan() }
    }

    public func pageIsNoLongerHidden(_ page: PageWebView) {
        guard hidden.removeValue(forKey: ObjectIdentifier(page)) != nil else { return }
        if hidden.isEmpty { deadline.cancel() }
    }

    /// Freezes every hidden page past its grace and arms one deadline for the next.
    ///
    /// The grace is counted in the clock's own durations, so the deadline lands when the next page
    /// comes due (a clock sleep ends at or after its deadline), with no rounding margin.
    func replan() {
        hidden = hidden.filter { $0.value.page != nil }
        guard let seconds = setting.freezeSeconds else {
            deadline.cancel()
            return
        }
        let grace = Duration.seconds(seconds)
        let current = now()
        var next: Duration?
        // Iterates a copy: removing a frozen page below does not disturb the loop.
        for (key, entry) in hidden {
            let remaining = grace - (current - entry.since)
            guard remaining <= .zero else {
                next = min(next ?? remaining, remaining)
                continue
            }
            // Frozen, or not freezable now (it still boots: it reports again at its first message).
            if entry.page?.freezeWhileHidden() == true { frozenCount += 1 }
            hidden[key] = nil
        }
        if let next {
            deadline.schedule(after: next) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
    }
}
