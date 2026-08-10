import Foundation

/// Coalesces one in-flight Feed refresh per Mac and owns task cancellation.
@MainActor
public final class MobileAgentFeedRefreshTaskCoalescer {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]

    /// Creates an empty task owner.
    public init() {}

    /// Number of currently owned refresh tasks.
    public var activeCount: Int { entries.count }

    /// Starts a refresh unless one already exists for `ownerKey`.
    @discardableResult
    public func schedule(
        ownerKey: String,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        if let existing = entries[ownerKey] { return existing.task }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            guard self?.entries[ownerKey]?.token == token else { return }
            self?.entries[ownerKey] = nil
        }
        entries[ownerKey] = Entry(token: token, task: task)
        return task
    }

    /// Cancels and releases every owned refresh task.
    public func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries = [:]
    }
}
