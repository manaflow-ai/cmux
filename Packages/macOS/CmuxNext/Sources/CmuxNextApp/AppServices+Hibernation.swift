import CmuxNextBridge
import CmuxNextSettings

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the hibernation controller, follows `browser.hibernation`,
    /// and starts the memory pressure source that also sizes the terminal
    /// warm set and each window's parked workspaces.
    func startHibernation(settings: SettingsController) {
        let hibernation = BrowserHibernation(cache: cache)
        cache.hibernation = hibernation
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.onPressureChange = { [weak self] level in self?.memoryPressureDidChange(level) }
        hibernation.follow(settings)
        hibernation.start()
    }

    func memoryPressureDidChange(_ level: MemoryPressureLevel) {
        let budget = WarmSetBudget.current(pressure: level)
        cache.setWarmBudget(budget)
        for controller in windows.controllers { controller.setParkedWorkspaceLimit(budget.parkedWorkspaces) }
    }
}
