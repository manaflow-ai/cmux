#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A large, automatically focused prompt canvas for the agent's first instruction.
struct TaskComposerPromptCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var prompt: String
    let placeholder: String
    let isDisabled: Bool
    let endEditing: () -> Void
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let selectTemplate: (MobileTaskTemplate.ID) -> Void
    let editTemplates: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TaskComposerAgentMenu(
                value: TaskComposerAgentMenuValue(
                    templates: templates,
                    selectedTemplateID: selectedTemplateID,
                    isDisabled: isDisabled
                ),
                actions: TaskComposerAgentMenuActions(
                    selectTemplate: selectTemplate,
                    editTemplates: editTemplates
                )
            )
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)

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
                .taskComposerEditingCompletion(
                    isFocused: isFocused,
                    endEditing: endEditing
                )

        }
        .padding(14)
        .mobileGlassField(cornerRadius: 26)
    }

    private var promptLineLimit: ClosedRange<Int> {
        dynamicTypeSize.isAccessibilitySize ? 2...6 : 5...12
    }

    private var promptMinimumHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 96 : 132
    }
}
#endif
