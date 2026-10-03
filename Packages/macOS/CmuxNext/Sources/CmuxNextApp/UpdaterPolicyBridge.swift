import AppKit
import CmuxNextSettings
import CmuxNextUpdater
import Observation

/// Hands `UpdateChannel` and `MinimumVersion` from the managed policy (the
/// settings controller is the one reader) to the updater (P17-2).
@MainActor
struct UpdaterPolicyBridge {
    let settings: SettingsController
    let updater: UpdaterService

    func start() {
        let settings = settings
        // task-owner: app-lifetime observation of the managed policy; ends with the process
        Task { [weak updater] in
            for await policy in Observations({ settings.managedPolicy }) {
                guard let updater else { return }
                updater.applyManagedPolicy(channel: policy["UpdateChannel"]?.stringValue,
                                           minimumVersion: policy["MinimumVersion"]?.stringValue)
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
}
