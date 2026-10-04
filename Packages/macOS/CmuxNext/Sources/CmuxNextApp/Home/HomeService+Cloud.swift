import CmuxHomeCore
import CmuxNextDaemon
import Foundation

/// The cloud half of Home (home-cloud-proxy.md): the daemon proxies the
/// cloud owners, the app leases the signed-in account's token to it, and
/// `cloudSource` reads and writes through that proxy only.
extension HomeService {
    /// The daemon connection with the cloud transport and the account it serves.
    nonisolated struct CloudLink: Equatable, Sendable {
        var connection: DaemonConnection?
        var userID: String?
        var displayName: String

        static func == (lhs: CloudLink, rhs: CloudLink) -> Bool {
            lhs.connection.map(ObjectIdentifier.init) == rhs.connection.map(ObjectIdentifier.init)
                && lhs.userID == rhs.userID && lhs.displayName == rhs.displayName
        }
    }

    /// Follows the local daemon's connection and the signed-in account:
    /// each change re-leases the token and reconfigures the cloud source.
    func startCloud() {
        let local = services.machines.local
        let auth = services.cloud.auth
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let lease = HomeCloudLease(auth: auth, apiBaseURL: services.feed.apiBaseURL, clientVersion: version, logger: logger)
        cloudLease = lease
        // task-owner: lives as long as the service; event-driven (Observation)
        cloudLink = Task { [weak self] in
            var last: CloudLink?
            for await link in Observations({
                CloudLink(connection: local.supports(DaemonCapabilities.shared.cloudConversations) ? local.connection : nil,
                          userID: auth.isSignedIn ? auth.user?.id : nil,
                          displayName: auth.user?.displayName ?? auth.user?.primaryEmail ?? "")
            }) {
                guard let self, link != last else { continue }
                last = link
                if let connection = link.connection { await lease.sync(connection) }
                let identity = link.userID.map {
                    CloudIdentity(stackUserID: $0, displayName: link.displayName, localID: homeSource.me.id)
                }
                cloudSource.configure(commands: link.connection.map(CloudConversationClient.init),
                                      link: link.connection.map(ObjectIdentifier.init), identity: identity)
            }
        }
    }

    func handleCloud(_ event: CloudConversationsEvent) {
        if case .sessionNeeded(let needed) = event {
            guard let connection = services.machines.local.connection else { return }
            cloudLease?.renew(connection, reason: needed.reason)
            return
        }
        cloudSource.handle(event)
    }
}
