import CmuxNextBridge
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the browser and agent page hibernation, follows `browser.hibernation`, and starts the
    /// memory pressure source that also sizes the terminal warm set (the one budget of hidden GPU surfaces).
    /// The ``MemoryPressureEvents`` made here has one subscriber, the hibernation, which holds it. The app
    /// still has four other kernel memory pressure sources (HostPressureMonitor, TabHoverCard,
    /// NewTabSparePool, PageHostPool); when they subscribe, the events become an `AppServices` stored
    /// service that all of them share.
    func startHibernation(settings: SettingsController) {
        let memoryPressure = MemoryPressureEvents(source: KernelMemoryPressureSource())
        let hibernation = BrowserHibernation(cache: cache, memoryPressure: memoryPressure)
        cache.hibernation = hibernation
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.onPressureChange = { [weak self] level in self?.memoryPressureDidChange(level) }
        hibernation.isDownloading = { [weak self] key in self?.cache.pageRequests.downloads.isDownloading(tab: key) ?? false }
        hibernation.measureMemory = { [weak self] in
            guard let self else { return [:] }
            return await self.resources.sample(.everything).browserTabMemory()
        }
        hibernation.agentPages = AgentPageHibernation(services: self)
        // cmux's own pages in Chromium (Settings, Diff, Files, chats...) freeze when hidden, as browser tabs do.
        let cmuxPages = CmuxPageFreezing()
        hibernation.cmuxPages = cmuxPages
        (PageWebView.chromiumHosting as? ChromiumPageHost)?.freezePolicy = cmuxPages
        hibernation.follow(settings)
        hibernation.start()
    }

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        // Critical keeps only what shows, the parked workspaces too.
        if level == .critical { windows.controllers.forEach { $0.releaseParked() } }
    }
}
