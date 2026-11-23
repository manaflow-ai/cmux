public import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextWakeups
public import CmuxNextSettings
public import CmuxNextUpdater

extension UpdaterService {
    /// Applies `updates.*` from cmux.json (R114): the web updates, live web reload, the gate's
    /// preferences, and Sparkle's schedule and download behavior.
    public func apply(_ updates: UpdatesSettings) {
        WebUpdates.shared.follow(updates)
        WebDevOverride.setAllowed(updates.liveWebReload)
        let preferences = UpdatePreferences(
            installOnQuit: updates.installOnQuit,
            notify: UpdateNotifyMode(rawValue: updates.notify.rawValue) ?? .badge,
            keepPreviousVersions: updates.keepPreviousVersions, oneClickInstall: updates.oneClickInstall, whatsNewInstall: updates.whatsNewInstall)
        if self.preferences != preferences { self.preferences = preferences }
        configure(checkAutomatically: updates.checkAutomatically, checkInterval: updates.checkIntervalSeconds,
                  downloadAutomatically: updates.downloadAutomatically,
                  metered: UpdateMeteredMode(rawValue: updates.meteredNetwork.rawValue) ?? .deferLowData, ring: updates.channel.rawValue, idleInstall: (updates.idleInstallMaxWaitSeconds, updates.idleInstallQuietSeconds),
                  installWhenIdleMinutes: updates.installWhenIdle ? updates.installWhenIdleMinutes : nil)
    }

    /// NIGHTLY's install check (``NightlyInstallCheck``): once per build, a canary chat to this
    /// build's acpmux daemon (`host`, the app's agent host); a refusal rolls app and daemon back to
    /// the last build that passed. `notify` posts the one line to the daemon's notification ledger,
    /// which outlives the relaunch.
    public func attachInstallCheck(host: any AgentPaneHostProviding, notify: @escaping @MainActor (_ title: String, _ body: String) -> Void) {
        let check = NightlyInstallCheck(self)
        guard check.isEnabled else { return }
        let host = host as? AcpmuxHost
        let directories = pulledWatch.stateDirectories()
        // task-owner: one check per launch that ends by itself (each step has its own deadline); it starts
        // from this main-actor call at launch, at background priority, and does its waiting off the main actor.
        Task(priority: WorkPriority.bestEffort.taskPriority) {
            await check.run(canary: {
                switch await host?.installCanary() {
                case nil: nil
                case .passed: .passed
                case .refused(let reason): .refused(reason)
                case .inconclusive(let reason): .inconclusive(reason)
                }
            }, stateDirectories: directories, notify: notify)
        }
    }
}
