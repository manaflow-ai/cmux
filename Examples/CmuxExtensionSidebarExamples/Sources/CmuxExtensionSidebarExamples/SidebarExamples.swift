import CmuxSidebarProviderKit
import Foundation

public enum SidebarExamples {
    public static let providers: [any CmuxSidebarProvider] = [
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
    var title: CmuxSidebarProviderLocalizedText
    var systemImageName: String
    var projectRootPath: String?
    var workspaces: [CmuxSidebarProviderWorkspace]

    func render(
        rowTitle: (CmuxSidebarProviderWorkspace) -> String = { $0.title },
        accessory: CmuxSidebarProviderRowAccessory? = .inspector,
        subtitle: (CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? = { _ in nil },
        trailingText: (CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? = { _ in nil },
        leadingIcon: (CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderIcon? = { _ in nil }
    ) -> CmuxSidebarProviderSection {
        CmuxSidebarProviderSection(
            id: id,
            treeSection: CmuxSidebarProviderTreeSection(
                id: id,
                title: title.defaultValue,
                titleText: title,
                subtitle: nil,
                systemImageName: systemImageName,
                projectRootPath: projectRootPath,
                workspaceIds: workspaces.map(\.id)
            ),
            rows: workspaces.map { workspace in
                CmuxSidebarProviderRow(
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

func localized(_ key: String, _ defaultValue: String) -> CmuxSidebarProviderLocalizedText {
    CmuxSidebarProviderLocalizedText(key: key, defaultValue: defaultValue)
}

func renderModel(
    providerId: String,
    snapshot: CmuxSidebarProviderSnapshot,
    sections: [CmuxSidebarProviderSection],
    presentation: CmuxSidebarProviderPresentation = .tree
) -> CmuxSidebarProviderRenderModel {
    CmuxSidebarProviderRenderModel(
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

func projectRoot(for workspace: CmuxSidebarProviderWorkspace) -> String? {
    trimmed(workspace.projectRootPath)
}

func displayName(for path: String) -> String {
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let name = url.lastPathComponent
    return name.isEmpty ? path : name
}
