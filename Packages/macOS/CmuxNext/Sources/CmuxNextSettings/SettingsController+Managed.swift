public import CmuxNextWakeups
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
        // A stale read must not roll back a newer version of the same team's policy.
        if !layer.teamID.isEmpty, layer.teamID == teamPolicy.teamID, layer.version < teamPolicy.version { return }
        teamPolicy = layer
        requestReload()
    }

    /// Writes the managed-settings status file after every applied load
    /// whose content changed (osquery, Fleet, Jamf extension attributes,
    /// `cmux mdm status --json`). Call before `start()`. The file is written on `work`'s files lane,
    /// in order, best effort (the file is a convenience for local tooling; the backend report is the record).
    public func writeManagedStatus(to url: URL, context: ManagedStatusReport.Context, work: BackgroundWork) {
        statusTarget = (url, context, OrderedWrites(work: work) { _ in })
        lastStatusBody = nil
    }

    func reportManagedStatus(managed: ManagedPreferences, team: TeamPolicyLayer, effective: EffectiveSettings) {
        guard let target = statusTarget else { return }
        let body = ManagedStatusReport.body(context: target.context, managed: managed, team: team, effective: effective)
        guard body != lastStatusBody else { return }
        lastStatusBody = body
        let document = ManagedStatusReport.document(body: body, writtenAt: Date())
        target.writes.save(Data((document.prettyText() + "\n").utf8), to: target.url)
    }

    /// The managed key a write at `path` would change (the path is the key,
    /// inside it, or an ancestor object of it), or nil. Actions that apply a
    /// value before writing it check this first, so a forced value is never
    /// overridden for the session.
    public func managedKey(forPath path: [String]) -> (key: String, source: ManagedSource)? {
        for (key, source) in managedKeys.sorted(by: { $0.key < $1.key }) {
            let keyPath = CmuxConfigFile.keyPath(from: key)
            if path.starts(with: keyPath) || keyPath.starts(with: path) { return (key, source) }
        }
        return nil
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
