import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import XCTest

final class SmartSchedulerSidebarTests: XCTestCase {
    func testBalancedAgesOlderUnreadNotificationsAhead() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let newer = workspace(
            title: "Newer",
            unreadCount: 1,
            latestNotificationText: "needs review",
            latestNotificationCreatedAt: now.addingTimeInterval(-60),
            latestNotificationIsUnread: true
        )
        let older = workspace(
            title: "Older",
            unreadCount: 1,
            latestNotificationText: "needs review",
            latestNotificationCreatedAt: now.addingTimeInterval(-90 * 60),
            latestNotificationIsUnread: true
        )

        let model = SmartSchedulerSidebar(strategy: .balanced).render(
            snapshot: snapshot([newer, older]),
            context: CmuxSidebarProviderRenderContext(now: now)
        )

        let focus = try XCTUnwrap(model.sections.first { $0.id == "focus" })
        XCTAssertEqual(focus.rows.map(\.workspaceId), [older.id, newer.id])
    }

    func testBlockedFirstElevatesBlockedWorkspace() throws {
        let ready = workspace(
            title: "Ready",
            latestNotificationText: "tests passed, ready to review",
            pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/1"]
        )
        let blocked = workspace(
            title: "Blocked",
            latestNotificationText: "needs input before continuing"
        )

        let model = SmartSchedulerSidebar(strategy: .blockedFirst).render(snapshot: snapshot([ready, blocked]))

        let focus = try XCTUnwrap(model.sections.first { $0.id == "focus" })
        XCTAssertEqual(focus.rows.map(\.workspaceId), [blocked.id, ready.id])
    }

    func testSmallWinsElevatesReadySmallWork() throws {
        let failedLargeTask = workspace(
            title: "Large refactor",
            latestNotificationText: "build failed after large migration"
        )
        let smallReadyTask = workspace(
            title: "Small bug fix",
            latestNotificationText: "opened PR, tests passed",
            pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/2"]
        )

        let model = SmartSchedulerSidebar(strategy: .smallWins).render(snapshot: snapshot([failedLargeTask, smallReadyTask]))

        let focus = try XCTUnwrap(model.sections.first { $0.id == "focus" })
        XCTAssertEqual(focus.rows.map(\.workspaceId), [smallReadyTask.id, failedLargeTask.id])
    }

    func testRoundRobinKeepsWorkspaceOrderAmongUnreadItems() throws {
        let first = workspace(
            title: "First",
            unreadCount: 1,
            latestNotificationText: "newer",
            latestNotificationCreatedAt: Date(timeIntervalSince1970: 200),
            latestNotificationIsUnread: true
        )
        let quiet = workspace(title: "Quiet")
        let third = workspace(
            title: "Third",
            unreadCount: 1,
            latestNotificationText: "older",
            latestNotificationCreatedAt: Date(timeIntervalSince1970: 100),
            latestNotificationIsUnread: true
        )

        let model = SmartSchedulerSidebar(strategy: .roundRobin).render(snapshot: snapshot([first, quiet, third]))

        let focus = try XCTUnwrap(model.sections.first { $0.id == "focus" })
        XCTAssertEqual(focus.rows.map(\.workspaceId), [first.id, third.id])
    }

    private func snapshot(_ workspaces: [CmuxSidebarProviderWorkspace]) -> CmuxSidebarProviderSnapshot {
        CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: workspaces
        )
    }

    private func workspace(
        title: String,
        customDescription: String? = nil,
        remoteDisplayTarget: String? = nil,
        remoteConnectionState: String? = nil,
        unreadCount: Int = 0,
        latestNotificationText: String? = nil,
        latestNotificationCreatedAt: Date? = nil,
        latestNotificationIsUnread: Bool = false,
        latestSubmittedMessage: String? = nil,
        latestSubmittedAt: Date? = nil,
        listeningPorts: [Int] = [],
        pullRequestURLs: [String] = []
    ) -> CmuxSidebarProviderWorkspace {
        CmuxSidebarProviderWorkspace(
            id: UUID(),
            title: title,
            customDescription: customDescription,
            isPinned: false,
            rootPath: nil,
            projectRootPath: nil,
            branchSummary: nil,
            remoteDisplayTarget: remoteDisplayTarget,
            remoteConnectionState: remoteConnectionState,
            unreadCount: unreadCount,
            latestNotificationText: latestNotificationText,
            latestNotificationCreatedAt: latestNotificationCreatedAt,
            latestNotificationIsUnread: latestNotificationIsUnread,
            latestSubmittedMessage: latestSubmittedMessage,
            latestSubmittedAt: latestSubmittedAt,
            listeningPorts: listeningPorts,
            pullRequestURLs: pullRequestURLs
        )
    }
}
