import CmuxNextCompat
public import CmuxNextSettings
public import Foundation

extension JoinConsentModel {
    /// Follows the Labs switch (a change drops what was read at once and reads again; turning it on stops
    /// a Mac Screen session until a read allows it) and, while it is on, acpmux's machine consent folder
    /// (``MachineConsentChanges``), where a join, a consent change or a refusal lands: each burst of
    /// changes there is one `machine_consent_get`, never a read of the files. Event-driven, never a poll.
    /// A change is taken at once, never behind a read still running. Everything ends with the model
    /// (``JoinConsentModel/following``), and the folder watch also when the switch turns off.
    public func follow(settings: SettingsController, folder: URL?) {
        Self.invalidateGrants(grantGate, onEveryLoadOf: settings)
        // task-owner: the model's `following`, cancelled with it; one read per Labs change or folder burst
        following = Task { [weak self, weak settings] in
            var watch: Task<Void, Never>?
            var reading: Task<Void, Never>?
            defer {
                watch?.cancel()
                reading?.cancel()
            }
            var last: Bool?
            guard let settings else { return }
            for await on in ObservationStream({ settings.snapshot.machineJoin }) {
                guard let self, !Task.isCancelled else { return }
                watch?.cancel()
                watch = nil
                if let last, last != on {
                    featureSwitched()
                    reading?.cancel()
                    reading = Task { [weak self] in await self?.refresh() }
                }
                last = on
                guard on, let folder else { continue }
                watch = Task { [weak self] in
                    for await _ in await MachineConsentChanges(folder: folder).events() {
                        guard let self, !Task.isCancelled else { return }
                        await refresh()
                    }
                }
            }
        }
    }

    /// SECURITY: every settings load (the Labs switch moves only through one) invalidates the grant gate as
    /// it happens, in the load itself (``SettingsController/onEveryLoad(_:)``, on the main actor, before the
    /// load changes anything), never behind a task: a grant the line checks on its own queue right after a
    /// load is already stale. Every load, so a second load right after is caught too. Ends with the settings.
    public static func invalidateGrants(_ gate: JoinConsentGrantGate, onEveryLoadOf settings: SettingsController) {
        settings.onEveryLoad { gate.invalidate() }
    }
}
