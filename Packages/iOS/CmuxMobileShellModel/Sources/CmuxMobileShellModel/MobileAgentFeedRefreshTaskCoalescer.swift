import Foundation

/// Coalesces one in-flight Feed refresh per Mac and owns task cancellation.
@MainActor
public final class MobileAgentFeedRefreshTaskCoalescer {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
        var pending = false
        var operation: @MainActor @Sendable () async -> Void
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
        if var existing = entries[ownerKey] {
            existing.pending = true
            existing.operation = operation
            entries[ownerKey] = existing
            return existing.task
        }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain(ownerKey: ownerKey, token: token)
        }
        entries[ownerKey] = Entry(token: token, task: task, operation: operation)
        return task
    }

    private func drain(ownerKey: String, token: UUID) async {
        while let entry = entries[ownerKey], entry.token == token {
            await entry.operation()
            guard !Task.isCancelled,
                  var current = entries[ownerKey],
                  current.token == token else { break }
            if current.pending {
                current.pending = false
                entries[ownerKey] = current
            } else {
                entries[ownerKey] = nil
            }
        }
        if entries[ownerKey]?.token == token { entries[ownerKey] = nil }
    }

    /// Cancels and releases every owned refresh task.
    public func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries = [:]
    }

    public func cancel(ownerKey: String) {
        entries.removeValue(forKey: ownerKey)?.task.cancel()
    }
}
