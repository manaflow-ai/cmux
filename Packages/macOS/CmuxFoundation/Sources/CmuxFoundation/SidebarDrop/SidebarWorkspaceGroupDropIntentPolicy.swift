public import CoreGraphics

/// Decides whether an ambiguous sidebar workspace drop should target a
/// workspace group section or the surrounding root workspace list.
public struct SidebarWorkspaceGroupDropIntentPolicy: Sendable {
    private let memberIndent: CGFloat

    /// Creates a policy using the horizontal indent between root workspace rows
    /// and workspace rows rendered inside a group.
    public init(memberIndent: CGFloat) {
        self.memberIndent = memberIndent
    }

    /// Returns `true` when the pointer is far enough into the grouped-member
    /// lane to treat the drop as targeting the group section.
    ///
    /// Root-level rows (`targetLeadingIndent <= 0`) never prefer group scope.
    /// Grouped rows switch at half the configured member indent before the
    /// member row's leading edge, so small horizontal drift does not change the
    /// intended hierarchy.
    public func prefersGroupScope(
        pointerX: CGFloat,
        targetLeadingIndent: CGFloat
    ) -> Bool {
        guard targetLeadingIndent > 0 else { return false }
        return pointerX >= max(0, targetLeadingIndent - (memberIndent / 2))
    }
}
