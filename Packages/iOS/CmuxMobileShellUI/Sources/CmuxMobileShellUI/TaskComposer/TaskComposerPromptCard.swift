#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A large, automatically focused prompt canvas for the agent's first instruction.
struct TaskComposerPromptCard: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var prompt: String
    let placeholder: String
    let isDisabled: Bool
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let selectTemplate: (MobileTaskTemplate) -> Void
    let editTemplates: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TaskComposerAgentMenu(
                    templates: templates,
                    selectedTemplateID: selectedTemplateID,
                    isDisabled: isDisabled,
                    selectTemplate: selectTemplate,
                    editTemplates: editTemplates
                )
                Spacer(minLength: 0)
            }

            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(promptLineLimit)
                .frame(minHeight: promptMinimumHeight, alignment: .topLeading)
                .focused($isFocused)
                .disabled(isDisabled)
                .accessibilityLabel(L10n.string("mobile.taskComposer.prompt", defaultValue: "Prompt"))
                .accessibilityHint(placeholder)
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
        .shadow(
            color: isFocused ? Color.accentColor.opacity(0.1) : Color.black.opacity(0.035),
            radius: isFocused ? 16 : 10,
            y: 6
        )
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: 0.18),
            value: isFocused
        )
    }

    private var promptLineLimit: ClosedRange<Int> {
        dynamicTypeSize.isAccessibilitySize ? 2...6 : 5...12
    }

    private var promptMinimumHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 96 : 132
    }
}
#endif
