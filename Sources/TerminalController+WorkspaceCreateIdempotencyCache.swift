import Foundation
import OSLog

extension TerminalController {
    /// Bounded durable tombstones and live workspace IDs for idempotent creates.
    final class WorkspaceCreateIdempotencyCache {
        private struct AcceptanceRollbackEntry {
            let operationID: UUID
            let workspaceID: UUID?
            let chronology: UInt64
        }

        private struct AcceptanceReleasePlan {
            let nextOrder: [UUID]
            let restoredEntries: [AcceptanceRollbackEntry]
            let remainingEntries: [AcceptanceRollbackEntry]
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
        private var unassociatedReservationIDs: Set<UUID> = []
        private var rollbackChainsByOperationID: [UUID: [AcceptanceRollbackEntry]] = [:]
        // Independent reservations can be released in any order. Stable keys
        // merge their restored tombstones back into the original FIFO order.
        private var chronologyByOperationID: [UUID: UInt64] = [:]
        private var nextChronology: UInt64 = 0

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
            resetChronology(to: retained)
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
            guard !unassociatedReservationIDs.contains(operationID) else {
                throw WorkspaceCreateIdempotencyCacheError.mutationInProgress
            }
            guard pendingMutation == nil else {
                throw WorkspaceCreateIdempotencyCacheError.mutationInProgress
            }
            try retryInitialLoadSynchronouslyIfNeeded()

            let nextOrder = orderByAppending(operationID)
            let rollbackChain = rollbackChain(for: nextOrder)
            try persistence.saveOperationIDs(nextOrder)
            commitNewAcceptance(
                operationID: operationID,
                nextOrder: nextOrder,
                rollbackChain: rollbackChain,
                tracksUnassociatedReservation: false
            )
        }

        /// Persists on a serial background actor while the caller awaits. The
        /// main actor remains available for UI and later RPCs, and concurrent
        /// accepts are ordered from the last committed snapshot.
        func acceptAsynchronously(operationID: UUID) async throws -> Bool {
            await drainPendingMutation()
            guard !completedOperationIDs.contains(operationID),
                  !unassociatedReservationIDs.contains(operationID) else {
                return false
            }

            return try await runAsPendingMutation { cache in
                try await cache.retryInitialLoadAsynchronouslyIfNeeded()
                guard !cache.completedOperationIDs.contains(operationID),
                      !cache.unassociatedReservationIDs.contains(operationID) else {
                    return false
                }
                while true {
                    let expectedRevision = cache.stateRevision
                    let nextOrder = cache.orderByAppending(operationID)
                    let rollbackChain = cache.rollbackChain(for: nextOrder)
                    try await cache.persistenceWriter.saveOperationIDs(nextOrder)
                    // Session restore can add an in-memory tombstone while this
                    // actor is suspended on I/O. Rebuild from that newer state
                    // and save again so the completed write cannot erase it.
                    guard cache.stateRevision == expectedRevision else { continue }
                    cache.commitNewAcceptance(
                        operationID: operationID,
                        nextOrder: nextOrder,
                        rollbackChain: rollbackChain,
                        tracksUnassociatedReservation: true
                    )
                    return true
                }
            }
        }

        /// Removes a durable acceptance only while it remains unassociated
        /// with a live workspace, allowing a pre-start failure to be retried.
        func releaseUnassociatedAcceptanceAsynchronously(operationID: UUID) async throws -> Bool {
            await drainPendingMutation()
            guard unassociatedReservationIDs.contains(operationID),
                  workspaceIDs[operationID] == nil else {
                return false
            }

            return try await runAsPendingMutation { cache in
                var persistedRemoval = false
                while true {
                    guard cache.unassociatedReservationIDs.contains(operationID),
                          cache.workspaceIDs[operationID] == nil else {
                        if persistedRemoval {
                            try await cache.persistCurrentOrderUntilStable()
                        }
                        return false
                    }

                    let expectedRevision = cache.stateRevision
                    let releasePlan = cache.releasePlan(
                        operationID: operationID,
                        rollbackChain: cache.rollbackChainsByOperationID[operationID] ?? []
                    )
                    try await cache.persistenceWriter.saveOperationIDs(releasePlan.nextOrder)
                    persistedRemoval = true
                    guard cache.stateRevision == expectedRevision,
                          cache.unassociatedReservationIDs.contains(operationID),
                          cache.workspaceIDs[operationID] == nil else {
                        continue
                    }
                    cache.commitRelease(operationID: operationID, plan: releasePlan)
                    return true
                }
            }
        }

        private func drainPendingMutation() async {
            while let pendingMutation {
                _ = try? await pendingMutation.task.value
                if self.pendingMutation?.id == pendingMutation.id {
                    self.pendingMutation = nil
                }
            }
        }

        private func runAsPendingMutation(
            _ mutation: @escaping @MainActor (WorkspaceCreateIdempotencyCache) async throws -> Bool
        ) async throws -> Bool {
            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                return try await mutation(self)
            }
            let pendingID = UUID()
            pendingMutation = (pendingID, task)
            defer {
                if pendingMutation?.id == pendingID {
                    pendingMutation = nil
                }
            }
            return try await task.value
        }

        /// Associates a live workspace after construction. This mapping is an
        /// in-memory convenience; durable acceptance remains authoritative.
        func associate(operationID: UUID, workspaceID: UUID) {
            let removedReservation = unassociatedReservationIDs.remove(operationID) != nil
            let removedRollbackChain = rollbackChainsByOperationID.removeValue(forKey: operationID) != nil
            guard workspaceIDs[operationID] != workspaceID
                    || removedReservation
                    || removedRollbackChain else {
                return
            }
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
            restoring rollbackEntries: [AcceptanceRollbackEntry] = []
        ) {
            let evictedIDs = completedOperationIDs.subtracting(nextOrder)
            for evictedID in evictedIDs {
                workspaceIDs.removeValue(forKey: evictedID)
                chronologyByOperationID.removeValue(forKey: evictedID)
                if !unassociatedReservationIDs.contains(evictedID) {
                    rollbackChainsByOperationID.removeValue(forKey: evictedID)
                }
            }
            for rollbackEntry in rollbackEntries {
                chronologyByOperationID[rollbackEntry.operationID] = rollbackEntry.chronology
            }
            for operationID in nextOrder where chronologyByOperationID[operationID] == nil {
                chronologyByOperationID[operationID] = issueChronology()
            }
            insertionOrder = nextOrder
            completedOperationIDs = Set(nextOrder)
            for rollbackEntry in rollbackEntries {
                if let workspaceID = rollbackEntry.workspaceID,
                   workspaceIDs[rollbackEntry.operationID] == nil {
                    workspaceIDs[rollbackEntry.operationID] = workspaceID
                }
            }
            stateRevision &+= 1
        }

        private func orderByAppending(_ operationID: UUID) -> [UUID] {
            var nextOrder = insertionOrder.filter { $0 != operationID }
            if nextOrder.count == capacity { nextOrder.removeFirst() }
            nextOrder.append(operationID)
            return nextOrder
        }

        private func rollbackChain(for nextOrder: [UUID]) -> [AcceptanceRollbackEntry] {
            guard let evictedOperationID = insertionOrder.first(where: {
                !nextOrder.contains($0)
            }) else {
                return []
            }
            let evictedEntry = AcceptanceRollbackEntry(
                operationID: evictedOperationID,
                workspaceID: workspaceIDs[evictedOperationID],
                chronology: chronology(for: evictedOperationID)
            )
            guard unassociatedReservationIDs.contains(evictedOperationID) else {
                return [evictedEntry]
            }
            return [evictedEntry] + (rollbackChainsByOperationID[evictedOperationID] ?? [])
        }

        private func releasePlan(
            operationID: UUID,
            rollbackChain: [AcceptanceRollbackEntry]
        ) -> AcceptanceReleasePlan {
            var nextOrder = insertionOrder.filter { $0 != operationID }
            var seenOperationIDs = Set(nextOrder)
            seenOperationIDs.insert(operationID)
            let eligibleEntries = rollbackChain.filter {
                seenOperationIDs.insert($0.operationID).inserted
            }
            let restoreCount = min(capacity - nextOrder.count, eligibleEntries.count)
            let restoredEntries = Array(eligibleEntries.prefix(restoreCount))
            var orderedEntries = nextOrder.map { operationID in
                (
                    operationID: operationID,
                    chronology: chronology(for: operationID)
                )
            }
            orderedEntries.append(contentsOf: restoredEntries.map {
                (operationID: $0.operationID, chronology: $0.chronology)
            })
            orderedEntries.sort { lhs, rhs in
                if lhs.chronology != rhs.chronology {
                    return lhs.chronology < rhs.chronology
                }
                return lhs.operationID.uuidString < rhs.operationID.uuidString
            }
            nextOrder = orderedEntries.map(\.operationID)
            return AcceptanceReleasePlan(
                nextOrder: nextOrder,
                restoredEntries: restoredEntries,
                remainingEntries: Array(eligibleEntries.dropFirst(restoreCount))
            )
        }

        private func commitNewAcceptance(
            operationID: UUID,
            nextOrder: [UUID],
            rollbackChain: [AcceptanceRollbackEntry],
            tracksUnassociatedReservation: Bool
        ) {
            commitAcceptedOrder(nextOrder)
            guard tracksUnassociatedReservation,
                  workspaceIDs[operationID] == nil else {
                return
            }
            unassociatedReservationIDs.insert(operationID)
            if rollbackChain.isEmpty {
                rollbackChainsByOperationID.removeValue(forKey: operationID)
            } else {
                rollbackChainsByOperationID[operationID] = rollbackChain
            }
        }

        private func commitRelease(
            operationID: UUID,
            plan: AcceptanceReleasePlan
        ) {
            unassociatedReservationIDs.remove(operationID)
            rollbackChainsByOperationID.removeValue(forKey: operationID)
            for reservationID in Array(rollbackChainsByOperationID.keys) {
                let pruned = rollbackChainsByOperationID[reservationID]?.filter {
                    $0.operationID != operationID
                } ?? []
                if pruned.isEmpty {
                    rollbackChainsByOperationID.removeValue(forKey: reservationID)
                } else {
                    rollbackChainsByOperationID[reservationID] = pruned
                }
            }

            commitAcceptedOrder(plan.nextOrder, restoring: plan.restoredEntries)
            guard let restoredReservationID = plan.restoredEntries.first?.operationID,
                  unassociatedReservationIDs.contains(restoredReservationID) else {
                return
            }
            if plan.remainingEntries.isEmpty {
                rollbackChainsByOperationID.removeValue(forKey: restoredReservationID)
            } else {
                rollbackChainsByOperationID[restoredReservationID] = plan.remainingEntries
            }
        }

        private func commitAcceptedOrder(
            _ nextOrder: [UUID],
            restoring rollbackEntries: [AcceptanceRollbackEntry] = []
        ) {
            if let legacyDefaults, let legacyPersistenceKey {
                legacyDefaults.removeObject(forKey: legacyPersistenceKey)
            }
            commitInMemory(nextOrder, restoring: rollbackEntries)
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
                guard stateRevision == expectedRevision else { continue }
                return
            }
        }

        private func reconcileReloadedOperationIDs(_ loaded: [UUID]) {
            let retained = Self.uniqueSuffix(loaded + insertionOrder, capacity: capacity)
            resetChronology(to: retained)
            commitInMemory(retained)
            loadFailure = nil
        }

        private func chronology(for operationID: UUID) -> UInt64 {
            guard let chronology = chronologyByOperationID[operationID] else {
                preconditionFailure("Accepted operation is missing its chronology")
            }
            return chronology
        }

        private func issueChronology() -> UInt64 {
            defer { nextChronology &+= 1 }
            return nextChronology
        }

        private func resetChronology(to operationIDs: [UUID]) {
            chronologyByOperationID.removeAll(keepingCapacity: true)
            nextChronology = 0
            for operationID in operationIDs {
                chronologyByOperationID[operationID] = issueChronology()
            }
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
