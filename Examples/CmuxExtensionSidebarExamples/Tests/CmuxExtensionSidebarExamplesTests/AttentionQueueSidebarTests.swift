import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import XCTest

final class AttentionQueueSidebarTests: XCTestCase {
    func testLocalDisconnectedWorkspaceRemainsQuiet() throws {
        let local = workspace(
            title: "Local",
            customDescription: "Local project",
            remoteDisplayTarget: nil,
            remoteConnectionState: "disconnected"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [local]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        XCTAssertNil(model.sections.first { $0.id == "attention" })
        let quiet = try XCTUnwrap(model.sections.first { $0.id == "quiet" })
        XCTAssertEqual(quiet.rows.map(\.workspaceId), [local.id])
        XCTAssertEqual(quiet.rows.first?.subtitle, .plain("Local project"))
        XCTAssertNil(quiet.rows.first?.subtitleRole)
    }

    func testRemoteDisconnectedWorkspaceNeedsAttention() throws {
        let remote = workspace(
            title: "Remote",
            customDescription: "Remote project",
            remoteDisplayTarget: "devbox",
            remoteConnectionState: "disconnected"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [remote]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        let attention = try XCTUnwrap(model.sections.first { $0.id == "attention" })
        XCTAssertEqual(attention.rows.map(\.workspaceId), [remote.id])
        XCTAssertEqual(attention.rows.first?.subtitle, .plain("disconnected"))
        XCTAssertNil(attention.rows.first?.subtitleRole)
        XCTAssertNil(model.sections.first { $0.id == "quiet" })
    }

    func testLatestNotificationSubtitleIsAgentStatus() throws {
        let waiting = workspace(
            title: "Waiting",
            customDescription: "Agent workspace",
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            latestNotificationText: "Claude is waiting for your input"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [waiting]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        let attention = try XCTUnwrap(model.sections.first { $0.id == "attention" })
        XCTAssertEqual(attention.rows.map(\.workspaceId), [waiting.id])
        XCTAssertEqual(attention.rows.first?.subtitle, .plain("Claude is waiting for your input"))
        XCTAssertEqual(attention.rows.first?.subtitleRole, .agentStatus)
    }

    private func workspace(
        title: String,
        customDescription: String?,
        remoteDisplayTarget: String?,
        remoteConnectionState: String?,
        latestNotificationText: String? = nil
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
            unreadCount: 0,
            latestNotificationText: latestNotificationText,
            listeningPorts: []
        )
    }
}
