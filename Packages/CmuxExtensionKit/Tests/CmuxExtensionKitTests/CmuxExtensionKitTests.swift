import XCTest
@testable import CmuxExtensionKit

final class CmuxExtensionKitTests: XCTestCase {
    func testBuiltInProviderIDsAreStable() {
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.projectTree.id, "cmux.sidebar.project-tree")
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.attention.mode, .attention)
        XCTAssertEqual(CmuxExtensionSidebarProviderDescriptor.servers.mode, .servers)
    }

    func testProviderRenderModelAddsInspectorAccessories() {
        let first = workspace(title: "API", rootPath: "/tmp/cmux/api", projectRootPath: "/tmp/cmux")
        let second = workspace(title: "Web", rootPath: "/tmp/cmux/web", projectRootPath: "/tmp/cmux")
        let snapshot = CmuxExtensionSidebarSnapshot(
            sequence: 42,
            selectedWorkspaceId: first.id,
            workspaces: [first, second]
        )

        let model = CmuxExtensionWorkspaceTreeProvider(descriptor: .projectTree).render(snapshot: snapshot)

        XCTAssertEqual(model.providerId, CmuxExtensionSidebarProviderID.projectTree)
        XCTAssertEqual(model.snapshotSequence, 42)
        XCTAssertEqual(model.sections.map(\.treeSection.id), ["folder:/tmp/cmux"])
        XCTAssertEqual(model.sections[0].rows.map(\.workspaceId), [first.id, second.id])
        XCTAssertEqual(model.sections[0].rows.map(\.accessory?.kind), [.workspaceInspector, .workspaceInspector])
    }

    func testPresentationRequestCodableRoundTrips() throws {
        let workspaceId = UUID()
        let request = CmuxExtensionSidebarPresentationRequest.openWorkspaceWindow(
            workspaceId: workspaceId,
            preferredTab: .pullRequest
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CmuxExtensionSidebarPresentationRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    private func workspace(
        title: String,
        rootPath: String?,
        projectRootPath: String?
    ) -> CmuxExtensionWorkspaceSnapshot {
        CmuxExtensionWorkspaceSnapshot(
            id: UUID(),
            title: title,
            customDescription: nil,
            isPinned: false,
            rootPath: rootPath,
            projectRootPath: projectRootPath,
            branchSummary: nil,
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            unreadCount: 0,
            latestNotificationText: nil,
            listeningPorts: []
        )
    }
}
