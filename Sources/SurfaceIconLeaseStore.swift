import Bonsplit
import Foundation

/// Owns surface icons and optional deadlines; the caller authorizes replacements against the live terminal.
@MainActor
final class SurfaceIconLeaseStore {
    struct Entry: Sendable {
        let panelID: UUID
        let ownerID: String
        let token: UUID
        let revision: Int
        /// Changes for every full replacement, including reacquisition after a producer restart.
        let generation: UUID
        let animation: TabIconAnimation
        let ttlSeconds: Int?
    }

    enum LeaseError: Error, Equatable {
        case ownershipConflict
        case staleToken
        case revisionConflict
        case missingAnimation
        case invalidTTL
    }

    /// Erases the injected clock without erasing the instant's monotonic semantics.
    private struct Expiration {
        let id = UUID()
        let hasExpired: @Sendable () -> Bool
        let wait: @Sendable () async throws -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var expirations: [UUID: Expiration] = [:]
    private var expirationTasks: [UUID: Task<Void, Never>] = [:]
    private let makeExpiration: (Int) -> Expiration
    private let onChange: (UUID, TabIconAnimation?) -> Void

    convenience init(onChange: @escaping (UUID, TabIconAnimation?) -> Void) {
        self.init(clock: ContinuousClock(), onChange: onChange)
    }

    init<C: Clock>(clock: C, onChange: @escaping (UUID, TabIconAnimation?) -> Void)
    where C.Duration == Duration {
        self.onChange = onChange
        self.makeExpiration = { seconds in
            let origin = clock.now
            let lifetime = Duration.seconds(seconds)
            return Expiration(
                hasExpired: { origin.duration(to: clock.now) >= lifetime },
                wait: {
                    while true {
                        let now = clock.now
                        let remaining = lifetime - origin.duration(to: now)
                        guard remaining > .zero else { return }
                        // Chain representable deadlines, not nanoseconds or an unbounded instant addition.
                        // These are genuine deadline sleeps; the full requested TTL remains authoritative.
                        let segment = min(remaining, .seconds(31_536_000))
                        try await clock.sleep(until: now.advanced(by: segment), tolerance: .zero)
                        try Task.checkCancellation()
                    }
                }
            )
        }
    }

    /// Full sets without a TTL are indefinite. Conditional updates inherit an omitted TTL and renew it.
    /// Token-bearing updates remain conditional; a nil animation preserves the current pixels.
    @discardableResult
    func set(panelID: UUID, ownerID: String, token: UUID? = nil, expectedRevision: Int? = nil,
             animation: TabIconAnimation? = nil, ttlSeconds: Int? = nil) throws -> Entry {
        if let ttlSeconds, ttlSeconds <= 0 { throw LeaseError.invalidTTL }
        expireIfNeeded(panelID: panelID)
        let entry: Entry
        if let token {
            guard let previous = entries[panelID] else { throw LeaseError.staleToken }
            guard previous.ownerID == ownerID else { throw LeaseError.ownershipConflict }
            guard previous.token == token else { throw LeaseError.staleToken }
            guard let expectedRevision, previous.revision == expectedRevision,
                  previous.revision < Int.max else { throw LeaseError.revisionConflict }
            entry = Entry(panelID: panelID, ownerID: ownerID, token: token,
                          revision: previous.revision + 1, generation: previous.generation,
                          animation: animation ?? previous.animation,
                          ttlSeconds: ttlSeconds ?? previous.ttlSeconds)
        } else {
            guard expectedRevision == nil else { throw LeaseError.revisionConflict }
            guard let animation else { throw LeaseError.missingAnimation }
            entry = Entry(panelID: panelID, ownerID: ownerID, token: UUID(),
                          revision: 1, generation: UUID(), animation: animation, ttlSeconds: ttlSeconds)
        }
        entries[panelID] = entry
        scheduleExpiration(for: entry)
        onChange(panelID, entry.animation)
        return entry
    }

    func clear(panelID: UUID, ownerID: String, token: UUID, expectedRevision: Int? = nil) throws {
        expireIfNeeded(panelID: panelID)
        guard let entry = entries[panelID] else { throw LeaseError.staleToken }
        guard entry.ownerID == ownerID else { throw LeaseError.ownershipConflict }
        guard entry.token == token else { throw LeaseError.staleToken }
        guard let expectedRevision, entry.revision == expectedRevision else {
            throw LeaseError.revisionConflict
        }
        reset(panelID: panelID)
    }

    func entry(for panelID: UUID) -> Entry? {
        expireIfNeeded(panelID: panelID)
        return entries[panelID]
    }

    private func scheduleExpiration(for entry: Entry) {
        let panelID = entry.panelID
        expirationTasks.removeValue(forKey: panelID)?.cancel()
        expirations.removeValue(forKey: panelID)
        guard let seconds = entry.ttlSeconds else { return }
        let expiration = makeExpiration(seconds)
        expirations[panelID] = expiration
        expirationTasks[panelID] = Task { @MainActor [weak self] in
            do {
                try await expiration.wait()
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.expirations[panelID]?.id == expiration.id else { return }
            self.expireIfNeeded(panelID: panelID)
        }
    }

    private func expireIfNeeded(panelID: UUID) {
        guard expirations[panelID]?.hasExpired() == true else { return }
        reset(panelID: panelID)
    }

    func reset(panelID: UUID) {
        expirationTasks.removeValue(forKey: panelID)?.cancel()
        expirations.removeValue(forKey: panelID)
        guard entries.removeValue(forKey: panelID) != nil else { return }
        onChange(panelID, nil)
    }

    func resetAll() {
        // Snapshot before callbacks; callbacks may query the store.
        let panelIDs = Array(entries.keys)
        for panelID in panelIDs { reset(panelID: panelID) }
    }

    deinit {
        for task in expirationTasks.values { task.cancel() }
    }
}
