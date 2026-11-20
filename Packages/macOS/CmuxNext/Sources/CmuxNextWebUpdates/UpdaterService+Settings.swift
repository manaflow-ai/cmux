public import CmuxNextSettings
public import CmuxNextUpdater

extension UpdaterService {
    public func configureUpdates(_ updates: UpdatesSettings) {
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
}
