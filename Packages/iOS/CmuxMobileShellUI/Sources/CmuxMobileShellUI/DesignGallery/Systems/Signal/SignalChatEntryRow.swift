#if DEBUG
import SwiftUI

/// Renders one conversation fixture as a timestamped Signal log entry.
struct SignalChatEntryRow: View {
    let entry: GalleryChatEntry
    let theme: SignalTheme

    private var roleLabel: String {
        switch entry.role {
        case .user: "YOU"
        case .agent, .approval: "AGENT"
        case .tool: "TOOL"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SignalSectionLabel(text: roleLabel, color: theme.ink)
                Text(entry.timeText)
                    .font(.system(.footnote, design: .monospaced, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: 58, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.role {
        case .user, .agent:
            Text(entry.text)
                .font(.system(.subheadline, design: .default, weight: .regular))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .tool:
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.text)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(theme.ink)

                VStack(alignment: .leading, spacing: 8) {
                    if let command = entry.toolCommand {
                        Text(command)
                            .font(.system(.footnote, design: .monospaced, weight: .semibold))
                            .foregroundStyle(theme.ink)
                    }
                    if let output = entry.toolOutput {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced, weight: .regular))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.hairline, lineWidth: 1)
                }
            }
        case .approval:
            VStack(alignment: .leading, spacing: 10) {
                let status = SignalStatusStyle(state: .needsYou, theme: theme)
                HStack(spacing: 6) {
                    SignalStatusSquare(color: status.color)
                    SignalSectionLabel(text: status.label, color: theme.ink)
                    Text(status.symbol)
                        .font(.system(.footnote, design: .monospaced, weight: .bold))
                        .foregroundStyle(theme.ink)
                }

                if let question = entry.question {
                    Text(question)
                        .font(.system(.subheadline, design: .default, weight: .regular))
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SignalActionButtons(theme: theme)
            }
            .padding(10)
            .background(theme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.hairline, lineWidth: 1)
            }
        }
    }
}
#endif
