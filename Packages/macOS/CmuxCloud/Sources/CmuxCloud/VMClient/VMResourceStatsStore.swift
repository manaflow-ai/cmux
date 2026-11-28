import Foundation

/// Shared resource-state owner. Main-actor transitions keep resize acceptance and
/// snapshot presentation ordered without per-panel optimistic copies or timers.
@MainActor
public final class VMResourceStatsStore {
    private var entries: [String: Entry] = [:]
    private var fleetMachineIDs: Set<String> = []
    private var unlistedInsertionOrder: [String] = []
    private var observers: [UUID: VMResourceStatsSubscription] = [:]
    private let now: () -> Date
    private var retentionGeneration: UInt64 = 0
    private var nextRetentionSequence: UInt64 = 0
    private var acceptedRetentionSequence: UInt64 = 0

    public init(now: @escaping () -> Date = { .now }) { self.now = now }

    public var snapshot: [String: VMStats] { entries.compactMapValues(\.stats) }

    public func stats(for machineID: String) -> VMStats? { entries[machineID]?.stats }

    public func beginRead(machineID: String) -> Request {
        var entry = entry(for: machineID)
        entry.readSequence &+= 1
        entries[machineID] = entry
        return Request(machineID: machineID, revision: entry.revision, sequence: entry.readSequence)
    }

    @discardableResult
    public func finishRead(_ request: Request, stats: VMStats?) -> VMStats {
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

    public func beginResize(machineID: String) -> Request {
        var entry = entry(for: machineID)
        entry.revision = UUID()
        entry.resizing = true
        entry.stats = .unavailable(at: now())
        entries[machineID] = entry
        notify([machineID])
        return Request(machineID: machineID, revision: entry.revision, sequence: entry.readSequence)
    }

    public func finishResize(_ request: Request, stats: VMStats?) {
        guard var entry = entries[request.machineID], entry.revision == request.revision else { return }
        // Also fence reads started while the resize was in progress.
        entry.revision = UUID()
        entry.resizing = false
        entry.stats = stats ?? .unavailable(at: now())
        entries[request.machineID] = entry
        notify([request.machineID])
    }

    /// Start a list response's retention claim. A later claim supersedes an
    /// older in-flight response; auth reset also invalidates every old token.
    public func beginRetention() -> RetentionToken {
        nextRetentionSequence &+= 1
        return RetentionToken(generation: retentionGeneration, sequence: nextRetentionSequence)
    }

    /// Accept a list response only if it belongs to the current auth/reset
    /// generation and is not older than an already accepted response. Retain
    /// the entire authoritative fleet, including teams larger than the CLI cache.
    public func retain(machineIDs: Set<String>, token: RetentionToken) {
        guard token.generation == retentionGeneration,
              token.sequence >= acceptedRetentionSequence else { return }
        acceptedRetentionSequence = token.sequence
        fleetMachineIDs = machineIDs
        unlistedInsertionOrder.removeAll()
        let removed = Set(entries.keys).subtracting(machineIDs)
        guard !removed.isEmpty else { return }
        entries = entries.filter { machineIDs.contains($0.key) }
        notify(removed)
    }

    public func reset() {
        let removed = Set(entries.keys)
        entries.removeAll()
        fleetMachineIDs.removeAll()
        unlistedInsertionOrder.removeAll()
        retentionGeneration &+= 1
        acceptedRetentionSequence = 0
        notify(removed)
    }

    /// Each subscriber coalesces affected IDs and reads current accepted values.
    public func changes() -> VMResourceStatsSubscription {
        let id = UUID()
        let subscription = VMResourceStatsSubscription { [weak self] in
            Task { @MainActor [weak self] in self?.observers.removeValue(forKey: id) }
        }
        observers[id] = subscription
        return subscription
    }

    private func entry(for id: String) -> Entry {
        if let existing = entries[id] { return existing }
        // Visible fleet state scales with the server-owned list. Only extra
        // CLI reads compete for the bounded cache, never listed machines.
        if !fleetMachineIDs.contains(id) {
            if unlistedInsertionOrder.count >= 256 {
                let removed = unlistedInsertionOrder.removeFirst()
                entries.removeValue(forKey: removed)
                notify([removed])
            }
            unlistedInsertionOrder.append(id)
        }
        let entry = Entry()
        entries[id] = entry
        return entry
    }

    private func notify(_ machineIDs: Set<String>) {
        for observer in observers.values { observer.markChanged(machineIDs) }
    }
}
