public import Foundation

extension SettingsController {
    /// Re-reads managed preferences and reloads when they changed. The App
    /// calls it when it becomes active: macOS documents no notification
    /// for a profile change, and the managed files are only wake-up hints.
    public func managedPreferencesMayHaveChanged() {
        requestReload()
    }

    /// Sets the device-scoped values of the managing team's policy (decision
    /// E3: only the device's managing team). Reloads when they changed.
    public func setTeamPolicy(_ layer: TeamPolicyLayer) {
        guard layer != teamPolicy else { return }
        teamPolicy = layer
        requestReload()
    }

    /// Who manages `descriptor`'s key, or nil when the user decides.
    public func managedSource(for descriptor: SettingDescriptor) -> ManagedSource? {
        managedKeys[descriptor.id]
    }

    /// Watches the managed preference files (and their nearest existing
    /// ancestor directories while they do not exist) with kernel file events.
    func startManagedWatchers() {
        guard managedWatchers.isEmpty else { return }
        managedWatchers = managedWatchFiles.map { url in
            ConfigFileWatcher(url: url) { [weak self] in
                Task { @MainActor in self?.requestReload() }
            }
        }
        managedWatchers.forEach { $0.start() }
    }

    func stopManagedWatchers() {
        managedWatchers.forEach { $0.stop() }
        managedWatchers = []
    }
}
