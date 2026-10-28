import CmuxNotifications
import Testing

/// The unread mark sits in the same place on every row, so it does not jump sides in a list that
/// mixes colored and plain workspaces. The leading rail shows the workspace color and nothing else.
@Suite struct NotificationRowMarksTests {
    @Test func theUnreadMarkDoesNotDependOnTheWorkspaceColor() {
        for isRead in [false, true] {
            #expect(
                NotificationRowMarks(hasWorkspaceColor: true, isRead: isRead).showsUnreadDot
                    == NotificationRowMarks(hasWorkspaceColor: false, isRead: isRead).showsUnreadDot
            )
        }
        #expect(NotificationRowMarks(hasWorkspaceColor: false, isRead: false).showsUnreadDot)
        #expect(!NotificationRowMarks(hasWorkspaceColor: false, isRead: true).showsUnreadDot)
    }

    @Test func theRailShowsOnlyTheWorkspaceColor() {
        for isRead in [false, true] {
            #expect(NotificationRowMarks(hasWorkspaceColor: true, isRead: isRead).rail == .workspaceColor)
            #expect(NotificationRowMarks(hasWorkspaceColor: false, isRead: isRead).rail == .none)
        }
    }
}
