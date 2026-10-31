public import CmuxNextWakeups
public import CmuxNextHibernation
import CmuxNextBridge
import CmuxNextCompat
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
        hibernation.isPinned = { [weak self] key in self?.locateTabOnAnyMachine(key)?.0.pinned ?? false }
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

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        // Critical keeps only what shows, the parked workspaces too.
        if level == .critical { windows.controllers.forEach { $0.releaseParked() } }
        workspaceHibernation.pressureDidChange(level)
    }
}

// Workspace hibernation (plans/cmux-next/workspace-hibernation-DESIGN.md): what the Host forwards to.
extension AppServices {
    /// Whether tab `key` holds memory in this app: a terminal surface, a live page, a chat page.
    func holdsTabMemory(_ key: String) -> Bool { cache.holdsMemory(key) || madeAgentTabs?.existingView(key) != nil }

    /// Unmounts workspace `id` in every window, then frees its tabs' surfaces and pages.
    func hibernateWorkspace(_ id: String) {
        windows.releaseParked(id)
        cache.hibernateTabs(machines.workspace(id: id)?.0.screens.flatMap(\.panes).flatMap(\.tabs).map(\.id) ?? [])
    }
}

// The app's one-shot timer is workspace hibernation's deadline (plans/cmux-next/workspace-hibernation-DESIGN.md).
extension DemandTimer: WorkspaceHibernationDeadline {}
