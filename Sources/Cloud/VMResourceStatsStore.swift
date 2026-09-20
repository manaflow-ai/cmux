import Foundation

/// Shared resource-state owner. Main-actor transitions keep resize acceptance and
/// snapshot presentation ordered without per-panel optimistic copies or timers.
@MainActor
final class VMResourceStatsStore {
    struct Request: Sendable {
        let machineID: String
        let revision: UUID
    }

    private struct Entry {
        var revision = UUID()
        var resizing = false
        var stats: VMStats?
    }

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) { self.now = now }

    var snapshot: [String: VMStats] { entries.compactMapValues(\.stats) }

    func beginRead(machineID: String) -> Request {
        var entry = entry(for: machineID)
        // New polls also fence older polls that are cancelled by a refresh.
        // A read during resize must not supersede the mutation's revision.
        if !entry.resizing {
            entry.revision = UUID()
            entries[machineID] = entry
        }
        return Request(machineID: machineID, revision: entry.revision)
    }

    @discardableResult
    func finishRead(_ request: Request, stats: VMStats?) -> VMStats {
        guard var entry = entries[request.machineID], entry.revision == request.revision,
              !entry.resizing else {
            return entries[request.machineID]?.stats ?? .unavailable(at: now())
        }
        entry.stats = stats ?? .unavailable(preservingCapacityFrom: entry.stats, at: now())
        entries[request.machineID] = entry
        notify()
        return entry.stats!
    }

    func beginResize(machineID: String) -> Request {
        var entry = entry(for: machineID)
        entry.revision = UUID()
        entry.resizing = true
        entry.stats = .unavailable(at: now())
        entries[machineID] = entry
        notify()
        return Request(machineID: machineID, revision: entry.revision)
    }

    func finishResize(_ request: Request, stats: VMStats?) {
        guard var entry = entries[request.machineID], entry.revision == request.revision else { return }
        // Also fence reads started while the resize was in progress.
        entry.revision = UUID()
        entry.resizing = false
        entry.stats = stats ?? .unavailable(at: now())
        entries[request.machineID] = entry
        notify()
    }

    /// The fleet is authoritative for retention; removed machines cannot reappear
    /// when an outstanding request completes. The hard bound also covers CLI-only reads.
    func retain(machineIDs: Set<String>) {
        entries = entries.filter { machineIDs.contains($0.key) }
        insertionOrder.removeAll { !machineIDs.contains($0) }
        notify()
    }

    func reset() {
        entries.removeAll()
        insertionOrder.removeAll()
        notify()
    }

    /// Changes are wakeups; consumers read the current snapshot after each yield
    /// so a delayed delivery can never reapply an older snapshot.
    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.observers.removeValue(forKey: id) }
            }
        }
    }

    private func entry(for id: String) -> Entry {
        if let existing = entries[id] { return existing }
        if insertionOrder.count >= 256 { entries.removeValue(forKey: insertionOrder.removeFirst()) }
        let entry = Entry()
        entries[id] = entry
        insertionOrder.append(id)
        return entry
    }

    private func notify() {
        for observer in observers.values { observer.yield(()) }
    }
}
