import AppKit
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWakeups
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
    /// The app's main-thread scheduler: a policy change applies as one task on it.
    let mainWork: MainWorkScheduler
    /// The app's one observer per app notice (`AppServices.appEvents`).
    let appEvents: AppEvents

    /// Applies the current values now, before Cloud starts, then follows changes. The caller keeps the returned
    /// followers for the app's lifetime.
    func start() -> [AnyObject] {
        let settings = settings
        Self.apply(settings.forcedManagedValuesNow(), updater: updater, auth: auth)
        // `automation`: the device management profile (another process) changes the policy.
        let policy = ServiceObservation(.automation, owner: "ManagedPolicyBridge.policy", on: mainWork) {
            settings.managedPolicy
        } apply: { [weak updater, weak auth] policy in
            guard let updater, let auth else { return }
            Self.apply(policy, updater: updater, auth: auth)
        }
        // A required update dismissed with Escape comes back when the app is next activated.
        // raw-observer-allow: this is the AppEvents subscription recipe R-notif asks for (the app's one observer); only the notice's name matches
        let activation = appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "ManagedPolicyBridge.requiredUpdate") { [weak updater] in
            updater?.recheckRequiredUpdate()
        }
        return [policy, activation]
    }

    private static func apply(_ policy: [String: JSONValue], updater: UpdaterService, auth: CloudAuth) {
        updater.applyManagedPolicy(channel: policy["UpdateChannel"]?.stringValue,
                                   minimumVersion: policy["MinimumVersion"]?.stringValue)
        let team = policy["RestrictToManagedTeam"]?.boolValue == true ? policy["ManagedTeam"]?.stringValue : nil
        if auth.managedTeamID != team { auth.managedTeamID = team }
    }
}
