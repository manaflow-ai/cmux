import CmuxSidebarProviderKit
import Foundation

public struct ProjectWorktreeSidebar: CmuxSidebarProvider {
    /// Stable identifier used by the host to install Git-backed worktree rows.
    public static let providerID = "com.example.cmux.sidebar.project-worktrees"

    public let descriptor = CmuxSidebarProviderDescriptor(
        id: Self.providerID,
        title: localized("example.sidebar.projectWorktrees.title", "Project Worktrees"),
        subtitle: localized("example.sidebar.projectWorktrees.subtitle", "Built-in"),
        systemImageName: "folder",
        isHostProvided: true
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

        for workspace in snapshot.workspaces {
            let key: String
            if let projectRoot = projectRoot(for: workspace) {
                key = projectRoot
            } else {
                guard !workspace.isPinned else { continue }
                key = "no-folder"
            }
            if grouped[key] == nil {
                grouped[key] = []
                orderedProjectRoots.append(key)
            }
            if !workspace.isPinned {
                grouped[key]?.append(workspace)
            }
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
                    content: root == "no-folder" ? nil : .projectWorktrees,
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
