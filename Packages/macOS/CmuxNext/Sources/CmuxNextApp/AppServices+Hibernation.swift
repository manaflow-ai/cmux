import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextResources
import CmuxNextSettings

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the browser and agent page hibernation, follows `browser.hibernation`, and follows the
    /// memory pressure level that also sizes the terminal warm set (the one budget of hidden GPU surfaces).
    /// It registers with the app's one memory coordinator (`memoryCoordinator`) as a lossy consumer,
    /// which hands it each level.
    func startHibernation(settings: SettingsController) {
        let audible = features.isEnabled(.recentlyAudibleProtection) ? AudibleHistory() : nil
        let hibernation = BrowserHibernation(cache: cache, memory: memoryCoordinator, lowPower: energyMonitor.lowPowerMode, audible: audible)
        cache.hibernation = hibernation
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.onPressureChange = { [weak self] level in self?.memoryPressureDidChange(level) }
        hibernation.isDownloading = { [weak self] key in self?.cache.pageRequests.downloads.isDownloading(tab: key) ?? false }
        hibernation.measureMemory = { [weak self] in
            guard let self else { return [:] }
            return await self.resources.sample(.everything).browserPageMemory
        }
        hibernation.activity.isEnabled = features.isEnabled(.memorySaverBackgroundActivity)
        hibernation.discardsGrowingFrozenPages = features.isEnabled(.frozenGrowthDiscard)
        hibernation.discardsAppPages = features.isEnabled(.memoryDiscardPageTabs)
        hibernation.discardsStreamedPages = features.isEnabled(.memoryDiscardRemoteTabs)
        hibernation.openerGroup = { [weak self] key in self?.openerGroup(of: key) ?? [key] }
        let agentPages = AgentPageHibernation(services: self)
        memoryHistograms.follow(hibernation, agentPages: agentPages)
        hibernation.agentPages = agentPages
        hibernation.follow(settings)
        hibernation.start()
        memoryFootprints.start()
        if features.isEnabled(.occludedWindowDiscard) {
            hibernation.follow(WindowOcclusionChecker(windows: { [weak self] in self?.windows.controllers.compactMap(\.window) ?? [] }))
        }
    }

    /// Tab `key` and every tab script can reach from it through `window.opener`
    /// (`BrowserScriptOpeners`: its opener, the tabs it opened, theirs), for a discard of the whole
    /// group (`FrozenGrowthRule`). Runs only on such a discard.
    func openerGroup(of key: String) -> Set<String> {
        let keys = Dictionary(cache.browsers.map { (ObjectIdentifier($0.value.tab), $0.key) }) { first, _ in first }
        let openers = cache.pageRequests.scriptOpeners.openers { keys[ObjectIdentifier($0)] }
        return FrozenGrowthRule.openerGroup(of: key, openers: openers)
    }

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        // Critical keeps only what shows, the parked workspaces too.
        if level == .critical { windows.controllers.forEach { $0.releaseParked() } }
    }
}

// The memory histograms' discard and wake counts come from the page hibernation (p07-memory-016).
extension MemoryHistograms {
    /// The content kinds whose discards are counted: those whose discard path calls
    /// ``recordDiscard(kind:)`` through ``follow(_:agentPages:)``. Any other kind has no histogram
    /// (absent, never a measured 0) until its discard path records too.
    static let hibernationKinds = [ContentKind.browser, .agentPage].map(\.rawValue)

    /// Counts each page `hibernation` hibernates and each agent page `agentPages` releases as a
    /// discard of its kind, and records each woken page's time to be back.
    func follow(_ hibernation: BrowserHibernation, agentPages: AgentPageHibernation) {
        hibernation.onHibernate = { [weak self] in self?.recordDiscard(kind: ContentKind.browser.rawValue) }
        hibernation.onWakeMounted = { [weak self] in self?.recordWake($0) }
        agentPages.onRelease = { [weak self] in self?.recordDiscard(kind: ContentKind.agentPage.rawValue) }
    }
}

extension ResourceSampleSet {
    /// The browser pages' memory for the hibernation: each one's number and its sharers.
    var browserPageMemory: [String: PageMemoryReading] {
        tabMemoryReadings(kinds: TabResourceKind.browserPages).mapValues { PageMemoryReading(bytes: $0.bytes, sharers: $0.sharers) }
    }
}
