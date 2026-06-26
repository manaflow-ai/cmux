import Foundation

/// Serializes recently-closed-history persistence for the ``ClosedItemHistoryStore``
/// that owns it, ordering asynchronous saves per file path so a stale revision can
/// never overwrite a newer one.
///
/// De-singletonized from the former process-wide `static let shared` (CONVENTIONS §5
/// `static let shared` → construct-and-inject): the store constructs and holds one
/// instance, injected through its initializer, so the per-path revision-ordering
/// state is scoped to the store that owns the history file rather than shared across
/// the whole process.
actor ClosedItemHistoryPersistenceActor {
    private var latestRevisionByPath: [String: UInt64] = [:]

    func load(fileURL: URL) -> [ClosedItemHistoryRecord] {
        ClosedItemHistoryStore.loadRecords(fileURL: fileURL)
    }

    func save(_ records: [ClosedItemHistoryRecord], fileURL: URL, revision: UInt64) {
        let path = fileURL.standardizedFileURL.path
        if let latestRevision = latestRevisionByPath[path], revision < latestRevision {
            return
        }
        latestRevisionByPath[path] = revision
        ClosedItemHistoryStore.saveRecords(records, fileURL: fileURL)
    }
}
