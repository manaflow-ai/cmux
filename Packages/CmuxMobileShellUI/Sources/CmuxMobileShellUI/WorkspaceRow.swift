import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceRow: View {
    let workspace: MobileWorkspacePreview
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    /// When `true`, the workspace title wraps onto multiple lines instead of
    /// truncating to one (driven by the "Wrap Workspace Titles" setting).
    let wrapWorkspaceTitles: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkspaceAvatar(workspace: workspace)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(wrapWorkspaceTitles ? nil : 1)

                    if workspace.isUnread {
                        WorkspaceUnreadIndicator(unreadCount: workspace.unreadCount)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 8)

                    Text(workspace.timestampOrStatus(connectionStatus: connectionStatus))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(workspace.previewLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(workspace.statusColor(connectionStatus: connectionStatus))
                        .frame(width: 7, height: 7)

                    Text(workspace.detailLine(connectionStatus: connectionStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }
}

struct WorkspaceAvatar: View {
    let workspace: MobileWorkspacePreview

    var body: some View {
        ZStack {
            Circle()
                .fill(workspace.avatarGradient)
                .frame(width: 48, height: 48)

            Image(systemName: workspace.avatarSymbolName)
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
    }
}

private struct WorkspaceUnreadIndicator: View {
    let unreadCount: Int

    var body: some View {
        if unreadCount > 1 {
            Text("\(min(unreadCount, 99))")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color.accentColor))
        } else {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
        }
    }
}
