import CmuxNextBridge
import CmuxNextPages
import CmuxNextSettings

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the browser and agent page hibernation, follows `browser.hibernation`, and starts the
    /// memory pressure source that also sizes the terminal warm set (the one budget of hidden GPU surfaces).
    ///
    /// - Parameters:
    ///   - settings: The settings whose `browser.hibernation` the hibernation follows.
    ///   - cmuxPages: The freeze policy of cmux's own pages in Chromium; the same object goes to
    ///     ``makeChromiumPageHost(freezePolicy:)``, so the setting the hibernation applies is the one
    ///     every page reports to.
    func startHibernation(settings: SettingsController, cmuxPages: CmuxPageFreezing) {
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
        hibernation.follow(settings)
        hibernation.start()
    }

    /// The one Chromium host of cmux's own pages (``PageWebView/chromiumHosting``): every page view
    /// follows `browser.defaultEngine` through it, and every started page reports to `freezePolicy`,
    /// so a hidden cmux page (Settings, Diff, Files, chats...) freezes as hidden browser tabs do.
    ///
    /// - Parameter freezePolicy: The hibernation's freeze policy (``startHibernation(settings:cmuxPages:)``).
    /// - Returns: The host.
    func makeChromiumPageHost(freezePolicy: any PageFreezePolicy) -> ChromiumPageHost {
        ChromiumPageHost(
            cef: cache.cef,
            preference: { [weak self] in
                self?.settings?.snapshot.browserDefaultEngine ?? self?.cache.browserTabs.preference.defaultEngine ?? .fallback
            },
            keyRouter: keyRouter,
            freezePolicy: freezePolicy)
    }

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        // Critical keeps only what shows, the parked workspaces too.
        if level == .critical { windows.controllers.forEach { $0.releaseParked() } }
    }
}
