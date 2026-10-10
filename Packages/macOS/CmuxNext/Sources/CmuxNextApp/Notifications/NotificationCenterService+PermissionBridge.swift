import CmuxNextCompat
import Foundation

extension NotificationCenterService {
    /// Runs the agent permission feed bridge (cx-aocz) only while
    /// `feed.agentPermissionPrompts` is on: each pending prompt's tool and
    /// command summary then goes to the person's own feed, and the phone gets
    /// a push per prompt. Off (the default) stops it; nothing is posted.
    func followPermissionBridge(_ services: AppServices, principal: FeedInstallPrincipal) -> Task<Void, Never> {
        let feed = services.feed
        return Task { [weak self, weak feed] in
            for await on in ObservationStream({ [weak self] in self?.preferences.feedMirror.agentPermissionPrompts ?? false }) {
                guard let self else { return }
                if on, self.permissionBridge == nil, let socket = QuitAgents.environment(services)?.socketPath {
                    let bridge = AcpmuxPermissionFeedBridge(
                        socketPath: socket,
                        owner: { path, body in try await principal.call(path, body) },
                        isSignedIn: { feed?.isSignedIn ?? false },
                        ownInstall: { await principal.installID },
                        presenceKeys: { try await principal.presenceKeys() })
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
}
