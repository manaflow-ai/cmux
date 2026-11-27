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

    /// The account whose copy may exist: set when a lease is given, removed
    /// once that daemon confirmed the purge. An off switch found later (the
    /// setting edited while the app was closed, a purge the daemon could not
    /// finish) still deletes the copy.
    nonisolated static let publishedKey = "cmux.cloudReplica.publishedUser.v1"
    /// The daemon (pid) asked to purge for `publishedKey`: its `off` state
    /// then means the purge is done.
    nonisolated static let purgeAskedKey = "cmux.cloudReplica.purgeAskedDaemon.v1"

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

    private func apply(_ want: Want, renew: Bool) async {
        // No daemon: its lease died with it, and the next one starts with none.
        guard let connection = want.connection else { return }
        let client = CloudHostReplicaClient(connection)
        do {
            guard let user = want.userID else {
                // Signed out: no token to purge with; the mark stays for that account's next sign-in.
                _ = try await client.clear(purge: false)
                return
            }
            if want.on {
                if renew { await invalidate() }
                try await lease(client, user: user)
            } else if defaults.string(forKey: Self.publishedKey) == user {
                try await purge(client, user: user, daemon: want.daemon, renew: renew)
            } else {
                _ = try await client.clear(purge: false)
            }
        } catch {
            logger.error("host replica: \(String(describing: error), privacy: .public)")
        }
    }

    /// The off switch with a copy that may exist: lease (a purge needs a
    /// token), then purge. A lease resets a pending purge, so the purge is
    /// asked again after every lease. Never `clear(purge: false)` here: that
    /// would cancel the purge.
    private func purge(_ client: CloudHostReplicaClient, user: String, daemon: Int32?, renew: Bool) async throws {
        let asked = defaults.object(forKey: Self.purgeAskedKey) as? Int
        let state = try await client.status()
        if !renew, let daemon, asked == Int(daemon), state.state == "off", state.purgePending != true {
            // This daemon purged (or the cloud refused the install, and drops a removed host's copy itself).
            defaults.removeObject(forKey: Self.publishedKey)
            defaults.removeObject(forKey: Self.purgeAskedKey)
            return
        }
        if renew { await invalidate() }
        // No lease went (no Cloud origin): a purge without a token cannot run.
        guard try await lease(client, user: user) else { return }
        _ = try await client.clear(purge: true)
        if let daemon { defaults.set(Int(daemon), forKey: Self.purgeAskedKey) }
    }

    /// Gives the daemon this account's install token; false when no lease went.
    @discardableResult
    private func lease(_ client: CloudHostReplicaClient, user: String) async throws -> Bool {
        let (token, expiresAt) = try await installToken()
        guard let origin else { return false }
        // The daemon takes 1-64 Unicode scalars (cloud-host-replica-set).
        let name = await MacName().computerName().trimmingCharacters(in: .whitespacesAndNewlines)
        let hostName = name.isEmpty ? "Mac" : String(String.UnicodeScalarView(name.unicodeScalars.prefix(64)))
        defaults.set(user, forKey: Self.publishedKey)
        defaults.removeObject(forKey: Self.purgeAskedKey)
        _ = try await client.set(CloudHostReplicaSetRequest(apiBaseURL: origin, installToken: token, expiresAt: expiresAt,
                                                            clientVersion: clientVersion, hostName: hostName))
        return true
    }
}
