import CMUXMobileCore
import CmuxAgentChat
import CmuxAuthRuntime
import CmuxMobileTransport
import CmuxSettings
import CmuxTerminalCore
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os

/// The privacy-safe reason an admitted host connection stopped. Carries the
/// bounded diagnostic categories the previous transport's connection exit
/// carried, so log attribution is unchanged.
struct MobileHostConnectionExit: Equatable, Sendable {
    /// The local operation that ended the admitted connection.
    let lifecycle: DiagnosticSessionLifecycleKind

    /// The bounded failure category, or ``DiagnosticFailureKind/none`` for an
    /// expected close.
    let failure: DiagnosticFailureKind

    init(
        lifecycle: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) {
        self.lifecycle = lifecycle
        self.failure = failure
    }
}

/// The exact admitted peer tuple carried from grant verification into RPC
/// dispatch: the TLS-proven remote EndpointID plus the grant's device IDs.
struct MobileHostPeerAdmission: Equatable, Sendable {
    /// Lowercase hex EndpointID proven by the QUIC TLS handshake.
    let peerEndpointID: String
    /// The verified pair-grant ID that admitted this session.
    let grantID: String
    /// The iOS device that initiated the pairing grant.
    let initiatorDeviceID: String
    /// This Mac's device ID as signed into the grant.
    let acceptorDeviceID: String
}

enum MobileHostConnectionAuthorizationContext: Equatable, Sendable {
    case stackBearer
    case peerAdmission(MobileHostPeerAdmission)
}

extension MobileHostConnectionAuthorizationContext {
    /// One policy authority for transports accepted by the legacy
    /// private-network listener. Keeping this separate from Iroh admission
    /// makes version-skew coverage exercise the same authorization choice as
    /// the production listener.
    static let legacyPrivateNetworkListener: Self = .stackBearer
}

/// Immutable trust context carried from transport admission into RPC dispatch.
struct MobileHostRPCExecutionContext: Sendable {
    /// The per-connection identity, used to key long-lived subscriptions
    /// (e.g. browser stream sessions) and route pushed events back to the
    /// originating phone connection.
    let connectionID: UUID
    let authorization: MobileHostConnectionAuthorizationContext
    let artifactTransfers: MobileHostPeerArtifactTransferRegistry?

    func issueArtifactTransfer(
        canonicalPath: String
    ) async throws -> ChatArtifactLaneDescriptor {
        guard case let .peerAdmission(peer) = authorization,
              let artifactTransfers else {
            throw MobileHostPeerArtifactTransferRegistry.Error.unavailable
        }
        return try await artifactTransfers.issue(
            canonicalPath: canonicalPath,
            peer: peer
        )
    }
}


enum MobileHostEventTransport: String, Equatable, Sendable {
    case control = "control_v1"
    case irohServerEvents = "iroh_server_events_v1"
}

/// Optional independent event-lane boundary. Only an admitted Iroh session
/// supplies an implementation; legacy/private-network transports keep events
/// on their existing control stream.
protocol MobileHostIndependentEventWriting: Sendable {
    /// Probes a ready lane without competing with an in-flight event write.
    /// Returns true when the lane is ready or an existing write already proves
    /// it is active.
    func probe(_ framedData: Data) async -> Bool
    func send(_ framedData: Data) async throws
    func reset() async
    func close() async
}

/// Admission policy for active peer sessions owned by one client device.
///
/// Two sessions permit a live client to overlap its replacement connection
/// during route migration or reconnect without monopolizing the host pool.
/// The registry keeps the authoritative connection collection; this value only
/// evaluates it, so quota state cannot drift on removal.
struct MobileHostPeerConnectionQuota: Sendable {
    static let recommendedMaximumActiveConnectionsPerPeer = 2

    let maximumActiveConnectionsPerPeer: Int

    init(
        maximumActiveConnectionsPerPeer: Int =
            Self.recommendedMaximumActiveConnectionsPerPeer
    ) {
        precondition(maximumActiveConnectionsPerPeer > 0)
        self.maximumActiveConnectionsPerPeer = maximumActiveConnectionsPerPeer
    }

    /// Returns whether one more session for `peerKey` fits within the quota.
    /// The caller must evaluate and insert inside the same synchronization
    /// boundary so concurrent admissions cannot both consume the final slot.
    func allowsAdmission<ActivePeerKeys: Sequence>(
        for peerKey: String,
        activePeerKeys: ActivePeerKeys
    ) -> Bool where ActivePeerKeys.Element == String {
        var matchingConnectionCount = 0
        for activeKey in activePeerKeys where activeKey == peerKey {
            matchingConnectionCount += 1
            if matchingConnectionCount >= maximumActiveConnectionsPerPeer {
                return false
            }
        }
        return true
    }
}

final class MobileHostConnectionRegistry: @unchecked Sendable {
    private struct Entry {
        let connection: MobileHostConnection
        let authorization: MobileHostConnectionAuthorizationContext
        let insertionSequence: UInt64
    }

    static let shared = MobileHostConnectionRegistry()

    private let lock = NSLock()
    private let peerConnectionQuota = MobileHostPeerConnectionQuota()
    private var connections: [UUID: Entry] = [:]
    private var nextInsertionSequence: UInt64 = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    func insert(
        _ connection: MobileHostConnection,
        id: UUID,
        authorization: MobileHostConnectionAuthorizationContext,
        limit: Int
    ) -> Bool {
        lock.lock()
        guard connections.count < limit else {
            lock.unlock()
            return false
        }
        if case let .peerAdmission(peer) = authorization {
            let activePeerKeys = connections.values.lazy.compactMap { entry -> String? in
                guard case let .peerAdmission(activePeer) = entry.authorization else {
                    return nil
                }
                return activePeer.initiatorDeviceID
            }
            guard peerConnectionQuota.allowsAdmission(
                for: peer.initiatorDeviceID,
                activePeerKeys: activePeerKeys
            ) else {
                lock.unlock()
                return false
            }
        }
        nextInsertionSequence &+= 1
        connections[id] = Entry(
            connection: connection,
            authorization: authorization,
            insertionSequence: nextInsertionSequence
        )
        lock.unlock()
        // Notify after the authoritative count actually changes (this registry
        // backs `MobileHostServiceStatus.activeConnectionCount`), so the Mobile
        // settings diagnostics reflect the real count rather than a stale one.
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        return true
    }

    func remove(id: UUID) {
        lock.lock()
        let didRemove = connections.removeValue(forKey: id) != nil
        lock.unlock()
        if didRemove {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
    }

    func removeAll() -> [MobileHostConnection] {
        lock.lock()
        let values = connections.values.map(\.connection)
        connections.removeAll()
        lock.unlock()
        if !values.isEmpty {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
        return values
    }

    func removeStackBearerConnections() -> [MobileHostConnection] {
        removeConnections { authorization in
            authorization == .stackBearer
        }
    }

    func removeIrohConnections(initiatorDeviceID: String) -> [MobileHostConnection] {
        removeConnections { authorization in
            guard case let .peerAdmission(peer) = authorization else {
                return false
            }
            return peer.initiatorDeviceID == initiatorDeviceID
        }
    }

    func removeAllIrohConnections() -> [MobileHostConnection] {
        removeConnections { authorization in
            if case .peerAdmission = authorization {
                return true
            }
            return false
        }
    }

    /// Retires reconnect overlap only after the replacement has processed an
    /// authorized request. An older connection can never evict a newer one,
    /// even if its delayed request finishes after the replacement arrived.
    func removeOlderIrohConnectionsIfNewest(id: UUID) -> [MobileHostConnection] {
        lock.lock()
        guard let current = connections[id],
              case let .peerAdmission(currentPeer) = current.authorization else {
            lock.unlock()
            return []
        }
        let sameBinding = connections.filter { _, entry in
            guard case let .peerAdmission(peer) = entry.authorization else {
                return false
            }
            return peer.initiatorDeviceID == currentPeer.initiatorDeviceID
        }
        guard sameBinding.values.allSatisfy({
            $0.insertionSequence <= current.insertionSequence
        }) else {
            lock.unlock()
            return []
        }
        let older = sameBinding.filter { candidateID, entry in
            candidateID != id && entry.insertionSequence < current.insertionSequence
        }
        for olderID in older.keys {
            connections[olderID] = nil
        }
        lock.unlock()
        if !older.isEmpty {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
        return older.values.map(\.connection)
    }

    private func removeConnections(
        where shouldRemove: (MobileHostConnectionAuthorizationContext) -> Bool
    ) -> [MobileHostConnection] {
        lock.lock()
        let selected = connections.filter { shouldRemove($0.value.authorization) }
        for id in selected.keys { connections[id] = nil }
        lock.unlock()
        if !selected.isEmpty {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
        return selected.values.map(\.connection)
    }

    /// Snapshot of current connections — caller fans out event delivery
    /// without holding the registry lock across `await`.
    func snapshot() -> [MobileHostConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.map(\.connection)
    }

    /// Returns one connection for connection-scoped event delivery.
    func connection(id: UUID) -> MobileHostConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[id]?.connection
    }

    func snapshot(peerInitiatorDeviceID: String) -> [MobileHostConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.compactMap { entry in
            guard case let .peerAdmission(peer) = entry.authorization,
                  peer.initiatorDeviceID == peerInitiatorDeviceID else {
                return nil
            }
            return entry.connection
        }
    }

}

enum MobileHostPublicStatusCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var legacyRoutes: [CmxAttachRoute] = []
    private nonisolated(unsafe) static var irohRoute: CmxAttachRoute?

    static func update(routes nextRoutes: [CmxAttachRoute]) {
        lock.lock()
        legacyRoutes = nextRoutes
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    static func update(
        irohIdentity identity: CmxIrohPeerIdentity?,
        pathHints: [CmxIrohPathHint] = []
    ) {
        lock.lock()
        if let identity {
            irohRoute = try? CmxAttachRoute(
                id: CmxAttachTransportKind.iroh.rawValue,
                kind: .iroh,
                endpoint: .peer(
                    identity: identity,
                    pathHints: pathHints
                ),
                priority: 0
            )
        } else {
            irohRoute = nil
        }
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    static func removeAll() {
        lock.lock()
        legacyRoutes = []
        irohRoute = nil
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    static func snapshot() -> [CmxAttachRoute] {
        lock.lock()
        defer { lock.unlock() }
        return mergedRoutesLocked()
    }

    static func hasIrohRoute() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return irohRoute != nil
    }

    static func result(
        includeIdentity: Bool = false,
        additionalCapabilities: Set<String> = [],
        phonePushAdmission: PhonePushAdmission = .unknown,
        phonePushQueuePersistenceStatus: PhonePushQueuePersistenceStatus =
            .unknown
    ) -> MobileHostRPCResult {
        lock.lock()
        let cachedRoutes = mergedRoutesLocked()
        lock.unlock()
        return .ok(
            includeIdentity
                ? MobileHostService.identityStatusPayload(
                    routes: cachedRoutes,
                    additionalCapabilities: additionalCapabilities,
                    phonePushAdmission: phonePushAdmission,
                    phonePushQueuePersistenceStatus:
                        phonePushQueuePersistenceStatus
                )
                : MobileHostService.publicStatusPayload(routes: cachedRoutes)
        )
    }

    private static func mergedRoutesLocked() -> [CmxAttachRoute] {
        let routes = irohRoute.map { [$0] } ?? []
        return routes + legacyRoutes
    }
}
