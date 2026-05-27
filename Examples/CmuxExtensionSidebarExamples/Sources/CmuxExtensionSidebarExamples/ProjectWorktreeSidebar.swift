import CmuxExtensionKit
import Foundation

public struct ProjectWorktreeSidebar: CmuxExtensionSidebarProvider {
    public let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.project-worktrees",
        title: localized("example.sidebar.projectWorktrees.title", "Project Worktrees"),
        subtitle: localized("example.sidebar.projectWorktrees.subtitle", "User extension"),
        systemImageName: "folder",
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        var sections: [CmuxExtensionSidebarRenderSection] = []

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

        var grouped: [String: [CmuxExtensionWorkspaceSnapshot]] = [:]
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

    private func branchSubtitle(_ workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? {
        trimmed(workspace.branchSummary).map(CmuxExtensionSidebarRenderText.plain)
    }
}
