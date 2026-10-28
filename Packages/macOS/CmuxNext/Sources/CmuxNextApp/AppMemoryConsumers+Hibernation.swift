import CmuxNextHibernation
import CmuxNextSettings
import CmuxNextWakeups

// The memory consumers that start with the browser hibernation (AppServices+Hibernation's `startHibernation`).
extension AppMemoryConsumers {
    /// The consumers that start with the hibernation (`startHibernation` calls it once it made it): its pictures
    /// (``registerHibernationSnapshots(_:)``), and page tabs' discards, which follow its setting from now
    /// (``followPageDiscards(_:)``).
    func followHibernation(_ hibernation: BrowserHibernation, settings: SettingsController) {
        registerHibernationSnapshots(hibernation)
        followPageDiscards(settings)
    }

    /// Page tabs' discards (`memoryDiscardInternalPages` with `pageLifecycle` off) follow `browser.hibernation`, the
    /// current value now: off or not written, no page tab goes on its own, at any pressure, as browser tabs and the
    /// page lifecycle (trunk #25920: a page never reloads unless the person asks). `background`, as the Memory Saver
    /// mode: the scheduler's next look runs on its deadline, never in the flush's turn.
    private func followPageDiscards(_ settings: SettingsController) {
        guard let discards = services.pages.discards else { return }
        services.lifetimeFollowers.append(ServiceObservation(.background, owner: "AppMemoryConsumers.pageDiscards", on: services.mainWork) {
            settings.snapshot.browserHibernation
        } apply: { [weak discards] setting in discards?.update(browserHibernation: setting) })
    }
}
