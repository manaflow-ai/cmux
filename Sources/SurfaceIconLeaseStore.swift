import Bonsplit
import Foundation

/// Owns conditional surface-icon leases; the caller owns process identity and panel routing.
@MainActor
final class SurfaceIconLeaseStore {
    struct Entry: Sendable {
        let panelID: UUID
        let ownerID: String
        let token: UUID
        let revision: Int
        /// Changes for every fresh acquisition, including after reset or expiry.
        let generation: UUID
        let animation: TabIconAnimation
        let expiresAt: Date
    }

    enum LeaseError: Error, Equatable {
        case ownershipConflict
        case staleToken
        case revisionConflict
        case invalidTTL
        case missingAnimation
    }

    private var entries: [UUID: Entry] = [:]
    private var expirationTasks: [UUID: Task<Void, Never>] = [:]
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let onChange: (UUID, TabIconAnimation?) -> Void

    init(
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await ContinuousClock().sleep(for: .seconds($0))
        },
        onChange: @escaping (UUID, TabIconAnimation?) -> Void
    ) {
        self.now = now
        self.sleep = sleep
        self.onChange = onChange
    }

    deinit {
        for task in expirationTasks.values { task.cancel() }
    }

    /// A nil animation renews an existing lease without changing its pixels.
    @discardableResult
    func set(panelID: UUID, ownerID: String, token: UUID? = nil, expectedRevision: Int? = nil,
             animation: TabIconAnimation? = nil, ttl: TimeInterval) throws -> Entry {
        guard ttl.isFinite, (5...120).contains(ttl) else { throw LeaseError.invalidTTL }
        let instant = now()
        removeExpired(panelID: panelID, at: instant)
        let previous = entries[panelID]
        if let previous {
            guard previous.ownerID == ownerID else { throw LeaseError.ownershipConflict }
            guard let token, previous.token == token else { throw LeaseError.staleToken }
            if let expectedRevision, previous.revision != expectedRevision { throw LeaseError.revisionConflict }
            guard previous.revision < Int.max else { throw LeaseError.revisionConflict }
        } else {
            // Possessing a dead token must never grant authority over a newly vacant panel.
            guard token == nil else { throw LeaseError.staleToken }
            guard expectedRevision == nil else { throw LeaseError.revisionConflict }
        }
        guard let resolvedAnimation = animation ?? previous?.animation else { throw LeaseError.missingAnimation }
        let entry = Entry(panelID: panelID, ownerID: ownerID, token: previous?.token ?? UUID(),
                          revision: (previous?.revision ?? 0) + 1, generation: previous?.generation ?? UUID(),
                          animation: resolvedAnimation, expiresAt: instant.addingTimeInterval(ttl))
        expirationTasks.removeValue(forKey: panelID)?.cancel()
        entries[panelID] = entry
        scheduleExpiration(entry, after: ttl)
        onChange(panelID, resolvedAnimation)
        return entry
    }

    func clear(panelID: UUID, ownerID: String, token: UUID, expectedRevision: Int? = nil) throws {
        removeExpired(panelID: panelID, at: now())
        guard let entry = entries[panelID] else { throw LeaseError.staleToken }
        guard entry.ownerID == ownerID else { throw LeaseError.ownershipConflict }
        guard entry.token == token else { throw LeaseError.staleToken }
        if let expectedRevision, entry.revision != expectedRevision { throw LeaseError.revisionConflict }
        reset(panelID: panelID)
    }

    func entry(for panelID: UUID) -> Entry? {
        removeExpired(panelID: panelID, at: now())
        return entries[panelID]
    }

    /// Conditional expiry is also the deterministic test seam for deadline delivery.
    @discardableResult
    func expire(panelID: UUID, token: UUID, revision: Int, at instant: Date) -> Bool {
        guard let entry = entries[panelID], entry.token == token, entry.revision == revision,
              instant >= entry.expiresAt else { return false }
        reset(panelID: panelID)
        return true
    }

    func reset(panelID: UUID) {
        expirationTasks.removeValue(forKey: panelID)?.cancel()
        guard entries.removeValue(forKey: panelID) != nil else { return }
        onChange(panelID, nil)
    }

    func resetAll() {
        // Snapshot before callbacks; callbacks may query the store.
        let panelIDs = Array(entries.keys)
        for panelID in panelIDs { reset(panelID: panelID) }
    }

    private func removeExpired(panelID: UUID, at instant: Date) {
        guard let entry = entries[panelID] else { return }
        expire(panelID: panelID, token: entry.token, revision: entry.revision, at: instant)
    }

    private func scheduleExpiration(_ entry: Entry, after delay: TimeInterval) {
        let sleep = self.sleep
        expirationTasks[entry.panelID] = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  let current = self.entries[entry.panelID], current.token == entry.token,
                  current.revision == entry.revision else { return }
            let instant = self.now()
            if !self.expire(panelID: entry.panelID, token: entry.token, revision: entry.revision, at: instant) {
                // Wall time can move backwards; reschedule the remaining deadline, never expire early.
                self.scheduleExpiration(entry, after: entry.expiresAt.timeIntervalSince(instant))
            }
        }
    }
}
