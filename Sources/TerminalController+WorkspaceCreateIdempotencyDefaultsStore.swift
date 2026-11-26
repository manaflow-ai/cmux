import Foundation

extension TerminalController {
    final class WorkspaceCreateIdempotencyDefaultsStore: WorkspaceCreateIdempotencyPersisting, @unchecked Sendable {
        private enum StoreError: Error {
            case writeRejected
        }

        private let defaults: UserDefaults
        private let persistenceKey: String

        init(defaults: UserDefaults, persistenceKey: String) {
            self.defaults = defaults
            self.persistenceKey = persistenceKey
        }

        func loadOperationIDs() -> [UUID] {
            (defaults.stringArray(forKey: persistenceKey) ?? []).compactMap(UUID.init(uuidString:))
        }

        func saveOperationIDs(_ operationIDs: [UUID]) throws {
            let rawIDs = operationIDs.map(\.uuidString)
            defaults.set(rawIDs, forKey: persistenceKey)
            guard defaults.stringArray(forKey: persistenceKey) == rawIDs else {
                throw StoreError.writeRejected
            }
        }
    }
}
