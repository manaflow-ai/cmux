#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A large, automatically focused prompt canvas for the agent's first instruction.
struct TaskComposerPromptCard: View {
    @Binding var prompt: String
    let placeholder: String
    let isDisabled: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("mobile.taskComposer.prompt", defaultValue: "Prompt"),
                systemImage: "text.cursor"
            )
            .font(.headline)
            .foregroundStyle(.primary)

            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(4...10)
                .frame(minHeight: 108, alignment: .topLeading)
                .focused($isFocused)
                .disabled(isDisabled)
                .accessibilityIdentifier("MobileTaskComposerPrompt")
        }
        .padding(16)
        .mobileGlassField(cornerRadius: 24)
        .onAppear {
            guard !isDisabled else { return }
            isFocused = true
        }
    }
}
#endif
