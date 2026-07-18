public import Foundation

extension CmuxAgentSessionRegistry {
    /// A synchronous, transaction-scoped view used to restore many indexed
    /// hibernated rows without reopening SQLite for every panel.
    public final class RecordRebindBatch {
        let registry: CmuxAgentSessionRegistry
        var database: OpaquePointer?

        init(registry: CmuxAgentSessionRegistry, database: OpaquePointer) {
            self.registry = registry
            self.database = database
        }

        func invalidate() {
            database = nil
        }

        /// Returns the session that owns an active slot inside this batch's transaction.
        ///
        /// - Parameters:
        ///   - provider: The provider namespace containing the slot.
        ///   - key: The workspace or surface slot to inspect.
        /// - Returns: The owning session identifier, or `nil` when the slot is unoccupied.
        public func activeSlotSessionID(
            provider: String,
            key: ActiveSlotKey
        ) throws -> String? {
            guard let database else { throw CocoaError(.fileReadUnknown) }
            return try registry.readSlot(
                database: database,
                provider: provider,
                scope: key.scope,
                scopeID: key.scopeID
            )?.sessionID
        }

        /// Rebinds one record and its active slots atomically in this batch's transaction.
        ///
        /// - Parameters:
        ///   - provider: The provider namespace containing the record.
        ///   - sessionID: The durable session identifier to rebind.
        ///   - updatedAt: The timestamp written to the record and active slots.
        ///   - previousSlots: Slots that may be removed when owned by `sessionID`.
        ///   - activeSlots: Slots the rebound session must own after the mutation.
        ///   - requireExistingActiveSlots: Whether every active slot must already be owned by `sessionID`.
        ///   - monotonicUpdatedAt: Whether the write must preserve the greatest timestamp already owned by the record or slots.
        ///   - shouldMutate: A predicate that validates the current record before mutation.
        ///   - mutate: The record mutation applied after ownership validation.
        /// - Returns: Whether the record was patched, missing, or rejected.
        public func patchRecordRebindingActiveSlots(
            provider: String,
            sessionID: String,
            updatedAt: TimeInterval,
            previousSlots: [ActiveSlotKey],
            activeSlots: [ActiveSlotKey],
            requireExistingActiveSlots: Bool = false,
            monotonicUpdatedAt: Bool = false,
            shouldMutate: ([String: Any]) -> Bool = { _ in true },
            mutate: (inout [String: Any]) -> Void
        ) throws -> RecordRebindResult {
            guard let database else { throw CocoaError(.fileReadUnknown) }
            return try registry.patchRecordRebindingActiveSlots(
                database: database,
                provider: provider,
                sessionID: sessionID,
                updatedAt: updatedAt,
                previousSlots: previousSlots,
                activeSlots: activeSlots,
                requireExistingActiveSlots: requireExistingActiveSlots,
                monotonicUpdatedAt: monotonicUpdatedAt,
                shouldMutate: shouldMutate,
                mutate: mutate
            )
        }
    }
}
