import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileNotificationFeedModelTests {
    @Test func appliesListNewestFirstAndMutatesReadState() {
        let model = MobileNotificationFeedModel()
        let older = item(id: 1, seconds: 10, isRead: false)
        let newer = item(id: 2, seconds: 20, isRead: true)
        model.applyList(MobileNotificationListResponse(items: [older, newer], unreadCount: 1))
        #expect(model.items.map(\.id) == [newer.id, older.id])
        #expect(model.hasLoaded)

        model.markRead([older.id])
        #expect(model.items.allSatisfy { $0.isRead })
        #expect(model.unreadCount == 0)
        model.markUnread(newer.id)
        #expect(model.items.first?.isRead == false)
        #expect(model.unreadCount == 1)
        model.remove([newer.id])
        #expect(model.items.map(\.id) == [older.id])
        #expect(model.unreadCount == 0)
    }

    @Test func dismissedEventMutationMarksOnlyMatchingItemsRead() {
        let model = MobileNotificationFeedModel()
        let first = item(id: 1, seconds: 20, isRead: false)
        let second = item(id: 2, seconds: 10, isRead: false)
        model.applyList(MobileNotificationListResponse(items: [first, second], unreadCount: 2))
        model.markRead([second.id])
        #expect(model.items.first(where: { $0.id == first.id })?.isRead == false)
        #expect(model.items.first(where: { $0.id == second.id })?.isRead == true)
        #expect(model.unreadCount == 1)
    }

    @Test func markAllBatchesStayWithinWireCap() {
        let model = MobileNotificationFeedModel()
        let items = (0..<600).map { item(id: $0, seconds: Double($0), isRead: false) }
        model.applyList(MobileNotificationListResponse(items: items, unreadCount: items.count))
        let batches = model.unreadIDBatches()
        #expect(batches.map(\.count) == [256, 256, 88])
        #expect(Set(batches.flatMap { $0 }).count == 600)
    }

    private func item(id: Int, seconds: Double, isRead: Bool) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            workspaceID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            title: "Title",
            createdAt: Date(timeIntervalSince1970: seconds),
            isRead: isRead,
            workspaceName: "Workspace"
        )
    }
}
