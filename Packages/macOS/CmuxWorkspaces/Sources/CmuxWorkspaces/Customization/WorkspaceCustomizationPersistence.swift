import Foundation

struct WorkspaceCustomizationPersistenceEntry: Codable, Equatable, Sendable {
    let customization: WorkspaceCustomization
    let revision: UInt64
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
        entries[key] = WorkspaceCustomizationPersistenceEntry(
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
