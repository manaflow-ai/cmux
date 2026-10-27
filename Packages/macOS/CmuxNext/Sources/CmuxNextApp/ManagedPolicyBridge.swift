import AppKit
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWakeups
import Observation

extension AppServices {
    /// The launch's managed policy (p08-startup-101, plans/cmux-next/startup-DESIGN.md critical rows 4 to 6): the
    /// prefetched forced values (`SettingsController.managedPolicyInEffect`) apply in three critical steps, each at
    /// once in the caller's turn, before any feature starts and before any page engine makes a page, as Chrome's
    /// platform policy provider has loaded before the first profile and its tabs exist
    /// (chrome/browser/policy/chrome_browser_policy_connector.cc, `ChromeBrowserPolicyConnector`). Only the status
    /// write (`Settings.writeManagedStatus`, after startup) and the watchers (`Settings.followActivation` after the
    /// first frame, the profile file watchers armed off main by `SettingsController.start`) wait. The followers live
    /// as long as these services.
    func applyManagedPolicyAtLaunch(_ settings: SettingsController, on startup: StartupScheduler) {
        // `DisabledFeatures` on the registry: no action of a disabled feature is offered or runs.
        startup.post(.critical, "Settings.applyManagedFeaturesNow", on: .main) { settings.applyManagedFeaturesNow() }
        // The updater, Cloud auth and the WebKit URL filter; Chromium reads Chrome's policy domain at its own start.
        startup.post(.critical, "ManagedPolicyBridge.start", on: .main) { [self] in
            lifetimeFollowers += ManagedPolicyBridge(settings: settings, updater: updater, auth: cloudAuth, mainWork: mainWork,
                                                     appEvents: appEvents).start()
            lifetimeFollowers += BrowserManagedPolicyPreference.follow(settings, webKit: cache.webKit, chromium: cache.chromium, on: mainWork)
        }
        // The owning services refuse a disabled feature before Cloud, SSH, the server reach or apps start.
        startup.post(.critical, "FeaturePolicyEnforcer.start", on: .main) { [self] in
            lifetimeFollowers.append(FeaturePolicyEnforcer(services: self).start())
        }
    }
}

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
        // Until the first load the launch's forced values are the policy (`managedPolicyInEffect`), so the values
        // applied now are never cleared before the load. `automation`: the device management profile (another
        // process) changes the policy.
        let policy = ServiceObservation(.automation, owner: "ManagedPolicyBridge.policy", on: mainWork) {
            ManagedDeviceValues(settings.managedPolicyInEffect)  // the keys this bridge hands on: others apply nothing
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

    private static func apply(_ values: ManagedDeviceValues, updater: UpdaterService, auth: CloudAuth) {
        updater.applyManagedPolicy(channel: values.channel, minimumVersion: values.minimumVersion)
        if auth.managedTeamID != values.team { auth.managedTeamID = values.team }
    }
}
