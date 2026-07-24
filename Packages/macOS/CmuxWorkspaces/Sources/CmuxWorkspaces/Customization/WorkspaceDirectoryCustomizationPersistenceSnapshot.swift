import Foundation

/// The bounded, versioned persistence envelope for sticky directory customizations.
struct WorkspaceDirectoryCustomizationPersistenceSnapshot: Codable, Sendable {
    static let currentVersion = 2

    var version = currentVersion
    var nextRevision: UInt64
    var entries: [String: WorkspaceDirectoryCustomizationPersistenceEntry]

    init(
        nextRevision: UInt64 = 0,
        entries: [String: WorkspaceDirectoryCustomizationPersistenceEntry] = [:]
    ) {
        self.nextRevision = nextRevision
        self.entries = entries
    }

    init(migrating legacy: [String: WorkspaceDirectoryCustomization]) {
        var revision: UInt64 = 0
        entries = Dictionary(uniqueKeysWithValues: legacy.keys.sorted().compactMap { key in
            guard let customization = legacy[key] else { return nil }
            revision += 1
            return (
                key,
                WorkspaceDirectoryCustomizationPersistenceEntry(
                    customization: customization,
                    revision: revision
                )
            )
        })
        nextRevision = revision
    }

    mutating func set(
        _ customization: WorkspaceDirectoryCustomization,
        for key: String
    ) {
        nextRevision &+= 1
        entries[key] = WorkspaceDirectoryCustomizationPersistenceEntry(
            customization: customization,
            revision: nextRevision
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
