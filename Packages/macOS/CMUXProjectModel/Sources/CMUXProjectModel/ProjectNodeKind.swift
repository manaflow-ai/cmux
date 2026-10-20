import Foundation

/// The two kinds of nodes that can appear in a ``ProjectGroup``'s children.
///
/// Modeled as an `indirect enum` so a group can recursively contain other
/// groups without forcing the model to use reference types. SwiftUI
/// `OutlineGroup` consumes this directly via a children key path that
/// projects ``ProjectGroup/children`` when the case is ``group``.
public indirect enum ProjectNodeKind: Sendable, Hashable, Identifiable {
    case group(ProjectGroup)
    case file(ProjectFileNode)

    public var id: ProjectNodeID {
        switch self {
        case let .group(group):
            return group.id
        case let .file(file):
            return file.id
        }
    }

    public var displayName: String {
        switch self {
        case let .group(group):
            return group.displayName
        case let .file(file):
            return file.displayName
        }
    }

    /// Children of this node, projected for SwiftUI ``OutlineGroup``.
    ///
    /// Returns `nil` for a file leaf so the outline renders it without a
    /// disclosure chevron. Returns an empty array for an empty group so it
    /// still renders with the chevron.
    public var children: [ProjectNodeKind]? {
        switch self {
        case let .group(group):
            return group.children
        case .file:
            return nil
        }
    }
}
