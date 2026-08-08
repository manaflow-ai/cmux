import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import Foundation
import XCTest

final class ProjectWorktreeSidebarTests: XCTestCase {
    func testCustomDescriptionReplacesBranchSubtitle() throws {
        let workspace = CmuxSidebarProviderWorkspace(
            id: UUID(),
            title: "Issue 4889",
            customDescription: "Custom workspace description",
            isPinned: false,
            rootPath: "/tmp/issue-4889",
            projectRootPath: "/tmp/issue-4889",
            branchSummary: "issue-4889-branch",
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            unreadCount: 0,
            latestNotificationText: nil,
            listeningPorts: []
        )

        try assertCustomDescriptionSubtitle(for: workspace)
    }

    func testLiveSnapshotUsesCustomDescriptionAsSubtitle() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let snapshotPath = environment["CMUX_PROJECT_WORKTREE_SNAPSHOT_PATH"] else {
            throw XCTSkip("Live snapshot fixture is supplied by test-e2e.yml")
        }
        let expectedDescription = try XCTUnwrap(
            environment["CMUX_PROJECT_WORKTREE_EXPECTED_DESCRIPTION"]
        )
        let expectedBranch = try XCTUnwrap(
            environment["CMUX_PROJECT_WORKTREE_EXPECTED_BRANCH"]
        )
        let workspace = try liveWorkspace(at: snapshotPath, expectedDescription: expectedDescription)

        XCTAssertEqual(workspace.customDescription, expectedDescription)
        XCTAssertEqual(workspace.branchSummary, expectedBranch)
        try assertCustomDescriptionSubtitle(for: workspace)
    }

    private func assertCustomDescriptionSubtitle(
        for workspace: CmuxSidebarProviderWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: workspace.id,
            workspaces: [workspace]
        )
        let model = ProjectWorktreeSidebar().render(snapshot: snapshot)
        let row = try XCTUnwrap(
            model.sections.lazy.flatMap(\.rows).first { $0.workspaceId == workspace.id },
            "Expected the provider render model to contain the workspace",
            file: file,
            line: line
        )

        XCTAssertEqual(
            row.subtitle,
            workspace.customDescription.map(CmuxSidebarProviderText.plain),
            "Expected customDescription to be the rendered workspace subtitle",
            file: file,
            line: line
        )
        XCTAssertNotEqual(
            row.subtitle,
            workspace.branchSummary.map(CmuxSidebarProviderText.plain),
            "The git branch must only be the fallback subtitle",
            file: file,
            line: line
        )
    }

    private func liveWorkspace(
        at path: String,
        expectedDescription: String
    ) throws -> CmuxSidebarProviderWorkspace {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let payload = (root["result"] as? [String: Any]) ?? root
        let workspaces = try XCTUnwrap(payload["workspaces"] as? [[String: Any]])
        let value = try XCTUnwrap(
            workspaces.first { ($0["description"] as? String) == expectedDescription },
            "Expected the live extension snapshot to contain the described workspace"
        )

        return CmuxSidebarProviderWorkspace(
            id: try XCTUnwrap(UUID(uuidString: try XCTUnwrap(value["id"] as? String))),
            title: try XCTUnwrap(value["title"] as? String),
            customDescription: value["description"] as? String,
            isPinned: (value["pinned"] as? Bool) ?? false,
            rootPath: value["root_path"] as? String,
            projectRootPath: value["project_root_path"] as? String,
            branchSummary: value["branch_summary"] as? String,
            remoteDisplayTarget: value["remote_display_target"] as? String,
            remoteConnectionState: value["remote_connection_state"] as? String,
            unreadCount: (value["unread_count"] as? NSNumber)?.intValue ?? 0,
            latestNotificationText: value["latest_notification_text"] as? String,
            latestSubmittedMessage: value["latest_submitted_message"] as? String,
            listeningPorts: (value["listening_ports"] as? [NSNumber])?.map(\.intValue) ?? [],
            pullRequestURLs: value["pull_request_urls"] as? [String] ?? [],
            panelDirectories: value["panel_directories"] as? [String] ?? []
        )
    }
}
