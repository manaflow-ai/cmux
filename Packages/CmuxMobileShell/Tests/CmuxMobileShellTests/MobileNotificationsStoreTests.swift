import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Pure-logic tests for ``MobileNotificationsStore``: unread-count derivation
/// (total and per-workspace), snapshot apply (replace + recent-N cap + ordering),
/// and read-state transitions (single and per-workspace).
@MainActor
@Suite struct MobileNotificationsStoreTests {
    private func notification(
        id: String,
        workspace: String,
        secondsAgo: TimeInterval = 0,
        isRead: Bool = false
    ) -> MobileNotificationPreview {
        MobileNotificationPreview(
            id: id,
            workspaceID: workspace,
            workspaceName: "Workspace \(workspace)",
            surfaceID: nil,
            title: "Title \(id)",
            subtitle: "",
            body: "Body \(id)",
            createdAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo),
            isRead: isRead
        )
    }

    @Test func totalUnreadCountsOnlyUnread() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1", isRead: false),
            notification(id: "b", workspace: "w1", isRead: true),
            notification(id: "c", workspace: "w2", isRead: false),
        ])
        #expect(store.unreadCount == 2)
    }

    @Test func perWorkspaceUnreadCount() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1", isRead: false),
            notification(id: "b", workspace: "w1", isRead: false),
            notification(id: "c", workspace: "w1", isRead: true),
            notification(id: "d", workspace: "w2", isRead: false),
        ])
        #expect(store.unreadCount(forWorkspace: "w1") == 2)
        #expect(store.unreadCount(forWorkspace: "w2") == 1)
        #expect(store.unreadCount(forWorkspace: "missing") == 0)
    }

    @Test func unreadCountsByWorkspaceMapExcludesReadAndEmpty() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1", isRead: false),
            notification(id: "b", workspace: "w1", isRead: false),
            notification(id: "c", workspace: "w2", isRead: true),
        ])
        let map = store.unreadCountsByWorkspace()
        #expect(map == ["w1": 2])
        // A fully-read workspace must not appear (so its badge is hidden).
        #expect(map["w2"] == nil)
    }

    @Test func applySortsNewestFirst() {
        let store = MobileNotificationsStore()
        store.apply([
            notification(id: "old", workspace: "w1", secondsAgo: 100),
            notification(id: "new", workspace: "w1", secondsAgo: 0),
            notification(id: "mid", workspace: "w1", secondsAgo: 50),
        ])
        #expect(store.notifications.map(\.id) == ["new", "mid", "old"])
    }

    @Test func applyReplacesPreviousSnapshot() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1"),
        ])
        store.apply([
            notification(id: "b", workspace: "w2"),
        ])
        // Replace-with-recent-N: the old snapshot is gone entirely.
        #expect(store.notifications.map(\.id) == ["b"])
    }

    @Test func applyCapsToRecentLimit() {
        let limit = MobileNotificationsStore.recentLimit
        let many = (0..<(limit + 25)).map { index in
            // Higher index = more recent, so newest-first keeps the top `limit`.
            notification(id: String(format: "%05d", index), workspace: "w1", secondsAgo: TimeInterval(limit + 25 - index))
        }
        let store = MobileNotificationsStore()
        store.apply(many)
        #expect(store.notifications.count == limit)
        // The newest item (highest index) survives; the oldest is dropped.
        #expect(store.notifications.first?.id == String(format: "%05d", limit + 24))
        #expect(!store.notifications.contains { $0.id == String(format: "%05d", 0) })
    }

    @Test func markReadLocallyFlipsSingleAndRecomputesCount() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1", isRead: false),
            notification(id: "b", workspace: "w1", isRead: false),
        ])
        #expect(store.unreadCount == 2)
        store.markReadLocally(id: "a")
        #expect(store.unreadCount == 1)
        #expect(store.notifications.first { $0.id == "a" }?.isRead == true)
        #expect(store.notifications.first { $0.id == "b" }?.isRead == false)
    }

    @Test func markReadLocallyForWorkspaceFlipsOnlyThatWorkspace() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1", isRead: false),
            notification(id: "b", workspace: "w1", isRead: false),
            notification(id: "c", workspace: "w2", isRead: false),
        ])
        store.markReadLocally(forWorkspace: "w1")
        #expect(store.unreadCount(forWorkspace: "w1") == 0)
        #expect(store.unreadCount(forWorkspace: "w2") == 1)
        #expect(store.unreadCount == 1)
    }

    @Test func markReadLocallyUnknownIDIsNoOp() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1", isRead: false),
        ])
        store.markReadLocally(id: "does-not-exist")
        #expect(store.unreadCount == 1)
    }

    @Test func decodesNotificationsListWireShape() throws {
        let json = """
        {
          "notifications": [
            {
              "id": "n1",
              "workspace_id": "w1",
              "workspace_name": "my-feature",
              "surface_id": "s1",
              "title": "Build done",
              "subtitle": "sub",
              "body": "exit 0",
              "created_at": 1000000.5,
              "is_read": false
            }
          ]
        }
        """.data(using: .utf8)!
        let response = try MobileNotificationsListResponse.decode(json)
        let previews = response.previews()
        #expect(previews.count == 1)
        let first = try #require(previews.first)
        #expect(first.id == "n1")
        #expect(first.workspaceID == "w1")
        #expect(first.workspaceName == "my-feature")
        #expect(first.surfaceID == "s1")
        #expect(first.title == "Build done")
        #expect(first.isRead == false)
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_000_000.5))
    }

    @Test func decodesNotificationWithMissingWorkspaceName() throws {
        // An older Mac (or a closed/untitled workspace) omits workspace_name;
        // it must decode to nil rather than throwing.
        let json = """
        {
          "notifications": [
            {
              "id": "n1",
              "workspace_id": "w1",
              "surface_id": null,
              "title": "t",
              "subtitle": "",
              "body": "",
              "created_at": 1000000,
              "is_read": true
            }
          ]
        }
        """.data(using: .utf8)!
        let previews = try MobileNotificationsListResponse.decode(json).previews()
        #expect(previews.first?.workspaceName == nil)
        #expect(previews.first?.surfaceID == nil)
    }
}
