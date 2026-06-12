import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os

let mobileHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

extension Notification.Name {
    static let mobileHostEventSubscriptionsDidChange = Notification.Name(
        "cmux.mobileHostEventSubscriptionsDidChange"
    )

    /// Posted whenever the mobile pairing host's observable status changes:
    /// the listener binds or stops, the bound port changes, or the active
    /// connection count changes. The Settings host adapter bridges this to an
    /// `AsyncStream` so the Mobile settings section can show the live bound
    /// port and connection count without polling.
    static let mobileHostStatusDidChange = Notification.Name(
        "cmux.mobileHostStatusDidChange"
    )
}

enum MobileHostEventSubscriptionTracker {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var topicCounts: [String: Int] = [:]

    static func hasSubscribers(topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (topicCounts[topic] ?? 0) > 0
    }

    static func replace(previousTopics: Set<String>?, nextTopics: Set<String>?) {
        let changedTopics = updateCounts(previousTopics: previousTopics, nextTopics: nextTopics)
        guard !changedTopics.isEmpty else { return }
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": Array(changedTopics).sorted()]
        )
    }

    private static func updateCounts(previousTopics: Set<String>?, nextTopics: Set<String>?) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var changedTopics = Set<String>()
        let allTopics = Set(previousTopics ?? []).union(nextTopics ?? [])
        let before = Dictionary(uniqueKeysWithValues: allTopics.map { ($0, topicCounts[$0] ?? 0) })

        for topic in previousTopics ?? [] {
            let nextCount = max(0, (topicCounts[topic] ?? 0) - 1)
            if nextCount == 0 {
                topicCounts.removeValue(forKey: topic)
            } else {
                topicCounts[topic] = nextCount
            }
        }
        for topic in nextTopics ?? [] {
            topicCounts[topic] = (topicCounts[topic] ?? 0) + 1
        }

        for topic in allTopics {
            let wasActive = (before[topic] ?? 0) > 0
            let isActive = (topicCounts[topic] ?? 0) > 0
            if wasActive != isActive {
                changedTopics.insert(topic)
            }
        }
        return changedTopics
    }

    static func reset() {
        lock.lock()
        topicCounts.removeAll()
        lock.unlock()
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": []]
        )
    }

    #if DEBUG
    static func resetForTesting() {
        reset()
    }
    #endif
}

final class MobileHostConnectionRegistry: @unchecked Sendable {
    static let shared = MobileHostConnectionRegistry()

    private let lock = NSLock()
    private var connections: [UUID: MobileHostConnection] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    func insert(_ connection: MobileHostConnection, id: UUID, limit: Int) -> Bool {
        lock.lock()
        guard connections.count < limit else {
            lock.unlock()
            return false
        }
        connections[id] = connection
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
        let values = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        if !values.isEmpty {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
        return values
    }

    /// Snapshot of current connections — caller fans out event delivery
    /// without holding the registry lock across `await`.
    func snapshot() -> [MobileHostConnection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(connections.values)
    }
}

enum MobileHostPublicStatusCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var routes: [CmxAttachRoute] = []

    static func update(routes nextRoutes: [CmxAttachRoute]) {
        lock.lock()
        routes = nextRoutes
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    static func result() -> MobileHostRPCResult {
        lock.lock()
        let cachedRoutes = routes
        lock.unlock()
        return .ok([
            "routes": cachedRoutes.map(\.mobileHostJSONObject),
            "terminal_fidelity": "render_grid",
            "capabilities": MobileHostService.mobileHostCapabilities,
        ])
    }
}

enum MobileHostRequestActivity {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var activeRequestCount = 0
    private nonisolated(unsafe) static var activeConnectionCount = 0
    private nonisolated(unsafe) static var lastActivityUptime: TimeInterval = 0

    static var hasActiveRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestCount > 0
    }

    static func hasRecentActivity(within interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return true }
        guard lastActivityUptime > 0 else { return false }
        return ProcessInfo.processInfo.systemUptime - lastActivityUptime < interval
    }

    static func quietDelay(for interval: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return interval }
        guard lastActivityUptime > 0 else { return 0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastActivityUptime
        return max(0, interval - elapsed)
    }

    static func beginConnection() {
        lock.lock()
        activeConnectionCount += 1
        lock.unlock()
    }

    static func endConnection() {
        lock.lock()
        activeConnectionCount = max(0, activeConnectionCount - 1)
        lock.unlock()
    }

    static func beginRequest() {
        lock.lock()
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        activeRequestCount += 1
        lock.unlock()
    }

    static func endRequest() {
        lock.lock()
        activeRequestCount = max(0, activeRequestCount - 1)
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    #if DEBUG
    static func resetForTesting() {
        lock.lock()
        activeRequestCount = 0
        activeConnectionCount = 0
        lastActivityUptime = 0
        lock.unlock()
    }
    #endif
}

struct MobileHostServiceStatus {
    let isRunning: Bool
    let port: Int?
    /// The preferred port from settings the listener tried to bind.
    let configuredPort: Int
    /// True when the listener is running on an OS-assigned ephemeral port
    /// because the configured port could not be bound.
    let usesEphemeralFallback: Bool
    let routes: [CmxAttachRoute]
    let activeConnectionCount: Int
    let lastErrorDescription: String?

    var payload: [String: Any] {
        [
            "is_running": isRunning,
            "port": port ?? NSNull(),
            "configured_port": configuredPort,
            "uses_ephemeral_fallback": usesEphemeralFallback,
            "routes": routes.map(\.mobileHostJSONObject),
            "active_connection_count": activeConnectionCount,
            "last_error": lastErrorDescription ?? NSNull()
        ]
    }
}

/// What ``MobileHostService/syncToSettings()`` should do to reconcile
/// the live listener with the current settings. A pure value so the
/// restart-on-port-change logic is unit-testable without a real `NWListener`.
enum MobileHostSyncDecision: Equatable {
    case noop
    case start
    case stop
    case restart
}

/// Outcome of an explicit "Apply port" request from settings. A pure value so
/// ``MobileHostService/portApplyDecision(enabled:currentBoundPort:requestedPort:isAvailable:)``
/// is unit-testable without binding a real `NWListener`.
enum MobileHostPortApplyOutcome: Equatable {
    /// The port was accepted; the listener is (or will be) bound to it.
    case applied(Int)
    /// The port is in use by another process; the running listener was left untouched.
    case portInUse
    /// Pairing is off, so the port was saved and will bind when pairing is enabled.
    case savedWhileDisabled
    /// The requested port was outside the valid `1...65535` range.
    case invalid
}

@MainActor
final class MobileHostService {
    static let shared = MobileHostService()
    nonisolated static let maximumActiveConnectionCount = 10

    /// The single source of truth for the capabilities advertised to mobile
    /// clients via `mobile.host.status`. Every status path (the public-status
    /// cache and `TerminalController`'s full status) reads this so the lists
    /// cannot drift; iOS gates features like rename/pin on the entries
    /// present here.
    ///
    /// In DEBUG builds this also advertises `dogfood.v1`, the DEV dogfood
    /// feedback round-trip (`dogfood.feedback.submit`). It is absent from
    /// release builds, so a release client never sees the verb advertised.
    nonisolated static var mobileHostCapabilities: [String] {
        var capabilities = [
            "events.v1",
            "terminal.bytes.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "workspace.actions.v1",
        ]
        #if DEBUG
        capabilities.append("dogfood.v1")
        #endif
        return capabilities
    }

    let callbackQueue = DispatchQueue(label: "dev.cmux.mobile.host-listener")
    let routeResolver = MobileRouteResolver()
    let ticketStore = MobileAttachTicketStore()
    var listener: NWListener?
    var listenerGeneration = UUID()
    var listenerUsesEphemeralFallback = false
    var listenerPort: Int?
    /// The preferred port the active start-sequence targeted (regardless of an
    /// ephemeral fallback). Used to decide whether a settings change needs a
    /// restart. `nil` while stopped.
    var appliedPreferredPort: Int?
    var activeConnections: [UUID: MobileHostConnection] = [:]
    var clientIDsByConnectionID: [UUID: Set<String>] = [:]
    var lastErrorDescription: String?
    /// Injected once via `configure(auth:)` at app startup, before the
    /// listener starts accepting connections.
    private var auth: AuthCoordinator?
    var readinessWaiters: [CheckedContinuation<MobileHostServiceStatus, Never>] = []
    var readinessTimeoutTask: Task<Void, Never>?
    #if DEBUG
    var debugAcceptedStackAuthToken: String?
    #endif

    private init() {}

    /// Inject the auth dependency. Call once at the composition root.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
    }

    /// The signed-in local user's id, awaiting launch session restore first so
    /// pairing checks can't race it. `nil` when signed out (or before the auth
    /// graph is configured), which the authorization policy rejects.
    func currentAuthenticatedLocalUserID() async -> String? {
        guard let auth else { return nil }
        await auth.awaitBootstrapped()
        guard auth.isAuthenticated else { return nil }
        return auth.currentUser?.id
    }

}

