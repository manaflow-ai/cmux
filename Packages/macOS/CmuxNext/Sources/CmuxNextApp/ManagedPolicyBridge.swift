import AppKit
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWakeups
import Observation

/// Hands managed device keys from the managed policy (the settings
/// controller is the one reader) to their owners: `UpdateChannel` and
/// `MinimumVersion` to the updater (P17-2), `DisableRemoteFeatureFlags` to the
/// updater's flags fetch before it starts, `RestrictToManagedTeam` with
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

    /// The managed keys this bridge hands on; a policy change of other keys applies nothing.
    struct Values: Equatable {
        let channel: String?
        let minimumVersion: String?
        /// `ManagedTeam` while `RestrictToManagedTeam` is on.
        let team: String?
        /// `DisableRemoteFeatureFlags`: the updater's flags fetch reads it at start.
        let flagsFetch: FlagsFetchPolicy

        init(_ policy: [String: JSONValue]) {
            channel = policy["UpdateChannel"]?.stringValue
            minimumVersion = policy["MinimumVersion"]?.stringValue
            team = policy["RestrictToManagedTeam"]?.boolValue == true ? policy["ManagedTeam"]?.stringValue : nil
            flagsFetch = FlagsFetchPolicy(managedPolicy: policy)
        }
    }

    /// Applies the current values now, before Cloud starts, then follows changes. The caller keeps the returned
    /// followers for the app's lifetime.
    func start() -> [AnyObject] {
        let settings = settings
        // Until the first load the launch's forced values are the policy (`managedPolicy` is still empty), so the
        // values applied now are never cleared before the load. `automation`: the device management profile
        // (another process) changes the policy.
        let policy = ServiceObservation(.automation, owner: "ManagedPolicyBridge.policy", on: mainWork) {
            Values(settings.loadCount >= 1 ? settings.managedPolicy : settings.forcedManagedValuesNow())
        } apply: { [weak updater, weak auth] values in
            guard let updater, let auth else { return }
            Self.apply(values, updater: updater, auth: auth)
        }
        // A required update dismissed with Escape comes back when the app is next activated.
        // raw-observer-allow: this is the AppEvents subscription recipe R-notif asks for (the app's one observer); only the notice's name matches
        let activation = appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "ManagedPolicyBridge.requiredUpdate") { [weak updater] in
            updater?.recheckRequiredUpdate()
        }
        return [policy, activation]
    }

    private static func apply(_ values: Values, updater: UpdaterService, auth: CloudAuth) {
        updater.applyManagedPolicy(channel: values.channel, minimumVersion: values.minimumVersion)
        updater.remoteFeatureFlagsPolicy = values.flagsFetch
        if auth.managedTeamID != values.team { auth.managedTeamID = values.team }
    }
}
