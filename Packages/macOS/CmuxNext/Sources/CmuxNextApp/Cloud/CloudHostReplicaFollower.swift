import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHomeEngine
import CmuxNextSettings
import Foundation
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
/// older lease never lands after a newer one.
@MainActor
final class CloudHostReplicaFollower {
    struct Want: Equatable {
        var connection: DaemonConnection?
        var userID: String?
        var on: Bool

        static func == (lhs: Want, rhs: Want) -> Bool {
            lhs.connection === rhs.connection && lhs.userID == rhs.userID && lhs.on == rhs.on
        }
    }

    /// Set once a lease was given and no purge was asked since: an off
    /// switch found at launch (cmux.json edited while the app was closed)
    /// still deletes the copy.
    nonisolated static let publishedKey = "cmux.cloudReplica.published.v1"

    private let identity: MacInstallIdentity
    private let apiBaseURL: URL
    private let clientVersion: String?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud.replica")
    private var observation: Task<Void, Never>?
    private var want = Want(connection: nil, userID: nil, on: false)
    /// The newest lease work; the next waits for it.
    private var work: Task<Void, Never>?

    init(identity: MacInstallIdentity, apiBaseURL: URL, clientVersion: String?, defaults: UserDefaults = .standard) {
        self.identity = identity
        self.apiBaseURL = apiBaseURL
        self.clientVersion = clientVersion
        self.defaults = defaults
    }

    /// Follows the setting, the account and the local daemon connection.
    func follow(_ settings: SettingsController, cloud: CloudService, local: DaemonService) {
        observation?.cancel()
        // task-owner: lives as long as the settings controller; event-driven (Observation)
        observation = Task { [weak self] in
            await settings.waitForLoad(atLeast: 1)
            for await next in ObservationStream({ () -> Want in
                let connection = local.supports(DaemonCapabilities.shared.cloudHostReplica) ? local.connection : nil
                let allowed = cloud.auth.isSignedIn && cloud.mayCallCloud && !cloud.policyDisabled
                return Want(connection: connection, userID: allowed ? cloud.auth.user?.id : nil,
                            on: settings.snapshot.sessions.publishesCloudReplica)
            }) {
                guard let self else { return }
                self.want = next
                self.enqueue(renew: false)
            }
        }
    }

    /// The install was registered (sign-in finished): a lease that failed
    /// for want of it can go now.
    func installReady() {
        enqueue(renew: false)
    }

    /// `cloud-host-replica-needed`: the token expires soon or the cloud refused it.
    func needed(_ needed: CloudHostReplicaNeeded) {
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
            guard want.userID != nil else {
                _ = try await client.clear(purge: false)
                return
            }
            if want.on {
                if renew { await identity.invalidate() }
                try await lease(client)
            } else if defaults.bool(forKey: Self.publishedKey) {
                // The copy may exist: purge needs a lease, then the lease goes when the cloud confirms.
                let state = try await client.status()
                if state.state == "off" { try await lease(client) }
                _ = try await client.clear(purge: true)
                defaults.set(false, forKey: Self.publishedKey)
            } else {
                _ = try await client.clear(purge: false)
            }
        } catch {
            logger.error("host replica: \(String(describing: error), privacy: .public)")
        }
    }

    private func lease(_ client: CloudHostReplicaClient) async throws {
        let token = try await identity.installToken()
        guard let origin = HomeCloudLease.origin(apiBaseURL) else { return }
        let expiresAt = HomeCloudLease.expiry(ofJWT: token) ?? HomeCloudLease.fallbackExpiry(now: Date())
        let hostName = await MacName().computerName()
        defaults.set(true, forKey: Self.publishedKey)
        _ = try await client.set(CloudHostReplicaSetRequest(apiBaseURL: origin, installToken: token, expiresAt: expiresAt,
                                                            clientVersion: clientVersion, hostName: hostName))
    }
}
