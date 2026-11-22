import CmuxNextDesign
import CmuxNextCompat
import CmuxNextControl

extension AppServices {
    /// Labs > Show Window Shell at Launch (`labs.launchShellFirst`): keeps stage 0's opt-in file
    /// (`LaunchShellPaths.optIn`) matching the setting, so the next launch checks one file instead of
    /// reading the settings. After the first frame; a change applies at the next launch.
    func followLaunchShellOptIn() {
        guard let bundleID = environment.launch.bundleID else { return }
        let support = LaunchTimesFile.supportDirectory(bundleID: bundleID)
        // task-owner: lives as long as the app; event-driven (Observation), one file write per change
        Task { [weak self] in
            for await on in ObservationStream({ [weak self] in self?.settings?.snapshot.launchShellFirst ?? false }) {
                guard self != nil else { return }
                _ = await LaunchShellPaths.setOptedIn(on, support: support)
            }
        }
    }
}
