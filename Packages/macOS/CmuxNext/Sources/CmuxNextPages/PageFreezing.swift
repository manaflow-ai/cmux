public import CmuxNextSettings
import CmuxNextWakeups

/// Freezes cmux pages in Chromium that nobody sees (Home, Settings, Diff, Files, History, Stats,
/// Cloud, Keybindings, agent chats) by the rule that freezes hidden browser tabs:
/// `browser.freezeHiddenTabs` seconds unseen (30 by default; `off` never), through the app's freeze
/// plan (`HibernationPlanner.freezePlan`, handed in as ``Plan``) (perf-lead.md F3). A page you
/// switched away from, or whose window is covered, minimized or ordered out, then stops its timers,
/// React effects and clocks and takes no push, so it costs no CPU and no wakeups.
///
/// Events only, no polling: a page reports when it hides or does something while hidden
/// (``PageFreezePolicy``), and one deadline runs for the next page to come due. An owner may keep a
/// page awake while it works unseen (``exemption``, a chat whose turn runs); ``replan()`` after the
/// owner's state changed freezes it, or thaws a frozen page that the owner needs now. Releasing a
/// hidden chat's page after the hibernation threshold stays with the app's `AgentPageHibernation`.
///
/// ```swift
/// let freezing = PageFreezing(plan: { setting, hidden in (hidden.filter { $0.value >= 30 }.map(\.key), nil) })
/// let host = ChromiumPageHost(cef: cef, preference: preference, keyRouter: router, freezePolicy: freezing)
/// ```
@MainActor
public final class PageFreezing: PageFreezePolicy {
    /// The freeze plan: the keys of the pages due now, of `hidden` (key to seconds unseen), and the
    /// seconds until the next one is (nil: none will).
    public typealias Plan = @MainActor (_ setting: BrowserHibernationSetting, _ hidden: [String: Double]) -> (due: [String], next: Double?)

    private final class Entry {
        weak var page: PageWebView?
        var since: ContinuousClock.Instant

        init(_ page: PageWebView, since: ContinuousClock.Instant) {
            self.page = page
            self.since = since
        }
    }

    private let plan: Plan
    private(set) var setting: BrowserHibernationSetting = .fallback
    /// Unseen, awake pages and since when.
    private var hidden: [ObjectIdentifier: Entry] = [:]
    /// Pages this froze, so an owner's need can thaw them.
    private var frozen: [ObjectIdentifier: Entry] = [:]
    private let deadline: DemandTimer
    /// A pass runs now: a page it thaws reports back inside it, and that needs no pass of its own.
    private var planning = false
    /// Why an owner keeps `page` awake while unseen, or nil (the app: a chat whose turn runs or
    /// waits on the person). Such a page never comes due; the owner calls ``replan()`` when that
    /// changes.
    public var exemption: @MainActor (PageWebView) -> String? = { _ in nil }
    /// The clock (tests set it).
    public var now: () -> ContinuousClock.Instant = { .now }
    /// Pages frozen so far (`debug.surfaces`, tests).
    public private(set) var frozenCount = 0

    /// - Parameters:
    ///   - plan: Which unseen pages are due (the browser tabs' freeze plan).
    ///   - clock: The deadline's clock (tests pass one they step).
    public init(plan: @escaping Plan, clock: any Clock<Duration> = ContinuousClock()) {
        self.plan = plan
        deadline = DemandTimer(owner: "CmuxPageFreeze", clock: clock)
    }

    /// Unseen, awake pages the policy waits on (tests).
    public var waitingCount: Int { hidden.values.filter { $0.page != nil }.count }
    /// A page is due later and the timer for it runs (tests).
    public var hasDeadline: Bool { deadline.isScheduled }

    /// Follows `browser.hibernation` (its `freezeHiddenTabs`).
    public func update(setting: BrowserHibernationSetting) {
        guard setting != self.setting else { return }
        self.setting = setting
        replan()
    }

    /// O(1) on the push path (a page that keeps working while hidden reports often): a later
    /// `since` only moves a page's deadline later, so a pending deadline stays right (it may fire
    /// early, and that pass arms the next); a new page's grace is the longest, so it needs a pass
    /// only when no deadline runs.
    public func hiddenPageWoke(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        frozen[key] = nil
        if let entry = hidden[key] {
            entry.since = now()
            return
        }
        hidden[key] = Entry(page, since: now())
        if !deadline.isScheduled, !planning { replan() }
    }

    public func pageIsNoLongerHidden(_ page: PageWebView) {
        let key = ObjectIdentifier(page)
        frozen[key] = nil
        guard hidden.removeValue(forKey: key) != nil else { return }
        if hidden.isEmpty { deadline.cancel() }
    }

    /// Thaws frozen pages an owner now keeps awake, freezes every unseen page past its grace, and
    /// arms one deadline for the next.
    public func replan() {
        planning = true
        defer { planning = false }
        hidden = hidden.filter { $0.value.page != nil }
        frozen = frozen.filter { $0.value.page != nil }
        for (key, entry) in frozen {
            guard let page = entry.page, exemption(page) != nil else { continue }
            frozen[key] = nil
            // Reports itself as woken while hidden: it waits in `hidden`, exempt, with no deadline.
            page.thawWhileHidden()
        }
        let current = now()
        var unseen: [String: Double] = [:]
        for (key, entry) in hidden {
            guard let page = entry.page, exemption(page) == nil else { continue }
            unseen[Self.name(key)] = (current - entry.since).seconds
        }
        let plan = plan(setting, unseen)
        let due = Set(plan.due)
        for (key, entry) in hidden where due.contains(Self.name(key)) {
            hidden[key] = nil
            // Frozen, or not freezable now (it still boots or talks to the host: it reports again).
            guard let page = entry.page, page.freezeWhileHidden() else { continue }
            frozenCount += 1
            frozen[key] = entry
        }
        if let next = plan.next {
            // The deadline is the plan's own; 50 ms past it, so the pass finds the page due.
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
    }

    /// The plan's key of a live page: its object address, unique while the page lives.
    private static func name(_ key: ObjectIdentifier) -> String { String(UInt(bitPattern: key)) }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
