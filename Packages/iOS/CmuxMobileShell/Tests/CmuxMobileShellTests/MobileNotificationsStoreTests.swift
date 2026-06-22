import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Pure-logic tests for ``MobileNotificationsStore``: snapshot apply (replace +
/// recent-N cap + ordering), local read-state transitions, and wire decoding.
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
            surfaceID: nil,
            title: "Title \(id)",
            subtitle: "",
            body: "Body \(id)",
            isContentHidden: false,
            createdAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo),
            isRead: isRead
        )
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
        store.markReadLocally(id: "a")
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
        #expect(store.notifications.first { $0.id == "a" }?.isRead == true)
        #expect(store.notifications.first { $0.id == "b" }?.isRead == true)
        #expect(store.notifications.first { $0.id == "c" }?.isRead == false)
    }

    @Test func markReadLocallyUnknownIDIsNoOp() {
        let store = MobileNotificationsStore(notifications: [
            notification(id: "a", workspace: "w1", isRead: false),
        ])
        store.markReadLocally(id: "does-not-exist")
        #expect(store.notifications.first?.isRead == false)
    }

    @Test func decodesNotificationsListWireShape() throws {
        let json = """
        {
          "notifications": [
            {
              "id": "n1",
              "workspace_id": "w1",
              "surface_id": "s1",
              "title": "Build done",
              "subtitle": "sub",
              "body": "exit 0",
              "is_content_hidden": false,
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
        #expect(first.surfaceID == "s1")
        #expect(first.title == "Build done")
        #expect(first.isContentHidden == false)
        #expect(first.isRead == false)
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_000_000.5))
    }

    @Test func decodesNotificationWithMissingSurfaceID() throws {
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
              "is_content_hidden": true,
              "created_at": 1000000,
              "is_read": true
            }
          ]
        }
        """.data(using: .utf8)!
        let previews = try MobileNotificationsListResponse.decode(json).previews()
        #expect(previews.first?.surfaceID == nil)
    }
}
