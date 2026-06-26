import Foundation

/// The process-wide set of live `MobileHostConnection`s, keyed by connection id.
///
/// A real instance type with no static state: the single process-wide default is
/// held at the composition point (``MobileHostService/sharedConnectionRegistry``)
/// and reached through it, rather than via a `static let shared` on this type.
/// It backs `MobileHostServiceStatus.activeConnectionCount` and is the fan-out
/// source for `MobileHostService.emitEvent`.
///
/// `@unchecked Sendable` with an `NSLock`: the registry is mutated from both the
/// `@MainActor` listener-lifecycle paths and the off-main accept/emit paths, so
/// every access takes the lock and the lock makes the shared mutable dictionary
/// safe to cross isolation boundaries.
final class MobileHostConnectionRegistry: @unchecked Sendable {
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
