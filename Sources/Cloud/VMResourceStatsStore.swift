import Foundation

/// Shared resource-state owner. Main-actor transitions keep resize acceptance and
/// snapshot presentation ordered without per-panel optimistic copies or timers.
@MainActor
final class VMResourceStatsStore {
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var observers: [UUID: VMResourceStatsSubscription] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) { self.now = now }

    var snapshot: [String: VMStats] { entries.compactMapValues(\.stats) }

    func stats(for machineID: String) -> VMStats? { entries[machineID]?.stats }

    func beginRead(machineID: String) -> Request {
        var entry = entry(for: machineID)
        entry.readSequence &+= 1
        entries[machineID] = entry
        return Request(machineID: machineID, revision: entry.revision, sequence: entry.readSequence)
    }

    @discardableResult
    func finishRead(_ request: Request, stats: VMStats?) -> VMStats {
        guard var entry = entries[request.machineID], entry.revision == request.revision,
              !entry.resizing else {
            return entries[request.machineID]?.stats ?? .unavailable(at: now())
        }
        // Failed newer attempts are not newer observations. Keep an older
        // in-flight success eligible until a newer success has been accepted.
        if let stats, request.sequence >= entry.acceptedSequence {
            entry.stats = stats
            entry.acceptedSequence = request.sequence
        } else if stats == nil, request.sequence == entry.readSequence,
                  request.sequence >= entry.acceptedSequence {
            entry.stats = .unavailable(preservingCapacityFrom: entry.stats, at: now())
        } else {
            return entry.stats ?? .unavailable(at: now())
        }
        entries[request.machineID] = entry
        notify([request.machineID])
        return entry.stats!
    }

    func beginResize(machineID: String) -> Request {
        var entry = entry(for: machineID)
        entry.revision = UUID()
        entry.resizing = true
        entry.stats = .unavailable(at: now())
        entries[machineID] = entry
        notify([machineID])
        return Request(machineID: machineID, revision: entry.revision, sequence: entry.readSequence)
    }

    func finishResize(_ request: Request, stats: VMStats?) {
        guard var entry = entries[request.machineID], entry.revision == request.revision else { return }
        // Also fence reads started while the resize was in progress.
        entry.revision = UUID()
        entry.resizing = false
        entry.stats = stats ?? .unavailable(at: now())
        entries[request.machineID] = entry
        notify([request.machineID])
    }

    /// The fleet is authoritative for retention; removed machines cannot reappear
    /// when an outstanding request completes. The hard bound also covers CLI-only reads.
    func retain(machineIDs: Set<String>) {
        let removed = Set(entries.keys).subtracting(machineIDs)
        guard !removed.isEmpty else { return }
        entries = entries.filter { machineIDs.contains($0.key) }
        insertionOrder.removeAll { !machineIDs.contains($0) }
        notify(removed)
    }

    func reset() {
        let removed = Set(entries.keys)
        entries.removeAll()
        insertionOrder.removeAll()
        notify(removed)
    }

    /// Each subscriber coalesces affected IDs and reads current accepted values.
    func changes() -> VMResourceStatsSubscription {
        let id = UUID()
        let subscription = VMResourceStatsSubscription { [weak self] in
            Task { @MainActor [weak self] in self?.observers.removeValue(forKey: id) }
        }
        observers[id] = subscription
        return subscription
    }

    private func entry(for id: String) -> Entry {
        if let existing = entries[id] { return existing }
        if insertionOrder.count >= 256 {
            let removed = insertionOrder.removeFirst()
            entries.removeValue(forKey: removed)
            notify([removed])
        }
        let entry = Entry()
        entries[id] = entry
        insertionOrder.append(id)
        return entry
    }

    private func notify(_ machineIDs: Set<String>) {
        for observer in observers.values { observer.markChanged(machineIDs) }
    }
}
