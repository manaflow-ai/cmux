import Foundation

/// Sendable handle to Foundation's documented thread-safe defaults storage.
/// It owns no mutable coordination state; request ordering stays actor-isolated.
final class BrowserSurfaceArchiveDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

/// Delivers immutable browser archive I/O away from the main actor while
/// keeping blocking defaults encoding and writes actor-isolated.
actor BrowserSurfaceArchiveWriter {
    private let defaults: BrowserSurfaceArchiveDefaults
    private let key: String
    private let generationKey: String
    private let legacyMigrationKey: String

    init(defaults: BrowserSurfaceArchiveDefaults, key: String) {
        self.defaults = defaults
        self.key = key
        self.generationKey = "\(key).generation"
        self.legacyMigrationKey = "\(key).generation.legacyMigration"
    }

    func write(
        scope: BrowserPersistenceScope,
        snapshotsByWorkspace: [String: BrowserSurfaceSnapshot],
        generation: String
    ) {
        let snapshots = snapshotsByWorkspace.keys.sorted().compactMap {
            snapshotsByWorkspace[$0]
        }
        let archive = BrowserSurfaceArchive(
            scope: scope,
            surfaces: snapshots,
            generation: generation
        )
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.value.set(data, forKey: key)
        if defaults.value.string(forKey: generationKey) == generation,
           defaults.value.string(forKey: legacyMigrationKey) == generation {
            defaults.value.removeObject(forKey: legacyMigrationKey)
        }
    }

    func remove() {
        defaults.value.removeObject(forKey: key)
    }
}
