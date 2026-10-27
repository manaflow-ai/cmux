import CmuxHomeCore
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextSettings
import Foundation

/// The cloud half of Home (home-cloud-proxy.md): the daemon proxies the
/// cloud owners, the app leases the signed-in account's token to it, and
/// `cloudSource` reads and writes through that proxy only.
extension HomeService {
    /// Follows the local daemon's connection, the signed-in account and
    /// `home.server`: each change re-leases (the Stack token for cmux Cloud,
    /// no token for a self-hosted server) and reconfigures the cloud source.
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
        // Read inside the observation, so a cmux.json edit re-leases.
        let homeServer = { [weak appServices = services] in appServices?.settings?.snapshot.homeServer }
        // task-owner: lives as long as the service; event-driven (Observation)
        cloudLink = Task {
            // A trigger: a daemon restart on the same connection refreshes the inbox again.
            for await link in ObservationStream({ () -> ObservationTrigger<HomeCloudLink.Link> in
                let connection = local.supports(DaemonCapability.cloudConversations.rawValue) ? local.connection : nil
                return ObservationTrigger(HomeCloudLink.Link(endpoint: connection.map(CloudConversationClient.init),
                                                             id: connection.map(ObjectIdentifier.init),
                                                             userID: auth.isSignedIn ? auth.user?.id : nil,
                                                             displayName: auth.user?.displayName ?? auth.user?.primaryEmail ?? "",
                                                             server: Self.cloudServer(homeServer())))
            }) {
                await linker.apply(link.value)
                cloudInbox.connectionChanged(local.supports(DaemonCapability.cloudConversations.rawValue) ? local.connection : nil)
            }
        }
    }

    /// `home.server` as the Cloud link's server: cmux Cloud unless a self-hosted origin is set.
    nonisolated static func cloudServer(_ setting: HomeServerSetting.Value?) -> HomeCloudServer {
        if case .selfHosted(let url)? = setting { return .selfHosted(url) }
        return .hosted
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
