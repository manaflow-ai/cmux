import CMUXMobileCore
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

enum MobileHostConnectionAuthorizationContext: Equatable, Sendable {
    case stackBearer
}

extension MobileHostConnectionAuthorizationContext {
    /// One policy authority for transports accepted by the private-network
    /// listener.
    static let legacyPrivateNetworkListener: Self = .stackBearer
}

/// Immutable trust context carried from transport admission into RPC dispatch.
struct MobileHostRPCExecutionContext: Sendable {
    /// The per-connection identity, used to key long-lived subscriptions
    /// (e.g. browser stream sessions) and route pushed events back to the
    /// originating phone connection.
    let connectionID: UUID
    let authorization: MobileHostConnectionAuthorizationContext
}

enum MobileHostEventTransport: String, Equatable, Sendable {
    case control = "control_v1"
}

final class MobileHostConnectionRegistry: @unchecked Sendable {
    private struct Entry {
        let connection: MobileHostConnection
        let authorization: MobileHostConnectionAuthorizationContext
        let insertionSequence: UInt64
    }

    static let shared = MobileHostConnectionRegistry()

    private let lock = NSLock()
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
}

enum MobileHostPublicStatusCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var legacyRoutes: [CmxAttachRoute] = []

    static func update(routes nextRoutes: [CmxAttachRoute]) {
        lock.lock()
        legacyRoutes = nextRoutes
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    static func removeAll() {
        lock.lock()
        legacyRoutes = []
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    static func snapshot() -> [CmxAttachRoute] {
        lock.lock()
        defer { lock.unlock() }
        return legacyRoutes
    }

    static func result(
        includeIdentity: Bool = false,
        additionalCapabilities: Set<String> = [],
        phonePushAdmission: PhonePushAdmission = .unknown,
        phonePushQueuePersistenceStatus: PhonePushQueuePersistenceStatus =
            .unknown
    ) -> MobileHostRPCResult {
        lock.lock()
        let cachedRoutes = legacyRoutes
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
}
