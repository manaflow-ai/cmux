import CmuxHomeCore
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// The cloud half of Home (home-cloud-proxy.md): the daemon proxies the
/// cloud owners, the app leases the signed-in account's token to it, and
/// `cloudSource` reads and writes through that proxy only.
extension HomeService {
    /// Follows the local daemon's connection and the signed-in account:
    /// each change re-leases the token and reconfigures the cloud source.
    func startCloud() {
        let local = services.machines.local
        let auth = services.cloud.auth
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let lease = HomeCloudLease(tokens: auth, apiBaseURL: services.feed.apiBaseURL, clientVersion: version, logger: logger)
        let linker = HomeCloudLink(lease: lease, source: cloudSource, localID: homeSource.me.id,
                                   stackProjectID: auth.configuration.stackProjectID)
        cloudLinker = linker
        let cloudInbox = homeCloudInbox
        // task-owner: lives as long as the service; event-driven (Observation)
        cloudLink = Task {
            // A trigger: a daemon restart on the same connection refreshes the inbox again.
            for await link in ObservationStream({ () -> ObservationTrigger<HomeCloudLink.Link> in
                let connection = local.supports(DaemonCapabilities.shared.cloudConversations) ? local.connection : nil
                return ObservationTrigger(HomeCloudLink.Link(endpoint: connection.map(CloudConversationClient.init),
                                                             id: connection.map(ObjectIdentifier.init),
                                                             userID: auth.isSignedIn ? auth.user?.id : nil,
                                                             displayName: auth.user?.displayName ?? auth.user?.primaryEmail ?? ""))
            }) {
                await linker.apply(link.value)
                cloudInbox.connectionChanged(local.supports(DaemonCapabilities.shared.cloudConversations) ? local.connection : nil)
            }
        }
    }

    func handleCloud(_ event: CloudConversationsEvent) {
        if case .sessionNeeded(let needed) = event {
            cloudLinker?.sessionNeeded(reason: needed.reason, expiresAt: needed.expiresAt)
            return
        }
        if case .hostReplicaNeeded(let needed) = event { return services.cloud.hostReplica.needed(needed) }
        cloudSource.handle(event)
    }
}
