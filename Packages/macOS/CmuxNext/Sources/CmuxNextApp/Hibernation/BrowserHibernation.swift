import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import os

/// Hibernates hidden browser pages and restores them when shown
/// (plans/cmux-next/tab-lifecycle.md). Configured by
/// `browser.hibernation`; "off" disables it completely.
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
    /// History and snapshot captured by the probe, used by the `release` effect.
    private var prepared: [String: (state: BrowserRestoreState, snapshot: HibernationSnapshots.Picture?)] = [:]
    /// Hibernated pages' pictures (`HibernationTunables.compressedSnapshots`), and their wakes (`debug.surfaces`).
    let snapshots = HibernationSnapshots()
    var wakeLog = HibernationWakes()
    /// A navigation that woke a hibernated page, applied once it is back; at most one per page.
    var pendingWakes: [String: HibernatedBrowserTab.Wake] = [:]
    private var probing: Set<String> = []
    private let deadline = DemandTimer(owner: "BrowserHibernation")
    /// Hidden pages frozen now (`browser.freezeHiddenTabs`); they thaw when shown or driven.
    private(set) var frozen: Set<String> = []
    /// Pages a freeze probe is asking (media, Web Audio, capture).
    private var freezeProbing: Set<String> = []
    /// When a page the probe kept awake (playing audio) is asked again.
    private var freezeKeptAt: [String: ContinuousClock.Instant] = [:]
    private let freezeDeadline = DemandTimer(owner: "BrowserFreeze")
    private var pressureSource: (any DispatchSourceMemoryPressure)?
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
    private let lowPower: LowPowerMode
    private var lowPowerObservation: LowPowerModeObservation?
    /// The page's freeze control (a seam for tests; Chromium pages only in the app).
    var freezer: (any BrowserTab) -> (any BrowserFreezing)? = { $0 as? any BrowserFreezing }

    init(cache: TabContentCache, lowPower: LowPowerMode = .system) {
        self.cache = cache
        self.lowPower = lowPower
    }

    /// Tabs on each side of a shown tab that stay awake now: the setting, or 0
    /// under memory pressure or in Low Power Mode.
    var neighborRadius: Int {
        NeighborTabs.radius(setting: setting.neighborRadius, pressure: pressure, lowPower: lowPower.isEnabled)
    }

    /// Starts listening to memory pressure (the dispatch source; no polling).
    func start() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let level: MemoryPressureLevel = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            MainActor.assumeIsolated { self?.pressureDidChange(level) } // main-proof: dispatch source on queue: .main
        }
        source.activate()
        pressureSource = source
        lowPowerObservation = lowPower.observe { [weak self] _ in self?.refreshNeighbors() }
    }

    func stop() {
        settingsObservation?.cancel()
        pressureSource?.cancel()
        pressureSource = nil
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
        logger.info("memory pressure \(level.rawValue, privacy: .public)")
        onPressureChange?(level)
        agentPages?.update(setting: setting, pressure: pressure)
        refreshNeighbors(replans: false)
        replan()
    }

    // MARK: Lifecycle notifications (from TabContentCache effects)

    func tabDidHide(_ key: String) {
        guard cache?.browsers[key] != nil else { return }
        hiddenAt[key] = .now
        replan()
    }

    func tabDidShow(_ key: String) {
        if frozen.contains(key) { coldShows += 1 }
        thaw(key)
        freezeKeptAt[key] = nil
        hoveredAt[key] = nil
        hiddenAt[key] = nil
        prepared[key] = nil
        exemptions[key] = nil
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
        exemptions[key] = nil
        frozen.remove(key)
        freezeProbing.remove(key)
        freezeKeptAt[key] = nil
        hoveredAt[key] = nil
        awakeNeighbors.remove(key)
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
            return candidate(key, entry: entry, hiddenFor: (now - at).seconds)
        }
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: candidates)
        exemptions.merge(plan.exemptions) { $1 }
        for key in plan.due { prepare(key) }
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

    /// Asks the page for playing media, Web Audio and capture, then freezes it
    /// if it is still the same hidden page. A page that plays stays awake and
    /// is asked again after `freezeSeconds`.
    private func freeze(_ key: String) {
        guard let cache, let tab = cache.browsers[key]?.tab, let page = freezer(tab),
              let generation = cache.lifecycle.record(key)?.generation, freezeProbing.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            let probe = await PageProbe.run(tab)
            guard let self, let cache = self.cache else { return }
            self.freezeProbing.remove(key)
            guard cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
                  cache.lifecycle.phase(key) == .mountedHidden, self.hiddenAt[key] != nil else { return }
            if let used = self.agentUsedAt[key], (ContinuousClock.now - used).seconds < Self.agentGrace { return }
            // It became a neighbor (or was hovered) while the probe ran.
            if self.awakeNeighbors.contains(key) || self.hoverLeft(key, now: .now) != nil { return }
            if probe.capturing || probe.playingMedia || probe.webAudio {
                self.freezeKeptAt[key] = .now
                self.replan()
                return
            }
            page.setFrozen(true)
            self.frozen.insert(key)
            cache.trace(key, "frozen")
        }
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

    private func candidate(_ key: String, entry: BrowserEntry, hiddenFor: Double) -> HibernationPlanner.Candidate {
        let tab = entry.tab
        let capturing = (tab as? any PageInfoProviding).map { !$0.pageInfoInUse.union($0.pageInfoActivity.inUse).isEmpty } ?? false
        return HibernationPlanner.Candidate(
            key: key, hiddenFor: hiddenFor, host: tab.state.url?.host(), isPinned: isPinned(key),
            hasDevTools: (tab as? any BrowserDevToolsHosting)?.devTools.isOpen ?? false, isCapturing: capturing,
            canRestore: (tab as? any BrowserHibernationSource)?.supportsHibernation ?? false,
            showsFormSubmission: (tab as? any BrowserHibernationSource)?.showsFormSubmission ?? false
        )
    }

    // MARK: Hibernate

    /// The user's Hibernate Tab action: a hidden page hibernates now unless
    /// its engine cannot restore it. Returns why not, or nil when it started.
    func hibernateNow(_ key: String) -> HibernationPlanner.Exemption? {
        guard let cache, let entry = cache.browsers[key], cache.lifecycle.phase(key) == .mountedHidden else { return .disabled }
        let facts = candidate(key, entry: entry, hiddenFor: 0)
        guard facts.canRestore else { return .unsupported }
        guard !facts.showsFormSubmission else { exemptions[key] = .formSubmission; return .formSubmission }
        prepare(key, user: true)
        return nil
    }

    /// Probes the page, captures its history and snapshot, then hibernates
    /// it if it is still hidden with the same generation.
    private func prepare(_ key: String, user: Bool = false) {
        guard let cache, let entry = cache.browsers[key], let source = entry.tab as? any BrowserHibernationSource,
              let generation = cache.lifecycle.record(key)?.generation, probing.insert(key).inserted else { return }
        let tab = entry.tab
        // The probe and the history capture run script: a frozen page runs none.
        thaw(key)
        Task { @MainActor [weak self] in
            let probe = user ? PageProbe() : await PageProbe.run(tab)
            let exemption = probe.exemption(pressure: self?.pressure ?? .normal) ?? (source.showsFormSubmission ? .formSubmission : nil)
            // A page that stays needs no picture (each replan probes it again).
            let snapshot = exemption == nil ? await self?.snapshot(tab, key: key) : nil
            guard let self, let cache = self.cache else { return }
            self.probing.remove(key)
            // Still the same hidden page: no show, hide or close since.
            guard cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
                  cache.lifecycle.phase(key) == .mountedHidden else {
                cache.trace(key, "hibernate probe dropped (stale)")
                return
            }
            if let exemption {
                self.exemptions[key] = exemption
                return
            }
            // It became a neighbor or was hovered while the probe ran (the person's Hibernate Tab still applies).
            if !user, self.awakeNeighbors.contains(key) || self.hoverLeft(key, now: .now) != nil {
                self.exemptions[key] = .neighbor
                return
            }
            // An agent called the page while the probe ran: it stays awake (the person's Hibernate Tab still applies).
            if !user, let used = self.agentUsedAt[key], (ContinuousClock.now - used).seconds < Self.agentGrace {
                self.exemptions[key] = .agentDriving
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
        hiddenAt[key] = nil
        // A probe that kept the page before no longer applies (`debug.surfaces`).
        exemptions[key] = nil
        hibernatedCount += 1
        logger.info("hibernated \(key, privacy: .public) \(token.description, privacy: .public)")
    }
}

/// What the page says right before it hibernates.
struct PageProbe {
    var playingMedia = false
    var editedForm = false
    /// Camera, microphone or screen capture the page started (`BrowserPageBusy`).
    var capturing = false
    /// A running Web Audio context. It may be silent (a chat app's notification sounds, a
    /// game), unlike a playing element, so critical memory pressure overrides it.
    var webAudio = false

    func exemption(pressure: MemoryPressureLevel) -> HibernationPlanner.Exemption? {
        if capturing { return .capturing }
        if playingMedia { return .audio }
        if editedForm { return .formInput }
        return webAudio && pressure != .critical ? .webAudio : nil
    }

    static func run(_ tab: any BrowserTab) async -> PageProbe {
        do {
            let (value, busy) = try await ControlDeadline.shared.run(method: "hibernation.probe", deadline: .now + .seconds(2)) { @MainActor in
                (try await tab.evaluate(BrowserPageBusy.fieldProbeScript, world: .isolated), try await tab.pageBusy())
            }
            guard case .string(let json) = value, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return PageProbe(playingMedia: true) }
            // Media the tab's mute silences still plays (cx-d0d.24): hibernating would drop the mute.
            let muted = tab.state.isAudioMuted && tab.state.media?.isPlaying == true
            // A video in Picture in Picture plays on in its floating window, paused or muted alike.
            let floating = tab.state.media?.isPictureInPicture == true
            // The recorder knows the person's edits (`BrowserPageBusy`); a page loaded before it compares every field.
            return PageProbe(playingMedia: muted || floating || (object["media"] ?? true), editedForm: busy.editedForm ?? object["form"] ?? true,
                             capturing: busy.capturing, webAudio: busy.audio)
        } catch {
            return PageProbe(playingMedia: true)
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
