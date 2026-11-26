import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextSettings
public import Foundation
import os

/// Applies Settings > Accounts > Phone Access > `phone.cloudReplica`
/// (plans/cmux-next/object-sync/DESIGN.md phase 3): while it is on, the
/// account is signed in, Cloud is allowed and the local daemon serves
/// `cloud-host-replica-v1`, the app leases this Mac's install token to the
/// daemon, which publishes the narrow workspace list. Turning it off deletes
/// the cloud copy (`cloud-host-replica-clear` with `purge`); sign-out drops
/// the lease. The daemon asks for a new token with
/// `cloud-host-replica-needed`.
///
/// Lease work runs one at a time, in the order it was asked for, so an
/// older lease never lands after a newer one. The App supplies the install
/// token (with its expiry), the Cloud origin and the account that may publish.
@MainActor
public final class CloudHostReplicaFollower {
    /// One install token and when it expires (Unix ms).
    public typealias InstallToken = @Sendable () async throws -> (token: String, expiresAt: UInt64)

    nonisolated struct Want: Equatable, Sendable {
        var connection: DaemonConnection?
        /// The daemon process behind the connection: a restart on the same
        /// connection starts with no lease, so it is a new want.
        var daemon: Int32?
        var userID: String?
        var on: Bool

        nonisolated static func == (lhs: Want, rhs: Want) -> Bool {
            lhs.connection === rhs.connection && lhs.daemon == rhs.daemon && lhs.userID == rhs.userID && lhs.on == rhs.on
        }
    }

    /// The defaults keys (`cmux-phone-core`'s `replica_keys`): the account whose copy may exist (set when a lease is
    /// given, removed once that daemon confirmed the purge), and the daemon (pid) asked to purge for it, whose `off`
    /// state then means the purge is done. An off switch found later still deletes the copy.
    nonisolated static let keys = ReplicaRules.ask(ReplicaRules.Keys.self, "replica_keys")

    private let installToken: InstallToken
    private let invalidate: @Sendable () async -> Void
    private let origin: String?
    private let clientVersion: String?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud.replica")
    private var observation: Task<Void, Never>?
    private var want = Want(connection: nil, daemon: nil, userID: nil, on: false)
    /// The newest lease work; the next waits for it.
    private var work: Task<Void, Never>?

    /// `origin`: the Cloud API origin (`scheme://host[:port]`), nil when it has none.
    public init(origin: String?, clientVersion: String?, defaults: UserDefaults = .standard,
                installToken: @escaping InstallToken, invalidate: @escaping @Sendable () async -> Void) {
        self.origin = origin
        self.clientVersion = clientVersion
        self.defaults = defaults
        self.installToken = installToken
        self.invalidate = invalidate
    }

    /// Follows the setting, the account and the local daemon connection.
    /// `account`: the signed-in user's id while Cloud may be called, else nil.
    public func follow(_ settings: SettingsController, local: DaemonService, account: @escaping @MainActor () -> String?) {
        observation?.cancel()
        // task-owner: lives as long as the settings controller; event-driven (Observation)
        observation = Task { [weak self] in
            await settings.waitForLoad(atLeast: 1)
            for await next in ObservationStream({ () -> Want in
                let supported = local.supports(DaemonCapability.cloudHostReplica.rawValue)
                return Want(connection: supported ? local.connection : nil, daemon: supported ? local.identity?.pid : nil,
                            userID: account(), on: settings.snapshot.sessions.publishesCloudReplica)
            }) {
                guard let self else { return }
                self.want = next
                self.enqueue(renew: false)
            }
        }
    }

    /// The install was registered (sign-in finished): a lease that failed
    /// for want of it can go now.
    public func installReady() {
        enqueue(renew: false)
    }

    /// `cloud-host-replica-needed`: the token expires soon or the cloud
    /// refused it. A purge in flight needs the new token too.
    public func needed(_ needed: CloudHostReplicaNeeded) {
        logger.info("host replica asks for a token: \(needed.reason, privacy: .public)")
        enqueue(renew: true)
    }

    private func enqueue(renew: Bool) {
        let prior = work
        let want = want
        // task-owner: one token read and one cloud-host-replica-set or -clear, after the previous work; ends with the reply
        work = Task { [weak self] in
            _ = await prior?.value
            await self?.apply(want, renew: renew)
        }
    }

    /// One piece of lease work; `cmux-phone-core`'s `replica_apply`, `replica_purge` and `replica_lease` decide each step.
    private func apply(_ want: Want, renew: Bool) async {
        guard let connection = want.connection, let keys = Self.keys else { return }
        var wanted: [String: Any] = ["connected": true, "on": want.on]
        if let user = want.userID { wanted["user_id"] = user }
        var fields: [String: Any] = ["want": wanted, "renew": renew]
        if let published = defaults.string(forKey: keys.published) { fields["published_user"] = published }
        guard let step = ReplicaRules.ask(ReplicaRules.Step.self, "replica_apply", fields) else {
            logger.error("host replica: no rule answer")
            return
        }
        let client = CloudHostReplicaClient(connection)
        do {
            switch step.action {
            case "clear": _ = try await client.clear(purge: false)
            case "lease":
                if step.invalidate == true { await invalidate() }
                if let user = want.userID { try await lease(client, user: user, keys: keys) }
            case "status":
                if let user = want.userID { try await purge(client, user: user, daemon: want.daemon, renew: renew, keys: keys) }
            default: return
            }
        } catch {
            logger.error("host replica: \(String(describing: error), privacy: .public)")
        }
    }

    /// The off switch with a copy that may exist: the status read, then `replica_purge` says forget, or lease (a
    /// purge needs a token) then purge.
    private func purge(_ client: CloudHostReplicaClient, user: String, daemon: Int32?, renew: Bool, keys: ReplicaRules.Keys) async throws {
        let state = try await client.status()
        var status: [String: Any] = ["state": state.state]
        if let pending = state.purgePending { status["purge_pending"] = pending }
        var fields: [String: Any] = ["renew": renew, "status": status]
        if let daemon { fields["daemon"] = Int64(daemon) }
        if let asked = defaults.object(forKey: keys.purgeAsked) as? Int { fields["purge_asked"] = Int64(asked) }
        guard let step = ReplicaRules.ask(ReplicaRules.Step.self, "replica_purge", fields) else { return }
        if step.action == "forget" {
            defaults.removeObject(forKey: keys.published)
            defaults.removeObject(forKey: keys.purgeAsked)
            return
        }
        if step.invalidate == true { await invalidate() }
        guard try await lease(client, user: user, keys: keys) else { return }
        _ = try await client.clear(purge: true)
        if let mark = step.markPurgeAsked { defaults.set(Int(mark), forKey: keys.purgeAsked) }
    }

    /// Gives the daemon this account's install token; false when no lease went (`replica_lease` found no Cloud origin).
    @discardableResult
    private func lease(_ client: CloudHostReplicaClient, user: String, keys: ReplicaRules.Keys) async throws -> Bool {
        let (token, expiresAt) = try await installToken()
        var fields: [String: Any] = ["token": token, "expires_at": expiresAt, "computer_name": await MacName().computerName()]
        if let origin { fields["origin"] = origin }
        if let clientVersion { fields["client_version"] = clientVersion }
        guard let lease = ReplicaRules.ask(ReplicaRules.Lease.self, "replica_lease", fields)?.lease else { return false }
        defaults.set(user, forKey: keys.published)
        defaults.removeObject(forKey: keys.purgeAsked)
        _ = try await client.set(CloudHostReplicaSetRequest(apiBaseURL: lease.apiBaseURL, installToken: lease.installToken,
                                                            expiresAt: lease.expiresAt, clientVersion: lease.clientVersion,
                                                            hostName: lease.hostName))
        return true
    }
}
