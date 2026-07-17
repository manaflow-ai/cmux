#if canImport(UIKit) && DEBUG
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

/// DEBUG-only production-feed fixture selected by `CMUX_UITEST_NOTIFICATION_FEED_PREVIEW`.
public struct NotificationFeedPreviewView: View {
    @State private var items: [MobileNotificationFeedItem]
    @State private var showsIntro: Bool
    @State private var pushEnabled = false
    private let referenceNow: Date

    /// Creates the selected populated or empty notification-feed fixture.
    public init() {
        let now = Date()
        referenceNow = now
        let isEmpty = UITestConfig.notificationFeedPreview == "empty"
        _items = State(initialValue: isEmpty ? [] : Self.fixtures(now: now))
        _showsIntro = State(initialValue: !isEmpty)
    }

    public var body: some View {
        let sections = NotificationFeedDayGrouping(now: referenceNow, calendar: .current)
            .sections(for: items.sorted { $0.createdAt > $1.createdAt }, createdAt: \.createdAt)
            .map { NotificationFeedSection(day: $0.day, items: $0.items) }
        NavigationStack {
            NotificationFeedView(
                sections: sections,
                isRefreshing: false,
                hasLoaded: true,
                showsIntro: showsIntro,
                pushEnabled: pushEnabled,
                actions: NotificationFeedActions(
                    refresh: {},
                    open: { item in setRead(item.id, true) },
                    toggleRead: { item in setRead(item.id, !item.isRead) },
                    remove: { item in items.removeAll { $0.id == item.id } },
                    dismissIntro: { showsIntro = false },
                    enablePush: { pushEnabled = true }
                )
            )
        }
    }

    private func setRead(_ id: UUID, _ isRead: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = items[index].settingRead(isRead)
    }

    private static func fixtures(now: Date) -> [MobileNotificationFeedItem] {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now) ?? now.addingTimeInterval(-259_200)
        return [
            MobileNotificationFeedItem(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                workspaceID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                surfaceID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                title: "Implementation complete",
                subtitle: "Agent",
                body: "Finished the notification feed implementation, ran the focused package tests, and prepared a detailed verification summary for review.",
                createdAt: now.addingTimeInterval(-120),
                isRead: false,
                workspaceName: "cmux"
            ),
            MobileNotificationFeedItem(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                workspaceID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                title: "Waiting for input",
                body: "",
                createdAt: now.addingTimeInterval(-2_400),
                isRead: false,
                workspaceName: "iOS"
            ),
            MobileNotificationFeedItem(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                workspaceID: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                title: "Docs updated",
                subtitle: "Writer",
                body: "Added the migration guide.",
                createdAt: now.addingTimeInterval(-10_800),
                isRead: true,
                workspaceName: "Documentation"
            ),
            MobileNotificationFeedItem(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                workspaceID: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
                title: "テストが完了しました",
                body: "すべてのテストに合格しました。",
                createdAt: yesterday,
                isRead: true,
                workspaceName: "ローカライズ"
            ),
            MobileNotificationFeedItem(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
                workspaceID: UUID(uuidString: "20000000-0000-0000-0000-000000000005")!,
                title: "Workspace removed",
                body: "This notification remains available after its workspace was deleted.",
                createdAt: threeDaysAgo,
                isRead: false,
                workspaceName: nil
            ),
        ]
    }
}
#endif
