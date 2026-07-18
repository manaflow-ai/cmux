#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A large, automatically focused prompt canvas for the agent's first instruction.
struct TaskComposerPromptCard: View {
    @Binding var prompt: String
    let placeholder: String
    let isDisabled: Bool
    let template: MobileTaskTemplate?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                if let template {
                    TaskTemplateIcon(value: template.icon, size: 17)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.11), in: Circle())
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.11), in: Circle())
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string("mobile.taskComposer.prompt", defaultValue: "Prompt"))
                        .font(.subheadline.weight(.semibold))
                    if let template {
                        Text(template.name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFocused ? Color.accentColor : Color.secondary.opacity(0.65))
                    .accessibilityHidden(true)
            }

            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(4...10)
                .frame(minHeight: 98, alignment: .topLeading)
                .focused($isFocused)
                .disabled(isDisabled)
                .accessibilityIdentifier("MobileTaskComposerPrompt")
        }
        .padding(14)
        .mobileGlassField(cornerRadius: 26)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.58) : Color.primary.opacity(0.06),
                    lineWidth: isFocused ? 1.25 : 1
                )
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)
                .padding(.vertical, 22)
                .offset(x: -1)
                .accessibilityHidden(true)
        }
        .shadow(
            color: isFocused ? Color.accentColor.opacity(0.1) : Color.black.opacity(0.035),
            radius: isFocused ? 16 : 10,
            y: 6
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
#endif
