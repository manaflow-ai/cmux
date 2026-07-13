#if DEBUG
import SwiftUI

/// Displays one dense workspace snapshot in Phosphor's attention queue.
struct PhosphorWorkspaceRow: View {
    let workspace: GalleryWorkspaceFixture

    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)
        let statusColor = theme.statusColor(workspace.state)

        HStack(spacing: 8) {
            VStack(spacing: 4) {
                PhosphorStatusDot(state: workspace.state)
                Image(systemName: theme.statusSymbol(workspace.state))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(typography.bodySemibold)
                        .foregroundStyle(theme.textPrimary)
                    Text(workspace.agentName)
                        .font(typography.caption)
                        .foregroundStyle(theme.textTertiary)
                }

                Text(workspace.branch)
                    .font(typography.monoCaption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(workspace.elapsedText)
                    .font(typography.dataMedium)
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                Text(theme.statusLabel(workspace.state))
                    .font(typography.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background {
            if theme.isNeedsYou(workspace.state) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.statusNeedsYou.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.statusNeedsYou, lineWidth: 1)
                    }
            } else {
                Rectangle().fill(theme.bg1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(workspace.name), \(workspace.branch), \(theme.statusLabel(workspace.state)), \(workspace.elapsedText), \(workspace.detailText)"
        )
    }
}
#endif
