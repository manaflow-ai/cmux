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
        XCTAssertNil(model.sections.first { $0.id == "quiet" })
    }

    private func workspace(
        title: String,
        customDescription: String?,
        remoteDisplayTarget: String?,
        remoteConnectionState: String?
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
            latestNotificationText: nil,
            listeningPorts: []
        )
    }
}
