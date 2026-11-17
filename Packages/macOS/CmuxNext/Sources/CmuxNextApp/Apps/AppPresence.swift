import CmuxNextApps

extension AppsService {
    /// The presence of every app now (observed through the client; the rule: `AppPresence`).
    var presence: AppPresence { AppPresence(client.apps) }
}
