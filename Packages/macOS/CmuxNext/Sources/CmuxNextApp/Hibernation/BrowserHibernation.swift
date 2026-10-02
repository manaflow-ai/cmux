import AppKit
import CmuxNextBridge
import CmuxNextBrowser
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
    /// History and snapshot captured by the probe, used by the `release` effect.
    private var prepared: [String: (state: BrowserRestoreState, snapshot: CGImage?)] = [:]
    private var probing: Set<String> = []
    private let deadline = DemandTimer(owner: "BrowserHibernation")
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    /// Pinned state of a tab (the daemon record); injected by the App.
    var isPinned: (String) -> Bool = { _ in false }
    /// Memory pressure changed (the App resizes the terminal warm set and
    /// the parked workspaces).
    var onPressureChange: ((MemoryPressureLevel) -> Void)?
    private(set) var exemptions: [String: HibernationPlanner.Exemption] = [:]
    private var settingsObservation: Task<Void, Never>?
    private(set) var hibernatedCount = 0
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
            MainActor.assumeIsolated { self?.pressureDidChange(level) }
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
            for await setting in Observations({ settings.snapshot.browserHibernation }) {
                self?.apply(setting)
            }
        }
    }

    func apply(_ setting: BrowserHibernationSetting) {
        guard setting != self.setting else { return }
        self.setting = setting
        replan()
    }

    func pressureDidChange(_ level: MemoryPressureLevel) {
        guard level != pressure else { return }
        pressure = level
        logger.info("memory pressure \(level.rawValue, privacy: .public)")
        onPressureChange?(level)
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

    func forget(_ key: String) {
        cache?.dormantTabs.set(key, false)
        hiddenAt[key] = nil
        prepared[key] = nil
        probing.remove(key)
        exemptions[key] = nil
    }

    // MARK: Planning

    /// Hibernates every due page and arms one deadline for the next.
    func replan() {
        guard let cache else { return }
        let now = ContinuousClock.now
        let candidates = cache.lifecycle.keys(in: .mountedHidden).compactMap { key -> HibernationPlanner.Candidate? in
            guard let at = hiddenAt[key], !probing.contains(key), let entry = cache.browsers[key] else { return nil }
            return candidate(key, entry: entry, hiddenFor: (now - at).seconds)
        }
        let plan = HibernationPlanner.plan(setting, pressure: pressure, candidates: candidates)
        exemptions.merge(plan.exemptions) { $1 }
        for key in plan.due { prepare(key) }
        if let next = plan.nextCheck {
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
            canRestore: (tab as? any BrowserHibernationSource)?.supportsHibernation ?? false
        )
    }

    // MARK: Hibernate

    /// The user's Hibernate Tab action: a hidden page hibernates now unless
    /// its engine cannot restore it. Returns why not, or nil when it started.
    func hibernateNow(_ key: String) -> HibernationPlanner.Exemption? {
        guard let cache, let entry = cache.browsers[key], cache.lifecycle.phase(key) == .mountedHidden else { return .disabled }
        let facts = candidate(key, entry: entry, hiddenFor: 0)
        guard facts.canRestore else { return .unsupported }
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
            let snapshot = await Self.snapshot(tab, cached: self?.cache?.previews.image(for: key))
            guard let self, let cache = self.cache else { return }
            self.probing.remove(key)
            // Still the same hidden page: no show, hide or close since.
            guard cache.browsers[key]?.tab === tab, cache.lifecycle.record(key)?.generation == generation,
                  cache.lifecycle.phase(key) == .mountedHidden else {
                cache.trace(key, "hibernate probe dropped (stale)")
                return
            }
            if let exemption = probe.exemption {
                self.exemptions[key] = exemption
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

    private static func snapshot(_ tab: any BrowserTab, cached: CGImage?) async -> CGImage? {
        if let cached { return cached }
        return try? await ControlDeadline.shared.run(method: "hibernation.snapshot", deadline: .now + .seconds(2)) { @MainActor in
            try await tab.snapshot()
        }
    }

    /// The `release` effect: swaps the page for a `HibernatedBrowserTab`
    /// holding its history and snapshot, and closes the engine page.
    func release(_ key: String, token: ContentLifecycle<String>.Token) {
        guard let cache, let entry = cache.browsers[key], let saved = prepared.removeValue(forKey: key) else {
            logger.error("hibernate \(key, privacy: .public): nothing prepared")
            return
        }
        let page = entry.tab
        let placeholder = HibernatedBrowserTab(
            id: page.id, engine: page.engineKind, profile: page.profileID, state: page.state,
            favicon: page.favicon, restoreState: saved.state, snapshot: saved.snapshot
        )
        placeholder.onWake = { [weak self] url in self?.wakeForNavigation(key, url: url) }
        if let snapshot = saved.snapshot { cache.previews.insert(snapshot, for: key) }
        cache.swapPage(key, with: placeholder)
        cache.dormantTabs.set(key, true)
        hiddenAt[key] = nil
        hibernatedCount += 1
        logger.info("hibernated \(key, privacy: .public) \(token.description, privacy: .public)")
    }

    // MARK: Restore

    /// The user navigated or reloaded a hibernated page: restore it, then load.
    private func wakeForNavigation(_ key: String, url: URL?) {
        guard let cache else { return }
        pendingLoads[key] = url
        cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
    }

    private var pendingLoads: [String: URL?] = [:]

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
        var configuration = BrowserTabConfiguration(id: placeholder.id, profile: placeholder.profileID, zoom: placeholder.state.zoom)
        switch placeholder.engineKind {
        case .webkit:
            let tab = cache.webKit.makeWebKitTab(configuration)
            if !tab.restore(placeholder.restoreState), let url = placeholder.state.url { tab.load(url) }
            finishRestore(key, token: token, page: tab)
        case .cef:
            configuration.initialURL = placeholder.state.url
            configuration.restoreState = placeholder.restoreState
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
        restoredCount += 1
        cache.applyLifecycle(cache.lifecycle.send(.mounted(key, token)))
        // A navigation that woke the page runs once its history is back
        // (reload and back/forward just wake it).
        if case .some(.some(let url)) = pendingLoads.removeValue(forKey: key) { page.load(url) }
    }
}

/// What the page says right before it hibernates.
struct PageProbe {
    var playingMedia = false
    var editedForm = false

    var exemption: HibernationPlanner.Exemption? {
        playingMedia ? .audio : editedForm ? .formInput : nil
    }

    /// Unmuted media playing, or form fields whose value differs from the
    /// page's default (form interaction). A page that does not
    /// answer within the deadline is treated as busy and kept.
    static let script = """
    (() => {
      const media = [...document.querySelectorAll('audio,video')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0);
      const form = [...document.querySelectorAll('input,textarea,select')].some(e => {
        if (e.disabled || e.type === 'hidden' || e.type === 'submit' || e.type === 'button') return false;
        if (e.tagName === 'SELECT') return [...e.options].some(o => o.selected !== o.defaultSelected);
        if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
        return e.value !== e.defaultValue;
      });
      return JSON.stringify({media, form});
    })()
    """

    static func run(_ tab: any BrowserTab) async -> PageProbe {
        do {
            let value = try await ControlDeadline.shared.run(method: "hibernation.probe", deadline: .now + .seconds(2)) { @MainActor in
                try await tab.evaluate(script, world: .isolated)
            }
            guard case .string(let json) = value, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return PageProbe(playingMedia: true) }
            return PageProbe(playingMedia: object["media"] ?? true, editedForm: object["form"] ?? true)
        } catch {
            return PageProbe(playingMedia: true)
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
