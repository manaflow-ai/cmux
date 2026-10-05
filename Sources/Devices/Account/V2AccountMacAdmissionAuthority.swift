import CmuxIrxTransport
import Foundation
import os

/// Synchronous inbound authority for same-user Macs from other teams.
///
/// It admits only `platform == .mac` rows from the account directory's
/// `inboundMacs` that opted into `cmux.mac-devices.v1` and share this host's
/// user, environment, project, app namespace and build tag, and only while this
/// host's own team record advertises `cmux.mac-host.v1`. iOS rows are never
/// admitted here: phone pairing stays on the team authority alone.
final class V2AccountMacAdmissionAuthority: Sendable {
    private struct Entry: Sendable {
        let peer: IrxAdmittedPeerInfo
        let deadline: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var invalidated = false
        var revision = -1
        var issuedAt = -1
        var entries: [String: Entry] = [:]
    }

    private let host: V2DeviceDescriptor
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wallNow: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let initialWall: Date
    private let initialMonotonic: ContinuousClock.Instant

    /// Creates an authority bound to one Mac tuple, key and generation.
    /// - Throws: A scope error if `host` is not a Mac.
    init(host: V2DeviceDescriptor,
         wallNow: @escaping @Sendable () -> Date = { Date() },
         monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        guard host.metadata.platform == .mac, Self.validKey(host.endpointID) else {
            throw V2ControlFailure.scopeMismatch
        }
        self.host = host
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
        initialWall = wallNow()
        initialMonotonic = monotonicNow()
    }

    /// Replaces authority from the latest account directory and this host's team record.
    /// - Parameters:
    ///   - account: The latest account snapshot, or nil when none applies.
    ///   - hostRecord: This host's current team record (`V2CachedState.device`).
    /// - Returns: Whether authority changed and live sessions should be rechecked.
    @discardableResult
    func apply(account: AccountMacDirectorySnapshot?, hostRecord: V2DeviceRecord?) -> Bool {
        state.withLock { current in
            guard !current.invalidated else { return false }
            guard let hostRecord, !hostRecord.revoked,
                  hostRecord.descriptor.identity == host.identity,
                  hostRecord.descriptor.endpointID == host.endpointID,
                  hostRecord.descriptor.identityGeneration == host.identityGeneration,
                  hostRecord.descriptor.metadata.platform == .mac,
                  hostRecord.descriptor.metadata.capabilities.contains("cmux.mac-host.v1"),
                  let account, account.belongs(to: host),
                  account.directory.userID == host.identity.userID,
                  account.directory.supportsAccountPeers,
                  account.directory.inboundMacs.count <= 64 else {
                return Self.clear(&current)
            }
            let directory = account.directory
            guard (directory.revision, directory.issuedAt) >= (current.revision, current.issuedAt) else { return false }
            current.revision = directory.revision
            current.issuedAt = directory.issuedAt
            let now = monotonicNow()
            let elapsed = initialMonotonic.duration(to: now).components
            let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            // A wall-clock rollback cannot stretch a lease past elapsed monotonic time.
            let logicalWall = max(wallNow().timeIntervalSince1970,
                initialWall.timeIntervalSince1970 + max(0, elapsedSeconds))
            var entries: [String: Entry] = [:]
            var duplicates = Set<String>()
            for permission in directory.inboundMacs {
                let record = permission.device
                let device = record.descriptor
                let identity = device.identity
                guard device.metadata.platform == .mac,
                      device.metadata.capabilities.contains("cmux.mac-devices.v1"),
                      !record.revoked, !record.deviceRecordID.isEmpty,
                      identity.userID == host.identity.userID,
                      identity.environment == host.identity.environment,
                      identity.projectID == host.identity.projectID,
                      identity.appNamespace == host.identity.appNamespace,
                      identity.buildTag == host.identity.buildTag,
                      identity.deviceID.lowercased() != host.identity.deviceID.lowercased(),
                      device.endpointID != host.endpointID, Self.validKey(device.endpointID),
                      device.identityGeneration >= 0 else { continue }
                if entries[device.endpointID] != nil { duplicates.insert(device.endpointID); continue }
                let expiry = min(permission.permissionExpiresAt, directory.permissionExpiresAt)
                let remaining = min(Double(expiry) - logicalWall, Double(expiry) - Double(directory.issuedAt))
                guard remaining > 0, now >= initialMonotonic else { continue }
                entries[device.endpointID] = Entry(peer: IrxAdmittedPeerInfo(
                    bindingID: record.deviceRecordID, deviceID: identity.deviceID,
                    tag: identity.buildTag, endpointIDHex: device.endpointID,
                    identityGeneration: device.identityGeneration), deadline: now.advanced(by: .seconds(remaining)))
            }
            // An endpoint named twice is ambiguous; admit neither row.
            for endpoint in duplicates { entries[endpoint] = nil }
            let changed = entries.mapValues(\.peer) != current.entries.mapValues(\.peer)
            current.entries = entries
            return changed
        }
    }

    /// Permanently stops this owner before teardown begins.
    func invalidate() {
        state.withLock { current in
            current.invalidated = true
            Self.clear(&current)
        }
    }

    /// Current permission for the QUIC-authenticated key, or nil.
    func authorizedPeer(endpointID: String) -> IrxAdmittedPeerInfo? {
        try? lookup(endpointID: endpointID).get()
    }

    /// The next future peer expiry for the runtime's enforcement task.
    var nextExpiration: ContinuousClock.Instant? {
        state.withLock { current in
            let now = monotonicNow()
            guard !current.invalidated else { return nil }
            return current.entries.values.map(\.deadline).filter { $0 > now }.min()
        }
    }

    /// A synchronous judge with the same contract as the team authority's.
    func judgment() -> IrxGrantJudgment {
        { [self] _, endpointID in try lookup(endpointID: endpointID).get() }
    }

    /// Rechecks the exact admitted tuple for the session registry.
    func recheck(_ admitted: IrxAdmittedPeerInfo) -> @Sendable (String) -> Bool {
        { [self] endpointID in
            endpointID == admitted.endpointIDHex && authorizedPeer(endpointID: endpointID) == admitted
        }
    }

    private func lookup(endpointID: String) -> Result<IrxAdmittedPeerInfo, IrxAdmissionDenied> {
        state.withLock { current in
            let now = monotonicNow()
            guard !current.invalidated else { return .failure(IrxAdmissionDenied(code: .revoked)) }
            guard let entry = current.entries[endpointID] else {
                return .failure(IrxAdmissionDenied(code: .invalidGrant))
            }
            guard now >= initialMonotonic, now < entry.deadline else {
                return .failure(IrxAdmissionDenied(code: .grantExpired))
            }
            return .success(entry.peer)
        }
    }

    @discardableResult
    private static func clear(_ current: inout State) -> Bool {
        let changed = !current.entries.isEmpty
        current.entries.removeAll()
        return changed
    }

    private static func validKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
