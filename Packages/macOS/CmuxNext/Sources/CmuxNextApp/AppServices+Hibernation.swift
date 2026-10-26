import CmuxNextBridge
import CmuxNextCompat
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
        let hibernation = BrowserHibernation(cache: cache, memory: memoryCoordinator)
        cache.hibernation = hibernation
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.onPressureChange = { [weak self] level in self?.memoryPressureDidChange(level) }
        hibernation.isDownloading = { [weak self] key in self?.cache.pageRequests.downloads.isDownloading(tab: key) ?? false }
        hibernation.measureMemory = { [weak self] in
            guard let self else { return [:] }
            return await self.resources.sample(.everything).tabMemory(kinds: TabResourceKind.browserPages)
        }
        hibernation.discardsGrowingFrozenPages = features.isEnabled(.frozenGrowthDiscard)
        hibernation.openerGroup = { [weak self] key in self?.openerGroup(of: key) ?? [key] }
        hibernation.agentPages = AgentPageHibernation(services: self)
        hibernation.follow(settings)
        hibernation.start()
    }

    /// Tab `key` and every tab linked to it through the tab strip's opener relations
    /// (`BrowserTabOpeners.openerOf`: openers, the tabs they opened, theirs), for a discard of
    /// the whole group (`FrozenGrowthRule`). Runs only on such a discard.
    func openerGroup(of key: String) -> Set<String> {
        guard let start = locateTab(key)?.0.surface else { return [key] }
        let group = FrozenGrowthRule.openerGroup(of: start, openers: cache.pageRequests.openers.openerOf)
        return Set(group.compactMap { locateTab(surface: $0)?.id }).union([key])
    }

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        // Critical keeps only what shows, the parked workspaces too.
        if level == .critical { windows.controllers.forEach { $0.releaseParked() } }
    }
}
