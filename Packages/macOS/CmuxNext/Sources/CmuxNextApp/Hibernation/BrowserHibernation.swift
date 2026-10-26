import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

/// Hibernates hidden browser pages and restores them when shown
/// (plans/cmux-next/tab-lifecycle.md). Configured by
/// `browser.hibernation`; "off" disables it completely.
///
/// Triggers are events only: a page hides (a one-shot deadline for the
/// earliest page to reach its threshold), the memory coordinator's level (a
/// lossy consumer registration, `MemoryLevelConsumer` below), a settings
/// change, or the user's Hibernate Tab action. There is no polling. Before a
/// page hibernates, a probe asks it for playing media and edited form fields (with a deadline) and captures its history; the
/// hibernate event is sent only while the page is still hidden with the
/// same generation, so a page the user selects meanwhile is never touched.
///
/// Long before that, a hidden Chromium page freezes after
/// `browser.freezeHiddenTabs` seconds (30 by default) to save power, and
/// thaws when it shows, when an agent drives it, or before it hibernates.
///
/// The tabs beside each pane's shown tab (`browser.keepNeighborTabsAwake`,
/// one on each side by default) never freeze or hibernate, and wake as soon
/// as they become neighbors, so Ctrl-Tab, Cmd-Shift-[ ] and the next click
/// show a live page. A hovered tab wakes too. Memory pressure and Low Power
/// Mode turn this off (plans/cmux-next/neighbor-tabs-DESIGN.md).
///
/// Which page goes first is a ranking (`ContentDiscardPlanner.idleness`): how long it has been
/// hidden, how often the person showed it in the last hour, and under memory pressure how much
/// memory it holds. A few pages go per pass (`HibernationPlanner.Pace`), never all at once.
/// A page never hibernates while it shows, plays (an element or Web Audio; with `recentlyAudibleProtection`, a minute after), captures, has DevTools
/// open, an agent holds its lease or called it lately, a download it started runs, it holds the
/// person's form input (also in a child frame it cannot read), its `beforeunload` would ask, or it
/// has a connected WebRTC peer or an open device; the
/// page's own answers keep it at every memory pressure (`PageProbe`). Pinned tabs and Never
/// Hibernate hosts stay unless the setting says otherwise.
@MainActor
final class BrowserHibernation {
    private(set) weak var cache: TabContentCache?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
    private(set) var setting: BrowserHibernationSetting = .fallback
    private(set) var pressure: MemoryPressureLevel = .normal
    /// When each hidden page, or each page of `offScreenShown`, was last on screen.
    private var hiddenAt: [String: ContinuousClock.Instant] = [:]
    /// Pages shown in off-screen windows: kept as each window's active tab (`DiscardRule.activeTab`).
    private var offScreenShown: Set<String> = []
    /// When an agent last called each page (`noteAgentUse`).
    private(set) var agentUsedAt: [String: ContinuousClock.Instant] = [:]
    /// Seconds after an agent's call during which its hidden page stays awake
    /// whatever the memory pressure, so a page does not close under a script
    /// or between two calls of one task.
    static let agentGrace: Double = 30
    /// History and snapshot captured by the probe, used by the `release` effect.
    private var prepared: [String: (state: BrowserRestoreState, snapshot: HibernationSnapshots.Picture?)] = [:]
    /// Hibernated pages' pictures (`HibernationTunables.compressedSnapshots`), and their wakes (`debug.surfaces`).
    let snapshots = HibernationSnapshots()
    var wakeLog = HibernationWakes()
    /// A navigation that woke a hibernated page, applied once it is back; at most one per page.
    var pendingWakes: [String: HibernatedBrowserTab.Wake] = [:]
    /// Pages a discard probe is asking now.
    private(set) var probing: Set<String> = []
    /// Hidden pages whose `beforeunload` asked, once, right before a discard: they stay until shown,
    /// and their handlers do not run again on every replan (each run is the page's own unload logic
    /// on a page that lives on).
    var askedBeforeUnload: Set<String> = []
    private let deadline = DemandTimer(owner: "BrowserHibernation")
    /// Hidden pages frozen now (`browser.freezeHiddenTabs`); they thaw when shown or driven.
    private(set) var frozen: Set<String> = []
    /// Pages a freeze probe is asking (media, Web Audio, capture).
    private var freezeProbing: Set<String> = []
    /// When a page the probe kept awake (playing audio) is asked again.
    private var freezeKeptAt: [String: ContinuousClock.Instant] = [:]
    /// What each hidden page's probes said lately: the benefit of the doubt while it does not
    /// answer (the freeze probes, `freezeSeconds` apart, count the misses).
    private var probeHistory = PageProbeHistory()
    private let freezeDeadline = DemandTimer(owner: "BrowserFreeze")
    /// A frozen page whose memory grows goes with its opener group (`FrozenGrowthRule`, feature
    /// `frozenGrowthDiscard`, set by the App); `growthDeadline` is its next one-shot reading.
    var discardsGrowingFrozenPages = false
    var frozenGrowth = FrozenGrowthRule()
    let growthDeadline = DemandTimer(owner: "BrowserFrozenGrowth")
    /// Tab `key`'s opener group (its openers and the tabs they opened), itself included; injected by the App.
    var openerGroup: (String) -> Set<String> = { [$0] }
    /// The memory coordinator it registers with, made by `AppServices` (tests pass their own).
    private let memory: any MemoryConsumerRegistry
    /// Its lossy consumer registration while started; the coordinator hands it each level and limit.
    private var memoryRegistration: MemoryConsumerRegistration?
    /// The coordinator's limit: critical (0 %) means the next release slice runs an urgent pass.
    var memoryLimit = MemoryLimit.default
    /// Urgent passes the coordinator's critical release slices ran (`debug.surfaces`).
    var urgentPasses = 0
    /// Pinned state of a tab (the daemon record); injected by the App.
    var isPinned: (String) -> Bool = { _ in false }
    /// Memory pressure changed (the App resizes the terminal warm set).
    var onPressureChange: ((MemoryPressureLevel) -> Void)?
    private(set) var exemptions: [String: HibernationPlanner.Exemption] = [:]
    private var settingsObservation: Task<Void, Never>?
    private(set) var hibernatedCount = 0
    /// A page was hibernated (the App counts it in the memory histograms).
    var onHibernate: () -> Void = {}
    /// A hibernated page is back, this long after its wake started (the App records it in the memory histograms).
    var onWakeMounted: (Duration) -> Void = { _ in }
    /// Hidden agent chat pages, on the same setting and pressure.
    var agentPages: AgentPageHibernation? {
        didSet { agentPages?.update(setting: setting, pressure: pressure) }
    }
    var restoredCount = 0
    /// Each pane's tab order and shown tab, from its `PaneController`.
    private var neighbors = NeighborTabs()
    /// Tabs kept awake now because they sit beside a shown tab.
    private(set) var awakeNeighbors: Set<String> = []
    /// When the pointer last rested on each hidden tab's strip cell (`noteHover`).
    private var hoveredAt: [String: ContinuousClock.Instant] = [:]
    /// Seconds a hovered tab stays awake after the hover, as for an agent's call.
    static let hoverGrace: Double = 30
    /// Pages woken early (neighbors and hovers): `debug.surfaces` and the bench read it.
    private(set) var prewarmedCount = 0
    /// The longest a woken page's last frame stands in for it before it paints (Chrome has no
    /// picture; a page that paints later than this shows itself loading rather than look frozen).
    static let standInCap: Duration = .milliseconds(500)
    /// The clock of the stand-in cap (a seam for tests).
    var standInClock: any Clock<Duration> = ContinuousClock()
    /// Wakes with a picture whose page could show no stand-in (`debug.surfaces`).
    var uncoveredWakes = 0
    private let lowPower: LowPowerMode
    private var lowPowerObservation: LowPowerModeObservation?
    /// The app's windows going off screen and back (`occludedWindowDiscard`); nil when off.
    private var windowOcclusion: WindowOcclusionChecker?
    /// The page's freeze control (a seam for tests; Chromium pages only in the app).
    var freezer: (any BrowserTab) -> (any BrowserFreezing)? = { $0 as? any BrowserFreezing }

    /// When the person showed each tab lately (at most `focusLimit`, within `focusWindow`).
    private var focusedAt: [String: [ContinuousClock.Instant]] = [:]
    /// Seconds of focus history a tab's ranking counts.
    static let focusWindow: Double = 3_600
    static let focusLimit = 64
    /// Tabs whose browser lease an agent holds now (`noteLease`).
    private(set) var leased: Set<String> = []
    /// A download tab `key` started still runs; injected by the App.
    var isDownloading: (String) -> Bool = { _ in false }
    /// Samples each browser tab's memory (renderer footprint, shared renderers split); injected
    /// by the App. Run under memory pressure at most every `PageMemoryReadings.maxAge`, and at a
    /// frozen page's freeze and one-shot readings (`FrozenGrowthRule`).
    var measureMemory: (() async -> [String: PageMemoryReading])?
    /// The last readings; only their own methods change them (the sampling lives in +Probe).
    var memoryReadings = PageMemoryReadings()
    var memoryBytes: [String: UInt64] { memoryReadings.bytes }
    /// Each hibernated page's memory in its last measurement before the discard (`memoryBytes`, from
    /// the pressure sample or the Task Manager's), kept while it sleeps: what Memory Saver saved by
    /// discarding it. Set at `release`, dropped when the page wakes or closes. Chrome records the
    /// same number on the page at discard time (`PreDiscardResourceUsage`,
    /// chrome/browser/performance_manager/public/user_tuning/user_performance_tuning_manager.h).
    var savedBytes: [String: UInt64] = [:]
    /// When the probe last kept each page; under pressure such a page ranks after the others
    /// for `keptBackoff` seconds, so one playing page does not hold up the relief of the rest.
    private var probeKeptAt: [String: ContinuousClock.Instant] = [:]
    static let keptBackoff: Double = 60
    /// Hidden pages' title and icon changes (`DiscardRule.backgroundActivity`); the App turns it on.
    let activity = PageActivityWatch()
    /// When each page last played sound (`DiscardRule.recentlyAudible`); the end of a hidden page's
    /// sound replans. Nil while the `recentlyAudibleProtection` feature is off: no page is watched,
    /// no candidate carries a sound fact, and the plans are those from before the rule.
    let audible: AudibleHistory?
    /// Seconds after the last replan that the hibernation deadline fires; nil when none is armed.
    private(set) var nextCheck: Double?

    /// - Parameters:
    ///   - lowPower: The app's Low Power Mode (its energy monitor's); the default, fixed off, is for tests.
    ///   - audible: The pages' sound history (`recentlyAudibleProtection`); nil turns the recently
    ///     audible protection off.
    init(cache: TabContentCache, memory: any MemoryConsumerRegistry, lowPower: LowPowerMode = LowPowerMode(enabled: false),
         audible: AudibleHistory? = nil) {
        self.cache = cache
        self.lowPower = lowPower
        self.memory = memory
        self.audible = audible
        audible?.onEnded = { [weak self] key in self?.soundDidEnd(key) }
    }

    /// Tabs on each side of a shown tab that stay awake now: the setting, or 0
    /// under memory pressure or in Low Power Mode.
    var neighborRadius: Int {
        NeighborTabs.radius(setting: setting.neighborRadius, pressure: pressure, lowPower: lowPower.isEnabled)
    }

    /// Registers with the memory coordinator as one lossy consumer (event-driven, no polling): the
    /// coordinator hands it the current level at once, then each change on the main actor, and
    /// `stop()` cancels the registration at once, so none lands after `stop()`.
    func start() {
        guard memoryRegistration == nil else { return }
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: memory)
        lowPowerObservation = lowPower.observe { [weak self] _ in self?.refreshNeighbors() }
        // Pages mounted before the hibernation existed (a restored session) are followed too.
        for (key, entry) in cache?.browsers ?? [:] { pageDidMount(key, entry.tab) }
    }

    func stop() {
        windowOcclusion?.stop()
        windowOcclusion = nil
        settingsObservation?.cancel()
        memoryRegistration?.cancel()
        memoryRegistration = nil
        lowPowerObservation?.cancel()
        lowPowerObservation = nil
        deadline.cancel()
        nextCheck = nil
        freezeDeadline.cancel()
        growthDeadline.cancel()
        hoverDwell.cancel()
        activity.stop()
    }

    /// Follows `checker`'s off-screen windows from now until `stop()`.
    func follow(_ checker: WindowOcclusionChecker) {
        windowOcclusion?.stop()
        windowOcclusion = checker
        checker.onChange = { [weak self] window, offScreen in self?.cache?.windowDidChangeOnScreen(window, offScreen: offScreen) }
        checker.onClose = { [weak self] window in self?.cache?.offScreenWindowDidClose(window) }
        checker.start()
    }

    /// The app ordered a window in (`WindowActivation`): the checker looks again.
    func windowsDidReorder() { windowOcclusion?.windowsDidReorder() }

    /// Applies every loaded cmux.json snapshot's `browser.hibernation`.
    func follow(_ settings: SettingsController) {
        settingsObservation?.cancel()
        settingsObservation = Task { [weak self] in
            for await setting in ObservationStream({ settings.snapshot.browserHibernation }) {
                self?.apply(setting)
            }
        }
    }

    func apply(_ setting: BrowserHibernationSetting) {
        guard setting != self.setting else { return }
        self.setting = setting
        agentPages?.update(setting: setting, pressure: pressure)
        if !setting.isEnabled { stopGrowthReadings() }
        refreshNeighbors(replans: false)
        replan()
    }

    /// Takes a new pressure level; `replans` false leaves the pass to the caller (the coordinator's
    /// critical release slice, `releaseMemory(within:)`).
    func pressureDidChange(_ level: MemoryPressureLevel, replans: Bool = true) {
        guard level != pressure else { return }
        pressure = level
        logger.info("memory pressure \(level.rawValue, privacy: .public)")
        onPressureChange?(level)
        agentPages?.update(setting: setting, pressure: pressure)
        refreshNeighbors(replans: false)
        guard replans else { return }
        replan()
        refreshMemoryIfNeeded()
    }

    /// An agent took (`held`) or let go of tab `key`'s browser lease. A leased page never
    /// freezes or hibernates; it thaws at once so the agent's next call runs.
    func noteLease(_ key: String, held: Bool) {
        if held {
            guard leased.insert(key).inserted else { return }
            thaw(key)
        } else {
            guard leased.remove(key) != nil else { return }
            if exemptions[key] == .agentLease { exemptions[key] = nil }
            // The agent left it: its hidden clock starts now.
            if cache?.lifecycle.phase(key) == .mountedHidden { hiddenAt[key] = .now }
        }
        replan()
    }

    // MARK: Lifecycle notifications (from TabContentCache effects)

    func tabDidHide(_ key: String) {
        guard let tab = cache?.browsers[key]?.tab else { return }
        _ = markOffScreen(key, false)
        hiddenAt[key] = .now
        watchActivity(key, tab)
        replan()
    }

    func tabDidShow(_ key: String) {
        if frozen.contains(key) { coldShows += 1 }
        thaw(key)
        freezeKeptAt[key] = nil
        probeHistory.clearMisses(key)
        hoveredAt[key] = nil
        hiddenAt[key] = nil
        offScreenShown.remove(key)
        prepared[key] = nil
        exemptions[key] = nil
        probeKeptAt[key] = nil
        askedBeforeUnload.remove(key)
        activity.forget(key)
        noteFocus(key, at: .now)
    }

    /// Records a show of tab `key` for its ranking, dropping shows older than `focusWindow`.
    func noteFocus(_ key: String, at now: ContinuousClock.Instant) {
        var times = focusedAt[key, default: []].filter { (now - $0).seconds < Self.focusWindow }
        times.append(now)
        if times.count > Self.focusLimit { times.removeFirst(times.count - Self.focusLimit) }
        focusedAt[key] = times
    }

    /// Shows of tab `key` within `focusWindow` of `now`.
    func recentFocusCount(_ key: String, now: ContinuousClock.Instant) -> Int {
        focusedAt[key]?.filter { (now - $0).seconds < Self.focusWindow }.count ?? 0
    }

    /// An agent acted on tab `key` (`cmux browser`, MCP, the browser REPL):
    /// a hidden page's clock starts again, so a page an agent drives in the
    /// background does not hibernate between two of its calls, and a page an
    /// agent woke sleeps again once the agent leaves it alone that long.
    func noteAgentUse(_ key: String) {
        guard let cache, cache.browsers[key] != nil else { return }
        agentUsedAt[key] = .now
        // Before the agent's call goes out: a frozen page runs no script.
        thaw(key)
        guard cache.lifecycle.phase(key) == .mountedHidden else { return }
        hiddenAt[key] = .now
        replan()
    }

    func forget(_ key: String) {
        agentPages?.forget(key)
        cache?.dormantTabs.set(key, false)
        hiddenAt[key] = nil
        agentUsedAt[key] = nil
        prepared[key] = nil
        probing.remove(key)
        askedBeforeUnload.remove(key)
        exemptions[key] = nil
        frozen.remove(key)
        untrackGrowth(key)
        freezeProbing.remove(key)
        freezeKeptAt[key] = nil
        probeHistory.forget(key)
        hoveredAt[key] = nil
        awakeNeighbors.remove(key)
        focusedAt[key] = nil
        leased.remove(key)
        offScreenShown.remove(key)
        memoryReadings.forget(key)
        savedBytes[key] = nil
        probeKeptAt[key] = nil
        audible?.forget(key)
        snapshots.remove(key)
        wakeLog.forget(key)
        activity.forget(key)
    }

    // MARK: Neighbors

    /// A pane's tab order or shown tab changed (a switch, reorder, close or
    /// new tab); `selected` is nil while the pane shows nothing or is parked.
    func paneDidChange(_ pane: ObjectIdentifier, order: [String], selected: String?) {
        neighbors.set(pane, order: order, selected: selected)
        refreshNeighbors()
    }

    /// The pane is gone: its tabs are no longer anyone's neighbors.
    func paneDidGo(_ pane: ObjectIdentifier) {
        neighbors.remove(pane)
        refreshNeighbors()
    }

    /// The window of `panes` (showing `shownPages`) went off screen or came back: an off-screen
    /// pane keeps no neighbors awake, and back on screen they wake as neighbors again.
    func panesDidChangeScreen(_ panes: [ObjectIdentifier], shownPages: [String], offScreen: Bool) {
        guard !panes.isEmpty else { return }
        for pane in panes { neighbors.setOffScreen(offScreen, pane: pane) }
        for key in shownPages { _ = markOffScreen(key, offScreen) }
        refreshNeighbors(replans: false)
        replan()
    }

    /// Shown page `key` is in an off-screen window (a switch or a move there) or not.
    func pageDidChangeScreen(_ key: String, offScreen: Bool) {
        if markOffScreen(key, offScreen) { replan() }
    }

    /// Starts or stops shown page `key`'s hidden clock with its window; true when that changed.
    private func markOffScreen(_ key: String, _ offScreen: Bool) -> Bool {
        if offScreen {
            guard offScreenShown.insert(key).inserted else { return false }
            hiddenAt[key] = .now
        } else {
            guard offScreenShown.remove(key) != nil else { return false }
            hiddenAt[key] = nil
            if exemptions[key] == .activeTab { exemptions[key] = nil }
        }
        return true
    }

    /// The pointer moved onto hidden tab `key` in a strip (nil: off every tab).
    /// A frozen page thaws at once (one message); a hibernated page restores
    /// only once the pointer stays `hoverDwell`, so a sweep across the strip
    /// reloads nothing. Either stays awake `hoverGrace` seconds after.
    func noteHover(_ key: String?) {
        hoverDwell.cancel()
        guard let key, neighborRadius > 0, let cache, cache.browsers[key] != nil,
              cache.lifecycle.phase(key) != .mountedVisible else { return }
        hoveredAt[key] = .now
        thaw(key, prewarm: true)
        if cache.lifecycle.phase(key) == .hibernated {
            // Justified delay: a dwell, not a poll; the next hover change cancels it.
            hoverDwell.schedule(after: Self.hoverDwellDelay) { @MainActor [weak self] in self?.warm(key) }
        }
        replan()
    }

    /// How long the pointer stays on a hibernated tab before it restores.
    static let hoverDwellDelay: Duration = .milliseconds(150)
    private let hoverDwell = DemandTimer(owner: "BrowserNeighborHover")

    /// Recomputes the awake neighbors; a new neighbor wakes now (thaws, or
    /// restores in the background), and one that stops being a neighbor
    /// starts its hidden clock again, so it sleeps `freezeSeconds` later.
    private func refreshNeighbors(replans: Bool = true) {
        guard let cache else { return }
        let next = neighbors.awake(radius: neighborRadius).filter { cache.browsers[$0] != nil }
        guard next != awakeNeighbors else { return }
        let left = awakeNeighbors.subtracting(next)
        let joined = next.subtracting(awakeNeighbors)
        awakeNeighbors = next
        let now = ContinuousClock.now
        for key in left where cache.lifecycle.phase(key) == .mountedHidden {
            hiddenAt[key] = now
            if exemptions[key] == .neighbor { exemptions[key] = nil }
        }
        for key in joined { warm(key) }
        if replans { replan() }
    }

    /// Wakes a hidden page early: thaws a frozen one, restores a hibernated one
    /// in the background (the lifecycle keeps it hidden until selected).
    private func warm(_ key: String) {
        guard let cache else { return }
        thaw(key, prewarm: true)
        if cache.lifecycle.phase(key) == .hibernated {
            cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
            prewarmedCount += 1
            cache.trace(key, "prewarmed (restore)")
        }
    }

    /// Seconds until the hover grace of `key` ends; nil when it is not hovered (or it ended).
    private func hoverLeft(_ key: String, now: ContinuousClock.Instant) -> Double? {
        guard let at = hoveredAt[key] else { return nil }
        let left = Self.hoverGrace - (now - at).seconds
        if left > 0, neighborRadius > 0 { return left }
        hoveredAt[key] = nil
        return nil
    }

    // MARK: Planning

    /// Hibernates every due page and arms one deadline for the next.
    func replan() {
        guard let cache else { return }
        let now = ContinuousClock.now
        let shownOffScreen = offScreenShown.filter { cache.lifecycle.phase($0) == .mountedVisible }
        let hidden = (cache.lifecycle.keys(in: .mountedHidden) + shownOffScreen).compactMap { hiddenCandidate($0, now: now) }
        let candidates = hidden.map { $0.facts }
        let graceEnds = hidden.compactMap { $0.graceEnds }.min()
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: candidates)
        for key in plan.endedSoundReasons(of: candidates.map(\.key), held: exemptions, probeKept: { probeKeptAt[$0] != nil }) {
            exemptions[key] = nil
        }
        exemptions.merge(plan.exemptions) { $1 }
        if !plan.due.isEmpty { refreshMemoryIfNeeded() }
        for key in plan.due { prepare(key, for: HibernationPlanner.discardReason(at: pressure)) }
        nextCheck = [plan.nextCheck, graceEnds].compactMap(\.self).min()
        if let next = nextCheck {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
        replanFreeze(candidates.filter { !$0.isNeighbor && !$0.isAgentDriving && !$0.isActiveTab })
    }

    /// The planner's facts of hidden page `key` (or of a page shown in an off-screen window, kept as
    /// its active tab) now, and in how many seconds its hover or agent grace ends; nil when it is no
    /// such page that could go. Graces that ended are dropped.
    private func hiddenCandidate(_ key: String, now: ContinuousClock.Instant) -> (facts: HibernationPlanner.Candidate, graceEnds: Double?)? {
        guard let cache, let at = hiddenAt[key], !probing.contains(key), let entry = cache.browsers[key] else { return nil }
        let phase = cache.lifecycle.phase(key)
        let shownOffScreen = offScreenShown.contains(key)
        guard phase == .mountedHidden || (shownOffScreen && phase == .mountedVisible) else { return nil }
        var facts = candidate(key, entry: entry, hiddenFor: (now - at).seconds, now: now)
        facts.isActiveTab = shownOffScreen
        // Beside a shown tab or just hovered: stays awake for an instant switch (`DiscardRule.neighbor`).
        var graceEnds = awakeNeighbors.contains(key) ? nil : hoverLeft(key, now: now)
        facts.isNeighbor = awakeNeighbors.contains(key) || graceEnds != nil
        if !facts.isNeighbor, exemptions[key] == .neighbor { exemptions[key] = nil }
        if !facts.isNeighbor, let used = agentUsedAt[key] {
            let left = Self.agentGrace - (now - used).seconds
            if left > 0, setting.isEnabled {
                facts.isAgentDriving = true
                graceEnds = left
            } else {
                agentUsedAt[key] = nil
                if exemptions[key] == .agentDriving { exemptions[key] = nil }
            }
        }
        if let kept = probeKeptAt[key] {
            if (now - kept).seconds < Self.keptBackoff { facts.recentlyKept = true } else { probeKeptAt[key] = nil }
        }
        return (facts, graceEnds)
    }

    /// Frozen pages whose memory grew (`FrozenGrowthRule.record`) go with the frozen hidden pages of
    /// their opener group; the lead rule and the person's choices still keep any of them.
    func discardGrowing(_ growing: [String]) {
        let now = ContinuousClock.now
        let members = Set(growing.flatMap { openerGroup($0).union([$0]) })
        let hidden = members.reduce(into: [String: HibernationPlanner.Candidate]()) { $0[$1] = hiddenCandidate($1, now: now)?.facts }
        let plan = frozenGrowth.plan(growing: growing, groups: openerGroup, candidates: hidden, setting: setting)
        exemptions.merge(plan.exemptions) { $1 }
        for key in plan.due {
            cache?.trace(key, "discard (\(DiscardReason.frozenWithGrowingMemory.rawValue))")
            prepare(key, for: .frozenWithGrowingMemory)
        }
    }

    // MARK: Freeze

    /// Freezes every hidden page past `freezeSeconds` and arms one deadline
    /// for the next (`HibernationPlanner.freezePlan`). Events only, as for hibernation.
    private func replanFreeze(_ hidden: [HibernationPlanner.Candidate]) {
        guard let cache else { return }
        let now = ContinuousClock.now
        let threshold = setting.freezeSeconds
        var recheck: Double?
        let candidates = hidden.filter { candidate in
            guard !frozen.contains(candidate.key), !freezeProbing.contains(candidate.key),
                  let tab = cache.browsers[candidate.key]?.tab, freezer(tab) != nil else { return false }
            if let kept = freezeKeptAt[candidate.key], let threshold {
                let left = threshold - (now - kept).seconds
                if left > 0 { recheck = min(recheck ?? left, left); return false }
                freezeKeptAt[candidate.key] = nil
            }
            return true
        }
        let plan = HibernationPlanner.freezePlan(setting, candidates: candidates)
        for key in plan.due { freeze(key) }
        if let next = [plan.nextCheck, recheck].compactMap(\.self).min() {
            freezeDeadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            freezeDeadline.cancel()
        }
    }

    /// Asks the page for playing media, Web Audio, capture, WebRTC and open devices, then freezes it
    /// if it is still the same hidden page. A page that plays, or that still gets the
    /// benefit of the doubt (`PageProbeHistory`), stays awake and is asked again after
    /// `freezeSeconds`.
    private func freeze(_ key: String) {
        guard let cache, let tab = cache.browsers[key]?.tab, let page = freezer(tab),
              let generation = cache.lifecycle.record(key)?.generation, freezeProbing.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            let probe = await Self.probe(tab)
            guard let self, let cache = self.cache else { return }
            self.freezeProbing.remove(key)
            guard cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
                  cache.lifecycle.phase(key) == .mountedHidden, self.hiddenAt[key] != nil else { return }
            // An agent called it, or it became a neighbor (or was hovered) while the probe ran.
            guard self.mayFreeze(key) else { return }
            let doubted = self.probeHistory.record(probe, for: key, step: .freeze)
            if probe.audible { self.audible?.heard(key) }
            if probe.stopsWhenFrozen || doubted {
                self.freezeKeptAt[key] = .now
                self.replan()
                return
            }
            self.freeze(key, page)
        }
    }

    /// No agent drives the hidden page (`isAgentDriven`), it showed no background activity (its
    /// updates stay live), and it is no neighbor or hovered tab.
    private func mayFreeze(_ key: String) -> Bool {
        !isAgentDriven(key) && !activity.contains(key) && !awakeNeighbors.contains(key) && hoverLeft(key, now: .now) == nil
    }

    private func freeze(_ key: String, _ page: any BrowserFreezing) {
        // The engine refuses a page it still counts visible: it stays awake and is asked again
        // after `freezeSeconds` (a hidden page's visibility reaches the engine within a frame).
        guard page.setFrozen(true) else {
            freezeKeptAt[key] = .now
            cache?.trace(key, "freeze refused")
            replan()
            return
        }
        frozen.insert(key)
        cache?.trace(key, "frozen")
        trackGrowth(key)
    }

    /// Thaws a frozen page (shown, driven by an agent, about to hibernate, or
    /// woken early as a neighbor or hovered tab: `prewarm`).
    private func thaw(_ key: String, prewarm: Bool = false) {
        guard frozen.remove(key) != nil else { return }
        untrackGrowth(key)
        if let tab = cache?.browsers[key]?.tab { freezer(tab)?.setFrozen(false) }
        if prewarm { prewarmedCount += 1 }
        cache?.trace(key, prewarm ? "prewarmed (thaw)" : "thawed")
    }

    /// Shows of a page that was still frozen (it thawed on the switch): the cold
    /// switches neighbors exist to avoid (`debug.surfaces`, the bench).
    private(set) var coldShows = 0

    // MARK: Hibernate

    /// The user's Hibernate Tab action (Chrome's external discard): a hidden page hibernates now
    /// unless a disallowed rule keeps it (`HibernationPlanner.hibernateTabRefusal`). Returns why
    /// not, or nil when it started.
    func hibernateNow(_ key: String) -> HibernationPlanner.Exemption? {
        guard let cache, let entry = cache.browsers[key], cache.lifecycle.phase(key) == .mountedHidden else { return .disabled }
        if let refusal = HibernationPlanner.hibernateTabRefusal(candidate(key, entry: entry, hiddenFor: 0), setting: setting) {
            exemptions[key] = refusal
            return refusal
        }
        prepare(key, for: .external)
        return nil
    }

    /// Probes the page, captures its history and snapshot, then hibernates it if it is still hidden
    /// with the same generation. `.external` is the person's Hibernate Tab, which asks the page nothing.
    private func prepare(_ key: String, for reason: DiscardReason) {
        let user = reason == .external
        guard let cache, let entry = cache.browsers[key], let source = entry.tab as? any BrowserHibernationSource,
              let generation = cache.lifecycle.record(key)?.generation, probing.insert(key).inserted else { return }
        let tab = entry.tab
        // The probe and the history capture run script: a frozen page runs none.
        thaw(key)
        Task { @MainActor [weak self] in
            // The person's Hibernate Tab asks the page nothing (only a disallowed rule keeps it).
            var exemption: HibernationPlanner.Exemption?
            var mayAsk = false
            if user {
                exemption = self.flatMap { HibernationPlanner.hibernateTabRefusal($0.candidate(key, entry: entry, hiddenFor: 0), setting: $0.setting) }
            } else {
                let probe = await Self.probe(tab)
                if probe.audible { self?.audible?.heard(key) }
                // The freeze probe counts the misses (it runs beside this one and refreezes the
                // page); this one records an answer only.
                let doubted = probe.answered ? self?.probeHistory.record(probe, for: key) ?? false : self?.probeHistory.doubted(key) ?? true
                // A timeout or pressure discard reads the pressure of the answer's turn.
                exemption = self.flatMap { probe.keepReason($0.candidate(key, entry: entry, hiddenFor: 0), setting: $0.setting,
                                                            for: reason == .frozenWithGrowingMemory ? reason : HibernationPlanner.discardReason(at: $0.pressure),
                                                            doubted: doubted) }
                mayAsk = probe.unloadHandler
            }
            // A page that stays needs no picture (each replan probes it again).
            let snapshot = exemption == nil ? await self?.snapshot(tab, key: key) : nil
            guard let self else { return }
            // The page's beforeunload handlers run last, only when nothing else keeps it, still hidden
            // and about to go, and at most once while it stays hidden (`askedBeforeUnload`).
            if exemption == nil, mayAsk, self.discardCheck(key, tab: tab, generation: generation, user: user) == .go {
                exemption = await self.asksBeforeUnload(key, tab) ? .beforeUnload : nil
            }
            guard let cache = self.cache else { return }
            self.probing.remove(key)
            switch self.discardCheck(key, tab: tab, generation: generation, user: user) {
            case .stale:
                cache.trace(key, "hibernate probe dropped (stale)")
                return
            case .keep(let reason) where exemption == nil:
                self.exemptions[key] = reason
                return
            case .keep, .go:
                break
            }
            if let exemption {
                self.exemptions[key] = exemption
                self.probeKeptAt[key] = .now
                return
            }
            guard let state = source.hibernationState() else {
                self.exemptions[key] = .unsupported
                return
            }
            self.prepared[key] = (state, snapshot)
            cache.applyLifecycle(cache.lifecycle.send(.hibernate(key)))
        }
    }

    /// Takes a hidden page's picture (a seam for tests).
    var capture: (any BrowserTab) async -> CGImage? = { tab in
        try? await ControlDeadline.shared.run(method: "hibernation.snapshot", deadline: .now + .seconds(2)) { @MainActor in
            try await tab.snapshot()
        }
    }

    /// The `release` effect: swaps the page for a `HibernatedBrowserTab`
    /// holding its history, and closes the engine page. Its snapshot lives in a bounded store
    /// only (`keep`): each placeholder used to keep its own full-size picture (about 7 MB of
    /// app memory per hibernated tab in the 2026-10-14 audit).
    func release(_ key: String, token: ContentLifecycle<String>.Token) {
        guard let cache, let entry = cache.browsers[key], let saved = prepared.removeValue(forKey: key) else {
            logger.error("hibernate \(key, privacy: .public): nothing prepared")
            return
        }
        let page = entry.tab
        let placeholder = HibernatedBrowserTab(
            id: page.id, engine: page.engineKind, profile: page.profileID, state: page.state,
            favicon: page.favicon, restoreState: saved.state, snapshot: { [weak self] in self?.snapshotImage(key) }
        )
        placeholder.onWake = { [weak self] wake in self?.wakeForNavigation(key, wake) }
        if let snapshot = saved.snapshot { keep(snapshot, for: key) }
        cache.swapPage(key, with: placeholder)
        cache.dormantTabs.set(key, true)
        savedBytes[key] = memoryBytes[key].flatMap { $0 > 0 ? $0 : nil }
        hiddenAt[key] = nil
        activity.forget(key)
        // A probe that kept the page before no longer applies (`debug.surfaces`).
        exemptions[key] = nil
        hibernatedCount += 1
        onHibernate()
        logger.info("hibernated \(key, privacy: .public) \(token.description, privacy: .public)")
    }

    /// Whether hidden page `key` may still be discarded, checked again after each await of `prepare`:
    /// `.stale` when it is no longer this hidden page (shown, hidden again or closed); `.keep` when it
    /// became a neighbor, was hovered, or an agent called it while the probe ran (the person's
    /// Hibernate Tab, `user`, still applies to those).
    private func discardCheck(_ key: String, tab: any BrowserTab, generation: UInt64, user: Bool) -> DiscardCheck {
        guard let cache, cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
              cache.lifecycle.phase(key) == .mountedHidden else { return .stale }
        if user { return .go }
        if awakeNeighbors.contains(key) || hoverLeft(key, now: .now) != nil { return .keep(.neighbor) }
        if let used = agentUsedAt[key], (ContinuousClock.now - used).seconds < Self.agentGrace { return .keep(.agentDriving) }
        return .go
    }

    private enum DiscardCheck: Equatable {
        case go, stale
        case keep(HibernationPlanner.Exemption)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
