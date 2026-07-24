import Foundation

/// One persisted sticky customization with its mutation-recency revision.
struct WorkspaceDirectoryCustomizationPersistenceEntry: Codable, Equatable, Sendable {
    let customization: WorkspaceDirectoryCustomization
    let revision: UInt64
}
