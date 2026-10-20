import Foundation

/// A leaf file in a ``ProjectGroup`` navigator tree.
///
/// Carries the file's resolved on-disk path (or `nil` for files whose
/// `sourceTree` resolves to a runtime variable that we cannot evaluate
/// statically, e.g. `BUILT_PRODUCTS_DIR`), an `existsOnDisk` flag for the
/// "missing file" warning glyph, and the list of target memberships that
/// drive the membership chips in the detail strip.
public struct ProjectFileNode: Sendable, Hashable, Identifiable {
    public let id: ProjectNodeID
    public let displayName: String
    public let resolvedPath: URL?
    public let fileType: String?
    public let existsOnDisk: Bool
    public let memberships: [TargetMembership]

    public init(
        id: ProjectNodeID,
        displayName: String,
        resolvedPath: URL?,
        fileType: String?,
        existsOnDisk: Bool,
        memberships: [TargetMembership]
    ) {
        self.id = id
        self.displayName = displayName
        self.resolvedPath = resolvedPath
        self.fileType = fileType
        self.existsOnDisk = existsOnDisk
        self.memberships = memberships
    }
}
