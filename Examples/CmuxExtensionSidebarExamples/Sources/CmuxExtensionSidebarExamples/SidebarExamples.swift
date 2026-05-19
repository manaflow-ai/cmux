import CmuxExtensionKit
import Foundation

public enum SidebarExamples {
    public static let providers: [any CmuxExtensionSidebarProvider] = [
        ProjectWorktreeSidebar(),
        AttentionQueueSidebar(),
        DevServerSidebar(),
        LastPromptSidebar(),
        SuperCompactSidebar(),
    ]
}

struct ExampleSidebarSection {
    var id: String
    var title: CmuxExtensionLocalizedText
    var systemImageName: String
    var projectRootPath: String?
    var workspaces: [CmuxExtensionWorkspaceSnapshot]

    func render(
        rowTitle: (CmuxExtensionWorkspaceSnapshot) -> String = { $0.title },
        accessory: CmuxExtensionWorkspaceRowAccessory? = .inspector,
        subtitle: (CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? = { _ in nil },
        trailingText: (CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? = { _ in nil }
    ) -> CmuxExtensionSidebarRenderSection {
        CmuxExtensionSidebarRenderSection(
            id: id,
            treeSection: CmuxExtensionWorkspaceTreeSection(
                id: id,
                title: title.defaultValue,
                titleText: title,
                subtitle: nil,
                systemImageName: systemImageName,
                projectRootPath: projectRootPath,
                workspaceIds: workspaces.map(\.id)
            ),
            rows: workspaces.map { workspace in
                CmuxExtensionSidebarRenderRow(
                    id: workspace.id,
                    title: rowTitle(workspace),
                    workspaceId: workspace.id,
                    accessory: accessory,
                    subtitle: subtitle(workspace),
                    trailingText: trailingText(workspace)
                )
            }
        )
    }
}

func localized(_ key: String, _ defaultValue: String) -> CmuxExtensionLocalizedText {
    CmuxExtensionLocalizedText(key: key, defaultValue: defaultValue)
}

func renderModel(
    providerId: String,
    snapshot: CmuxExtensionSidebarSnapshot,
    sections: [CmuxExtensionSidebarRenderSection]
) -> CmuxExtensionSidebarRenderModel {
    CmuxExtensionSidebarRenderModel(
        providerId: providerId,
        snapshotSequence: snapshot.sequence,
        sections: sections.filter { !$0.rows.isEmpty }
    )
}

func trimmed(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func projectRoot(for workspace: CmuxExtensionWorkspaceSnapshot) -> String? {
    trimmed(workspace.projectRootPath)
        ?? trimmed(workspace.rootPath).map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL
                .deletingLastPathComponent()
                .path
        }
}

func displayName(for path: String) -> String {
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let name = url.lastPathComponent
    return name.isEmpty ? path : name
}
