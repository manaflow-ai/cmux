import CmuxExtensionKit
import Foundation

public enum SidebarExamples {
    public static let providers: [any CmuxExtensionSidebarProvider] = [
        ProjectWorktreeSidebar(),
        AttentionQueueSidebar(),
        DevServerSidebar(),
        LastPromptSidebar(),
        SuperCompactSidebar(),
        BrowserStackSidebar(onAsyncStateLoaded: {
            BrowserStackSidebar.postStateDidLoadNotification()
        }),
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
        trailingText: (CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? = { _ in nil },
        leadingIcon: (CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderIcon? = { _ in nil }
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
                    trailingText: trailingText(workspace),
                    leadingIcon: leadingIcon(workspace)
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
    sections: [CmuxExtensionSidebarRenderSection],
    presentation: CmuxExtensionSidebarPresentation = .tree
) -> CmuxExtensionSidebarRenderModel {
    CmuxExtensionSidebarRenderModel(
        providerId: providerId,
        snapshotSequence: snapshot.sequence,
        sections: presentation == .browserStack ? sections : sections.filter { !$0.rows.isEmpty },
        presentation: presentation
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
}

func displayName(for path: String) -> String {
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let name = url.lastPathComponent
    return name.isEmpty ? path : name
}
