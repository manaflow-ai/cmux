public import Foundation

/// The visible row space where a resolved workspace drop indicator should be
/// drawn.
public enum SidebarWorkspaceReorderDropIndicatorScope: Equatable, Sendable {
    /// Draw against the full raw workspace row order.
    case raw

    /// Draw against top-level rows, with expanded groups represented by their
    /// anchors.
    case topLevel

    /// Draw against the rows belonging to one workspace group.
    case group(UUID)

    /// Whether this scope renders against one workspace group's visible rows.
    public var isGroup: Bool {
        guard case .group = self else { return false }
        return true
    }
}
