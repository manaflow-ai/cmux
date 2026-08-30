import Foundation

struct WorkspaceCustomizationPersistenceEntry: Codable, Equatable, Sendable {
    let customization: WorkspaceCustomization
    let revision: UInt64
    let titleMutationRevision: UInt64
    let automaticTitleOrdering: UInt64

    init(
        customization: WorkspaceCustomization,
        revision: UInt64,
        titleMutationRevision: UInt64 = 0,
        automaticTitleOrdering: UInt64 = 0
    ) {
        self.customization = customization
        self.revision = revision
        self.titleMutationRevision = titleMutationRevision
        self.automaticTitleOrdering = automaticTitleOrdering
    }

    private enum CodingKeys: String, CodingKey {
        case customization
        case revision
        case titleMutationRevision
        case automaticTitleOrdering
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customization = try container.decode(
            WorkspaceCustomization.self,
            forKey: .customization
        )
        revision = try container.decode(UInt64.self, forKey: .revision)
        // Older journals have no title-specific revision. Zero is a safe
        // compatibility value; the next title mutation advances it.
        titleMutationRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .titleMutationRevision
        ) ?? 0
        automaticTitleOrdering = try container.decodeIfPresent(
            UInt64.self,
            forKey: .automaticTitleOrdering
        ) ?? 0
    }
}

struct WorkspaceCustomizationPersistenceSnapshot: Codable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var nextRevision: UInt64
    var entries: [String: WorkspaceCustomizationPersistenceEntry]

    init(
        nextRevision: UInt64 = 0,
        entries: [String: WorkspaceCustomizationPersistenceEntry] = [:]
    ) {
        self.nextRevision = nextRevision
        self.entries = entries
    }

    mutating func set(_ customization: WorkspaceCustomization, for key: String) {
        nextRevision &+= 1
        let previous = entries[key]
        entries[key] = WorkspaceCustomizationPersistenceEntry(
            customization: customization,
            revision: nextRevision,
            titleMutationRevision: previous?.titleMutationRevision ?? 0,
            automaticTitleOrdering: previous?.automaticTitleOrdering ?? 0
        )
    }

    mutating func setTitle(
        _ customization: WorkspaceCustomization,
        for key: String,
        automaticTitleOrdering: UInt64 = 0
    ) {
        nextRevision &+= 1
        entries[key] = WorkspaceCustomizationPersistenceEntry(
            customization: customization,
            revision: nextRevision,
            titleMutationRevision: nextRevision,
            automaticTitleOrdering: automaticTitleOrdering
        )
    }

    mutating func trim(to capacity: Int) {
        guard entries.count > capacity else { return }
        entries = Dictionary(uniqueKeysWithValues: entries
            .sorted { lhs, rhs in
                if lhs.value.revision != rhs.value.revision {
                    return lhs.value.revision > rhs.value.revision
                }
                return lhs.key < rhs.key
            }
            .prefix(capacity)
            .map { ($0.key, $0.value) })
    }
}

/// One process-wide lock keeps independent store values from racing a
/// read-modify-write against the same UserDefaults database. Store values are
/// copied into each window manager, so an instance-local lock would not cover
/// all writers.
private final class WorkspaceCustomizationPersistenceLock: @unchecked Sendable {
    static let shared = WorkspaceCustomizationPersistenceLock()

    let value = NSRecursiveLock()

    private init() {}
}

/// Owns the synchronous persistence boundary shared by actor-isolated stores.
///
/// Normal callers reach this through ``WorkspaceCustomizationStore`` on the
/// main actor. A workspace owner can also hand pending records here from its
/// nonisolated deinitializer. The lock covers the complete read-modify-write
/// transaction so that handoff cannot race another store mutation. UserDefaults
/// is thread-safe for individual calls, but does not make this compound
/// transaction atomic.
final class WorkspaceCustomizationSynchronousWriter: @unchecked Sendable {
    private struct CachedSnapshot {
        let data: Data?
        let snapshot: WorkspaceCustomizationPersistenceSnapshot
    }

    private let defaults: UserDefaults?
    private let storageKey: String
    private let capacity: Int
    // UserDefaults posts didChangeNotification synchronously on the setter
    // thread. A recursive lock lets an observer read this store during that
    // callback without deadlocking the transaction that triggered it. The
    // critical section is bounded to one snapshot decode/encode and defaults
    // update because deinitializers cannot suspend for an actor hop.
    private let lock = WorkspaceCustomizationPersistenceLock.shared.value
    // This short lock protects only the cache reference. Notification
    // callbacks must not take the transaction lock: another writer can be in a
    // defaults setter that synchronously waits for this callback to return.
    private let cacheLock = NSLock()
    private var cachedSnapshot: CachedSnapshot?
    private var defaultsChangeObserver: (any NSObjectProtocol)?

    init(defaults: UserDefaults?, storageKey: String, capacity: Int) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.capacity = capacity
        guard defaults != nil else { return }

        // Observe every UserDefaults instance. The notification object identifies
        // the instance that wrote the value, so filtering by object would leave
        // separately-created stores for the same suite stale. This writer has a
        // per-instance cache, and a process-wide notification invalidates all
        // copies that may read the same defaults database.
        self.defaultsChangeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateCachedSnapshot()
        }
    }

    deinit {
        if let defaultsChangeObserver {
            NotificationCenter.default.removeObserver(defaultsChangeObserver)
        }
    }

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func persistPendingAutomaticTitles(
        _ pending: [WorkspaceCustomizationPendingAutomaticTitle]
    ) {
        guard !pending.isEmpty else { return }
        withLock {
            guard let defaults else { return }
            var snapshot = loadSnapshotUnlocked(defaults: defaults)
            for item in pending.sorted(by: { lhs, rhs in
                lhs.stableId.uuidString < rhs.stableId.uuidString
            }) {
                let key = item.stableId.uuidString
                guard let currentEntry = snapshot.entries[key] else { continue }
                let sameRevision = currentEntry.titleMutationRevision == item.titleMutationRevision
                let newerConcurrentAutomaticTitle =
                    currentEntry.titleMutationRevision > item.titleMutationRevision
                    && currentEntry.automaticTitleOrdering > 0
                    && item.automaticTitleOrdering > currentEntry.automaticTitleOrdering
                guard sameRevision || newerConcurrentAutomaticTitle else {
                    // Any mutation after the automatic title was queued makes
                    // this record stale unless it is a later automatic title
                    // queued by another manager at the same observed revision.
                    // Explicit user mutations retain precedence.
                    continue
                }
                switch currentEntry.customization.customTitle {
                case .cleared, .autoValue:
                    break
                case .absent, .value:
                    // Keep the legacy user-value guard as a defense in depth
                    // for journals written before title-specific revisions.
                    continue
                }
                let trimmed = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let field: WorkspaceCustomizationField = trimmed.isEmpty
                    ? .cleared
                    : .autoValue(trimmed)
                snapshot.setTitle(
                    WorkspaceCustomization(
                        customTitle: field,
                        customColor: snapshot.entries[key]?.customization.customColor ?? .absent
                    ),
                    for: key,
                    automaticTitleOrdering: item.automaticTitleOrdering
                )
            }
            snapshot.trim(to: capacity)
            persistSnapshotUnlocked(snapshot, defaults: defaults)
        }
    }

    func loadSnapshot() -> WorkspaceCustomizationPersistenceSnapshot {
        withLock {
            guard let defaults else { return WorkspaceCustomizationPersistenceSnapshot() }
            return loadSnapshotUnlocked(defaults: defaults)
        }
    }

    func updateSnapshot(
        _ update: (inout WorkspaceCustomizationPersistenceSnapshot) -> Void
    ) {
        withLock {
            guard let defaults else { return }
            var snapshot = loadSnapshotUnlocked(defaults: defaults)
            update(&snapshot)
            snapshot.trim(to: capacity)
            persistSnapshotUnlocked(snapshot, defaults: defaults)
        }
    }

    private func loadSnapshotUnlocked(
        defaults: UserDefaults
    ) -> WorkspaceCustomizationPersistenceSnapshot {
        let data = defaults.data(forKey: storageKey)
        if let cachedSnapshot = cachedSnapshot(matching: data) {
            return cachedSnapshot
        }

        guard let data,
              var snapshot = try? JSONDecoder().decode(
                  WorkspaceCustomizationPersistenceSnapshot.self,
                  from: data
              ),
              snapshot.version == WorkspaceCustomizationPersistenceSnapshot.currentVersion else {
            let empty = WorkspaceCustomizationPersistenceSnapshot()
            setCachedSnapshot(CachedSnapshot(data: data, snapshot: empty))
            return empty
        }
        let previousCount = snapshot.entries.count
        snapshot.trim(to: capacity)
        if snapshot.entries.count != previousCount {
            persistSnapshotUnlocked(snapshot, defaults: defaults)
        } else {
            setCachedSnapshot(CachedSnapshot(data: data, snapshot: snapshot))
        }
        return snapshot
    }

    private func persistSnapshotUnlocked(
        _ snapshot: WorkspaceCustomizationPersistenceSnapshot,
        defaults: UserDefaults
    ) {
        guard !snapshot.entries.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            setCachedSnapshot(CachedSnapshot(data: nil, snapshot: snapshot))
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
        setCachedSnapshot(CachedSnapshot(data: data, snapshot: snapshot))
    }

    private func invalidateCachedSnapshot() {
        cacheLock.lock()
        cachedSnapshot = nil
        cacheLock.unlock()
    }

    private func cachedSnapshot(
        matching data: Data?
    ) -> WorkspaceCustomizationPersistenceSnapshot? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cachedSnapshot, cachedSnapshot.data == data else { return nil }
        return cachedSnapshot.snapshot
    }

    private func setCachedSnapshot(_ snapshot: CachedSnapshot) {
        cacheLock.lock()
        cachedSnapshot = snapshot
        cacheLock.unlock()
    }
}
