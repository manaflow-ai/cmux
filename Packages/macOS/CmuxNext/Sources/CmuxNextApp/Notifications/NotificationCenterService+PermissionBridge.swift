import CmuxNextCompat
import Foundation
import CmuxNextFeedClient

extension NotificationCenterService {
    /// Runs the agent permission feed bridge (cx-aocz) only while
    /// `feed.agentPermissionPrompts` is on: each pending prompt's tool and
    /// command summary then goes to the person's own feed, and the phone gets
    /// a push per prompt. Off (the default) stops it; nothing is posted.
    func followPermissionBridge(_ services: AppServices, principal: FeedInstallPrincipal) -> Task<Void, Never> {
        let feed = services.feed
        return Task { [weak self, weak feed] in
            var changes: UInt64?
            for await on in ObservationStream({ [weak self] in self?.preferences.feedMirror.agentPermissionPrompts ?? false }) {
                guard let self else { return }
                if on, self.permissionBridge == nil, let environment = QuitAgents.environment(services) {
                    let bridge = AcpmuxPermissionFeedBridge(
                        environment: environment,
                        owner: { path, body in try await principal.call(path, body) },
                        isSignedIn: { feed?.isSignedIn ?? false },
                        ownInstall: { await principal.ensureInstallID() },
                        presenceKeys: { try await principal.presenceKeys() })
                    self.permissionBridge = bridge
                    // The owner-confirmed state of the items this launch posted, read when the feed changes them.
                    changes = feed?.daemon.observe { [weak bridge, weak feed] change in
                        guard let bridge, let daemon = feed?.daemon else { return }
                        let mine = bridge.posted.keys.filter(change.touches)
                        guard !mine.isEmpty else { return }
                        // task-owner: one daemon read per feed change of this launch's items; it hands them to the bridge and ends.
                        Task { [weak bridge] in
                            guard let items = try? await daemon.items(Array(mine), confirmed: true) else { return }
                            bridge?.itemsChanged(items)
                        }
                    }
                    bridge.start()
                } else if !on, self.permissionBridge != nil {
                    if let changes { feed?.daemon.unobserve(changes) }
                    changes = nil
                    self.permissionBridge = nil
                }
            }
        }
    }
}
