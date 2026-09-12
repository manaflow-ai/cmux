import Foundation

/// Orders accepted credential mutations while keeping storage work off the UI actor.
///
/// Writes and invalidations for one identity run in enqueue order. Different
/// identities remain independent. Callers provide a concurrent storage boundary;
/// this type owns only pending request state and never performs synchronous I/O.
@MainActor
public final class CredentialPersistenceQueue {
    private var pending: [String: (id: UUID, task: Task<Bool, Never>)] = [:]
    private var failedKeys: Set<String> = []

    /// Creates an empty mutation queue owned by one transport composition root.
    public init() {}

    /// Whether an identity has a mutation whose authoritative result is pending.
    ///
    /// - Parameter key: The identity whose persisted state is being queried.
    /// - Returns: True until every accepted mutation for this identity completes.
    public func hasPending(key: String) -> Bool { pending[key] != nil }

    /// Whether protected storage can be treated as the authoritative current value.
    ///
    /// A failed mutation blocks reads until a later mutation succeeds, so a
    /// refused deletion never makes the old credential appear valid again.
    ///
    /// - Parameter key: The identity whose persisted state is being queried.
    /// - Returns: False during a mutation or after its latest failure.
    public func permitsRead(key: String) -> Bool {
        pending[key] == nil && !failedKeys.contains(key)
    }

    /// Enqueues a mutation without blocking the calling actor on storage I/O.
    ///
    /// Accepted mutations finish even if the task awaiting their result is
    /// cancelled, so a later invalidation cannot be overtaken by an older write.
    ///
    /// - Parameters:
    ///   - key: Identity used to order related writes and invalidations.
    ///   - operation: An async storage operation with its own concurrent boundary.
    /// - Returns: An owned task whose result indicates whether persistence succeeded.
    @discardableResult
    public func enqueue(
        key: String, operation: @escaping @Sendable () async -> Bool
    ) -> Task<Bool, Never> {
        let previous = pending[key]?.task
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            let result = await operation()
            if let self, self.pending[key]?.id == id {
                if result { self.failedKeys.remove(key) } else { self.failedKeys.insert(key) }
                self.pending.removeValue(forKey: key)
            }
            return result
        }
        pending[key] = (id, task)
        return task
    }
}
