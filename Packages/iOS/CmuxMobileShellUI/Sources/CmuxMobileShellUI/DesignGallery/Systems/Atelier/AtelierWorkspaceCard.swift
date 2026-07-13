#if DEBUG
import SwiftUI

/// Presents one workspace as a calm card with an embedded next action when needed.
struct AtelierWorkspaceCard: View {
    let workspace: GalleryWorkspaceFixture

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        Button(action: {}) {
            HStack(spacing: 0) {
                if workspace.state == .needsYou {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.needsYou)
                        .frame(width: 4)
                        .padding(.vertical, 4)
                        .padding(.trailing, 16)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workspace.name)
                                .font(.system(size: 19, weight: .semibold, design: .serif))
                                .foregroundStyle(theme.textPrimary)
                            Text(workspace.branch)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Text(workspace.elapsedText)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textTertiary)
                    }

                    AtelierStatusMark(state: workspace.state)

                    if let question = workspace.pendingQuestion {
                        Text(question)
                            .font(.system(size: 16, weight: .regular, design: .serif))
                            .italic()
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Review request")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.accentForeground)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        Text(workspace.detailText)
                            .font(.system(size: 16))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("\(workspace.agentName) · \(workspace.absoluteTimeText)")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(theme.hairline, lineWidth: 1)
            }
            .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(AtelierPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(workspace.state == .needsYou ? "Review request" : "Open workspace")
    }
}
#endif
