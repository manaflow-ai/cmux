public import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Coordinates durable browser snapshots without sharing live scene state.
///
/// Every mobile scene owns a distinct ``BrowserSurfaceStore``. Stores publish
/// complete snapshot contributions here, and this process owner merges those
/// contributions into one deterministic archive. The coordinator is the sole
/// archive writer and generation owner, so one scene cannot erase another
/// scene's live browser by closing or reconciling its own copy.
@MainActor
public final class BrowserSurfacePersistenceCoordinator {
    private struct VersionedSnapshot {
        let snapshot: BrowserSurfaceSnapshot
        let revision: UInt64
        let clientID: UUID
    }

    private let defaults: UserDefaults?
    private let archiveKey: String
    private let archiveWriter: BrowserSurfaceArchiveWriter?
    private var archiveGeneration: BrowserArchiveGenerationState
    private var persistenceScope: BrowserPersistenceScope?
    private var contributionsByClient: [UUID: [String: VersionedSnapshot]] = [:]
    private var nextRevision: UInt64 = 0

    /// Creates the process persistence owner.
    ///
    /// - Parameters:
    ///   - defaults: Defaults storage, or `nil` for memory-only scenes.
    ///   - archiveKey: The versioned browser archive key.
    public init(
        defaults: UserDefaults?,
        archiveKey: String = "cmux.mobile.browserSurfaces.v1"
    ) {
        self.defaults = defaults
        self.archiveKey = archiveKey
        self.archiveWriter = defaults.map {
            BrowserSurfaceArchiveWriter(defaults: $0, key: archiveKey)
        }
        self.archiveGeneration = BrowserArchiveGenerationState(
            defaults: defaults,
            archiveKey: archiveKey
        )
    }

    /// Registers or re-scopes one scene and returns independent restore values.
    func setScope(
        _ newScope: BrowserPersistenceScope?,
        for clientID: UUID
    ) -> [String: BrowserSurfaceSnapshot] {
        if newScope != persistenceScope {
            if persistenceScope != nil {
                revokePersistedArchive()
            }
            persistenceScope = newScope
            contributionsByClient.removeAll()
            nextRevision = 0
        }

        guard let newScope else { return [:] }
        if let existing = contributionsByClient[clientID] {
            return existing.mapValues(\.snapshot)
        }

        let aggregate: [String: VersionedSnapshot]
        if contributionsByClient.isEmpty {
            aggregate = restoreArchive(for: newScope)
        } else {
            aggregate = aggregateSnapshots()
        }
        contributionsByClient[clientID] = aggregate.mapValues { versioned in
            VersionedSnapshot(
                snapshot: versioned.snapshot,
                revision: versioned.revision,
                clientID: clientID
            )
        }
        return aggregate.mapValues(\.snapshot)
    }

    /// Replaces one scene's complete durable contribution and persists the merge.
    func replaceSnapshots(
        _ snapshots: [String: BrowserSurfaceSnapshot],
        for clientID: UUID,
        scope: BrowserPersistenceScope?
    ) {
        guard let scope, scope == persistenceScope else { return }
        let previous = contributionsByClient[clientID] ?? [:]
        var replacement: [String: VersionedSnapshot] = [:]
        for (workspaceID, snapshot) in snapshots {
            if let existing = previous[workspaceID], existing.snapshot == snapshot {
                replacement[workspaceID] = existing
            } else {
                nextRevision &+= 1
                replacement[workspaceID] = VersionedSnapshot(
                    snapshot: snapshot,
                    revision: nextRevision,
                    clientID: clientID
                )
            }
        }
        contributionsByClient[clientID] = replacement
        enqueueAggregateWrite(scope: scope)
    }

    #if canImport(WebKit)
    /// Returns the account-and-team-isolated shared WebKit storage container.
    func websiteDataStore(for scope: BrowserPersistenceScope?) -> WKWebsiteDataStore {
        guard let scope, let defaults else { return .nonPersistent() }
        let identifier = BrowserWebsiteDataStoreIDStore(
            defaults: defaults,
            key: "\(archiveKey).websiteDataStoreIDs"
        ).identifier(for: scope)
        return WKWebsiteDataStore(forIdentifier: identifier)
    }
    #endif

    /// Waits for archive requests already submitted by any scene.
    public func flush() async {
        await archiveWriter?.flush()
    }

    private func restoreArchive(
        for scope: BrowserPersistenceScope
    ) -> [String: VersionedSnapshot] {
        guard let defaults, let data = defaults.data(forKey: archiveKey) else { return [:] }
        guard let archive = try? JSONDecoder().decode(BrowserSurfaceArchive.self, from: data),
              archive.scope == scope,
              archiveGeneration.accepts(archive.generation) else {
            defaults.removeObject(forKey: archiveKey)
            return [:]
        }
        if archive.generation == nil {
            archiveGeneration.consumeLegacyRestore()
        }

        var restored: [String: VersionedSnapshot] = [:]
        for snapshot in archive.surfaces where restored[snapshot.workspaceID] == nil {
            restored[snapshot.workspaceID] = VersionedSnapshot(
                snapshot: snapshot,
                revision: 0,
                clientID: UUID()
            )
        }
        if archive.generation == nil {
            enqueueAggregateWrite(scope: scope, snapshots: restored)
        }
        return restored
    }

    private func aggregateSnapshots() -> [String: VersionedSnapshot] {
        var aggregate: [String: VersionedSnapshot] = [:]
        for contribution in contributionsByClient.values {
            for (workspaceID, candidate) in contribution {
                guard let current = aggregate[workspaceID] else {
                    aggregate[workspaceID] = candidate
                    continue
                }
                if candidate.revision > current.revision
                    || (candidate.revision == current.revision
                        && candidate.clientID.uuidString < current.clientID.uuidString) {
                    aggregate[workspaceID] = candidate
                }
            }
        }
        return aggregate
    }

    private func enqueueAggregateWrite(scope: BrowserPersistenceScope) {
        enqueueAggregateWrite(scope: scope, snapshots: aggregateSnapshots())
    }

    private func enqueueAggregateWrite(
        scope: BrowserPersistenceScope,
        snapshots: [String: VersionedSnapshot]
    ) {
        archiveWriter?.enqueueWrite(
            scope: scope,
            snapshotsByWorkspace: snapshots.mapValues(\.snapshot),
            generation: archiveGeneration.current
        )
    }

    private func revokePersistedArchive() {
        archiveGeneration.revoke(in: defaults)
        defaults?.removeObject(forKey: archiveKey)
        archiveWriter?.enqueueRemoval()
    }
}
