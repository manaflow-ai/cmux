import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

/// Hibernates hidden browser pages and restores them when shown
/// (plans/cmux-next/tab-lifecycle.md). Configured by
/// `browser.hibernation`; "off" disables it completely.
///
/// A page never reloads unless the person asks (Leo, 2026-10-26: "why does cmux-next's browser
/// keep refreshing and reloading?"). A discarded page reloads when it wakes, so by default hidden
/// pages only freeze (they keep their memory and state) and nothing is discarded on its own; the
/// timeout and memory pressure discard only once cmux.json sets `browser.hibernation`
/// (`BrowserHibernationSetting.discardsAutomatically`). Every discard and every restore is logged
/// at notice level with its cause, so a reload in the field can be traced.
///
/// Triggers are events only: a page hides (a one-shot deadline for the
/// earliest page to reach its threshold), the memory pressure dispatch
/// source, a settings change, or the user's Hibernate Tab action. There is
/// no polling. Before a page hibernates, a probe asks it for playing media
/// and edited form fields (with a deadline) and captures its history; the
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
/// Which page goes first is a ranking (`HibernationPlanner.idleness`): how long it has been
/// hidden, how often the person showed it in the last hour, and under memory pressure how much
/// memory it holds. A few pages go per pass (`HibernationPlanner.Pace`), never all at once.
/// A page never hibernates while it shows, plays (an element or Web Audio), captures, has DevTools
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
    /// When each hidden page was last visible.
    private var hiddenAt: [String: ContinuousClock.Instant] = [:]
    /// When an agent last called each page (`noteAgentUse`).
    private var agentUsedAt: [String: ContinuousClock.Instant] = [:]
    /// Seconds after an agent's call during which its hidden page stays awake
    /// whatever the memory pressure, so a page does not close under a script
    /// or between two calls of one task.
    static let agentGrace: Double = 30
    /// History and snapshot captured by the probe, and why the page goes, used by the `release` effect.
    private var prepared: [String: (state: BrowserRestoreState, snapshot: HibernationSnapshots.Picture?, cause: String)] = [:]
    /// Hibernated pages' pictures (`HibernationTunables.compressedSnapshots`), and their wakes (`debug.surfaces`).
    let snapshots = HibernationSnapshots()
    var wakeLog = HibernationWakes()
    /// A navigation that woke a hibernated page, applied once it is back; at most one per page.
    var pendingWakes: [String: HibernatedBrowserTab.Wake] = [:]
    /// Pages a discard probe is asking now.
    private(set) var probing: Set<String> = []
    /// Pages the person discarded (Hibernate Tab): only a show or a wake restores them, never a
    /// neighbor or hover prewarm.
    private(set) var discardedByUser: Set<String> = []
    /// Why a prewarm restores a page (`neighbor`, `hover`), read by the restore's log.
    var prewarmCauses: [String: String] = [:]
    /// Hidden pages whose `beforeunload` asked, once, right before a discard: they stay until shown,
    /// and their handlers do not run again on every replan (each run is the page's own unload logic
    /// on a page that lives on).
    private var askedBeforeUnload: Set<String> = []
    private let deadline = DemandTimer(owner: "BrowserHibernation")
    /// Hidden pages frozen now (`browser.freezeHiddenTabs`); they thaw when shown or driven.
    private(set) var frozen: Set<String> = []
    /// Pages a freeze probe is asking (media, Web Audio, capture).
    private(set) var freezeProbing: Set<String> = []
    /// When a page the probe kept awake (playing audio) is asked again.
    private var freezeKeptAt: [String: ContinuousClock.Instant] = [:]
    /// What each hidden page's probes said lately: the benefit of the doubt while it does not
    /// answer (the freeze probes, `freezeSeconds` apart, count the misses).
    private var probeHistory = PageProbeHistory()
    private let freezeDeadline = DemandTimer(owner: "BrowserFreeze")
    /// The memory pressure events it follows, made by `AppServices` (tests pass their own).
    private let memoryPressure: MemoryPressureEvents
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?
    /// Pinned state of a tab (the daemon record); injected by the App.
    var isPinned: (String) -> Bool = { _ in false }
    /// Memory pressure changed (the App resizes the terminal warm set).
    var onPressureChange: ((MemoryPressureLevel) -> Void)?
    private(set) var exemptions: [String: HibernationPlanner.Exemption] = [:]
    private var settingsObservation: Task<Void, Never>?
    private(set) var hibernatedCount = 0
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
    /// The clock hidden, grace and backoff times are read from (tests set it, as for
    /// `AgentPageHibernation.now`). The probe's own deadlines stay on the wall clock.
    var now: () -> ContinuousClock.Instant = { .now }
    /// How long a hidden page has to answer the probe or say whether its `beforeunload` asks
    /// (a seam: tests that do not check a silent page set it longer, so a starved test machine is not
    /// a page that did not answer).
    var pageDeadline: Duration = .seconds(2)
    /// Wakes with a picture whose page could show no stand-in (`debug.surfaces`).
    var uncoveredWakes = 0
    private let lowPower: LowPowerMode
    private var lowPowerObservation: LowPowerModeObservation?
    /// The page's freeze control (a seam for tests; Chromium pages only in the app).
    var freezer: (any BrowserTab) -> (any BrowserFreezing)? = { $0 as? any BrowserFreezing }

    /// When the person showed each tab lately (at most `focusLimit`, within `focusWindow`).
    private var focusedAt: [String: [ContinuousClock.Instant]] = [:]
    /// Seconds of focus history a tab's ranking counts.
    static let focusWindow: Double = 3_600
    static let focusLimit = 64
    /// Tabs whose browser lease an agent holds now (`noteLease`).
    private(set) var leased: Set<String> = []
    /// Hidden pages whose workspace hibernates (`hibernateForWorkspace`): discarded without
    /// `browser.hibernation`, still after every page check; cleared when shown or closed.
    private(set) var workspaceDue: Set<String> = []
    /// A download tab `key` started still runs; injected by the App.
    var isDownloading: (String) -> Bool = { _ in false }
    /// Samples each browser tab's memory (renderer footprint, shared renderers split); injected
    /// by the App. Run only under memory pressure, at most every `memoryMaxAge` seconds.
    var measureMemory: (() async -> [String: UInt64])?
    private(set) var memoryBytes: [String: UInt64] = [:]
    private var memoryMeasuredAt: ContinuousClock.Instant?
    private var measuringMemory = false
    static let memoryMaxAge: Double = 30
    /// When the probe last kept each page; under pressure such a page ranks after the others
    /// for `keptBackoff` seconds, so one playing page does not hold up the relief of the rest.
    private var probeKeptAt: [String: ContinuousClock.Instant] = [:]
    static let keptBackoff: Double = 60

    init(cache: TabContentCache, memoryPressure: MemoryPressureEvents, lowPower: LowPowerMode = .system) {
        self.cache = cache
        self.lowPower = lowPower
        self.memoryPressure = memoryPressure
    }

    /// Tabs on each side of a shown tab that stay awake now: the setting, or 0
    /// under memory pressure or in Low Power Mode.
    var neighborRadius: Int {
        NeighborTabs.radius(setting: setting.neighborRadius, pressure: pressure, lowPower: lowPower.isEnabled)
    }

    /// Starts following memory pressure (`memoryPressure`; event-driven, no polling). Each level arrives
    /// on the main actor and `stop()` cancels the registration at once, so none lands after `stop()`.
    func start() {
        guard pressureObservation == nil else { return }
        pressureObservation = memoryPressure.observe { [weak self] pressure in
            self?.pressureDidChange(pressure)
        }
        lowPowerObservation = lowPower.observe { [weak self] _ in self?.refreshNeighbors() }
    }

    func stop() {
        settingsObservation?.cancel()
        pressureObservation?.cancel()
        pressureObservation = nil
        lowPowerObservation?.cancel()
        lowPowerObservation = nil
        deadline.cancel()
        freezeDeadline.cancel()
        hoverDwell.cancel()
    }

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
        refreshNeighbors(replans: false)
        replan()
    }

    func pressureDidChange(_ level: MemoryPressureLevel) {
        guard level != pressure else { return }
        pressure = level
        logger.notice("memory pressure \(level.rawValue, privacy: .public)")
        onPressureChange?(level)
        agentPages?.update(setting: setting, pressure: pressure)
        refreshNeighbors(replans: false)
        replan()
        refreshMemoryIfNeeded()
    }

    /// Under memory pressure, samples the tabs' memory when the last sample is stale, then
    /// replans with it (the heaviest of equally idle pages goes first).
    private func refreshMemoryIfNeeded() {
        guard pressure != .normal, let measureMemory, !measuringMemory else { return }
        if let at = memoryMeasuredAt, (now() - at).seconds < Self.memoryMaxAge { return }
        measuringMemory = true
        Task { @MainActor [weak self] in
            let sample = await measureMemory()
            guard let self else { return }
            self.measuringMemory = false
            self.memoryBytes = sample
            self.memoryMeasuredAt = self.now()
            self.replan()
        }
    }

    /// The host of the page tab `key` shows (Never Hibernate This Site); nil for none.
    func host(of key: String) -> String? {
        guard let host = cache?.browsers[key]?.tab.state.url?.host(), !host.isEmpty else { return nil }
        return host
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
        guard cache?.browsers[key] != nil else { return }
        hiddenAt[key] = now()
        replan()
    }

    func tabDidShow(_ key: String) {
        if frozen.contains(key) { coldShows += 1 }
        thaw(key)
        freezeKeptAt[key] = nil
        probeHistory.clearMisses(key)
        hoveredAt[key] = nil
        hiddenAt[key] = nil
        prepared[key] = nil
        exemptions[key] = nil
        probeKeptAt[key] = nil
        askedBeforeUnload.remove(key)
        discardedByUser.remove(key)
        workspaceDue.remove(key)
        noteFocus(key, at: now())
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
        agentUsedAt[key] = now()
        // Before the agent's call goes out: a frozen page runs no script.
        thaw(key)
        guard cache.lifecycle.phase(key) == .mountedHidden else { return }
        hiddenAt[key] = now()
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
        discardedByUser.remove(key)
        workspaceDue.remove(key)
        prewarmCauses[key] = nil
        exemptions[key] = nil
        frozen.remove(key)
        freezeProbing.remove(key)
        freezeKeptAt[key] = nil
        probeHistory.forget(key)
        hoveredAt[key] = nil
        awakeNeighbors.remove(key)
        focusedAt[key] = nil
        leased.remove(key)
        memoryBytes[key] = nil
        probeKeptAt[key] = nil
        snapshots.remove(key)
        wakeLog.forget(key)
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

    /// The pointer moved onto hidden tab `key` in a strip (nil: off every tab).
    /// A frozen page thaws at once (one message); a hibernated page restores
    /// only once the pointer stays `hoverDwell`, so a sweep across the strip
    /// reloads nothing. Either stays awake `hoverGrace` seconds after.
    func noteHover(_ key: String?) {
        hoverDwell.cancel()
        guard let key, neighborRadius > 0, let cache, cache.browsers[key] != nil,
              cache.lifecycle.phase(key) != .mountedVisible else { return }
        hoveredAt[key] = now()
        thaw(key, prewarm: true)
        if cache.lifecycle.phase(key) == .hibernated {
            // Justified delay: a dwell, not a poll; the next hover change cancels it.
            hoverDwell.schedule(after: Self.hoverDwellDelay) { @MainActor [weak self] in self?.warm(key, cause: "hover") }
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
        let now = self.now()
        for key in left where cache.lifecycle.phase(key) == .mountedHidden {
            hiddenAt[key] = now
            if exemptions[key] == .neighbor { exemptions[key] = nil }
        }
        for key in joined { warm(key, cause: "neighbor") }
        if replans { replan() }
    }

    /// Wakes a hidden page early: thaws a frozen one, and restores a hibernated one in the
    /// background (the lifecycle keeps it hidden until selected) only when `mayPrewarmRestore`.
    private func warm(_ key: String, cause: String) {
        guard let cache else { return }
        thaw(key, prewarm: true)
        guard cache.lifecycle.phase(key) == .hibernated else { return }
        guard mayPrewarmRestore(key) else {
            cache.trace(key, "prewarm restore skipped (\(cause))")
            return
        }
        // A restore loads the page again: logged with its cause, as every non-user reload is.
        logger.notice("prewarm restore \(key, privacy: .public) cause=\(cause, privacy: .public)")
        prewarmCauses[key] = cause
        cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
        prewarmedCount += 1
        cache.trace(key, "prewarmed (restore)")
    }

    /// Whether a neighbor or hover may restore hibernated page `key` before it shows. A restore
    /// reloads the page, so a page the person discarded (Hibernate Tab) restores only when shown or
    /// woken, and with no `browser.hibernation` written (no automatic discards) no discarded page
    /// restores early at all.
    func mayPrewarmRestore(_ key: String) -> Bool {
        setting.isEnabled && setting.discardsAutomatically && !discardedByUser.contains(key)
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

    /// Hibernates every due page and arms one deadline for the next. `freezeOnly` plans the
    /// freezes alone (a probe that kept a page: planning its discard again would ask it at once).
    func replan(freezeOnly: Bool = false) {
        guard let cache else { return }
        let now = self.now()
        var graceEnds: Double?
        let candidates = cache.lifecycle.keys(in: .mountedHidden).compactMap { key -> HibernationPlanner.Candidate? in
            guard let at = hiddenAt[key], !probing.contains(key), let entry = cache.browsers[key] else { return nil }
            // Beside a shown tab or just hovered: stays awake for an instant switch.
            if awakeNeighbors.contains(key) {
                exemptions[key] = .neighbor
                return nil
            }
            if let left = hoverLeft(key, now: now) {
                exemptions[key] = .neighbor
                graceEnds = min(graceEnds ?? left, left)
                return nil
            }
            if exemptions[key] == .neighbor { exemptions[key] = nil }
            if let used = agentUsedAt[key] {
                let left = Self.agentGrace - (now - used).seconds
                if left > 0, setting.isEnabled {
                    exemptions[key] = .agentDriving
                    graceEnds = min(graceEnds ?? left, left)
                    return nil
                }
                agentUsedAt[key] = nil
                if exemptions[key] == .agentDriving { exemptions[key] = nil }
            }
            var facts = candidate(key, entry: entry, hiddenFor: (now - at).seconds, now: now)
            if let kept = probeKeptAt[key] {
                if (now - kept).seconds < Self.keptBackoff { facts.recentlyKept = true } else { probeKeptAt[key] = nil }
            }
            return facts
        }
        guard !freezeOnly else { return replanFreeze(candidates) }
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: candidates)
        exemptions.merge(plan.exemptions) { $1 }
        if !plan.due.isEmpty { refreshMemoryIfNeeded() }
        for key in plan.due {
            let hiddenFor = hiddenAt[key].map { Int((now - $0).seconds) } ?? 0
            prepare(key, cause: pressure == .normal ? "timeout hidden=\(hiddenFor)s" : "memory-pressure=\(pressure.rawValue) hidden=\(hiddenFor)s")
        }
        if let next = [plan.nextCheck, graceEnds].compactMap(\.self).min() {
            deadline.schedule(after: .milliseconds(Int64(next * 1000) + 50)) { @MainActor [weak self] in self?.replan() }
        } else {
            deadline.cancel()
        }
        replanFreeze(candidates)
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
        let limit = pageDeadline
        Task { @MainActor [weak self] in
            let probe = await Self.probe(tab, within: limit)
            guard let self, let cache = self.cache else { return }
            self.freezeProbing.remove(key)
            guard cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
                  cache.lifecycle.phase(key) == .mountedHidden, self.hiddenAt[key] != nil else {
                // Shown and hidden again while it was asked: that hide's replan skipped it (it was
                // being probed), so plan again for a page still hidden, or it never freezes.
                if cache.lifecycle.phase(key) == .mountedHidden { self.replan() }
                return
            }
            // An agent called it, or it became a neighbor (or was hovered) while the probe ran.
            guard self.mayFreeze(key) else { return }
            let doubted = self.probeHistory.record(probe, for: key, step: .freeze)
            if probe.stopsWhenFrozen || doubted {
                self.freezeKeptAt[key] = self.now()
                self.replan()
                return
            }
            self.freeze(key, page)
        }
    }

    /// No agent called the hidden page within `agentGrace` or holds its lease, and it is no
    /// neighbor or hovered tab.
    private func mayFreeze(_ key: String) -> Bool {
        if let used = agentUsedAt[key], (now() - used).seconds < Self.agentGrace { return false }
        // An agent holds its lease: its next call would wait on a thaw.
        if leased.contains(key) { return false }
        return !awakeNeighbors.contains(key) && hoverLeft(key, now: now()) == nil
    }

    private func freeze(_ key: String, _ page: any BrowserFreezing) {
        // The engine refuses a page it still counts visible: it stays awake and is asked again
        // after `freezeSeconds` (a hidden page's visibility reaches the engine within a frame).
        guard page.setFrozen(true) else {
            freezeKeptAt[key] = now()
            cache?.trace(key, "freeze refused")
            replan()
            return
        }
        frozen.insert(key)
        cache?.trace(key, "frozen")
    }

    /// Thaws a frozen page (shown, driven by an agent, about to hibernate, or
    /// woken early as a neighbor or hovered tab: `prewarm`).
    private func thaw(_ key: String, prewarm: Bool = false) {
        guard frozen.remove(key) != nil else { return }
        if let tab = cache?.browsers[key]?.tab { freezer(tab)?.setFrozen(false) }
        if prewarm { prewarmedCount += 1 }
        cache?.trace(key, prewarm ? "prewarmed (thaw)" : "thawed")
    }

    /// Shows of a page that was still frozen (it thawed on the switch): the cold
    /// switches neighbors exist to avoid (`debug.surfaces`, the bench).
    private(set) var coldShows = 0

    private func candidate(_ key: String, entry: BrowserEntry, hiddenFor: Double, now: ContinuousClock.Instant) -> HibernationPlanner.Candidate {
        let tab = entry.tab
        let capturing = (tab as? any PageInfoProviding).map { !$0.pageInfoInUse.union($0.pageInfoActivity.inUse).isEmpty } ?? false
        var candidate = HibernationPlanner.Candidate(
            key: key, hiddenFor: hiddenFor, host: tab.state.url?.host(), isPinned: isPinned(key),
            hasDevTools: (tab as? any BrowserDevToolsHosting)?.devTools.isOpen ?? false, isCapturing: capturing,
            // A page whose renderer ended shows the crash notice until the person reloads it: a
            // discard would drop the notice and its restore would load the page by itself.
            canRestore: tab.state.processExit == nil && ((tab as? any BrowserHibernationSource)?.supportsHibernation ?? false),
            showsFormSubmission: (tab as? any BrowserHibernationSource)?.showsFormSubmission ?? false
        )
        candidate.recentFocusCount = recentFocusCount(key, now: now)
        candidate.memoryBytes = memoryBytes[key]
        candidate.isDownloading = isDownloading(key)
        candidate.hasAgentLease = leased.contains(key)
        candidate.allowsNotifications = (tab as? any BrowserHibernationSource)?.allowsNotifications ?? false
        return candidate
    }

    // MARK: Hibernate

    /// The user's Hibernate Tab action: a hidden page hibernates now unless
    /// its engine cannot restore it. Returns why not, or nil when it started.
    func hibernateNow(_ key: String) -> HibernationPlanner.Exemption? {
        guard let cache, let entry = cache.browsers[key], cache.lifecycle.phase(key) == .mountedHidden else { return .disabled }
        let facts = candidate(key, entry: entry, hiddenFor: 0, now: now())
        guard facts.canRestore else { return .unsupported }
        // An agent holds its lease: its next call would find no page.
        guard !facts.hasAgentLease else { exemptions[key] = .agentLease; return .agentLease }
        guard !facts.showsFormSubmission else { exemptions[key] = .formSubmission; return .formSubmission }
        prepare(key, user: true, cause: "user")
        return nil
    }

    /// Its workspace hibernates (plans/cmux-next/workspace-hibernation-DESIGN.md): hidden page `key`
    /// is discarded unless the page check keeps it (edited fields, media, capture, a device, a
    /// `beforeunload` handler, an agent lease) or cmux.json turned `browser.hibernation` off. Unlike
    /// the timeout this runs without `browser.hibernation` set: the person's workspace setting asked.
    /// Returns why not, or nil when it started.
    @discardableResult
    func hibernateForWorkspace(_ key: String) -> HibernationPlanner.Exemption? {
        guard let cache, let entry = cache.browsers[key] else { noteWorkspacePage("no_page"); return .disabled }
        guard !(entry.tab is HibernatedBrowserTab) else { noteWorkspacePage("already_hibernated"); return .disabled }
        let phase = cache.lifecycle.phase(key)
        guard phase == .mountedHidden else { noteWorkspacePage("phase_\(phase.rawValue)"); return .disabled }
        // What keeps a page from the timeout keeps it here: a pinned tab, an excluded site, DevTools,
        // capture, a download, a form result, an agent lease, an engine that cannot restore it.
        let facts = candidate(key, entry: entry, hiddenFor: 0, now: now())
        if let kept = HibernationPlanner.exemption(facts, setting: setting) {
            exemptions[key] = kept
            noteWorkspacePage("kept_\(kept.rawValue)")
            return kept
        }
        workspaceDue.insert(key)
        if !prepare(key, cause: "workspace-idle") { noteWorkspacePage("not_prepared") }
        return nil
    }

    /// Probes the page, captures its history and snapshot, then hibernates
    /// it if it is still hidden with the same generation.
    @discardableResult
    private func prepare(_ key: String, user: Bool = false, cause: String) -> Bool {
        guard let cache, let entry = cache.browsers[key], let source = entry.tab as? any BrowserHibernationSource,
              let generation = cache.lifecycle.record(key)?.generation, probing.insert(key).inserted else { return false }
        let tab = entry.tab
        // The probe and the history capture run script: a frozen page runs none.
        thaw(key)
        let limit = pageDeadline
        Task { @MainActor [weak self] in
            // The person's Hibernate Tab asks the page nothing (only a form result keeps it).
            var exemption: HibernationPlanner.Exemption?
            var mayAsk = false
            if user {
                exemption = source.showsFormSubmission ? .formSubmission : nil
            } else {
                let probe = await Self.probe(tab, within: limit)
                // The freeze probe counts the misses (it runs beside this one and refreezes the
                // page); this one records an answer only.
                let doubted = probe.answered ? self?.probeHistory.record(probe, for: key) ?? false : self?.probeHistory.doubted(key) ?? true
                exemption = probe.keepReason(pressure: self?.pressure ?? .normal, doubted: doubted,
                                             showsFormSubmission: source.showsFormSubmission)
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
                if self.workspaceDue.contains(key) { self.noteWorkspacePage("stale") }
                // The probe thawed the page, and a hide meanwhile (shown, then hidden again) replanned
                // without it: plan again so a page still hidden freezes.
                self.replan()
                return
            case .keep(let reason):
                // The page's own answer (form input, audio) is the reason it reports, else why the
                // check kept it.
                self.exemptions[key] = exemption ?? reason
                if self.workspaceDue.contains(key) { self.noteWorkspacePage("kept_\((exemption ?? reason).rawValue)") }
                if exemption != nil { self.probeKeptAt[key] = self.now() }
                // The probe thawed the page and the replans meanwhile skipped it: plan again so it
                // freezes. No `.keep` reason (neighbor, hover, agent grace, the setting) makes it due.
                self.replan()
                return
            case .go:
                break
            }
            if let exemption {
                self.exemptions[key] = exemption
                if self.workspaceDue.contains(key) { self.noteWorkspacePage("kept_\(exemption.rawValue)") }
                self.probeKeptAt[key] = self.now()
                // The probe thawed it and the replans meanwhile skipped it: its freeze is planned
                // again (not its discard, which would ask the page again at once).
                self.replan(freezeOnly: true)
                return
            }
            // Its renderer ended while the probe ran: it keeps the crash notice.
            guard tab.state.processExit == nil, let state = source.hibernationState() else {
                self.exemptions[key] = .unsupported
                if self.workspaceDue.contains(key) { self.noteWorkspacePage("no_restore_state") }
                return
            }
            if self.workspaceDue.contains(key) { self.noteWorkspacePage("discarding") }
            self.prepared[key] = (state, snapshot, cause)
            if user { self.discardedByUser.insert(key) } else { self.discardedByUser.remove(key) }
            cache.applyLifecycle(cache.lifecycle.send(.hibernate(key)))
        }
        return true
    }

    /// How workspace hibernation's page discards ended, by outcome (`debug.surfaces`
    /// `workspace_pages`): a page that stayed says why.
    private(set) var workspacePageOutcomes: [String: Int] = [:]

    private func noteWorkspacePage(_ outcome: String) {
        workspacePageOutcomes[outcome, default: 0] += 1
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
        hiddenAt[key] = nil
        // A probe that kept the page before no longer applies (`debug.surfaces`).
        exemptions[key] = nil
        hibernatedCount += 1
        // Notice, not info: the field log keeps it, so a page that reloads on its next show can be traced.
        logger.notice("discarded \(key, privacy: .public) cause=\(saved.cause, privacy: .public) \(token.description, privacy: .public); it reloads from its saved history when it wakes")
    }

    /// Whether hidden page `key` may still be discarded, checked again after each await of `prepare`:
    /// `.stale` when it is no longer this hidden page (shown, hidden again or closed); `.keep` when it
    /// became a neighbor, was hovered, an agent called it while the probe ran, or the setting no
    /// longer discards on its own (the person's Hibernate Tab, `user`, still applies to those).
    private func discardCheck(_ key: String, tab: any BrowserTab, generation: UInt64, user: Bool) -> DiscardCheck {
        guard let cache, cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
              cache.lifecycle.phase(key) == .mountedHidden else { return .stale }
        // An agent took the page's lease while the probe ran (`noteLease` skips a probing page's
        // plan): a leased page is never discarded, not even by Hibernate Tab.
        if leased.contains(key) { return .keep(.agentLease) }
        if user { return .go }
        // Its workspace hibernates: the page's own answers above decided; the timeout's setting does not.
        if workspaceDue.contains(key) { return setting.isEnabled ? .go : .keep(.disabled) }
        // The setting changed while the probe ran: an automatic discard started under a timeout
        // the person has since removed (or turned off) does not happen.
        if !setting.isEnabled { return .keep(.disabled) }
        if !setting.discardsAutomatically { return .keep(.keepsState) }
        if awakeNeighbors.contains(key) || hoverLeft(key, now: now()) != nil { return .keep(.neighbor) }
        if let used = agentUsedAt[key], (now() - used).seconds < Self.agentGrace { return .keep(.agentDriving) }
        return .go
    }

    private enum DiscardCheck: Equatable {
        case go, stale
        case keep(HibernationPlanner.Exemption)
    }

    /// Whether hidden page `key` would ask before it unloads (`BrowserTab.asksBeforeUnload()`): runs
    /// its handlers once per hidden period; a page that asked, or could not be asked, stays.
    private func asksBeforeUnload(_ key: String, _ tab: any BrowserTab) async -> Bool {
        if askedBeforeUnload.contains(key) { return true }
        let asks = (try? await ControlDeadline.shared.run(method: "hibernation.beforeunload", deadline: .now + pageDeadline) { @MainActor in
            try await tab.asksBeforeUnload()
        }) ?? true
        if asks { askedBeforeUnload.insert(key) }
        return asks
    }

    // MARK: Probe

    /// Asks hidden page `tab` what it does (`PageProbe`). Runs no page code: whether a `beforeunload`
    /// handler would ask is learned only right before a discard (`asksBeforeUnload`).
    static func probe(_ tab: any BrowserTab, within limit: Duration = .seconds(2)) async -> PageProbe {
        do {
            let (value, busy) = try await ControlDeadline.shared.run(method: "hibernation.probe", deadline: .now + limit) { @MainActor in
                (try await tab.evaluate(BrowserPageBusy.fieldProbeScript, world: .isolated, gesture: .cmux), try await tab.pageBusy())
            }
            guard case .string(let json) = value, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return unanswered(tab) }
            // Media the tab's mute silences still plays (cx-d0d.24): hibernating would drop the mute.
            let muted = tab.state.isAudioMuted && tab.state.media?.isPlaying == true
            // A video in Picture in Picture plays on in its floating window, paused or muted alike.
            let floating = tab.state.media?.isPictureInPicture == true
            // The recorder knows the person's edits (`BrowserPageBusy`); a page loaded before it compares every field.
            return PageProbe(playingMedia: muted || floating || (object["media"] ?? true), editedForm: busy.editedForm ?? object["form"] ?? true,
                             capturing: busy.capturing, webAudio: busy.audio, beforeUnload: busy.beforeUnload,
                             unloadHandler: busy.unloadHandler, webRTC: busy.webRTC,
                             connectedDevice: busy.connectedDevice, unreadableFrame: busy.unreadableFrame)
        } catch {
            return unanswered(tab)
        }
    }

    /// A page that did not answer. It used to count as playing, so a page too busy to answer
    /// never froze and was asked again every `freezeSeconds` (the hottest renderer in the
    /// 2026-10-21 audit: 25 % CPU, 586 MB). The media the tab last reported still keeps it: the
    /// page's media script pushes that state (`BrowserMediaState+Scripts`), with no round trip.
    /// WebKit's own camera and microphone state is the planner's `isCapturing`; Chromium reports none to the app.
    static func unanswered(_ tab: any BrowserTab) -> PageProbe {
        let media = tab.state.media
        let playing = media.map { $0.isAudible || ($0.isPlaying && tab.state.isAudioMuted) || $0.isPictureInPicture } ?? false
        return PageProbe(playingMedia: playing, answered: false)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
