import Foundation

/// Owns route replacements independently of the obsolete mirrors they tear down.
@MainActor
public final class HiveMirrorRebindCoordinator<Key: Hashable & Sendable> {
    private struct Entry {
        let requestID: UUID
        let task: Task<Void, Never>
    }
    private var entries: [Key: Entry] = [:]

    /// Creates an empty route-replacement owner.
    public init() {}

    /// Starts one owned replacement, cancelling any older replacement for that key.
    /// - Parameters:
    ///   - key: The device/window identity whose mirror is being replaced.
    ///   - operation: Cancellation-aware teardown and reattachment work.
    /// - Returns: The replacement task, independent of its obsolete route observer.
    @discardableResult
    public func rebind(
        key: Key,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        cancel(key: key)
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.finish(key: key, requestID: requestID) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        entries[key] = Entry(requestID: requestID, task: task)
        return task
    }

    /// Cancels the pending replacement for one device/window identity.
    /// - Parameter key: The identity being detached or closed.
    public func cancel(key: Key) {
        entries.removeValue(forKey: key)?.task.cancel()
    }

    /// Cancels matching replacements, including ones between old and new mirrors.
    /// - Parameter predicate: Selects a device's windows, or all entries when omitted.
    public func cancelAll(matching predicate: (Key) -> Bool = { _ in true }) {
        for key in entries.keys.filter(predicate) { cancel(key: key) }
    }

    private func finish(key: Key, requestID: UUID) {
        guard entries[key]?.requestID == requestID else { return }
        entries.removeValue(forKey: key)
    }
}
