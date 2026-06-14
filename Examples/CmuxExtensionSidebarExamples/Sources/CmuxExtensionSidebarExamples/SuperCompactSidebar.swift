import CmuxSidebarProviderKit
import Foundation

public struct SuperCompactSidebar: CmuxSidebarProvider {
    public let descriptor = CmuxSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.super-compact",
        title: localized("example.sidebar.superCompact.title", "Super Compact"),
        subtitle: localized("example.sidebar.superCompact.subtitle", "User extension"),
        systemImageName: "rectangle.compress.vertical",
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        let ordered = snapshot.workspaces.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let section = ExampleSidebarSection(
            id: "workspaces",
            title: localized("example.sidebar.group.workspaces", "Workspaces"),
            systemImageName: "list.bullet",
            projectRootPath: nil,
            workspaces: ordered
        )
        .render(
            rowTitle: compactTitle,
            accessory: nil,
            trailingText: unreadTrailingText
        )

        return renderModel(providerId: descriptor.id, snapshot: snapshot, sections: [section])
    }

    private func compactTitle(_ workspace: CmuxSidebarProviderWorkspace) -> String {
        if let projectRoot = projectRoot(for: workspace) {
            return displayName(for: projectRoot)
        }
        return workspace.title
    }

    private func unreadTrailingText(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? {
        workspace.unreadCount > 0 ? .plain("\(workspace.unreadCount)") : nil
    }
}
