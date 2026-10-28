import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextMemory
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

/// Hibernates hidden browser pages and restores them when shown (plans/cmux-next/tab-lifecycle.md).
/// Configured by `browser.hibernation`; "off" disables it completely.
///
/// Triggers are events only: a page hides (a one-shot deadline for the earliest page to reach its
/// threshold), the memory coordinator's level (a lossy consumer registration, `MemoryLevelConsumer`
/// below), a settings change, or the user's Hibernate Tab action. There is no polling. Before a page
/// hibernates, a probe asks it for playing media and edited form fields (with a deadline) and captures
/// its history; the hibernate event is sent only while the page is still hidden with the same
/// generation, so a page the user selects meanwhile is never touched.
///
/// Long before that, a hidden Chromium page freezes after `browser.freezeHiddenTabs` seconds (30 by
/// default) to save power, and thaws when it shows, when an agent drives it, or before it hibernates.
///
/// The tabs beside each pane's shown tab (`browser.keepNeighborTabsAwake`, one on each side by default)
/// never freeze or hibernate, and wake as soon as they become neighbors, so Ctrl-Tab, Cmd-Shift-[ ] and
/// the next click show a live page. A hovered tab wakes too. Memory pressure and Energy Saver turn
/// this off (plans/cmux-next/neighbor-tabs-DESIGN.md), as Chrome's battery saver spends no work on
/// pages nobody sees (chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc).
/// In the saver a hidden page at Chrome's high-CPU proportion freezes before the delay (`saverCPU`).
///
/// Which page goes first is a ranking (`ContentDiscardPlanner.idleness`): how long it has been hidden, how
/// often the person showed it in the last hour, and under memory pressure how much memory it holds. A few
/// pages go per pass (`HibernationPlanner.Pace`), never all at once. A page never hibernates while it
/// shows, plays (an element or Web Audio; with `recentlyAudibleProtection`, a minute after), captures, has
/// DevTools open, an agent holds its lease or called it lately, a download it started runs, it holds the
/// person's form input (also in a child frame it cannot read), its `beforeunload` would ask, or it has a
/// connected WebRTC peer or an open device; the page's own answers keep it at every memory pressure
/// (`PageProbe`). Pinned tabs and Never Hibernate hosts stay unless the setting says otherwise.
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
    /// Seconds after an agent's call during which its hidden page stays awake whatever the memory
    /// pressure, so a page does not close under a script or between two calls of one task.
    static let agentGrace: Double = 30
    /// History and snapshot captured by the probe, used by the `release` effect.
    private var prepared: [String: (state: BrowserRestoreState, snapshot: PurgeablePicture?)] = [:]
    /// Hibernated pages' pictures, sized by the cache's `ImageCacheShares`, and their wakes (`debug.surfaces`).
    let snapshots: HibernationSnapshots
    var wakeLog = HibernationWakes()
    /// A navigation that woke a hibernated page, applied once it is back; at most one per page.
    var pendingWakes: [String: HibernatedBrowserTab.Wake] = [:]
    /// Pages a discard probe is asking now.
    private(set) var probing: Set<String> = []
    /// Pages whose discard was tried and did not finish (a refused freeze, a `beforeunload` that asked, no restore state,
    /// nothing prepared at release): kept from every discard until shown (`DiscardRule.discardAttempted`).
    var discardAttempts = ContentDiscardPlanner.AttemptMarkers()
    /// The next page to come due: one background deadline (nobody sees a discard happen).
    private let deadline: MainDeadline
    /// Hidden pages frozen now (`browser.freezeHiddenTabs`); they thaw when shown or driven.
    private(set) var frozen: Set<String> = []
    /// Pages a freeze probe is asking (media, Web Audio, capture).
    private var freezeProbing: Set<String> = []
    /// Which hidden pages may freeze: pages kept awake, Chrome's reasons and opener groups (`memoryFreezeEligibility`).
    let freezeRules = FreezeEligibility()
    /// What each hidden page's probes said lately: the benefit of the doubt while it does not
    /// answer (the freeze probes, `freezeSeconds` apart, count the misses).
    private var probeHistory = PageProbeHistory()
    private let freezeDeadline: MainDeadline
    /// A frozen page whose memory grows goes with its opener group (`FrozenGrowthRule`, feature
    /// `frozenGrowthDiscard`, set by the App); `growthDeadline` is its next one-shot reading.
    var discardsGrowingFrozenPages = false
    /// cmux pages in browser tabs (`BrowserAppPage`) hibernate as web pages do (feature
    /// `memoryDiscardPageTabs`, set by the App); off, they count as pages that cannot restore.
    var discardsAppPages = false
    /// Remote desktop and remote browser tabs (`BrowserStreamedPage`) hibernate to their last frame
    /// (feature `memoryDiscardRemoteTabs`, set by the App); off, they count as pages that cannot restore.
    var discardsStreamedPages = false
    /// A page shown in an off-screen window that does not follow its tab's node freezes at once, hidden to the
    /// engine first (feature `offScreenWindowPageFreeze`, set by the App; `Candidate.freezeCandidate`).
    var freezesOffScreenShownPages = false
    /// A hidden Chromium page whose out-of-process frame crashed is discarded (``subframeDidCrash(_:)``, feature
    /// `memoryDiscardCrashedSubframes`, set by the App before pages mount); off, it keeps its sad frame.
    var discardsCrashedSubframes = false
    /// Pages with a crashed frame: the document generation it crashed in (a new document has none).
    var crashedSubframes: [String: UInt64] = [:]
    var frozenGrowth = FrozenGrowthRule()
    let growthDeadline: MainDeadline
    /// Each tab script opened and the tab that opened it (`BrowserScriptOpeners`), by key; injected by the App.
    var openerLinks: () -> [String: String] = { [:] }
    /// The memory coordinator it registers with, made by `AppServices` (tests pass their own).
    private let memory: any MemoryConsumerRegistry
    /// Its lossy consumer registration while started; the coordinator hands it each level and limit.
    private var memoryRegistration: MemoryConsumerRegistration?
    /// The coordinator's limit: critical (0 %) means the next release slice runs an urgent pass.
    var memoryLimit = MemoryLimit.default
    /// Urgent passes the coordinator's critical release slices ran (`debug.surfaces`).
    var urgentPasses = 0
    /// The critical limit's release slice runs one urgent pass ranked over tabs, chats and pages
    /// (``urgentPass()``, feature `memoryUrgentDiscardRanking`, set by the App); off, it runs the
    /// browser's own pass (up to `criticalPace.perPass` tabs) and the chats and pages discard on their own.
    var ranksUrgentDiscards = false {
        didSet { updateFollowers() }
    }
    /// Ranks the urgent pass over tabs, chats and pages (``urgentPass()``).
    let urgentRanker = UrgentDiscardRanker()
    /// What the last urgent pass discarded (`debug.surfaces` and tests).
    var lastUrgentPass = UrgentDiscardRanker.Pass()
    /// Until when the paced passes discard no tab (``ranksUrgentDiscards``): the critical event's
    /// discard is the urgent pass's.
    var urgentHoldEnds: ContinuousClock.Instant?
    /// The urgent pass's other owners, ranked with the browser tabs: agent chats and cmux pages.
    lazy var urgentDiscardOwners: @MainActor () -> [any UrgentDiscardOwner] = { [weak self] in
        let owners: [(any UrgentDiscardOwner)?] = [self?.agentPages, self?.cache?.pageLifecycle]
        return owners.compactMap(\.self)
    }
    /// The clock of hidden times, graces and probe answers (a seam for tests).
    var now: @MainActor () -> ContinuousClock.Instant = { .now }
    /// Pinned state of a tab (the daemon record); injected by the App.
    var isPinned: (String) -> Bool = { _ in false }
    private(set) var exemptions: [String: HibernationPlanner.Exemption] = [:]
    /// Follows `browser.hibernation` (``follow(_:)``): its apply replans, which must happen while no window shows.
    private var settingsObservation: ServiceObservation<BrowserHibernationSetting>?
    /// Where the probes' answers land: one background task each (nobody waits on a hidden page's probe).
    let mainWork: MainWorkScheduler
    /// Where a woken page's load timing puts its 15 s bound when the page has no keyed waits (``timeLoad(_:page:)``).
    let mainDeadlines: MainDeadlineScheduler
    private(set) var hibernatedCount = 0
    /// A page was hibernated (the App counts it in the memory histograms).
    var onHibernate: () -> Void = {}
    /// A hibernated page is back, this long after its wake started (the App records it in the memory histograms).
    var onWakeMounted: (Duration) -> Void = { _ in }
    /// Hidden agent chat pages, on the same setting and pressure.
    var agentPages: AgentPageHibernation? {
        didSet { updateFollowers() }
    }
    /// The discard planner's last inputs for browser and agent pages (`debug.discards`).
    private(set) var discards = ContentDiscardReport(tracking: .browser, .agentPage)
    var restoredCount = 0
    /// Each pane's tab order and shown tab, from its `PaneController`.
    private(set) var neighbors = NeighborTabs()
    /// Tabs kept awake now because they sit beside a shown tab.
    private(set) var awakeNeighbors: Set<String> = []
    /// When the pointer last rested on each hidden tab's strip cell (`noteHover`).
    private var hoveredAt: [String: ContinuousClock.Instant] = [:]
    /// Seconds a hovered tab stays awake after the hover, as for an agent's call.
    static let hoverGrace: Double = 30
    /// Pages woken early (neighbors and hovers): `debug.surfaces` and the bench read it.
    var prewarmedCount = 0
    /// Which wakes nobody asked for start now (`memoryWakeAdmission`; off, all of them).
    var admission = WakeAdmission(isEnabled: false, freeBytes: { nil })
    /// The intent prewarm with this hibernation as its weak warmer, and its power feed (`intentPrewarmHover`'s
    /// hover dwell, `directionalPrewarm`'s key steps, `intentPrewarmPress`'s presses).
    var intentPrewarm: (service: IntentPrewarmService<String>, power: MainActorHandlerRegistration<EnergyInputs>)?
    var prewarmKinds = IntentPrewarmKinds() // the intent prewarm's cover decodes and target sizes
    /// The longest a woken page's last frame stands in for it before it paints (Chrome has no
    /// picture; a page that paints later than this shows itself loading rather than look frozen).
    static let standInCap: Duration = .milliseconds(500)
    /// The clock of the stand-in cap (a seam for tests).
    var standInClock: any Clock<Duration> = ContinuousClock()
    /// Wakes with a picture whose page could show no stand-in (`debug.surfaces`).
    var uncoveredWakes = 0
    /// The app's Energy Saver policy (`MainWorkScheduler.energy`).
    private let energy: EnergyPolicySource
    private var energyObservation: MainActorEnergyObservation?
    /// Pages spend less, as of the policy's last change: Energy Saver, or Low Power Mode while the
    /// `energySaver` feature is off (``EnergyPolicy/pageSaver``).
    private(set) var energySaver: Bool
    /// The app's windows going off screen and back (`occludedWindowDiscard`); nil when off.
    private var windowOcclusion: WindowOcclusionChecker?
    /// The page's freeze control (a seam for tests; Chromium pages only in the app).
    var freezer: (any BrowserTab) -> (any BrowserFreezing)? = { $0 as? any BrowserFreezing }
    /// Chromium tabs take their visibility from their tab's node, before the freeze (feature `chromiumTabVisibility`).
    let tabVisibility: BrowserVisibilityFollowers
    /// Energy Saver's one change to the freeze delay: a hidden page busy at Chrome's high-CPU proportion freezes early
    /// (`SaverCPUFreeze`); `measureCPU` reads renderer CPU off the main actor; `highEnergy` flags busy hidden tabs, each replan its wake (App-set).
    var saverCPU = SaverCPUFreeze(), measureCPU: SaverCPUFreeze.Measure?, highEnergy: HighEnergyTabMonitor?

    /// When the person showed each tab lately, for its ranking.
    private(set) var focusHistory = TabFocusHistory()
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
    let activity: PageActivityWatch
    /// When each page last played sound (`DiscardRule.recentlyAudible`); the end of a hidden page's
    /// sound replans. Nil while the `recentlyAudibleProtection` feature is off: no page is watched,
    /// no candidate carries a sound fact, and the plans are those from before the rule.
    let audible: AudibleHistory?
    /// Seconds after the last replan that the hibernation deadline fires; nil when none is armed.
    private(set) var nextCheck: Double?

    /// - Parameters:
    ///   - energy: The app's Energy Saver policy (`MainWorkScheduler.energy`); the default, fixed off, is for tests.
    ///   - audible: The pages' sound history (`recentlyAudibleProtection`); nil turns the recently audible protection off.
    ///   - deadlines: The app's main-thread deadline scheduler: the hibernation and freeze deadlines, the hover dwell and the frozen
    ///     pages' one-shot reading are `background` deadlines on it (nobody sees them), and the probes' answers land on its scheduler.
    init(cache: TabContentCache, memory: any MemoryConsumerRegistry, deadlines: MainDeadlineScheduler,
         energy: EnergyPolicySource = EnergyPolicySource(), audible: AudibleHistory? = nil, followsTabVisibility: Bool = false, freezeEligibility: Bool = false) {
        self.cache = cache
        tabVisibility = BrowserVisibilityFollowers(isEnabled: followsTabVisibility)
        growthDeadline = MainDeadline(owner: "BrowserFrozenGrowth", workClass: .background, scheduler: deadlines)
        deadline = MainDeadline(owner: "BrowserHibernation", workClass: .background, scheduler: deadlines)
        freezeDeadline = MainDeadline(owner: "BrowserFreeze", workClass: .background, scheduler: deadlines)
        hoverDwell = MainDeadline(owner: "BrowserNeighborHover", workClass: .background, scheduler: deadlines)
        mainWork = deadlines.work
        mainDeadlines = deadlines
        activity = PageActivityWatch(mainWork: deadlines.work)
        snapshots = HibernationSnapshots(fullCapacityBytes: cache.imageCaches.hibernationSnapshotBytes, allocator: cache.imageCaches.pictureAllocator)
        self.energy = energy
        energySaver = energy.policy.pageSaver
        self.memory = memory
        self.audible = audible
        audible?.onEnded = { [weak self] key in self?.soundDidEnd(key) }
        snapshots.neighbors = { [weak self] in self?.pictureNeighbors ?? [] }
        freezeRules.configure(isEnabled: freezeEligibility, work: deadlines.work, isLoading: { [weak cache] in cache?.browsers[$0]?.tab.state.isLoading }) { [weak self] in self?.replan() }
    }

    /// The tabs one step beside each pane's shown tab, at any pressure and setting: their pictures stay
    /// under every memory limit (`HibernationSnapshots`), since Ctrl-Tab and Cmd-Shift-[ ] show them next.
    private var pictureNeighbors: Set<String> { neighbors.awake(radius: 1) }

    /// Tabs on each side of a shown tab that stay awake now: the setting, or 0 under memory pressure or Energy Saver.
    var neighborRadius: Int {
        NeighborTabs.radius(setting: setting.neighborRadius, pressure: pressure, energySaver: energySaver)
    }

    /// Registers with the memory coordinator as one lossy consumer (event-driven, no polling): the
    /// coordinator hands it the current level at once, then each change on the main actor, and
    /// `stop()` cancels the registration at once, so none lands after `stop()`.
    func start() {
        guard memoryRegistration == nil else { return }
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: memory)
        energyObservation = MainActorEnergyObservation(energy) { [weak self] policy in self?.energySaverDidChange(policy.pageSaver) }
        energySaverDidChange(energy.policy.pageSaver)
        // Pages mounted before the hibernation existed (a restored session) are followed too.
        for (key, entry) in cache?.browsers ?? [:] { pageDidMount(key, entry.tab) }
    }

    func stop() {
        windowOcclusion?.stop()
        windowOcclusion = nil
        settingsObservation?.cancel()
        memoryRegistration?.cancel()
        memoryRegistration = nil
        energyObservation?.cancel()
        energyObservation = nil
        deadline.cancel()
        nextCheck = nil
        freezeDeadline.cancel()
        growthDeadline.cancel()
        hoverDwell.cancel()
        activity.stop()
        freezeRules.stop()
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

    /// Applies every loaded cmux.json snapshot's `browser.hibernation`, now and on each change: a
    /// ``ServiceObservation`` in the background class (its apply replans pages while no window shows).
    func follow(_ settings: SettingsController) {
        settingsObservation?.cancel()
        settingsObservation = ServiceObservation(.background, owner: "BrowserHibernation.settings", on: mainWork) {
            settings.snapshot.browserHibernation
        } apply: { [weak self] setting in
            self?.apply(setting)
        }
    }

    func apply(_ setting: BrowserHibernationSetting) {
        guard setting != self.setting else { return }
        self.setting = setting
        updateFollowers()
        if !setting.isEnabled { stopGrowthReadings() }
        refreshNeighbors(replans: false)
        replan()
    }

    /// Hands the setting, pressure and Energy Saver to the hidden pages that follow them: agent chats, and
    /// every cmux page's lifecycle (`pageLifecycle`; the cache holds none while it is off).
    private func updateFollowers() {
        agentPages?.leavesCriticalEventToUrgentPass = ranksUrgentDiscards
        cache?.pageLifecycle?.leavesCriticalEventToUrgentPass = ranksUrgentDiscards
        agentPages?.update(setting: setting, pressure: pressure)
        cache?.pageLifecycle?.setConditions(.init(setting: setting, pressure: pressure, energySaver: energySaver))
    }

    /// Energy Saver turned on or off: the neighbors and the cmux pages follow. Other policy changes
    /// (power source, sleep) change nothing here.
    private func energySaverDidChange(_ saver: Bool) {
        guard saver != energySaver else { return }
        energySaver = saver
        updateFollowers()
        refreshNeighbors()
    }

    /// Takes a new pressure level; `replans` false leaves the pass to the caller (the coordinator's
    /// critical release slice, `releaseMemory(within:)`).
    func pressureDidChange(_ level: MemoryPressureLevel, replans: Bool = true) {
        guard level != pressure else { return }
        if level == .critical, ranksUrgentDiscards { holdPacedDiscards() } else { urgentHoldEnds = nil }
        pressure = level
        logger.info("memory pressure \(level.rawValue, privacy: .public)")
        admitted(admission.pressureDidChange(level) { self.cache?.lifecycle.phase($0) == .hibernated })
        updateFollowers()
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
            if cache?.lifecycle.phase(key) == .mountedHidden { hiddenAt[key] = now() }
        }
        replan()
    }

    // MARK: Lifecycle notifications (from TabContentCache effects)

    func tabDidHide(_ key: String) {
        guard let tab = cache?.browsers[key]?.tab else { return }
        _ = markOffScreen(key, false)
        hiddenAt[key] = now()
        noteDiscard(.hidden(key, .browser))
        watchActivity(key, tab)
        replan()
        discardCrashedSubframe(key)
    }

    func tabDidShow(_ key: String) {
        intentPrewarm?.service.committed(key)
        if frozen.contains(key) { coldShows += 1 }
        thaw(key)
        freezeRules.shown(key)
        probeHistory.clearMisses(key)
        hoveredAt[key] = nil
        hiddenAt[key] = nil
        offScreenShown.remove(key)
        prepared[key] = nil
        exemptions[key] = nil
        probeKeptAt[key] = nil
        discardAttempts.clear(key)
        activity.forget(key)
        focusHistory.note(key, at: now())
        if cache?.browsers[key] != nil { noteDiscard(.shown(key, .browser)) }
    }

    /// Records an owner's report for `debug.discards` now (this and its `AgentPageHibernation`).
    func noteDiscard(_ event: ContentDiscardReport.Event) { discards.note(event, at: now()) }

    /// Keeps hidden page `key` for `reason` (`debug.surfaces`) and reports that verdict (`debug.discards`).
    private func keepPage(_ key: String, _ reason: HibernationPlanner.Exemption) {
        exemptions[key] = reason
        if let at = hiddenAt[key] { noteDiscard(.planned(key, .browser, hiddenFor: (now() - at).seconds, DiscardEligibility(keptFor: reason))) }
    }

    /// Chromium hears tab `key`'s node from its mount on (``tabVisibility``), its hide before the freeze. A capture thaws
    /// the page; the engine refuses a freeze while it lasts, so the page freezes again `freezeSeconds` after it ends.
    func followVisibility(_ key: String, _ page: any BrowserTab) {
        tabVisibility.follow(key, page, node: self.cache?.node(for: key)) { [weak self] in
            guard let self else { return }
            thaw(key)
            freezeRules.keep(key, at: now())
            replan()
        }
    }

    /// An agent acted on tab `key` (`cmux browser`, MCP, the browser REPL):
    /// a hidden page's clock starts again, so a page an agent drives in the
    /// background does not hibernate between two of its calls, and a page an
    /// agent woke sleeps again once the agent leaves it alone that long.
    func noteAgentUse(_ key: String) {
        guard let cache, cache.browsers[key] != nil else { return }
        agentUsedAt[key] = now()
        // Before the agent's call goes out: a frozen page runs no script.
        thaw(key)
        guard cache.lifecycle.phase(key) == .mountedHidden else { return }
        hiddenAt[key] = now()
        replan()
    }

    func forget(_ key: String) {
        forgetPrewarm(key)
        forgetWake(key)
        agentPages?.forget(key)
        cache?.dormantTabs.set(key, false)
        hiddenAt[key] = nil
        agentUsedAt[key] = nil
        prepared[key] = nil
        probing.remove(key)
        discardAttempts.clear(key)
        exemptions[key] = nil
        frozen.remove(key)
        tabVisibility.forget(key)
        untrackGrowth(key)
        freezeProbing.remove(key)
        freezeRules.forget(key)
        probeHistory.forget(key)
        hoveredAt[key] = nil
        awakeNeighbors.remove(key)
        focusHistory.forget(key)
        leased.remove(key)
        offScreenShown.remove(key)
        noteDiscard(.removed(key))
        memoryReadings.forget(key)
        savedBytes[key] = nil
        probeKeptAt[key] = nil
        audible?.forget(key)
        snapshots.remove(key)
        wakeLog.forget(key)
        activity.forget(key)
        crashedSubframes[key] = nil
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
        // Back on screen, a shown page frozen there (``freezesOffScreenShownPages``) thaws in the window's turn.
        for key in shownPages where markOffScreen(key, offScreen) && !offScreen { showsAgain(key) }
        refreshNeighbors(replans: false)
        replan()
    }

    /// Shown page `key` is in an off-screen window (a switch or a move there) or not.
    func pageDidChangeScreen(_ key: String, offScreen: Bool) {
        guard markOffScreen(key, offScreen) else { return }
        if !offScreen { showsAgain(key) }
        replan()
    }

    /// Shown page `key`'s window is back on screen: the person sees it again, so it thaws, and a freeze it refused
    /// off screen no longer marks it a failed discard (``discardAttempts`` clear when content shows again).
    private func showsAgain(_ key: String) {
        thaw(key)
        discardAttempts.clear(key)
    }

    /// Starts or stops shown page `key`'s hidden clock with its window; true when that changed.
    private func markOffScreen(_ key: String, _ offScreen: Bool) -> Bool {
        if offScreen {
            guard offScreenShown.insert(key).inserted else { return false }
            hiddenAt[key] = now()
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
        intentPrewarm?.service.pointerHovered(key) // the strip's hover dwell (`intentPrewarmHover`)
        hoverDwell.cancel()
        guard let key, neighborRadius > 0, let cache, cache.browsers[key] != nil,
              cache.lifecycle.phase(key) != .mountedVisible else { return }
        hoveredAt[key] = now()
        thaw(key, prewarm: true)
        if cache.lifecycle.phase(key) == .hibernated {
            // Justified delay: a dwell, not a poll; the next hover change cancels it.
            hoverDwell.schedule(after: Self.hoverDwellDelay) { [weak self] in self?.warm(key) }
        }
        replan()
    }

    /// How long the pointer stays on a hibernated tab before it restores.
    static let hoverDwellDelay: Duration = .milliseconds(150)
    /// The hover dwell: a background deadline, as the intent prewarm's own hover dwell (`IntentPrewarm.hoverDwell`).
    private let hoverDwell: MainDeadline

    /// Recomputes the awake neighbors; a new neighbor wakes now (thaws, or
    /// restores in the background), and one that stops being a neighbor
    /// starts its hidden clock again, so it sleeps `freezeSeconds` later.
    private func refreshNeighbors(replans: Bool = true) {
        guard let cache else { return }
        let next = neighbors.awake(radius: neighborRadius).filter { cache.browsers[$0] != nil }
        guard next != awakeNeighbors else { return }
        let (left, joined) = (awakeNeighbors.subtracting(next), next.subtracting(awakeNeighbors))
        awakeNeighbors = next
        let now = self.now()
        for key in left { admission.cancelPrewarm(key) } // a queued wake of a tab no longer beside a shown one
        for key in left where cache.lifecycle.phase(key) == .mountedHidden {
            hiddenAt[key] = now
            if exemptions[key] == .neighbor { exemptions[key] = nil }
        }
        for key in joined { warm(key) }
        if replans { replan() }
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

    /// Hibernates every due page and arms one deadline for the next; while the urgent pass holds the paced discards (``urgentHoldEnds``) they wait.
    func replan() {
        guard cache != nil else { return }
        let now = self.now()
        if let ends = urgentHoldEnds, now >= ends { urgentHoldEnds = nil }
        let holdLeft = urgentHoldEnds.map { ($0 - now).seconds }
        let hidden = hiddenCandidates(now: now)
        let candidates = hidden.map { $0.facts }
        let graceEnds = hidden.compactMap { $0.graceEnds }.min()
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: candidates)
        for key in plan.endedSoundReasons(of: candidates.map(\.key), held: exemptions, probeKept: { probeKeptAt[$0] != nil }) {
            exemptions[key] = nil
        }
        exemptions.merge(plan.exemptions) { $1 }
        discards.notePass(plan, candidates: candidates, probeKept: exemptions, at: now)
        let held = holdLeft != nil && !plan.due.isEmpty
        if !held, !plan.due.isEmpty {
            refreshMemoryIfNeeded()
            for key in plan.due { prepare(key, for: HibernationPlanner.discardReason(at: pressure)) }
        }
        nextCheck = [plan.nextCheck, graceEnds, held ? holdLeft : nil].compactMap(\.self).min()
        if let next = nextCheck {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
        replanFreeze(candidates.compactMap {
            $0.freezeCandidate(freezesShownPages: freezesOffScreenShownPages, followsNode: tabVisibility.follows($0.key),
                               freezeSeconds: setting.freezeSeconds)
        })
        highEnergy?.wake()
    }

    /// Every hidden page, and every page shown in an off-screen window, that could go now.
    private func hiddenCandidates(now: ContinuousClock.Instant) -> [(facts: HibernationPlanner.Candidate, graceEnds: Double?)] {
        guard let cache else { return [] }
        let shownOffScreen = offScreenShown.filter { cache.lifecycle.phase($0) == .mountedVisible }
        return (cache.lifecycle.keys(in: .mountedHidden) + shownOffScreen).compactMap { hiddenCandidate($0, now: now) }
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
        let now = self.now(), groups = FrozenGrowthRule.openerGroups(links: openerLinks)
        let members = Set(growing.flatMap { groups($0).union([$0]) })
        let hidden = members.reduce(into: [String: HibernationPlanner.Candidate]()) { $0[$1] = hiddenCandidate($1, now: now)?.facts }
        let plan = frozenGrowth.plan(growing: growing, groups: groups, candidates: hidden, setting: setting)
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
        let now = self.now()
        let threshold = setting.freezeSeconds
        var recheck: Double?
        let candidates = hidden.filter { candidate in
            guard !frozen.contains(candidate.key), !freezeProbing.contains(candidate.key),
                  let tab = cache.browsers[candidate.key]?.tab, freezer(tab) != nil else { return false }
            guard let left = freezeRules.keptLeft(candidate.key, threshold: threshold, now: now) else { return true }
            recheck = min(recheck ?? left, left)
            return false
        }
        let (planned, read) = saverCPU.pastGrace(candidates, saver: energy.policy.isSaver && measureCPU != nil, now: now)
        if let read { measureCPU?(read.keys, { [weak self] in if self?.saverCPU.land($0, generation: read.generation) == true { self?.replan() } }) }
        let plan = freezeRules.plan(setting, candidates: planned, frozen: frozen.union(freezeProbing), groups: FrozenGrowthRule.openerGroups(links: openerLinks))
        for key in plan.due { freeze(key) }
        if let next = [plan.nextCheck, recheck].compactMap(\.self).min() {
            freezeDeadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { [weak self] in self?.replan() }
        } else {
            freezeDeadline.cancel()
        }
    }

    /// Asks the page for media, Web Audio, capture, WebRTC, devices, Web Locks and IndexedDB, then freezes
    /// it if it is still the same hidden page. A page that plays (`FreezeEligibility.keeps`), or that still gets the
    /// benefit of the doubt (`PageProbeHistory`), stays awake and is asked again after `freezeSeconds`.
    private func freeze(_ key: String) {
        guard let cache, let tab = cache.browsers[key]?.tab, freezer(tab) != nil,
              let generation = cache.lifecycle.record(key)?.generation, freezeProbing.insert(key).inserted else { return }
        let mainWork = mainWork
        // task-owner: one freeze probe, bounded by the probe's 2 s deadline. R-hop: a nonisolated task awaits the
        // page's script calls; the answer lands in one background task (nobody waits on a hidden page's probe).
        Task { @concurrent [weak self] in
            let probe = await BrowserHibernation.probe(tab)
            await mainWork.apply(.background, owner: "BrowserHibernation.freezeProbe") { [weak self] in
                self?.freezeProbed(key, tab: tab, generation: generation, probe: probe)
            }
        }
    }

    /// The freeze probe of hidden page `key` (`tab`, at lifecycle `generation`) answered `probe`: it freezes
    /// unless it changed meanwhile, plays, or still gets the benefit of the doubt.
    private func freezeProbed(_ key: String, tab: any BrowserTab, generation: UInt64, probe: PageProbe) {
        freezeProbing.remove(key)
        guard let cache, cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
              cache.lifecycle.phase(key) == .mountedHidden || isShownOffScreen(key), hiddenAt[key] != nil,
              let page = freezer(tab) else { return }
        // An agent called it, it became a neighbor (or was hovered), its group thawed or it started loading while the probe ran.
        guard mayFreeze(key) else { return }
        let doubted = probeHistory.record(probe, for: key, step: .freeze)
        if probe.audible { audible?.heard(key) }
        if freezeRules.keeps(probe) || doubted {
            for member in freezeRules.keep(key, at: now()) { thaw(member) }
            replan()
            return
        }
        freeze(key, page)
    }

    /// No agent drives the hidden page, it showed no background activity (its updates stay live), is no neighbor or hovered tab, and `FreezeEligibility` lets it.
    private func mayFreeze(_ key: String) -> Bool {
        !isAgentDriven(key) && !activity.contains(key) && !awakeNeighbors.contains(key) && hoverLeft(key, now: now()) == nil && freezeRules.mayFreeze(key)
    }

    /// Page `key` is shown in an off-screen window, and may freeze there (``freezesOffScreenShownPages``).
    private func isShownOffScreen(_ key: String) -> Bool {
        freezesOffScreenShownPages && offScreenShown.contains(key) && cache?.lifecycle.phase(key) == .mountedVisible
    }

    private func freeze(_ key: String, _ page: any BrowserFreezing) {
        // The engine refuses a page it still counts visible: it stays awake and is asked again
        // after `freezeSeconds` (a hidden page's visibility reaches the engine within a frame).
        guard isShownOffScreen(key) ? page.freezeShownInOffScreenWindow() : page.setFrozen(true) else {
            for member in freezeRules.keep(key, at: now()) { thaw(member) }
            discardAttempts.mark(key)
            cache?.trace(key, "freeze refused")
            replan()
            return
        }
        frozen.insert(key)
        noteFrozen(key)
        noteDiscard(.frozen(key, true))
        trackGrowth(key)
    }

    /// Thaws a frozen page (shown, driven by an agent, about to hibernate, or woken early as a neighbor or hovered tab: `prewarm`)
    /// with its opener group, unless `alone`: a hibernation probe, as Chrome discards a page without thawing its group (freezing_policy.cc).
    func thaw(_ key: String, prewarm: Bool = false, alone: Bool = false) {
        if !alone { for member in freezeRules.thaw(key) { thaw(member, prewarm: prewarm) } }
        guard frozen.remove(key) != nil else { return }
        untrackGrowth(key)
        noteDiscard(.frozen(key, false))
        if let tab = cache?.browsers[key]?.tab { freezer(tab)?.setFrozen(false) }
        if prewarm { prewarmedCount += 1 }
        cache?.trace(key, prewarm ? "prewarmed (thaw)" : "thawed")
    }

    /// Shows of a page that was still frozen (it thawed on the switch): the cold
    /// switches neighbors exist to avoid (`debug.surfaces`, the bench).
    private(set) var coldShows = 0

    // MARK: Hibernate

    /// The user's Hibernate Tab action (Chrome's external discard): a hidden page hibernates now
    /// unless a disallowed rule keeps it (`HibernationPlanner.hibernateTabRefusal`). Returns why not, or nil when it started.
    func hibernateNow(_ key: String) -> HibernationPlanner.Exemption? {
        guard let cache, let entry = cache.browsers[key], cache.lifecycle.phase(key) == .mountedHidden else { return .disabled }
        if let refusal = HibernationPlanner.hibernateTabRefusal(candidate(key, entry: entry, hiddenFor: 0), setting: setting) {
            keepPage(key, refusal)
            return refusal
        }
        prepare(key, for: .external)
        return nil
    }

    /// Probes the page, captures its history and snapshot, then hibernates it if it is still hidden
    /// with the same generation. `.external` is the person's Hibernate Tab, which asks the page nothing.
    func prepare(_ key: String, for reason: DiscardReason) {
        let user = reason == .external
        guard let cache, let entry = cache.browsers[key], let source = entry.tab as? any BrowserHibernationSource,
              let generation = cache.lifecycle.record(key)?.generation, probing.insert(key).inserted else { return }
        let tab = entry.tab
        // The probe and the history capture run script: a frozen page runs none. Its opener group stays frozen.
        thaw(key, alone: true)
        // task-owner: one discard probe, bounded by each of its script calls' 2 s deadline
        // main-hop-allow: the probe, picture, view state and beforeunload ask are the page's main-actor async calls, and the discard checks the lifecycle again between them, so a page shown meanwhile is never touched
        Task { @MainActor [weak self] in
            // The person's Hibernate Tab asks the page nothing (only a disallowed rule keeps it).
            var exemption: HibernationPlanner.Exemption?
            var mayAsk = false
            // Its beforeunload handlers asked (or could not be asked): the discard was tried and failed.
            var askedOnUnload = false
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
                                                            for: reason == .proactive || reason == .urgent ? HibernationPlanner.discardReason(at: $0.pressure) : reason,
                                                            doubted: doubted) }
                mayAsk = probe.unloadHandler
            }
            // A page that stays needs no picture (each replan probes it again); a cmux page saves its view state too.
            let (snapshot, viewState): (PurgeablePicture?, BrowserAppPageState?) = exemption == nil
                ? (await self?.snapshot(tab, key: key), await (tab as? any BrowserAppPage)?.saveViewState()) : (nil, nil)
            guard let self else { return }
            // The page's beforeunload handlers run last, only when nothing else keeps it, still hidden
            // and about to go, and at most once while it stays hidden (`discardAttempts`).
            if exemption == nil, mayAsk, self.discardCheck(key, tab: tab, generation: generation, user: user) == .go {
                askedOnUnload = await self.asksBeforeUnload(key, tab)
            }
            guard let cache = self.cache else { return }
            self.probing.remove(key)
            switch self.discardCheck(key, tab: tab, generation: generation, user: user) {
            case .stale:
                cache.trace(key, "hibernate probe dropped (stale)")
                return
            case .keep(let reason) where exemption == nil && !askedOnUnload:
                self.keepPage(key, reason)
                return
            case .keep, .go:
                break
            }
            // A probe answer keeps the page and asks again after `keptBackoff`; it is no failed discard.
            if let exemption {
                self.keepPage(key, exemption)
                self.probeKeptAt[key] = self.now()
                return
            }
            if askedOnUnload { return self.discardFailed(key, .beforeUnload) }
            guard let state = viewState.map(BrowserRestoreState.appPage) ?? source.hibernationState() else {
                return self.discardFailed(key, .unsupported)
            }
            self.prepared[key] = (state, snapshot)
            self.noteDiscard(.discarding(key, .browser, reason))
            cache.applyLifecycle(cache.lifecycle.send(.hibernate(key)))
        }
    }

    /// Takes a hidden page's picture (a seam for tests): the frame a page past its hidden grace holds
    /// (`BrowserHiddenPagePicture`; a screenshot would make it draw again), else a thumbnail (none from Chromium: P0 #1).
    var capture: (any BrowserTab) async -> CGImage? = { tab in
        if let held = await (tab as? any BrowserHiddenPagePicture)?.hiddenPagePicture() { return held }
        return try? await ControlDeadline.shared.run(method: "hibernation.snapshot", deadline: .now + .seconds(2)) { @MainActor in
            try await tab.thumbnail()
        }
    }

    /// The `release` effect: swaps the page for a `HibernatedBrowserTab`
    /// holding its history, and closes the engine page. Its snapshot lives in a bounded store
    /// only (`keep`): each placeholder used to keep its own full-size picture (about 7 MB of
    /// app memory per hibernated tab in the 2026-10-14 audit).
    func release(_ key: String, token: ContentLifecycle<String>.Token) {
        guard let cache, let entry = cache.browsers[key], let saved = prepared.removeValue(forKey: key) else {
            logger.error("hibernate \(key, privacy: .public): nothing prepared")
            discardAttempts.mark(key)
            return
        }
        let page = entry.tab
        let placeholder = HibernatedBrowserTab(
            id: page.id, engine: page.engineKind, profile: page.profileID, state: page.state,
            favicon: page.favicon, restoreState: saved.state, snapshot: { [weak self] in self?.snapshotImage(key) }
        )
        placeholder.onWake = { [weak self] wake in self?.wakeForNavigation(key, wake) }
        keepAsleep(key, picture: saved.snapshot, size: page.contentView.frame.size)
        cache.swapPage(key, with: placeholder)
        cache.dormantTabs.set(key, true)
        savedBytes[key] = memoryBytes[key].flatMap { $0 > 0 ? $0 : nil }
        hiddenAt[key] = nil
        activity.forget(key)
        // A probe that kept the page before no longer applies (`debug.surfaces`).
        exemptions[key] = nil
        hibernatedCount += 1
        onHibernate()
        noteDiscard(.discarded(key))
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
        if awakeNeighbors.contains(key) || hoverLeft(key, now: now()) != nil { return .keep(.neighbor) }
        if let used = agentUsedAt[key], (now() - used).seconds < Self.agentGrace { return .keep(.agentDriving) }
        return .go
    }

    private enum DiscardCheck: Equatable { case go, stale, keep(HibernationPlanner.Exemption) }
}

// The critical memory event's one urgent pass over tabs, chats and pages (feature
// `memoryUrgentDiscardRanking`), as Chrome's `UrgentPageDiscardingPolicy` discards one page per
// critical event (chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc) in
// `PageDiscardingHelper`'s order (page_discarding_helper.cc). The browser hibernation is one owner
// (its tabs); the agent chats and the cmux page lifecycle are the others (`urgentDiscardOwners`).
extension BrowserHibernation: UrgentDiscardOwner {
    /// The paced passes discard no tab for one critical pace interval from now: the critical event's
    /// discard is the urgent pass's.
    func holdPacedDiscards() {
        urgentHoldEnds = now() + .seconds(HibernationPlanner.criticalPace.interval)
    }

    /// The hidden browser tabs the urgent pass may take now (``HibernationPlanner/urgentCandidates(_:candidates:)``).
    func urgentCandidates() -> [UrgentDiscardRanker.Candidate] {
        HibernationPlanner.urgentCandidates(setting, candidates: hiddenCandidates(now: now()).map(\.facts))
    }

    /// Starts tab `key`'s discard probe (the discard finishes on its own turn); false when a probe
    /// already runs for it or it is no hidden browser tab now.
    func urgentDiscard(_ key: String) -> Bool {
        guard !probing.contains(key) else { return false }
        prepare(key, for: .urgent)
        return probing.contains(key)
    }

    /// The paced passes wait one critical pace interval; the next look is armed for its end.
    func urgentPassDidRun() {
        holdPacedDiscards()
        replan()
    }
}
