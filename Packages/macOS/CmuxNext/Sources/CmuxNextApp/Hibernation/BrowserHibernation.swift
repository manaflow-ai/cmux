import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
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
@MainActor
final class BrowserHibernation {
    private weak var cache: TabContentCache?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.hibernation")
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
    private var prepared: [String: (state: BrowserRestoreState, snapshot: CGImage?)] = [:]
    private var probing: Set<String> = []
    private let deadline = DemandTimer(owner: "BrowserHibernation")
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
    private(set) var restoredCount = 0

    init(cache: TabContentCache) {
        self.cache = cache
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
    }

    func stop() {
        settingsObservation?.cancel()
        pressureSource?.cancel()
        pressureSource = nil
        deadline.cancel()
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
        replan()
    }

    func pressureDidChange(_ level: MemoryPressureLevel) {
        guard level != pressure else { return }
        pressure = level
        logger.info("memory pressure \(level.rawValue, privacy: .public)")
        onPressureChange?(level)
        agentPages?.update(setting: setting, pressure: pressure)
        replan()
    }

    // MARK: Lifecycle notifications (from TabContentCache effects)

    func tabDidHide(_ key: String) {
        guard cache?.browsers[key] != nil else { return }
        hiddenAt[key] = .now
        replan()
    }

    func tabDidShow(_ key: String) {
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
    }

    // MARK: Planning

    /// Hibernates every due page and arms one deadline for the next.
    func replan() {
        guard let cache else { return }
        let now = ContinuousClock.now
        var graceEnds: Double?
        let candidates = cache.lifecycle.keys(in: .mountedHidden).compactMap { key -> HibernationPlanner.Candidate? in
            guard let at = hiddenAt[key], !probing.contains(key), let entry = cache.browsers[key] else { return nil }
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
    }

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

    /// A fresh picture (never one from an earlier sleep), scaled so that several fit the 32 MB
    /// `previews` cache, which refuses a picture larger than itself (a big pane at 2x).
    private func snapshot(_ tab: any BrowserTab, key: String) async -> CGImage? {
        guard let image = await capture(tab) else { return nil }
        // A quarter of the cache, less a margin for row padding; same aspect and color space, off the main actor.
        let bytes = Double((cache?.previews.capacityBytes ?? 32 << 20) / 4) * 0.98
        let scale = min(1, (bytes / Double(max(image.width * image.height * 4, 1))).squareRoot())
        return await TabPreviewFitting.fit(image, CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
    }

    /// The `release` effect: swaps the page for a `HibernatedBrowserTab`
    /// holding its history, and closes the engine page. Its snapshot lives in the
    /// 32 MB `previews` LRU only: each placeholder used to keep its own full-size
    /// picture (about 7 MB of app memory per hibernated tab in the 2026-10-14 audit).
    func release(_ key: String, token: ContentLifecycle<String>.Token) {
        guard let cache, let entry = cache.browsers[key], let saved = prepared.removeValue(forKey: key) else {
            logger.error("hibernate \(key, privacy: .public): nothing prepared")
            return
        }
        let page = entry.tab
        let placeholder = HibernatedBrowserTab(
            id: page.id, engine: page.engineKind, profile: page.profileID, state: page.state,
            favicon: page.favicon, restoreState: saved.state, snapshot: { [weak cache] in cache?.previews.image(for: key) }
        )
        placeholder.onWake = { [weak self] wake in self?.wakeForNavigation(key, wake) }
        if let snapshot = saved.snapshot { cache.previews.insert(snapshot, for: key) }
        cache.swapPage(key, with: placeholder)
        cache.dormantTabs.set(key, true)
        hiddenAt[key] = nil
        // A probe that kept the page before no longer applies (`debug.surfaces`).
        exemptions[key] = nil
        hibernatedCount += 1
        logger.info("hibernated \(key, privacy: .public) \(token.description, privacy: .public)")
    }

    // MARK: Restore

    /// The user navigated, reloaded or went back or forward in a hibernated
    /// page: restore it, then apply that request.
    private func wakeForNavigation(_ key: String, _ wake: HibernatedBrowserTab.Wake) {
        guard let cache else { return }
        pendingWakes[key] = wake
        cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
    }

    /// At most one per hibernated page; dropped when it restores.
    private var pendingWakes: [String: HibernatedBrowserTab.Wake] = [:]

    /// The user's Wake Tab action (restores in the background).
    func wake(_ key: String) -> Bool {
        guard let cache, cache.lifecycle.phase(key) == .hibernated else { return false }
        cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
        return true
    }

    /// The `restore` effect: recreates the engine page from the saved
    /// history; the lifecycle shows it if it is still selected when it lands.
    func restore(_ key: String, token: ContentLifecycle<String>.Token) {
        guard let cache, let placeholder = cache.browsers[key]?.tab as? HibernatedBrowserTab else {
            cache?.applyLifecycle(cache?.lifecycle.send(.mountFailed(key, token)) ?? [])
            return
        }
        // The record's profile: a tab moved to another one while asleep wakes there, without the old one's history.
        let profile = cache.tabModel(key) == nil ? placeholder.profileID : cache.browserProfile?(key) ?? placeholder.profileID
        let history = profile == placeholder.profileID ? placeholder.restoreState : nil
        var configuration = BrowserTabConfiguration(id: placeholder.id, profile: profile, zoom: placeholder.state.zoom)
        switch placeholder.engineKind {
        case .webkit:
            let tab = cache.webKit.makeWebKitTab(id: configuration.id, profile: configuration.profile, zoom: configuration.zoom)
            if !(history.map({ tab.restore($0) }) ?? false), let url = placeholder.state.url { tab.load(url) }
            finishRestore(key, token: token, page: tab)
        case .cef:
            configuration.initialURL = placeholder.state.url
            configuration.restoreState = history
            let make = cache.makeCEFTab
            let tab = cache.tabModel(key)
            Task { @MainActor [weak self, weak cache] in
                do {
                    // The remote-localhost store and guard, as for any Chromium page.
                    let configured = await cache?.chromiumConfiguration(for: tab, base: configuration) ?? configuration
                    let page = try await make(configured)
                    self?.finishRestore(key, token: token, page: page)
                } catch {
                    guard let cache = self?.cache else { return }
                    self?.logger.error("restore \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    cache.applyLifecycle(cache.lifecycle.send(.mountFailed(key, token)))
                }
            }
        }
    }

    private func finishRestore(_ key: String, token: ContentLifecycle<String>.Token, page: any BrowserTab) {
        guard let cache, cache.browsers[key]?.tab is HibernatedBrowserTab, cache.lifecycle.record(key)?.pending == token else {
            // Closed or superseded while it restored.
            page.close()
            return
        }
        cache.swapPage(key, with: page)
        cache.dormantTabs.set(key, false)
        cache.previews.remove(key)  // the live page now; a later sleep takes a new picture
        restoredCount += 1
        cache.applyLifecycle(cache.lifecycle.send(.mounted(key, token)))
        // A navigation or history step that woke the page runs once its
        // history is back (a reload just wakes it: restoring loads the page).
        switch pendingWakes.removeValue(forKey: key) {
        case .load(let url)?: page.load(url)
        case .goBack?: page.goBack()
        case .goForward?: page.goForward()
        case .reload?, nil: break
        }
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
            // The recorder knows the person's edits (`BrowserPageBusy`); a page loaded before it compares every field.
            return PageProbe(playingMedia: muted || (object["media"] ?? true), editedForm: busy.editedForm ?? object["form"] ?? true,
                             capturing: busy.capturing, webAudio: busy.audio)
        } catch {
            return PageProbe(playingMedia: true)
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
