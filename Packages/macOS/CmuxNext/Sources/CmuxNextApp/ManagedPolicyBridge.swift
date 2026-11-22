import AppKit
import CmuxNextCloud
import CmuxNextSettings
import CmuxNextUpdater
import Observation

/// Hands managed device keys from the managed policy (the settings
/// controller is the one reader) to their owners: `UpdateChannel` and
/// `MinimumVersion` to the updater (P17-2), `RestrictToManagedTeam` with
/// `ManagedTeam` to Cloud auth (P17-3).
@MainActor
struct ManagedPolicyBridge {
    let settings: SettingsController
    let updater: UpdaterService
    let auth: CloudAuth

    func start() {
        let settings = settings
        // The current values apply now, before Cloud starts; changes follow.
        apply(settings.forcedManagedValuesNow())
        // task-owner: app-lifetime observation of the managed policy; ends with the process
        Task { [weak updater, weak auth] in
            for await policy in Observations({ settings.managedPolicy }) {
                guard updater != nil, auth != nil else { return }
                apply(policy)
            }
        }
        // A required update dismissed with Escape comes back when the app is next activated.
        // task-owner: app-lifetime activation observer; ends with the process
        Task { [weak updater] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                updater?.recheckRequiredUpdate()
            }
        }
    }

    private func apply(_ policy: [String: JSONValue]) {
        updater.applyManagedPolicy(channel: policy["UpdateChannel"]?.stringValue,
                                   minimumVersion: policy["MinimumVersion"]?.stringValue)
        let team = policy["RestrictToManagedTeam"]?.boolValue == true ? policy["ManagedTeam"]?.stringValue : nil
        if auth.managedTeamID != team { auth.managedTeamID = team }
    }
}
