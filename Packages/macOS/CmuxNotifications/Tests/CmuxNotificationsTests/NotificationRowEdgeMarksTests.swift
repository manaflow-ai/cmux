import CmuxNotifications
import Testing

@Suite struct NotificationRowEdgeMarksTests {
    @Test func aColoredWorkspaceKeepsItsColorOnTheLeftAndMarksUnreadOnTheRight() {
        let marks = NotificationRowEdgeMarks(hasWorkspaceColor: true, isRead: false)
        #expect(marks.leading == .workspaceColor)
        #expect(marks.trailing == .unread)
    }

    @Test func aReadRowInAColoredWorkspaceShowsOnlyTheColor() {
        let marks = NotificationRowEdgeMarks(hasWorkspaceColor: true, isRead: true)
        #expect(marks.leading == .workspaceColor)
        #expect(marks.trailing == .none)
    }

    @Test func withoutAColorUnreadStaysOnTheLeft() {
        #expect(NotificationRowEdgeMarks(hasWorkspaceColor: false, isRead: false)
            == NotificationRowEdgeMarks(hasWorkspaceColor: false, isRead: false))
        let unread = NotificationRowEdgeMarks(hasWorkspaceColor: false, isRead: false)
        #expect(unread.leading == .unread)
        #expect(unread.trailing == .none)
        let read = NotificationRowEdgeMarks(hasWorkspaceColor: false, isRead: true)
        #expect(read.leading == .none)
        #expect(read.trailing == .none)
    }
}
