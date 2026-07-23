import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceRow: View {
    private static let unreadDotColorCircleVisualGap: CGFloat = 10
    private static let colorCircleTextVisualGap: CGFloat = 8

    let workspace: MobileWorkspacePreview
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
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
            // Unread is JUST this dot, left of the color circle like iMessage. The
            // gutter is always present (hidden dot when read) so read and
            // unread rows line up. Centered against the color circle's height.
            WorkspaceUnreadDot(isUnread: workspace.hasUnread, leftShift: unreadIndicatorLeftShift)
                .frame(height: CGFloat(profilePictureSize))

            Spacer()
                .frame(width: unreadDotColorCircleLayoutGap)

            WorkspaceColorCircle(
                color: workspace.workspaceAccentColor,
                size: profilePictureSize,
                leftShift: profilePictureLeftShift
            )

            Spacer()
                .frame(width: colorCircleTextLayoutGap)

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

                if let description = workspace.displayDescription {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                        .accessibilityIdentifier("MobileWorkspaceDescription-\(workspace.id.rawValue)")
                }

                Text(workspace.previewLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(previewLineLimit, reservesSpace: true)
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

    private var unreadDotColorCircleLayoutGap: CGFloat {
        let dotTrailing = (WorkspaceUnreadDot.gutterWidth + WorkspaceUnreadDot.dotDiameter) / 2
            - CGFloat(unreadIndicatorLeftShift)
        return max(
            0,
            Self.unreadDotColorCircleVisualGap + dotTrailing - WorkspaceUnreadDot.gutterWidth
                + CGFloat(profilePictureLeftShift)
        )
    }

    private var colorCircleTextLayoutGap: CGFloat {
        max(0, Self.colorCircleTextVisualGap - CGFloat(profilePictureLeftShift))
    }
}

struct WorkspaceColorCircle: View {
    let color: Color?
    var size: Double = MobileDisplaySettings.defaultProfilePictureSize
    var leftShift: Double = MobileDisplaySettings.defaultProfilePictureLeftShift

    var body: some View {
        Circle()
            .fill(color ?? Color.clear)
            .frame(width: CGFloat(size), height: CGFloat(size))
            .accessibilityHidden(true)
            .offset(x: -CGFloat(leftShift))
    }
}
