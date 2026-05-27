import CmuxExtensionKit
import Foundation

struct CompactUnreadSidebar: CmuxExtensionSidebarProvider {
    let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "example.compactUnread",
        title: CmuxExtensionLocalizedText(
            key: "example.compactUnread.title",
            defaultValue: "Compact Unread"
        ),
        subtitle: CmuxExtensionLocalizedText(
            key: "example.compactUnread.subtitle",
            defaultValue: "Custom sidebar"
        ),
        systemImageName: "text.badge.checkmark",
        isHostProvided: false
    )

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        let sorted = snapshot.workspaces.sorted { lhs, rhs in
            if lhs.unreadCount != rhs.unreadCount {
                return lhs.unreadCount > rhs.unreadCount
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let section = CmuxExtensionSidebarRenderSection(
            id: "workspaces",
            treeSection: CmuxExtensionWorkspaceTreeSection(
                id: "workspaces",
                title: "Workspaces",
                titleText: CmuxExtensionLocalizedText(
                    key: "example.compactUnread.section.workspaces",
                    defaultValue: "Workspaces"
                ),
                subtitle: nil,
                systemImageName: "rectangle.stack",
                projectRootPath: nil,
                workspaceIds: sorted.map(\.id)
            ),
            rows: sorted.map { workspace in
                CmuxExtensionSidebarRenderRow(
                    id: workspace.id,
                    title: workspace.title,
                    workspaceId: workspace.id,
                    accessory: .inspector,
                    subtitle: subtitle(for: workspace),
                    trailingText: workspace.unreadCount > 0 ? .plain("\(workspace.unreadCount)") : nil,
                    leadingIcon: icon(for: workspace)
                )
            }
        )

        return CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: [section]
        )
    }

    private func subtitle(for workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? {
        if let latest = workspace.latestNotificationText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !latest.isEmpty {
            return .plain(latest)
        }
        if let branch = workspace.branchSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !branch.isEmpty {
            return .plain(branch)
        }
        return workspace.rootPath.map { .plain(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    private func icon(for workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderIcon {
        if workspace.unreadCount > 0 {
            return CmuxExtensionSidebarRenderIcon(
                systemImageName: "bell.fill",
                foregroundColorHex: "ffffff",
                backgroundColorHex: "d83b3b"
            )
        }
        return CmuxExtensionSidebarRenderIcon(
            systemImageName: workspace.isPinned ? "pin.fill" : "terminal",
            foregroundColorHex: "ffffff",
            backgroundColorHex: workspace.isPinned ? "3b82f6" : "68707d"
        )
    }
}

try CmuxExtensionSidebarExecutable.run(provider: CompactUnreadSidebar())
