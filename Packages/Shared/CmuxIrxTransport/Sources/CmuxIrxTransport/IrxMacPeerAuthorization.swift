public import Foundation

/// Exact Mac intent checked against the current v2 account and directory lease.
public struct IrxMacPeerAuthorization: Sendable {
    /// The missing or invalid permission that prevented a Mac connection.
    public enum Failure: Error, Equatable, Sendable {
        /// No current directory record matches the selected endpoint.
        case unavailable
        /// The exact authenticated Mac has not opted into Mac-to-Mac hosting.
        case notDiscoverable
        /// The complete directory is missing or expired.
        case staleDirectory
        /// The local authority or selected device was revoked.
        case revoked
        /// The endpoint, device, build, or account differs from the intended peer.
        case identityMismatch
    }

    /// The selected Mac installation identifier.
    public let deviceID: String
    /// The selected build tag.
    public let tag: String
    /// The selected QUIC peer key.
    public let endpointID: String

    /// Captures a selection without granting it any permission.
    public init(deviceID: String, tag: String, endpointID: String) {
        self.deviceID = deviceID.lowercased()
        self.tag = tag
        self.endpointID = endpointID
    }

    /// Resolves from one complete v2 permission snapshot; never from presence hints.
    /// - Parameters:
    ///   - cache: Current v2 control-service state.
    ///   - localIdentity: The complete scope that owns the outgoing endpoint.
    ///   - now: A wall time bounded by elapsed monotonic time at the caller.
    /// - Returns: The exact permitted, enabled Mac record.
    /// - Throws: ``Failure`` for stale, revoked, or mismatched authority.
    public func resolve(cache: V2CachedState, localIdentity: V2Identity, now: Date) throws -> V2DeviceRecord {
        guard cache.formatVersion == 2, cache.identity == localIdentity,
              let own = cache.device, own.descriptor.identity == localIdentity else { throw Failure.identityMismatch }
        guard !cache.authorityRevoked, !own.revoked else { throw Failure.revoked }
        guard let directory = cache.directory, directory.nextCursor == nil,
              directory.teamID == localIdentity.teamID,
              now.timeIntervalSince1970 >= Double(directory.issuedAt),
              now.timeIntervalSince1970 < Double(directory.permissionExpiresAt) else { throw Failure.staleDirectory }
        let matches = directory.devices.filter { $0.descriptor.endpointID == endpointID }
        guard !matches.isEmpty else { throw Failure.unavailable }
        guard matches.count == 1, let peer = matches.first else { throw Failure.identityMismatch }
        guard !peer.revoked else { throw Failure.revoked }
        let device = peer.descriptor
        let identity = device.identity
        guard device.metadata.platform == .mac,
              identity.deviceID.lowercased() == deviceID, identity.buildTag == tag,
              identity.userID == localIdentity.userID, identity.teamID == localIdentity.teamID,
              identity.environment == localIdentity.environment, identity.projectID == localIdentity.projectID,
              identity.appNamespace == localIdentity.appNamespace,
              device.endpointID != own.descriptor.endpointID,
              identity.deviceID.lowercased() != localIdentity.deviceID.lowercased(),
              peer.revision <= directory.revision else { throw Failure.identityMismatch }
        guard device.metadata.capabilities.contains("cmux.mac-host.v1") else {
            throw Failure.notDiscoverable
        }
        return peer
    }
}
