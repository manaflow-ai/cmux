import Foundation
import Testing
@testable import CmuxNotifications

@Suite("Sidebar notification preview")
struct SidebarNotificationPreviewTests {
    @Test
    func previewTextFollowsTheReadStateUnlessKeepingTheLatest() {
        let read = SidebarWorkspaceUnreadSummary(
            unreadCount: 0,
            latestNotificationText: "Needs permission",
            hasLatestNotification: true
        )
        #expect(read.previewText(.unread) == nil)
        #expect(read.previewText(.latest) == "Needs permission")
        #expect(read.previewText(.hidden) == nil)

        let unread = SidebarWorkspaceUnreadSummary(
            unreadCount: 2,
            latestNotificationText: "Done",
            latestUnreadNotificationText: "Needs permission",
            hasLatestNotification: true
        )
        // An older unread prompt outranks a newer notification already read.
        #expect(unread.previewText(.unread) == "Needs permission")
        #expect(unread.previewText(.latest) == "Done")

        // A workspace marked unread by hand previews its latest notification.
        let manualUnread = SidebarWorkspaceUnreadSummary(
            unreadCount: 1,
            latestNotificationText: "Done",
            hasLatestNotification: true
        )
        #expect(manualUnread.previewText(.unread) == "Done")
    }

    @Test(arguments: [1, 2])
    func blankUnreadNotificationDoesNotPreviewANewerReadMessage(unreadCount: Int) {
        let unread = SidebarWorkspaceUnreadSummary(
            unreadCount: unreadCount,
            latestNotificationText: "Already read",
            latestUnreadNotificationText: nil,
            hasUnreadNotification: true,
            hasLatestNotification: true
        )
        #expect(unread.previewText(.unread) == nil)
        #expect(unread.previewText(.latest) == "Already read")
        #expect(unread.previewText(.hidden) == nil)
    }

}
