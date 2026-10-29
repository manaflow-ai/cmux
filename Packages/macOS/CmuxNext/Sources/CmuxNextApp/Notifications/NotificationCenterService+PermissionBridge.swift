import CmuxNextWakeups
import Foundation

extension NotificationCenterService {
    /// Runs the agent permission feed bridge (cx-aocz) only while
    /// `feed.agentPermissionPrompts` is on: each pending prompt's tool and
    /// command summary then goes to the person's own feed, and the phone gets
    /// a push per prompt. Off (the default) stops it; nothing is posted. A
    /// setting nobody watches change on screen: the background class.
    func followPermissionBridge(_ services: AppServices, principal: FeedInstallPrincipal) -> AnyObject {
        let feed = services.feed
        return ServiceObservation(.background, owner: "notifications.permission-bridge", on: work) { [weak self] in
            self?.preferences.feedMirror.agentPermissionPrompts ?? false
        } apply: { [weak self, weak feed, weak services] on in
            guard let self, let services else { return }
            if on, self.permissionBridge == nil, let environment = QuitAgents.environment(services) {
                let bridge = AcpmuxPermissionFeedBridge(
                    environment: environment,
                    owner: { path, body in try await principal.call(path, body) },
                    isSignedIn: { feed?.isSignedIn ?? false },
                    ownInstall: { await principal.ensureInstallID() },
                    presenceKeys: { try await principal.presenceKeys() },
                    work: services.work, deadlines: services.mainDeadlines)
                self.permissionBridge = bridge
                feed?.onConfirmedItems = { [weak bridge] items in bridge?.itemsChanged(items) }
                bridge.start()
            } else if !on, self.permissionBridge != nil {
                feed?.onConfirmedItems = nil
                self.permissionBridge = nil
            }
        }
    }
}
