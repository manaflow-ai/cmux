import CmuxNextBridge
import CmuxNextPages
import CmuxNextSettings

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the browser and agent page hibernation, follows `browser.hibernation`, and starts the
    /// memory pressure source that also sizes the terminal warm set (the one budget of hidden GPU surfaces).
    ///
    /// - Parameter settings: The settings whose `browser.hibernation` the hibernation follows.
    func startHibernation(settings: SettingsController) {
        let hibernation = makeHibernation()
        hibernation.follow(settings)
        hibernation.start()
    }

    /// The app's browser and agent page hibernation, wired to these services and set as the cache's,
    /// not yet following settings. It keeps ``cmuxPages`` on its setting: the policy
    /// ``makeChromiumPageHost()`` hands to every cmux page.
    func makeHibernation() -> BrowserHibernation {
        let hibernation = BrowserHibernation(cache: cache, cmuxPages: cmuxPages)
        cache.hibernation = hibernation
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.onPressureChange = { [weak self] level in self?.memoryPressureDidChange(level) }
        hibernation.isDownloading = { [weak self] key in self?.cache.pageRequests.downloads.isDownloading(tab: key) ?? false }
        hibernation.measureMemory = { [weak self] in
            guard let self else { return [:] }
            return await self.resources.sample(.everything).browserTabMemory()
        }
        hibernation.agentPages = AgentPageHibernation(services: self)
        return hibernation
    }

    /// The app's Chromium host of every cmux page view: it follows `browser.defaultEngine` (the
    /// settings snapshot, so pages made while windows restore already follow the file) and hands
    /// every started page ``cmuxPages``, the policy the hibernation keeps on `browser.freezeHiddenTabs`.
    func makeChromiumPageHost() -> ChromiumPageHost {
        ChromiumPageHost(
            cef: cache.cef,
            preference: { [weak self] in
                self?.settings?.snapshot.browserDefaultEngine ?? self?.cache.browserTabs.preference.defaultEngine ?? .fallback
            },
            keyRouter: keyRouter,
            freezePolicy: cmuxPages)
    }

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        // Critical keeps only what shows, the parked workspaces too.
        if level == .critical { windows.controllers.forEach { $0.releaseParked() } }
    }
}
