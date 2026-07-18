#if DEBUG
import SwiftUI

/// Maps a shared conversation fixture entry into Atelier's conversational components.
struct AtelierChatEntryView: View {
    let entry: GalleryChatEntry

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(entry.text)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(entry.timeText)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(16)
                .background(
                    theme.accent.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
        case .agent:
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.text)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textPrimary)
                    .lineSpacing(6.4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.timeText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundStyle(theme.accent)
                    Text("Ran a command")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(entry.timeText)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }

                Text(entry.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSecondary)

                if let command = entry.toolCommand {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                }

                if let output = entry.toolOutput {
                    Text(output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineSpacing(4)
                }
            }
            .padding(16)
            .background(theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .approval:
            VStack(alignment: .leading, spacing: 16) {
                AtelierStatusMark(state: .needsYou)

                if let question = entry.question {
                    Text(question)
                        .font(.system(size: 19, weight: .semibold, design: .serif))
                        .italic()
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {}) {
                    Text(DesignGalleryFixtures.approvalActions[0])
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.accentForeground)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(AtelierPressButtonStyle())

                Button(action: {}) {
                    Text("Not yet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(AtelierPressButtonStyle())
            }
            .padding(16)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(theme.hairline, lineWidth: 1)
            }
            .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 2)
        }
    }
}
#endif
