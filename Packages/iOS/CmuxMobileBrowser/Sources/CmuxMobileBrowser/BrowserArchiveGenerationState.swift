import Foundation

/// Revokes queued archive writes without blocking the main actor on file I/O.
struct BrowserArchiveGenerationState {
    private(set) var current: String
    private(set) var allowsLegacyRestore: Bool
    private let defaultsKey: String
    private let legacyMigrationKey: String

    init(defaults: UserDefaults?, archiveKey: String) {
        defaultsKey = "\(archiveKey).generation"
        legacyMigrationKey = "\(archiveKey).generation.legacyMigration"
        if let persisted = defaults?.string(forKey: defaultsKey) {
            current = persisted
            allowsLegacyRestore = defaults?.string(forKey: legacyMigrationKey) == persisted
        } else {
            current = UUID().uuidString
            allowsLegacyRestore = defaults != nil
            defaults?.set(current, forKey: legacyMigrationKey)
            defaults?.set(current, forKey: defaultsKey)
        }
    }

    func accepts(_ generation: String?) -> Bool {
        generation == current || (generation == nil && allowsLegacyRestore)
    }

    mutating func consumeLegacyRestore() {
        allowsLegacyRestore = false
    }

    mutating func revoke(in defaults: UserDefaults?) {
        current = UUID().uuidString
        allowsLegacyRestore = false
        defaults?.set(current, forKey: defaultsKey)
        defaults?.removeObject(forKey: legacyMigrationKey)
    }
}
