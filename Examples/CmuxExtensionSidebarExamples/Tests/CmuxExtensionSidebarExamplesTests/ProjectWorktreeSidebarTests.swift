import CmuxSidebarProviderKit
@testable import CmuxExtensionSidebarExamples
import Foundation
import Testing

@Suite
struct ProjectWorktreeSidebarTests {
    @Test
    func descriptorIdentifiesBundledProvider() {
        let descriptor = ProjectWorktreeSidebar().descriptor

        #expect(descriptor.isHostProvided)
        #expect(descriptor.subtitle?.defaultValue == "Built-in")
    }

    @Test
    func pinnedOnlyRepositoryPreservesHostBackedProjectSection() throws {
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
        let project = try #require(model.sections.first { section in
            section.treeSection.projectRootPath == projectRoot
        })

        #expect(project.rows.isEmpty)
        #expect(project.treeSection.workspaceIds.isEmpty)
        #expect(project.treeSection.content == .projectWorktrees)
    }

    @Test
    func sectionContentIsOptionalAndRoundTrips() throws {
        let ordinary = CmuxSidebarProviderTreeSection(
            id: "ordinary",
            title: "Ordinary",
            subtitle: nil,
            systemImageName: "folder",
            projectRootPath: nil,
            workspaceIds: []
        )
        #expect(ordinary.content == nil)

        var project = ordinary
        project.content = .projectWorktrees
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(CmuxSidebarProviderTreeSection.self, from: encoded)

        #expect(decoded.content == .projectWorktrees)
    }
}
