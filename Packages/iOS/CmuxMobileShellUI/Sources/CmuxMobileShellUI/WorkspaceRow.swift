import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceRow: View {
    private static let unreadDotRailVisualGap: CGFloat = 8
    private static let railTextVisualGap: CGFloat = 10
    private static let railVerticalInset: CGFloat = 5
    private static let unreadDotAlignmentHeight: CGFloat = 22

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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Unread is JUST this dot, left of the workspace rail. The
            // gutter is always present (hidden dot when read) so read and
            // unread rows line up.
            WorkspaceUnreadDot(isUnread: workspace.hasUnread, leftShift: unreadIndicatorLeftShift)
                .frame(height: Self.unreadDotAlignmentHeight)

            Spacer()
                .frame(width: unreadDotRailLayoutGap)

            Color.clear
                .frame(width: WorkspaceColorRail.width)

            Spacer()
                .frame(width: Self.railTextVisualGap)

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
                }

                Text(workspace.previewLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(previewLineLimit, reservesSpace: true)
            }
        }
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: railLeadingOffset)

                WorkspaceColorRail(color: workspace.workspaceAccentColor)
                    .padding(.vertical, Self.railVerticalInset)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
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

    private var unreadDotRailLayoutGap: CGFloat {
        let dotTrailing = (WorkspaceUnreadDot.gutterWidth + WorkspaceUnreadDot.dotDiameter) / 2
            - CGFloat(unreadIndicatorLeftShift)
        return max(
            0,
            Self.unreadDotRailVisualGap + dotTrailing - WorkspaceUnreadDot.gutterWidth
        )
    }

    private var railLeadingOffset: CGFloat {
        WorkspaceUnreadDot.gutterWidth + unreadDotRailLayoutGap
    }
}

struct WorkspaceColorRail: View {
    static let width: CGFloat = 3
    private static let cornerRadius: CGFloat = 1.5

    let color: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(color ?? Color.clear)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .opacity(color == nil ? 0 : 0.95)
            .accessibilityHidden(true)
    }
}
