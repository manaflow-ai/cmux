import Foundation

/// The visual treatment for a resolved workspace drop target.
public enum MobileWorkspaceDropIndicatorKind: Equatable, Sendable {
    /// A horizontal insertion line at the resolved boundary.
    case insertLine
    /// A highlight over the group header receiving an append drop.
    case highlightGroup(MobileWorkspaceGroupPreview.ID)
}
