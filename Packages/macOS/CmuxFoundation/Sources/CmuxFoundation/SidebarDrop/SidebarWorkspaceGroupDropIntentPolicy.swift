public import CoreGraphics

public enum SidebarWorkspaceGroupDropIntentPolicy {
    public static func prefersGroupScope(
        pointerX: CGFloat,
        memberIndent: CGFloat
    ) -> Bool {
        pointerX >= -(memberIndent / 2)
    }
}
