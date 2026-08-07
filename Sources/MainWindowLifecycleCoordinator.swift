import AppKit
import Observation

/// Owns every main-window route from registration through recovery or close.
///
/// `AppDelegate` remains the composition root, but it no longer keeps a
/// registered-context dictionary and a separate recovery ledger that can
/// disagree about the same window.
@MainActor
@Observable
final class MainWindowLifecycleCoordinator {
    private var recordsByWindowId: [UUID: MainWindowLifecycleRecord] = [:]
    private(set) var registeredContextsByLookupKey:
        [ObjectIdentifier: AppDelegate.MainWindowContext] = [:]
    private var nextOrder: UInt64 = 0
    private(set) var persistenceTopologyRevision: UInt64 = 0

    var registeredContexts: [AppDelegate.MainWindowContext] {
        Array(registeredContextsByLookupKey.values)
    }

    func registeredContext(for lookupKey: ObjectIdentifier) -> AppDelegate.MainWindowContext? {
        registeredContextsByLookupKey[lookupKey]
    }

    func registeredContext(windowId: UUID) -> AppDelegate.MainWindowContext? {
        guard let record = recordsByWindowId[windowId],
              case .registered(let lookupKey) = record.phase else {
            return nil
        }
        return registeredContextsByLookupKey[lookupKey]
    }

    func register(
        _ context: AppDelegate.MainWindowContext,
        lookupKey: ObjectIdentifier
    ) {
        if let existing = recordsByWindowId[context.windowId],
           case .registered(let previousLookupKey) = existing.phase {
            registeredContextsByLookupKey.removeValue(forKey: previousLookupKey)
        }

        if let displaced = registeredContextsByLookupKey[lookupKey],
           displaced !== context {
            recordsByWindowId.removeValue(forKey: displaced.windowId)
        }

        let order = recordsByWindowId[context.windowId]?.order ?? issueOrder()
        registeredContextsByLookupKey[lookupKey] = context
        recordsByWindowId[context.windowId] = MainWindowLifecycleRecord(
            order: order,
            phase: .registered(lookupKey: lookupKey)
        )
        bumpPersistenceTopologyRevision()
    }

    @discardableResult
    func reindex(
        _ context: AppDelegate.MainWindowContext,
        lookupKey: ObjectIdentifier
    ) -> Bool {
        guard var record = recordsByWindowId[context.windowId],
              case .registered(let previousLookupKey) = record.phase,
              registeredContextsByLookupKey[previousLookupKey] === context else {
            return false
        }
        if previousLookupKey == lookupKey {
            return true
        }
        if let conflicting = registeredContextsByLookupKey[lookupKey],
           conflicting !== context {
            return false
        }

        registeredContextsByLookupKey.removeValue(forKey: previousLookupKey)
        registeredContextsByLookupKey[lookupKey] = context
        record.phase = .registered(lookupKey: lookupKey)
        recordsByWindowId[context.windowId] = record
        return true
    }

    @discardableResult
    func transitionToOrphaned(
        _ route: RecoverableMainWindowRoute,
        from context: AppDelegate.MainWindowContext
    ) -> Bool {
        guard var record = recordsByWindowId[context.windowId],
              case .registered(let lookupKey) = record.phase,
              registeredContextsByLookupKey[lookupKey] === context else {
            return false
        }
        registeredContextsByLookupKey.removeValue(forKey: lookupKey)
        record.phase = .orphaned(route)
        recordsByWindowId[context.windowId] = record
        bumpPersistenceTopologyRevision()
        return true
    }

    @discardableResult
    func transitionToClosing(
        _ route: RecoverableMainWindowRoute,
        from context: AppDelegate.MainWindowContext
    ) -> Bool {
        guard var record = recordsByWindowId[context.windowId],
              case .registered(let lookupKey) = record.phase,
              registeredContextsByLookupKey[lookupKey] === context else {
            return false
        }
        registeredContextsByLookupKey.removeValue(forKey: lookupKey)
        route.markForTeardown()
        record.phase = .closing(route)
        recordsByWindowId[context.windowId] = record
        bumpPersistenceTopologyRevision()
        return true
    }

    @discardableResult
    func transitionOrphanedRouteToClosing(
        windowId: UUID,
        window: NSWindow
    ) -> Bool {
        guard var record = recordsByWindowId[windowId],
              case .orphaned(let route) = record.phase,
              route.window === window else {
            return false
        }
        route.markForTeardown()
        record.phase = .closing(route)
        recordsByWindowId[windowId] = record
        bumpPersistenceTopologyRevision()
        return true
    }

    func orphanedRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        guard let record = recordsByWindowId[windowId],
              case .orphaned(let route) = record.phase else {
            return nil
        }
        return route
    }

    func orphanedRoutes() -> [RecoverableMainWindowRoute] {
        recordsByWindowId.values
            .compactMap { record -> (UInt64, RecoverableMainWindowRoute)? in
                guard case .orphaned(let route) = record.phase else { return nil }
                return (record.order, route)
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                return lhs.1.windowId.uuidString < rhs.1.windowId.uuidString
            }
            .map { $0.1 }
    }

    func teardownRoute(windowId: UUID) -> RecoverableMainWindowRoute? {
        guard let phase = recordsByWindowId[windowId]?.phase else { return nil }
        switch phase {
        case .registered:
            return nil
        case .orphaned(let route), .closing(let route):
            return route
        }
    }

    func removeRecoverableRoute(windowId: UUID) {
        guard let record = recordsByWindowId[windowId] else { return }
        guard case .registered = record.phase else {
            recordsByWindowId.removeValue(forKey: windowId)
            bumpPersistenceTopologyRevision()
            return
        }
    }

    func retireClosingRoutes(where shouldRetire: (RecoverableMainWindowRoute) -> Bool) -> Int {
        let windowIds = recordsByWindowId.compactMap { windowId, record -> UUID? in
            guard case .closing(let route) = record.phase,
                  shouldRetire(route) else {
                return nil
            }
            return windowId
        }
        for windowId in windowIds {
            recordsByWindowId.removeValue(forKey: windowId)
        }
        if !windowIds.isEmpty {
            bumpPersistenceTopologyRevision()
        }
        return windowIds.count
    }

    private func issueOrder() -> UInt64 {
        defer { nextOrder &+= 1 }
        return nextOrder
    }

    private func bumpPersistenceTopologyRevision() {
        persistenceTopologyRevision &+= 1
    }
}
