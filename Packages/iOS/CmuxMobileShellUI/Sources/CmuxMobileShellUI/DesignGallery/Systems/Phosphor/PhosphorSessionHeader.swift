#if DEBUG
import SwiftUI

/// Keeps the active agent's state visible above the full-bleed terminal.
struct PhosphorSessionHeader: View {
    let workspace: GalleryWorkspaceFixture

    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)
        let statusColor = theme.statusColor(workspace.state)

        HStack(spacing: 8) {
            PhosphorStatusDot(state: workspace.state)

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.agentName)
                    .font(typography.bodySemibold)
                    .foregroundStyle(theme.textPrimary)
                Text(workspace.branch)
                    .font(typography.monoCaption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: theme.statusSymbol(workspace.state))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(statusColor)

            Text(theme.statusLabel(workspace.state))
                .font(typography.captionSemibold)
                .foregroundStyle(statusColor)

            Text(workspace.elapsedText)
                .font(typography.dataMedium)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(theme.bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }
}
#endif
