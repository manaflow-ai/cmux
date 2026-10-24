import CmuxNextBridge
import CmuxNextPages
import CmuxNextSettings

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the browser and agent page hibernation, follows `browser.hibernation`, and starts the
    /// memory pressure source that also sizes the terminal warm set (the one budget of hidden GPU surfaces).
    func startHibernation(settings: SettingsController) {
        let hibernation = BrowserHibernation(cache: cache)
        cache.hibernation = hibernation
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.onPressureChange = { [weak self] level in self?.memoryPressureDidChange(level) }
        hibernation.isDownloading = { [weak self] key in self?.cache.pageRequests.downloads.isDownloading(tab: key) ?? false }
        hibernation.measureMemory = { [weak self] in
            guard let self else { return [:] }
            return await self.resources.sample(.everything).browserTabMemory()
        }
        let agentPages = AgentPageHibernation(services: self)
        hibernation.agentPages = agentPages
        // cmux's own pages in Chromium (Home, Settings, Diff, Files, chats...) freeze while nobody
        // sees them, by the browser tabs' freeze plan; a chat whose turn runs stays awake.
        let cmuxPages = PageFreezing.hibernation()
        cmuxPages.exemption = { [weak agentPages] page in agentPages?.freezeExemption(for: page)?.rawValue }
        agentPages.turnsChanged = { [weak cmuxPages] in cmuxPages?.replan() }
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

extension PageFreezing {
    /// The cmux pages' freeze policy on the browser tabs' freeze plan (`browser.freezeHiddenTabs`).
    ///
    /// - Parameter clock: The deadline's clock (tests pass one they step).
    static func hibernation(clock: any Clock<Duration> = ContinuousClock()) -> PageFreezing {
        PageFreezing(plan: { setting, hidden in
            let plan = HibernationPlanner.freezePlan(setting, candidates: hidden.map { HibernationPlanner.Candidate(key: $0.key, hiddenFor: $0.value) })
            return (plan.due, plan.nextCheck)
        }, clock: clock)
    }
}
