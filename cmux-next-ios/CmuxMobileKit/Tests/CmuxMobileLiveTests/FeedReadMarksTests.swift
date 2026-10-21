import CmuxMobileAgentChat
@testable import CmuxMobileFeed
import Foundation
import Testing

@MainActor @Suite struct FeedReadMarksTests {
    private func item(_ id: String) -> FeedItem {
        let request = ACPPermissionRequest(id: "p-\(id)", toolCall: .init(id: "c", title: "ls", kind: .execute),
                                           options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        return FeedItem(id: id, kind: .permission(request), workspaceID: "ws", tabID: "t", agentName: "Claude",
                        harness: "claude", workspaceTitle: "cmux", markdown: "ls", quote: nil, createdAt: Date())
    }

    @Test func readFlagsSurviveARelaunch() {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-read-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = FeedReadMarks(url: url)
        let first = FeedStore(items: [item("a"), item("b")], readMarks: marks)
        first.markRead("a")
        // Relaunch: the open asks come back unread from the Mac.
        let second = FeedStore(items: [item("a"), item("b")], readMarks: marks)
        #expect(second.item(id: "a")?.isRead == true)
        #expect(second.item(id: "b")?.isRead == false)
        second.markUnread("a")
        let third = FeedStore(items: [item("a")], readMarks: marks)
        #expect(third.item(id: "a")?.isRead == false)
    }

    @Test func reReportedEventsStayRead() {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-read-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FeedStore(items: [], readMarks: FeedReadMarks(url: url))
        store.insert(item("a"), atTop: true)
        store.markRead("a")
        let reopened = FeedStore(items: [], readMarks: FeedReadMarks(url: url))
        reopened.insert(item("a"), atTop: true)
        #expect(reopened.item(id: "a")?.isRead == true)
    }
}
