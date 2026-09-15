public import Foundation
import os

/// Synchronous inbound authority for one enrolled Mac tuple, key and generation.
/// The current directory is swapped under one lock; admission never waits for networking.
public final class V2InboundAdmissionAuthority: Sendable {
    private struct Entry: Sendable {
        let peer: IrxAdmittedPeerInfo
        let deadline: ContinuousClock.Instant
    }
    private struct State: Sendable {
        var invalidated = false
        var restored = false
        var liveLoaded = false
        var localRecordID: String?
        var sequence: UInt64?
        var revision = -1
        var issuedAt = -1
        var sourcePeers: [V2InboundPeerPermission]?
        var sourceExpiry: Int?
        var entries: [String: Entry] = [:]
        var revokedRecords = Set<String>()
        var revokedEndpoints = Set<String>()
    }

    private let host: V2DeviceDescriptor
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wallNow: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let initialWall: Date
    private let initialMonotonic: ContinuousClock.Instant

    /// Creates an authority that can never be reused for another Mac identity.
    /// - Parameters:
    ///   - host: Raw v2 Mac descriptor, including the bundle namespace without a UI prefix.
    ///   - wallNow: Wall time used when mapping server timestamps to local deadlines.
    ///   - monotonicNow: Clock used for every authorization and expiration check.
    /// - Throws: A scope error if this is not an enabled Mac identity.
    public init(host: V2DeviceDescriptor,
                wallNow: @escaping @Sendable () -> Date = { Date() },
                monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        guard host.metadata.platform == .mac, host.metadata.pairingEnabled,
              Self.validKey(host.endpointID), host.identityGeneration >= 0 else {
            throw V2ControlFailure.scopeMismatch
        }
        self.host = host
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
        initialWall = wallNow()
        initialMonotonic = monotonicNow()
    }

    /// Installs a v2 disk cache once, before observing any control-service snapshot.
    /// - Parameter cache: The cache for this exact Mac tuple.
    /// - Returns: Whether authority changed and existing sessions should be rechecked.
    @discardableResult
    public func restore(_ cache: V2CachedState) -> Bool {
        state.withLock { current in
            guard !current.invalidated, !current.restored, current.sequence == nil else { return false }
            current.restored = true
            return apply(cache, to: &current)
        }
    }

    /// Atomically replaces authority from a complete, ordered control observation.
    /// Empty startup observations preserve a restored cache until the service loads it.
    /// - Parameter snapshot: An observation from the one service belonging to this authority.
    /// - Returns: Whether authority changed and existing sessions should be rechecked.
    @discardableResult
    public func apply(_ snapshot: V2ControlSnapshot) -> Bool {
        state.withLock { current in
            guard !current.invalidated,
                  current.sequence.map({ snapshot.sequence > $0 }) ?? true else { return false }
            current.sequence = snapshot.sequence
            let cache = snapshot.cache
            guard cache.formatVersion == 2, cache.identity == host.identity else {
                current.invalidated = true
                return clear(&current)
            }
            if !current.liveLoaded, cache.device == nil, cache.directory == nil, !cache.authorityRevoked {
                // The service publishes before reading disk. This empty observation
                // carries no replacement authority and must not delay cached admission.
                return false
            }
            current.liveLoaded = true
            return apply(cache, to: &current)
        }
    }

    /// Permanently stops this owner before account/team teardown begins.
    public func invalidate() {
        state.withLock { current in
            current.invalidated = true
            clear(&current)
        }
    }

    /// Applies a known device revocation before the next complete directory arrives.
    /// Revoked record IDs stay denied for this authority's lifetime.
    /// - Parameter event: An authenticated event for the requesting Mac's team.
    /// - Returns: Whether live sessions should be rechecked.
    @discardableResult
    public func revoke(_ event: V2RevokedResponse) -> Bool {
        state.withLock { current in
            guard !current.invalidated, event.teamID == host.identity.teamID,
                  event.revision >= current.revision else { return false }
            current.revision = event.revision
            current.revokedRecords.insert(event.deviceRecordID)
            if event.deviceRecordID == current.localRecordID {
                current.invalidated = true
                clear(&current)
                return true
            }
            for (endpoint, entry) in current.entries where entry.peer.bindingID == event.deviceRecordID {
                current.revokedEndpoints.insert(endpoint)
                current.entries[endpoint] = nil
            }
            // Keep authority storage finite even under a stream of unknown revocations.
            if current.revokedRecords.count > 4096 {
                current.invalidated = true
                clear(&current)
            }
            return true
        }
    }

    /// Returns current permission for the QUIC-authenticated key in constant time.
    /// - Parameter endpointID: The exact lowercase key reported by the IROH connection.
    /// - Returns: Its server-bound tuple, or nil when permission is absent or expired.
    public func authorizedPeer(endpointID: String) -> IrxAdmittedPeerInfo? {
        try? lookup(endpointID: endpointID).get()
    }

    /// The next future peer expiry for one Mac-owned enforcement task.
    /// Expiries already reached are omitted after that task performs its sweep.
    public var nextExpiration: ContinuousClock.Instant? {
        return state.withLock { current in
            let now = monotonicNow()
            guard !current.invalidated else { return nil }
            return current.entries.values.map(\.deadline).filter { $0 > now }.min()
        }
    }

    /// Supplies the existing grantless admission API with current inbound authority.
    /// - Returns: A synchronous judge that ignores any legacy grant supplied by the peer.
    public func judgment() -> IrxGrantJudgment {
        { [self] _, endpointID in try lookup(endpointID: endpointID).get() }
    }

    /// Rechecks the exact receipt after admission's async work and before registry insertion.
    /// - Parameter admitted: The tuple returned by this authority's judgment.
    /// - Returns: The closure accepted by `IrxServerSessionRegistry.admit(stillAuthorized:)`.
    public func recheck(_ admitted: IrxAdmittedPeerInfo) -> @Sendable (String) -> Bool {
        { [self] endpointID in
            endpointID == admitted.endpointIDHex && authorizedPeer(endpointID: endpointID) == admitted
        }
    }

    private func lookup(endpointID: String) -> Result<IrxAdmittedPeerInfo, IrxAdmissionDenied> {
        return state.withLock { current in
            let now = monotonicNow()
            guard !current.invalidated, !current.revokedEndpoints.contains(endpointID) else {
                return .failure(IrxAdmissionDenied(code: .revoked))
            }
            guard let entry = current.entries[endpointID] else {
                return .failure(IrxAdmissionDenied(code: .invalidGrant))
            }
            guard now >= initialMonotonic, now < entry.deadline else {
                return .failure(IrxAdmissionDenied(code: .grantExpired))
            }
            return .success(entry.peer)
        }
    }

    private func apply(_ cache: V2CachedState, to current: inout State) -> Bool {
        guard cache.formatVersion == 2, cache.identity == host.identity, !cache.authorityRevoked,
              let own = cache.device, !own.revoked,
              own.descriptor.identity == host.identity,
              own.descriptor.endpointID == host.endpointID,
              own.descriptor.identityGeneration == host.identityGeneration,
              own.descriptor.metadata.platform == .mac, own.descriptor.metadata.pairingEnabled,
              !current.revokedRecords.contains(own.deviceRecordID) else {
            if cache.formatVersion != 2 || cache.authorityRevoked || cache.device != nil || cache.identity != host.identity {
                current.invalidated = true
            }
            return clear(&current)
        }
        current.localRecordID = own.deviceRecordID
        guard let directory = cache.directory else { return clear(&current) }
        guard directory.teamID == host.identity.teamID, directory.nextCursor == nil,
              (directory.inboundPeers?.count ?? 0) <= 4096 else { return clear(&current) }
        guard directory.revision >= current.revision, directory.issuedAt >= current.issuedAt else { return false }
        let peers = directory.inboundPeers ?? []
        if directory.revision == current.revision, directory.issuedAt == current.issuedAt {
            // A repeated observation cannot reinstate a cleared set or replace
            // it with different permissions under the same server stamp.
            guard let sourcePeers = current.sourcePeers else { return false }
            guard sourcePeers == peers, current.sourceExpiry == directory.permissionExpiresAt else {
                return clear(&current)
            }
            return false
        }
        current.revision = directory.revision
        current.issuedAt = directory.issuedAt
        current.sourcePeers = peers
        current.sourceExpiry = directory.permissionExpiresAt
        var entries: [String: Entry] = [:]
        var seenEndpoints = Set<String>()
        var seenRecords = Set<String>()
        var seenTuples = Set<Data>()
        let codec = V2WireSigningCodec()
        let now = monotonicNow()
        let elapsed = initialMonotonic.duration(to: now).components
        let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        // A wall-clock rollback cannot stretch an already mapped lease or
        // give a repeated cache observation another full lifetime.
        let logicalWall = max(wallNow().timeIntervalSince1970,
            initialWall.timeIntervalSince1970 + max(0, elapsedSeconds))
        for permission in peers {
            let record = permission.device
            let device = record.descriptor
            guard device.identity.environment == host.identity.environment,
                  device.identity.projectID == host.identity.projectID,
                  device.identity.teamID == host.identity.teamID,
                  device.endpointID != host.endpointID, Self.validKey(device.endpointID),
                  device.identityGeneration >= 0, !record.deviceRecordID.isEmpty,
                  record.revision <= directory.revision else { continue }
            guard seenEndpoints.insert(device.endpointID).inserted,
                  seenRecords.insert(record.deviceRecordID).inserted,
                  let tuple = try? codec.encode(device.identity), seenTuples.insert(tuple).inserted else {
                return clear(&current)
            }
            if record.revoked {
                current.revokedRecords.insert(record.deviceRecordID)
                current.revokedEndpoints.insert(device.endpointID)
            }
            guard !current.revokedRecords.contains(record.deviceRecordID),
                  !current.revokedEndpoints.contains(device.endpointID) else { continue }
            let expiry = min(permission.permissionExpiresAt, directory.permissionExpiresAt)
            let remaining = min(Double(expiry) - logicalWall, Double(expiry) - Double(directory.issuedAt))
            guard remaining > 0, now >= initialMonotonic else { continue }
            entries[device.endpointID] = Entry(peer: IrxAdmittedPeerInfo(
                bindingID: record.deviceRecordID, deviceID: device.identity.deviceID,
                tag: device.identity.buildTag, endpointIDHex: device.endpointID,
                identityGeneration: device.identityGeneration), deadline: now.advanced(by: .seconds(remaining)))
        }
        guard current.revokedRecords.count <= 4096, current.revokedEndpoints.count <= 4096 else {
            current.invalidated = true
            return clear(&current)
        }
        current.entries = entries
        return true
    }

    @discardableResult
    private func clear(_ current: inout State) -> Bool {
        let changed = current.sourcePeers != nil || !current.entries.isEmpty
        current.entries.removeAll()
        current.sourcePeers = nil
        current.sourceExpiry = nil
        return changed
    }

    private static func validKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
