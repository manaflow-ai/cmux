import CmuxSidebarProviderKit
import Foundation

public struct ProjectWorktreeSidebar: CmuxSidebarProvider {
    public let descriptor = CmuxSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.project-worktrees",
        title: localized("example.sidebar.projectWorktrees.title", "Project Worktrees"),
        subtitle: localized("example.sidebar.projectWorktrees.subtitle", "User extension"),
        systemImageName: "folder",
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        var sections: [CmuxSidebarProviderSection] = []

        sections.append(
            ExampleSidebarSection(
                id: "pinned",
                title: localized("example.sidebar.group.pinned", "Pinned"),
                systemImageName: "pin",
                projectRootPath: nil,
                workspaces: snapshot.workspaces.filter(\.isPinned)
            )
            .render(subtitle: branchSubtitle)
        )

        var grouped: [String: [CmuxSidebarProviderWorkspace]] = [:]
        var orderedProjectRoots: [String] = []

        for workspace in snapshot.workspaces where !workspace.isPinned {
            let key = projectRoot(for: workspace) ?? "no-folder"
            if grouped[key] == nil {
                grouped[key] = []
                orderedProjectRoots.append(key)
            }
            grouped[key]?.append(workspace)
        }

        for root in orderedProjectRoots {
            let title = root == "no-folder" ? "No Folder" : displayName(for: root)
            let titleText = root == "no-folder"
                ? localized("example.sidebar.group.noFolder", "No Folder")
                : localized("example.sidebar.group.project", title)
            sections.append(
                ExampleSidebarSection(
                    id: "project:\(root)",
                    title: titleText,
                    systemImageName: root == "no-folder" ? "tray" : "folder",
                    projectRootPath: root == "no-folder" ? nil : root,
                    workspaces: grouped[root] ?? []
                )
                .render(subtitle: branchSubtitle)
            )
        }

        return renderModel(providerId: descriptor.id, snapshot: snapshot, sections: sections)
    }

    private func branchSubtitle(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? {
        trimmed(workspace.branchSummary).map(CmuxSidebarProviderText.plain)
    }
}
