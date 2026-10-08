import CmuxIrxTransport
import Foundation

/// Exact outgoing Mac intent checked against the per-user account directory.
///
/// The same checks as ``IrxMacPeerAuthorization``, except that the peer must
/// share this Mac's Stack user instead of its team: two Macs of one user that
/// selected different teams hold different team endpoints, and only the
/// account directory names the peer's current one. Local authority still comes
/// from this Mac's own team cache, so a revoked or replaced local device never
/// dials through the account route.
struct IrxAccountMacPeerAuthorization: Sendable {
    /// Indexes one immutable account snapshot for endpoint and installation lookups.
    /// Building it once keeps discovery linear in the number of account rows.
    struct Index: Sendable {
        let byEndpoint: [String: [V2DeviceRecord]]
        let byInstallation: [String: [V2DeviceRecord]]

        init(_ directory: AccountMacDirectory) {
            var endpoints: [String: [V2DeviceRecord]] = [:]
            var installations: [String: [V2DeviceRecord]] = [:]
            for record in directory.macs {
                endpoints[record.descriptor.endpointID.lowercased(), default: []].append(record)
                installations[Self.installationKey(record.descriptor.identity), default: []].append(record)
            }
            byEndpoint = endpoints
            byInstallation = installations
        }

        private static func installationKey(_ identity: V2Identity) -> String {
            identity.deviceID.lowercased() + "\u{0}" + identity.buildTag
        }
    }

    let deviceID: String
    let tag: String
    let endpointID: String

    init(deviceID: String, tag: String, endpointID: String) {
        self.deviceID = deviceID.lowercased()
        self.tag = tag
        self.endpointID = endpointID
    }

    init(_ intent: IrxMacPeerAuthorization) {
        self.init(deviceID: intent.deviceID, tag: intent.tag, endpointID: intent.endpointID)
    }

    /// Resolves from one account snapshot; never from presence hints.
    /// - Parameters:
    ///   - account: The latest account directory and the descriptor that fetched it.
    ///   - cache: This Mac's current team cache (its own record and revocation state).
    ///   - localIdentity: The complete scope that owns the outgoing endpoint.
    ///   - now: A wall time bounded by elapsed monotonic time at the caller.
    /// - Returns: The exact permitted Mac record.
    /// - Throws: ``IrxMacPeerAuthorization/Failure`` for stale, revoked, or mismatched authority.
    func resolve(
        account: AccountMacDirectorySnapshot?,
        cache: V2CachedState,
        localIdentity: V2Identity,
        now: Date,
        index: Index? = nil
    ) throws -> V2DeviceRecord {
        guard cache.formatVersion == 2, cache.identity == localIdentity,
              let own = cache.device, own.descriptor.identity == localIdentity else {
            throw IrxMacPeerAuthorization.Failure.identityMismatch
        }
        guard !cache.authorityRevoked, !own.revoked else { throw IrxMacPeerAuthorization.Failure.revoked }
        guard let account, account.belongs(to: own.descriptor),
              account.directory.userID == localIdentity.userID,
              account.directory.supportsAccountPeers,
              account.isFresh(at: now) else { throw IrxMacPeerAuthorization.Failure.staleDirectory }
        let lookup = index ?? Index(account.directory)
        let matches = lookup.byEndpoint[endpointID.lowercased()] ?? []
        guard !matches.isEmpty else { throw IrxMacPeerAuthorization.Failure.unavailable }
        guard matches.count == 1, let peer = matches.first else { throw IrxMacPeerAuthorization.Failure.identityMismatch }
        // One installation has one account row. Two rows naming the same
        // device and build are ambiguous, and neither is authority.
        let sameInstallation = lookup.byInstallation[Self.installationKey(peer.descriptor.identity)] ?? []
        guard sameInstallation.count == 1 else { throw IrxMacPeerAuthorization.Failure.identityMismatch }
        guard !peer.revoked else { throw IrxMacPeerAuthorization.Failure.revoked }
        let device = peer.descriptor
        let identity = device.identity
        guard device.metadata.platform == .mac,
              identity.deviceID.lowercased() == deviceID, identity.buildTag == tag,
              identity.userID == localIdentity.userID,
              // Same-team Macs belong to the team directory alone, so
              // same-team behavior never depends on the account route.
              identity.teamID != localIdentity.teamID,
              identity.environment == localIdentity.environment, identity.projectID == localIdentity.projectID,
              identity.appNamespace == localIdentity.appNamespace,
              device.endpointID != own.descriptor.endpointID,
              identity.deviceID.lowercased() != localIdentity.deviceID.lowercased() else {
            throw IrxMacPeerAuthorization.Failure.identityMismatch
        }
        guard device.metadata.capabilities.contains("cmux.mac-host.v1") else {
            throw IrxMacPeerAuthorization.Failure.notDiscoverable
        }
        return peer
    }

    private static func installationKey(_ identity: V2Identity) -> String {
        identity.deviceID.lowercased() + "\u{0}" + identity.buildTag
    }
}
