import CmuxMobileChanges
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceRow: View {
    private static let unreadDotAvatarVisualGap: CGFloat = 10
    private static let avatarTextVisualGap: CGFloat = 8

    let workspace: MobileWorkspacePreview
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    /// The workspace's `+adds −dels` changes summary, when the connected Mac
    /// supports workspace changes and the repository is dirty. Rendered here
    /// (not in a wrapper) so every list pipeline that shows a workspace row
    /// (SwiftUI List and the UIKit table) carries the same signifier.
    var changesChip: MobileWorkspaceChangesChip? = nil
    /// When `true`, the workspace title wraps onto multiple lines instead of
    /// truncating to one (driven by the "Wrap Workspace Titles" setting).
    let wrapWorkspaceTitles: Bool
    /// How many lines the activity preview shows (1 or 2, driven by the
    /// "Preview Lines" setting; 2 is the default). Space is reserved so rows
    /// with short previews keep the same height as their neighbors.
    var previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount
    var unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    var profilePictureLeftShift: Double = MobileDisplaySettings.defaultProfilePictureLeftShift
    var profilePictureSize: Double = MobileDisplaySettings.defaultProfilePictureSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Unread is JUST this dot, left of the icon like iMessage. The
            // gutter is always present (hidden dot when read) so read and
            // unread rows line up. Centered against the avatar's height.
            WorkspaceUnreadDot(isUnread: workspace.hasUnread, leftShift: unreadIndicatorLeftShift)
                .frame(height: CGFloat(profilePictureSize))

            Spacer()
                .frame(width: unreadDotAvatarLayoutGap)

            WorkspaceAvatar(workspace: workspace, size: profilePictureSize, leftShift: profilePictureLeftShift)

            Spacer()
                .frame(width: avatarTextLayoutGap)

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

                    Spacer(minLength: 8)

                    Text(workspace.timestampOrStatus(connectionStatus: connectionStatus))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(alignment: .top, spacing: 8) {
                    Text(workspace.previewLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(previewLineLimit, reservesSpace: true)

                    if let changesChip, changesChip.filesChanged > 0 {
                        Spacer(minLength: 8)
                        WorkspaceChangesChipLabel(chip: changesChip, workspaceID: workspace.rpcWorkspaceID.rawValue)
                    }
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

    private var unreadDotAvatarLayoutGap: CGFloat {
        let dotTrailing = (WorkspaceUnreadDot.gutterWidth + WorkspaceUnreadDot.dotDiameter) / 2
            - CGFloat(unreadIndicatorLeftShift)
        return max(
            0,
            Self.unreadDotAvatarVisualGap + dotTrailing - WorkspaceUnreadDot.gutterWidth
                + CGFloat(profilePictureLeftShift)
        )
    }

    private var avatarTextLayoutGap: CGFloat {
        max(0, Self.avatarTextVisualGap - CGFloat(profilePictureLeftShift))
    }
}

struct WorkspaceAvatar: View {
    let workspace: MobileWorkspacePreview
    var size: Double = MobileDisplaySettings.defaultProfilePictureSize
    var leftShift: Double = MobileDisplaySettings.defaultProfilePictureLeftShift

    var body: some View {
        ZStack {
            Circle()
                .fill(workspace.avatarGradient)
                .frame(width: CGFloat(size), height: CGFloat(size))

            switch workspace.avatarIcon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: CGFloat(size) * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: CGFloat(size) * 0.5))
                    .accessibilityHidden(true)
            }
        }
        .offset(x: -CGFloat(leftShift))
    }
}

/// The compact `+adds −dels` capsule shared by every workspace-row pipeline.
struct WorkspaceChangesChipLabel: View {
    let chip: MobileWorkspaceChangesChip
    let workspaceID: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ChangesTheme(colorScheme: colorScheme)
        HStack(spacing: 3) {
            Text("+\(chip.additions)")
                .foregroundStyle(theme.addedStatus)
            Text("−\(chip.deletions)")
                .foregroundStyle(theme.deletedStatus)
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: String(
                    localized: "workspace.changes.chip.accessibility",
                    defaultValue: "%1$lld additions, %2$lld deletions",
                    bundle: .module
                ),
                chip.additions,
                chip.deletions
            )
        )
        .accessibilityIdentifier("MobileChangesChip-\(workspaceID)")
    }
}
