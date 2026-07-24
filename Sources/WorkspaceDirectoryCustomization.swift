import Foundation

/// The user-owned identity that cmux reapplies when a directory becomes a workspace again.
struct WorkspaceDirectoryCustomization: Codable, Equatable, Sendable {
    let customTitle: String?
    let customColor: String?

    var isEmpty: Bool {
        customTitle == nil && customColor == nil
    }
}
