import CMUXMobileCore
import CmuxAgentChat
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileTransport
import CmuxSettings
import CmuxTerminalCore
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os

enum MobileHostConnectionAuthorizationContext: Equatable, Sendable {
    case stackBearer
    case irohAdmission(CmxIrohAdmittedPeer)
    /// A browser connection authenticated by one revocable, per-client grant.
    case webGrant(UUID)
}

extension MobileHostConnectionAuthorizationContext {
    var isWebGrant: Bool {
        if case .webGrant = self { return true }
        return false
    }

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
    let artifactTransfers: MobileHostIrohArtifactTransferRegistry?
    /// Synchronous revocation fence for browser requests. The lease is held
    /// only across the final, non-async mutation boundary; it is `nil` for
    /// legacy and Iroh transports.
    let webGrantAdmission: WebClientGrantAdmission?

    func issueArtifactTransfer(
        canonicalPath: String
    ) async throws -> ChatArtifactLaneDescriptor {
        guard case let .irohAdmission(peer) = authorization,
              let artifactTransfers else {
            throw MobileHostIrohArtifactTransferRegistry.Error.unavailable
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

final class MobileHostConnectionRegistry: @unchecked Sendable {
    private struct Entry {
        let connection: MobileHostConnection
        let authorization: MobileHostConnectionAuthorizationContext
        let insertionSequence: UInt64
        let webGrantAdmission: WebClientGrantAdmission?
    }

    static let shared = MobileHostConnectionRegistry()

    private let lock = NSLock()
    private let irohBindingConnectionQuota = CmxIrohActiveBindingConnectionQuota()
    private var connections: [UUID: Entry] = [:]
    private var nextInsertionSequence: UInt64 = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    /// Phone/mobile transports only. Browser connections use an independent
    /// quota and must not satisfy the iOS pairing connection-count gate.
    var mobileConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.lazy.filter {
            !$0.authorization.isWebGrant
        }.count
    }

    func insert(
        _ connection: MobileHostConnection,
        id: UUID,
        authorization: MobileHostConnectionAuthorizationContext,
        limit: Int,
        webGrantAdmission: WebClientGrantAdmission? = nil
    ) -> Bool {
        // Keep the registry's stored authorization and revocation lease as one
        // invariant even for direct callers. A web entry without a lease could
        // survive grant invalidation; a non-web entry with one would make the
        // lease's ownership ambiguous.
        guard authorization.isWebGrant == (webGrantAdmission != nil) else {
            return false
        }
        if let webGrantAdmission {
            return webGrantAdmission.withValidAdmission {
                insertLocked(
                    connection,
                    id: id,
                    authorization: authorization,
                    limit: limit,
                    webGrantAdmission: webGrantAdmission
                )
            } ?? false
        }
        return insertLocked(
            connection,
            id: id,
            authorization: authorization,
            limit: limit,
            webGrantAdmission: nil
        )
    }

    private func insertLocked(
        _ connection: MobileHostConnection,
        id: UUID,
        authorization: MobileHostConnectionAuthorizationContext,
        limit: Int,
        webGrantAdmission: WebClientGrantAdmission?
    ) -> Bool {
        lock.lock()
        let scopedConnectionCount = connections.values.lazy.filter {
            $0.authorization.isWebGrant == authorization.isWebGrant
        }.count
        guard scopedConnectionCount < limit else {
            lock.unlock()
            return false
        }
        if case let .irohAdmission(peer) = authorization {
            let activeBindingIDs = connections.values.lazy.compactMap { entry -> String? in
                guard case let .irohAdmission(activePeer) = entry.authorization else {
                    return nil
                }
                return activePeer.bindingID
            }
            guard irohBindingConnectionQuota.allowsAdmission(
                for: peer.bindingID,
                activeBindingIDs: activeBindingIDs
            ) else {
                lock.unlock()
                return false
            }
        }
        nextInsertionSequence &+= 1
        connections[id] = Entry(
            connection: connection,
            authorization: authorization,
            insertionSequence: nextInsertionSequence,
            webGrantAdmission: webGrantAdmission
        )
        lock.unlock()
        // Only mobile transports back MobileHostServiceStatus and the iOS
        // pairing count. Browser state is reported by web.bridge.status.
        if !authorization.isWebGrant {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
        return true
    }

    func remove(id: UUID) {
        lock.lock()
        let removed = connections.removeValue(forKey: id)
        lock.unlock()
        if let removed, !removed.authorization.isWebGrant {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
    }

    func removeAll() -> [MobileHostConnection] {
        lock.lock()
        let values = connections.values.map(\.connection)
        let removedMobileConnection = connections.values.contains {
            !$0.authorization.isWebGrant
        }
        connections.removeAll()
        lock.unlock()
        if removedMobileConnection {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
        return values
    }

    func removeStackBearerConnections() -> [MobileHostConnection] {
        removeConnections { authorization in
            authorization == .stackBearer
        }
    }

    func removeIrohConnections(bindingID: String) -> [MobileHostConnection] {
        removeConnections { authorization in
            guard case let .irohAdmission(peer) = authorization else {
                return false
            }
            return peer.bindingID == bindingID
        }
    }

    func removeAllIrohConnections() -> [MobileHostConnection] {
        removeConnections { authorization in
            if case .irohAdmission = authorization {
                return true
            }
            return false
        }
    }

    /// Removes only browser connections belonging to one grant. Revocation
    /// intentionally leaves every other browser and mobile connection alive.
    func removeWebGrantConnections(_ grantID: UUID) -> [MobileHostConnection] {
        invalidateWebGrantAdmissions(grantID)
        removeConnections { authorization in
            guard case let .webGrant(activeGrantID) = authorization else {
                return false
            }
            return activeGrantID == grantID
        }
    }

    /// Invalidates pending and admitted browser insertions before removal.
    /// Callers must invoke this before deleting the grant from the store.
    func invalidateWebGrantAdmissions(_ grantID: UUID) {
        lock.lock()
        let admissions = connections.values.compactMap { entry -> WebClientGrantAdmission? in
            guard case let .webGrant(activeGrantID) = entry.authorization,
                  activeGrantID == grantID else { return nil }
            return entry.webGrantAdmission
        }
        lock.unlock()
        for admission in admissions { admission.invalidate() }
    }

    /// Synchronously invalidates every browser admission before a managed
    /// policy teardown begins its asynchronous connection closes.
    func invalidateAllWebGrantAdmissions() {
        lock.lock()
        let admissions = connections.values.compactMap { entry -> WebClientGrantAdmission? in
            guard entry.authorization.isWebGrant else { return nil }
            return entry.webGrantAdmission
        }
        lock.unlock()
        for admission in admissions { admission.invalidate() }
    }

    /// Retires reconnect overlap only after the replacement has processed an
    /// authorized request. An older connection can never evict a newer one,
    /// even if its delayed request finishes after the replacement arrived.
    func removeOlderIrohConnectionsIfNewest(id: UUID) -> [MobileHostConnection] {
        lock.lock()
        guard let current = connections[id],
              case let .irohAdmission(currentPeer) = current.authorization else {
            lock.unlock()
            return []
        }
        let sameBinding = connections.filter { _, entry in
            guard case let .irohAdmission(peer) = entry.authorization else {
                return false
            }
            return peer.bindingID == currentPeer.bindingID
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
        let removedMobileConnection = selected.values.contains {
            !$0.authorization.isWebGrant
        }
        for id in selected.keys { connections[id] = nil }
        lock.unlock()
        if removedMobileConnection {
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

    func snapshot(irohBindingID: String) -> [MobileHostConnection] {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.compactMap { entry in
            guard case let .irohAdmission(peer) = entry.authorization,
                  peer.bindingID == irohBindingID else {
                return nil
            }
            return entry.connection
        }
    }

    /// Counts active browser connections by grant without exposing bearer
    /// material or holding the registry lock across any await.
    func webGrantConnectionCounts() -> [UUID: Int] {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.reduce(into: [:]) { counts, entry in
            guard case let .webGrant(grantID) = entry.authorization else { return }
            counts[grantID, default: 0] += 1
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

    static func update(irohBinding binding: CmxIrohBrokerBindingMetadata) {
        lock.lock()
        irohRoute = try? CmxAttachRoute(
            id: CmxAttachTransportKind.iroh.rawValue,
            kind: .iroh,
            endpoint: .peer(
                identity: binding.endpointID,
                pathHints: binding.pathHints
            ),
            priority: 0
        )
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
