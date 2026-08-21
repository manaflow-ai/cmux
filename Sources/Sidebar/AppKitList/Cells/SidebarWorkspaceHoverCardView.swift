import SwiftUI

/// Hover-card detail for one workspace row in the icon rail: everything the
/// compact presentation stopped showing inline, in reading order.
struct SidebarWorkspaceHoverCardView: View {
    let model: SidebarWorkspaceRowModel

    var body: some View {
        SidebarHoverCardShell(
            icon: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(avatarTint)
                    .overlay {
                        Text(avatarLetter)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary)
                    }
            },
            title: model.snapshot.title
        ) {
            if let description = model.snapshot.customDescription, !description.isEmpty {
                SidebarHoverCardDetailRow(text: description)
            }
            if let remoteText = model.snapshot.remoteWorkspaceSidebarText, !remoteText.isEmpty {
                SidebarHoverCardDetailRow(text: remoteText)
            }
            if let branchSummary = model.snapshot.compactGitBranchSummaryText, !branchSummary.isEmpty {
                SidebarHoverCardDetailRow(text: branchSummary)
            }
            if model.unreadCount > 0 {
                SidebarHoverCardDetailRow(
                    text: String(
                        localized: "sidebar.workspace.hoverCard.unread",
                        defaultValue: "\(model.unreadCount) unread"
                    ),
                    secondary: false
                )
            }
        }
    }

    private var avatarTint: Color {
        if let hex = model.snapshot.customColorHex,
           let color = WorkspaceTabColorSettings.displayNSColor(
               hex: hex,
               colorScheme: model.colorSchemeIsDark ? .dark : .light,
               forceBright: false
           )
        {
            return Color(nsColor: color).opacity(0.4)
        }
        return Color.secondary.opacity(0.18)
    }

    private var avatarLetter: String {
        guard let first = model.snapshot.title
            .trimmingCharacters(in: .whitespacesAndNewlines).first
        else { return "•" }
        return String(first).uppercased()
    }
}

/// Hover-card detail for a group header row in the icon rail.
struct SidebarGroupHoverCardView: View {
    let model: SidebarGroupHeaderRowModel

    var body: some View {
        SidebarHoverCardShell(
            icon: {
                Image(systemName: model.iconSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            },
            title: model.name
        ) {
            SidebarHoverCardDetailRow(
                text: String(
                    localized: "sidebar.group.hoverCard.memberCount",
                    defaultValue: "\(model.memberCount) workspaces"
                )
            )
            if model.isCollapsed {
                SidebarHoverCardDetailRow(
                    text: String(
                        localized: "sidebar.group.hoverCard.collapsed",
                        defaultValue: "Collapsed"
                    )
                )
            }
        }
    }
}
