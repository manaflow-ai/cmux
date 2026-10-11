import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import XCTest

final class ProjectWorktreeSidebarTests: XCTestCase {
    func testCustomDescriptionTakesPrecedenceOverBranch() throws {
        let described = workspace(
            title: "Described",
            customDescription: "Custom workspace description",
            isPinned: false,
            branchSummary: "issue-4889-branch"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [described]
        )

        let model = ProjectWorktreeSidebar().render(snapshot: snapshot)

        let project = try XCTUnwrap(model.sections.first { $0.id == "project:/tmp/project" })
        XCTAssertEqual(project.rows.map(\.workspaceId), [described.id])
        XCTAssertEqual(project.rows.first?.subtitle, .plain("Custom workspace description"))
    }

    func testPinnedWorkspaceUsesCustomDescription() throws {
        let pinned = workspace(
            title: "Pinned",
            customDescription: "Pinned description",
            isPinned: true,
            branchSummary: "main"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [pinned]
        )

        let model = ProjectWorktreeSidebar().render(snapshot: snapshot)

        let section = try XCTUnwrap(model.sections.first { $0.id == "pinned" })
        XCTAssertEqual(section.rows.map(\.workspaceId), [pinned.id])
        XCTAssertEqual(section.rows.first?.subtitle, .plain("Pinned description"))
    }

    func testBlankCustomDescriptionFallsBackToBranch() throws {
        let blank = workspace(
            title: "Blank",
            customDescription: "  \n",
            isPinned: false,
            branchSummary: "feature/sidebar"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [blank]
        )

        let model = ProjectWorktreeSidebar().render(snapshot: snapshot)

        let project = try XCTUnwrap(model.sections.first { $0.id == "project:/tmp/project" })
        XCTAssertEqual(project.rows.first?.subtitle, .plain("feature/sidebar"))
    }

    private func workspace(
        title: String,
        customDescription: String?,
        isPinned: Bool,
        branchSummary: String?
    ) -> CmuxSidebarProviderWorkspace {
        CmuxSidebarProviderWorkspace(
            id: UUID(),
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            rootPath: "/tmp/project",
            projectRootPath: "/tmp/project",
            branchSummary: branchSummary,
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            unreadCount: 0,
            latestNotificationText: nil,
            listeningPorts: []
        )
    }
}
