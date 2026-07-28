import Foundation
import OSLog

extension TerminalController {
    /// Bounded durable tombstones and live workspace IDs for idempotent creates.
    final class WorkspaceCreateIdempotencyCache {
        private struct AcceptanceRollbackEntry {
            let operationID: UUID
            let workspaceID: UUID?
        }

        private static let legacyPersistenceKey = "cmux.workspaceCreate.completedOperationIDs.v1"

        private let capacity: Int
        private let persistence: any WorkspaceCreateIdempotencyPersisting
        private let persistenceWriter: WorkspaceCreateIdempotencyPersistenceWriter
        private let legacyDefaults: UserDefaults?
        private let legacyPersistenceKey: String?
        private var loadFailure: (any Error)?
        private var workspaceIDs: [UUID: UUID] = [:]
        private var completedOperationIDs: Set<UUID> = []
        private var insertionOrder: [UUID] = []
        private var stateRevision: UInt64 = 0
        private var pendingMutation: (id: UUID, task: Task<Bool, any Error>)?
        private var rollbackEntriesByOperationID: [UUID: AcceptanceRollbackEntry] = [:]

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
            persistenceWriter = WorkspaceCreateIdempotencyPersistenceWriter(persistence: persistence)
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
            guard pendingMutation == nil else {
                throw WorkspaceCreateIdempotencyCacheError.mutationInProgress
            }
            try retryInitialLoadSynchronouslyIfNeeded()

            let nextOrder = orderByAppending(operationID)
            let rollbackEntry = rollbackEntry(for: nextOrder)
            try persistence.saveOperationIDs(nextOrder)
            commitNewAcceptance(
                operationID: operationID,
                nextOrder: nextOrder,
                rollbackEntry: rollbackEntry
            )
        }

        /// Persists on a serial background actor while the caller awaits. The
        /// main actor remains available for UI and later RPCs, and concurrent
        /// accepts are ordered from the last committed snapshot.
        func acceptAsynchronously(operationID: UUID) async throws -> Bool {
            while let pendingMutation {
                _ = try? await pendingMutation.task.value
                if self.pendingMutation?.id == pendingMutation.id {
                    self.pendingMutation = nil
                }
            }
            guard !completedOperationIDs.contains(operationID) else { return false }

            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                try await retryInitialLoadAsynchronouslyIfNeeded()
                guard !completedOperationIDs.contains(operationID) else { return false }
                while true {
                    let expectedRevision = stateRevision
                    let nextOrder = orderByAppending(operationID)
                    let rollbackEntry = rollbackEntry(for: nextOrder)
                    try await persistenceWriter.saveOperationIDs(nextOrder)
                    guard stateRevision != expectedRevision else {
                        commitNewAcceptance(
                            operationID: operationID,
                            nextOrder: nextOrder,
                            rollbackEntry: rollbackEntry
                        )
                        return true
                    }
                    // Session restore can add an in-memory tombstone while this
                    // actor is suspended on I/O. Rebuild from that newer state
                    // and save again so the completed write cannot erase it.
                }
            }
            let pendingID = UUID()
            pendingMutation = (pendingID, task)
            do {
                let accepted = try await task.value
                if pendingMutation?.id == pendingID { pendingMutation = nil }
                return accepted
            } catch {
                if pendingMutation?.id == pendingID { pendingMutation = nil }
                throw error
            }
        }

        /// Removes a durable acceptance only while it remains unassociated
        /// with a live workspace, allowing a pre-start failure to be retried.
        func releaseUnassociatedAcceptanceAsynchronously(operationID: UUID) async throws -> Bool {
            while let pendingMutation {
                _ = try? await pendingMutation.task.value
                if self.pendingMutation?.id == pendingMutation.id {
                    self.pendingMutation = nil
                }
            }
            guard completedOperationIDs.contains(operationID),
                  workspaceIDs[operationID] == nil else {
                return false
            }

            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                var persistedRemoval = false
                while true {
                    guard completedOperationIDs.contains(operationID),
                          workspaceIDs[operationID] == nil else {
                        if persistedRemoval {
                            try await persistCurrentOrderUntilStable()
                        }
                        return false
                    }

                    let expectedRevision = stateRevision
                    let rollbackEntry = rollbackEntriesByOperationID[operationID]
                    let nextOrder = orderByReleasing(
                        operationID,
                        rollbackEntry: rollbackEntry
                    )
                    try await persistenceWriter.saveOperationIDs(nextOrder)
                    persistedRemoval = true
                    guard stateRevision == expectedRevision,
                          completedOperationIDs.contains(operationID),
                          workspaceIDs[operationID] == nil else {
                        continue
                    }
                    commitAcceptedOrder(nextOrder, restoring: rollbackEntry)
                    return true
                }
            }
            let pendingID = UUID()
            pendingMutation = (pendingID, task)
            do {
                let released = try await task.value
                if pendingMutation?.id == pendingID { pendingMutation = nil }
                return released
            } catch {
                if pendingMutation?.id == pendingID { pendingMutation = nil }
                throw error
            }
        }

        /// Associates a live workspace after construction. This mapping is an
        /// in-memory convenience; durable acceptance remains authoritative.
        func associate(operationID: UUID, workspaceID: UUID) {
            let removedRollbackEntry = rollbackEntriesByOperationID.removeValue(
                forKey: operationID
            ) != nil
            guard workspaceIDs[operationID] != workspaceID || removedRollbackEntry else { return }
            workspaceIDs[operationID] = workspaceID
            stateRevision &+= 1
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
                commitInMemory(orderByAppending(operationID))
            }
        }

        private func commitInMemory(
            _ nextOrder: [UUID],
            restoring rollbackEntry: AcceptanceRollbackEntry? = nil
        ) {
            let evictedIDs = completedOperationIDs.subtracting(nextOrder)
            for evictedID in evictedIDs {
                workspaceIDs.removeValue(forKey: evictedID)
                rollbackEntriesByOperationID.removeValue(forKey: evictedID)
            }
            insertionOrder = nextOrder
            completedOperationIDs = Set(nextOrder)
            if let rollbackEntry,
               let workspaceID = rollbackEntry.workspaceID,
               workspaceIDs[rollbackEntry.operationID] == nil {
                workspaceIDs[rollbackEntry.operationID] = workspaceID
            }
            stateRevision &+= 1
        }

        private func orderByAppending(_ operationID: UUID) -> [UUID] {
            var nextOrder = insertionOrder.filter { $0 != operationID }
            if nextOrder.count == capacity { nextOrder.removeFirst() }
            nextOrder.append(operationID)
            return nextOrder
        }

        private func rollbackEntry(for nextOrder: [UUID]) -> AcceptanceRollbackEntry? {
            guard let evictedOperationID = insertionOrder.first(where: {
                !nextOrder.contains($0)
            }) else {
                return nil
            }
            return AcceptanceRollbackEntry(
                operationID: evictedOperationID,
                workspaceID: workspaceIDs[evictedOperationID]
            )
        }

        private func orderByReleasing(
            _ operationID: UUID,
            rollbackEntry: AcceptanceRollbackEntry?
        ) -> [UUID] {
            var nextOrder = insertionOrder.filter { $0 != operationID }
            if let rollbackEntry,
               !nextOrder.contains(rollbackEntry.operationID) {
                nextOrder.insert(rollbackEntry.operationID, at: 0)
            }
            return nextOrder
        }

        private func commitNewAcceptance(
            operationID: UUID,
            nextOrder: [UUID],
            rollbackEntry: AcceptanceRollbackEntry?
        ) {
            commitAcceptedOrder(nextOrder)
            if workspaceIDs[operationID] == nil {
                rollbackEntriesByOperationID[operationID] = rollbackEntry
            }
        }

        private func commitAcceptedOrder(
            _ nextOrder: [UUID],
            restoring rollbackEntry: AcceptanceRollbackEntry? = nil
        ) {
            if let legacyDefaults, let legacyPersistenceKey {
                legacyDefaults.removeObject(forKey: legacyPersistenceKey)
            }
            commitInMemory(nextOrder, restoring: rollbackEntry)
        }

        private func retryInitialLoadSynchronouslyIfNeeded() throws {
            guard loadFailure != nil else { return }
            let loaded = try persistence.loadOperationIDs()
            reconcileReloadedOperationIDs(loaded)
        }

        private func retryInitialLoadAsynchronouslyIfNeeded() async throws {
            guard loadFailure != nil else { return }
            let loaded = try await persistenceWriter.loadOperationIDs()
            reconcileReloadedOperationIDs(loaded)
        }

        private func persistCurrentOrderUntilStable() async throws {
            while true {
                let expectedRevision = stateRevision
                let currentOrder = insertionOrder
                try await persistenceWriter.saveOperationIDs(currentOrder)
                guard stateRevision != expectedRevision else { return }
            }
        }

        private func reconcileReloadedOperationIDs(_ loaded: [UUID]) {
            let retained = Self.uniqueSuffix(loaded + insertionOrder, capacity: capacity)
            commitInMemory(retained)
            loadFailure = nil
        }

        private static func uniqueSuffix(_ operationIDs: [UUID], capacity: Int) -> [UUID] {
            var seen: Set<UUID> = []
            let uniqueReversed = operationIDs.reversed().filter { seen.insert($0).inserted }
            return Array(uniqueReversed.prefix(capacity).reversed())
        }
    }
}

private enum WorkspaceCreateIdempotencyCacheError: Error {
    case mutationInProgress
}

private actor WorkspaceCreateIdempotencyPersistenceWriter {
    private let persistence: any TerminalController.WorkspaceCreateIdempotencyPersisting

    init(persistence: any TerminalController.WorkspaceCreateIdempotencyPersisting) {
        self.persistence = persistence
    }

    func loadOperationIDs() throws -> [UUID] {
        try persistence.loadOperationIDs()
    }

    func saveOperationIDs(_ operationIDs: [UUID]) throws {
        try persistence.saveOperationIDs(operationIDs)
    }
}
