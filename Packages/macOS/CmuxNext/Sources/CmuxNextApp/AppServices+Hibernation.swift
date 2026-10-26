import CmuxNextBridge
import CmuxNextCompat
import CmuxNextMemory
import CmuxNextResources
import CmuxNextSettings

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the browser and agent page hibernation, follows `browser.hibernation`, and starts the
    /// memory pressure source that also sizes the terminal warm set (the one budget of hidden GPU surfaces).
    /// It subscribes to the app's one ``MemoryPressureEvents`` (`memoryPressure`), which the new tab
    /// and page host spare pools share.
    func startHibernation(settings: SettingsController) {
        let hibernation = BrowserHibernation(cache: cache, memoryPressure: memoryPressure)
        cache.hibernation = hibernation
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.onPressureChange = { [weak self] level in self?.memoryPressureDidChange(level) }
        Self.follow(memoryCoordinator, in: hibernation)
        hibernation.isDownloading = { [weak self] key in self?.cache.pageRequests.downloads.isDownloading(tab: key) ?? false }
        hibernation.measureMemory = { [weak self] in
            guard let self else { return [:] }
            return await self.resources.sample(.everything).tabMemory(kinds: TabResourceKind.browserPages)
        }
        hibernation.agentPages = AgentPageHibernation(services: self)
        hibernation.follow(settings)
        hibernation.start()
    }

    /// Makes `hibernation` act on `coordinator`'s level: its pressure override while one is set
    /// (`debug.hibernation.pressure`), else the level the kernel reports. That is the coordinator's own
    /// rule, applied to the reported level because pressure handlers run in no fixed order, so the
    /// coordinator may not have the event yet.
    ///
    /// - Parameters:
    ///   - coordinator: The app's one memory coordinator.
    ///   - hibernation: The browser hibernation, before `start()`.
    static func follow(_ coordinator: MemoryCoordinator, in hibernation: BrowserHibernation) {
        hibernation.effectiveLevel = { [weak coordinator] reported in coordinator?.pressureOverride ?? reported }
    }

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        // Critical keeps only what shows, the parked workspaces too.
        if level == .critical { windows.controllers.forEach { $0.releaseParked() } }
    }
}
