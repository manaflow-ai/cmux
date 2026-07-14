import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import XCTest

final class ProjectWorktreeSidebarTests: XCTestCase {
    func testPinnedOnlyRepositoryPreservesHostBackedProjectSection() throws {
        let projectRoot = "/tmp/pinned-only-repository"
        let workspace = CmuxSidebarProviderWorkspace(
            id: UUID(),
            title: "Pinned workspace",
            customDescription: nil,
            isPinned: true,
            rootPath: projectRoot,
            projectRootPath: projectRoot,
            branchSummary: "main",
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            unreadCount: 0,
            latestNotificationText: nil,
            listeningPorts: []
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: workspace.id,
            workspaces: [workspace]
        )

        let model = ProjectWorktreeSidebar().render(snapshot: snapshot)
        let project = try XCTUnwrap(model.sections.first { section in
            section.treeSection.projectRootPath == projectRoot
        })

        XCTAssertTrue(project.rows.isEmpty)
        XCTAssertTrue(project.treeSection.workspaceIds.isEmpty)
    }
}
