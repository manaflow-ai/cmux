public import CoreGraphics

public struct SidebarWorkspaceGroupDropIntentPolicy: Sendable {
    private let memberIndent: CGFloat

    public init(memberIndent: CGFloat) {
        self.memberIndent = memberIndent
    }

    public func prefersGroupScope(
        pointerX: CGFloat,
        targetLeadingIndent: CGFloat
    ) -> Bool {
        guard targetLeadingIndent > 0 else { return false }
        return pointerX >= max(0, targetLeadingIndent - (memberIndent / 2))
    }
}
