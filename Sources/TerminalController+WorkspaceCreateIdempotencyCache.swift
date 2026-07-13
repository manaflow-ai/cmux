import Foundation
import OSLog

extension TerminalController {
    /// Bounded durable tombstones and live workspace IDs for idempotent creates.
    final class WorkspaceCreateIdempotencyCache {
        private static let legacyPersistenceKey = "cmux.workspaceCreate.completedOperationIDs.v1"

        private let capacity: Int
        private let persistence: any WorkspaceCreateIdempotencyPersisting
        private let legacyDefaults: UserDefaults?
        private let legacyPersistenceKey: String?
        private var loadFailure: (any Error)?
        private var workspaceIDs: [UUID: UUID] = [:]
        private var completedOperationIDs: Set<UUID> = []
        private var insertionOrder: [UUID] = []

        convenience init(capacity: Int) {
            self.init(
                capacity: capacity,
                persistence: WorkspaceCreateIdempotencyFileStore(),
                legacyDefaults: .standard,
                legacyPersistenceKey: Self.legacyPersistenceKey
            )
        }

        init(
            capacity: Int,
            persistence: any WorkspaceCreateIdempotencyPersisting,
            legacyDefaults: UserDefaults? = nil,
            legacyPersistenceKey: String? = nil
        ) {
            precondition(capacity > 0)
            self.capacity = capacity
            self.persistence = persistence
            self.legacyDefaults = legacyDefaults
            self.legacyPersistenceKey = legacyPersistenceKey

            let loaded: [UUID]
            do {
                loaded = try persistence.loadOperationIDs()
            } catch {
                loaded = []
                loadFailure = error
            }

            var retained = Self.uniqueSuffix(loaded, capacity: capacity)
            if let legacyDefaults, let legacyPersistenceKey {
                let legacy = (legacyDefaults.stringArray(forKey: legacyPersistenceKey) ?? [])
                    .compactMap(UUID.init(uuidString:))
                let merged = Self.uniqueSuffix(retained + legacy, capacity: capacity)
                if merged != retained, loadFailure == nil {
                    do {
                        try persistence.saveOperationIDs(merged)
                        legacyDefaults.removeObject(forKey: legacyPersistenceKey)
                    } catch {
                        // Keep the legacy copy until a later accepted operation
                        // successfully commits the merged snapshot.
                        workspaceCreateIdempotencyLogger.error(
                            "Legacy tombstone migration deferred: \(String(describing: error), privacy: .private)"
                        )
                    }
                }
                retained = merged
            }

            insertionOrder = retained
            completedOperationIDs = Set(retained)
        }

        /// Compatibility seam for tests that need to observe or reject writes.
        /// Production uses the crash-durable file store above.
        convenience init(
            capacity: Int,
            defaults: UserDefaults,
            persistenceKey: String
        ) {
            self.init(
                capacity: capacity,
                persistence: WorkspaceCreateIdempotencyDefaultsStore(
                    defaults: defaults,
                    persistenceKey: persistenceKey
                )
            )
        }

        func workspaceID(for operationID: UUID) -> UUID? {
            workspaceIDs[operationID]
        }

        func containsCompletedOperation(_ operationID: UUID) -> Bool {
            completedOperationIDs.contains(operationID)
        }

        /// Persists an accepted operation before workspace startup can execute.
        /// Memory changes only after the durable transaction commits.
        func accept(operationID: UUID) throws {
            guard !completedOperationIDs.contains(operationID) else { return }
            if let loadFailure { throw loadFailure }

            var nextOrder = insertionOrder
            if nextOrder.count == capacity {
                nextOrder.removeFirst()
            }
            nextOrder.append(operationID)
            try persistence.saveOperationIDs(nextOrder)
            if let legacyDefaults, let legacyPersistenceKey {
                legacyDefaults.removeObject(forKey: legacyPersistenceKey)
            }
            commitInMemory(nextOrder)
        }

        /// Associates a live workspace after construction. This mapping is an
        /// in-memory convenience; durable acceptance remains authoritative.
        func associate(operationID: UUID, workspaceID: UUID) {
            workspaceIDs[operationID] = workspaceID
        }

        /// Session restore may discover a live operation created by an older
        /// build. If its durable upgrade fails, retain an in-memory tombstone
        /// so this process still fails closed after that workspace closes.
        func record(operationID: UUID, workspaceID: UUID) {
            associate(operationID: operationID, workspaceID: workspaceID)
            do {
                try accept(operationID: operationID)
            } catch {
                workspaceCreateIdempotencyLogger.error(
                    "Restored task tombstone is memory-only: \(String(describing: error), privacy: .private)"
                )
                var nextOrder = insertionOrder.filter { $0 != operationID }
                if nextOrder.count == capacity {
                    nextOrder.removeFirst()
                }
                nextOrder.append(operationID)
                commitInMemory(nextOrder)
            }
        }

        private func commitInMemory(_ nextOrder: [UUID]) {
            let evictedIDs = completedOperationIDs.subtracting(nextOrder)
            for evictedID in evictedIDs {
                workspaceIDs.removeValue(forKey: evictedID)
            }
            insertionOrder = nextOrder
            completedOperationIDs = Set(nextOrder)
        }

        private static func uniqueSuffix(_ operationIDs: [UUID], capacity: Int) -> [UUID] {
            var seen: Set<UUID> = []
            let uniqueReversed = operationIDs.reversed().filter { seen.insert($0).inserted }
            return Array(uniqueReversed.prefix(capacity).reversed())
        }
    }
}
