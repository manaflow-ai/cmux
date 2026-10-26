import CmuxNextCompat
import CmuxNextEnergy
import CmuxNextSettings
import CmuxNextWakeups

extension AppServices {
    /// Follows `energy.saver` into ``energyDriver`` once the settings have loaded, so the first policy
    /// it publishes already follows the setting. `AppDelegate` calls it at launch; a second call does nothing.
    func followEnergySaver(_ settings: SettingsController) {
        guard energySaverObservation == nil else { return }
        // task-owner: app lifetime; event-driven (Observation)
        energySaverObservation = Task { [weak self] in
            await settings.waitForLoad(atLeast: 1)
            for await mode in ObservationStream({ settings.snapshot.energySaver }) {
                self?.energyDriver.update(setting: mode)
            }
        }
    }
}
