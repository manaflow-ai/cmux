import Foundation

/// One legacy directory customization with its mutation-recency revision.
struct WorkspaceDirectoryCustomizationPersistenceEntry: Codable, Equatable, Sendable {
    let customization: WorkspaceDirectoryCustomization
    let revision: UInt64
}
