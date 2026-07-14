#if DEBUG
import SwiftUI

/// Maps each shared conversation role into Phosphor's flat message treatment.
struct PhosphorChatEntryView: View {
    let entry: GalleryChatEntry

    @Environment(\.colorScheme) private var colorScheme
    private let typography = PhosphorTypography()

    @ViewBuilder
    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.text)
                        .font(typography.body)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.timeText)
                        .font(typography.monoCaption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

        case .agent:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("Agent")
                        .font(typography.captionSemibold)
                        .foregroundStyle(theme.textSecondary)
                    Text(entry.timeText)
                        .font(typography.monoCaption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }
                Text(entry.text)
                    .font(typography.body)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            if let command = entry.toolCommand, let output = entry.toolOutput {
                PhosphorToolCard(
                    title: entry.text,
                    command: command,
                    output: output,
                    timeText: entry.timeText
                )
            }

        case .approval:
            if let question = entry.question {
                PhosphorApprovalCard(question: question, timeText: entry.timeText)
            }
        }
    }
}
#endif
