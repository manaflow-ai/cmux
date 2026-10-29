import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

extension SettingsController {
    /// Re-reads managed preferences and reloads when they changed. The App
    /// calls it when it becomes active: macOS documents no notification
    /// for a profile change, and the managed files are only wake-up hints.
    public func managedPreferencesMayHaveChanged() {
        requestReload()
    }

    /// Calls ``managedPreferencesMayHaveChanged()`` on each app activation, through the app's one
    /// activation observer on `events` (the event-driven backstop next to the managed-file watchers).
    /// The app follows after the first frame: the launch read and the watchers' first reload cover the launch.
    public func followActivation(on events: AppEvents) {
        activation = events.subscribeToActivation(owner: "Settings.managedActivation") { [weak self] in
            self?.managedPreferencesMayHaveChanged()
        }
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
    /// `cmux mdm status --json`). Call before `start()`.
    ///
    /// - Parameters:
    ///   - url: The status file.
    ///   - context: The app's version and bundle ID in the report.
    ///   - post: Runs each file write off the main thread, in order: the app posts it as an afterStartup task on a
    ///     files-lane sequence (nobody waits for the file at launch); tests record it. Never a pool thread.
    public func writeManagedStatus(to url: URL, context: ManagedStatusReport.Context,
                                   post: @escaping @MainActor (_ write: @escaping @Sendable () -> Void) -> Void) {
        statusTarget = ManagedStatusTarget(url: url, context: context, post: post)
        lastStatusBody = nil
    }

    /// Where the managed-settings status file goes and how its write runs (``writeManagedStatus(to:context:post:)``).
    struct ManagedStatusTarget {
        let url: URL
        let context: ManagedStatusReport.Context
        let post: @MainActor (_ write: @escaping @Sendable () -> Void) -> Void
    }

    func reportManagedStatus(managed: ManagedPreferences, team: TeamPolicyLayer, effective: EffectiveSettings) {
        guard let target = statusTarget else { return }
        let body = ManagedStatusReport.body(context: target.context, managed: managed, team: team, effective: effective)
        guard body != lastStatusBody else { return }
        lastStatusBody = body
        let document = ManagedStatusReport.document(body: body, writtenAt: Date())
        let data = Data((document.prettyText() + "\n").utf8), url = target.url
        target.post {
            // Best effort: the file is a convenience for local tooling; the backend report is the record.
            try? FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.blockingWrite(to: url, options: .atomic)
        }
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
    /// ancestor directories while they do not exist) with kernel file events; each event asks for a
    /// reload in one `visible` task on ``mainWork``.
    func startManagedWatchers() {
        guard managedWatchers.isEmpty else { return }
        let mainWork = mainWork
        managedWatchers = managedWatchFiles.map { url in
            ConfigFileWatcher(url: url) { [weak self] in
                mainWork.postFromAnyThread(.visible, owner: "Settings.managedFileChanged") { [weak self] in self?.requestReload() }
            }
        }
        managedWatchers.forEach { $0.startWithoutWaiting() }
    }

    func stopManagedWatchers() {
        managedWatchers.forEach { $0.stop() }
        managedWatchers = []
    }
}
