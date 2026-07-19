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
    let authorization: MobileHostConnectionAuthorizationContext
    let artifactTransfers: MobileHostIrohArtifactTransferRegistry?

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

    static func update(irohBinding binding: CmxIrohBrokerBinding?) {
        lock.lock()
        if let binding {
            irohRoute = try? CmxAttachRoute(
                id: CmxAttachTransportKind.iroh.rawValue,
                kind: .iroh,
                endpoint: .peer(
                    identity: binding.endpointID,
                    pathHints: binding.pathHints
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
        additionalCapabilities: Set<String> = []
    ) -> MobileHostRPCResult {
        lock.lock()
        let cachedRoutes = mergedRoutesLocked()
        lock.unlock()
        return .ok(
            includeIdentity
                ? MobileHostService.identityStatusPayload(
                    routes: cachedRoutes,
                    additionalCapabilities: additionalCapabilities
                )
                : MobileHostService.publicStatusPayload(routes: cachedRoutes)
        )
    }

    private static func mergedRoutesLocked() -> [CmxAttachRoute] {
        let routes = irohRoute.map { [$0] } ?? []
        return routes + legacyRoutes
    }
}
