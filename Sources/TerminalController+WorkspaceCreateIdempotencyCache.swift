import Foundation

extension TerminalController {
    /// Bounded durable tombstones and live workspace IDs for idempotent creates.
    final class WorkspaceCreateIdempotencyCache {
        private let capacity: Int
        private let defaults: UserDefaults
        private let persistenceKey: String
        private var workspaceIDs: [UUID: UUID] = [:]
        private var completedOperationIDs: Set<UUID> = []
        private var insertionOrder: [UUID] = []

        init(
            capacity: Int,
            defaults: UserDefaults = .standard,
            persistenceKey: String = "cmux.workspaceCreate.completedOperationIDs.v1"
        ) {
            precondition(capacity > 0)
            self.capacity = capacity
            self.defaults = defaults
            self.persistenceKey = persistenceKey
            let persisted = defaults.stringArray(forKey: persistenceKey) ?? []
            let retained = persisted.compactMap(UUID.init(uuidString:)).suffix(capacity)
            insertionOrder = Array(retained)
            completedOperationIDs = Set(retained)
        }

        func workspaceID(for operationID: UUID) -> UUID? {
            workspaceIDs[operationID]
        }

        func containsCompletedOperation(_ operationID: UUID) -> Bool {
            completedOperationIDs.contains(operationID)
        }

        func record(operationID: UUID, workspaceID: UUID) {
            workspaceIDs[operationID] = workspaceID
            guard completedOperationIDs.insert(operationID).inserted else { return }
            if insertionOrder.count == capacity {
                let evictedID = insertionOrder.removeFirst()
                workspaceIDs.removeValue(forKey: evictedID)
                completedOperationIDs.remove(evictedID)
            }
            insertionOrder.append(operationID)
            defaults.set(insertionOrder.map(\.uuidString), forKey: persistenceKey)
        }
    }
}
