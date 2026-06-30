import SwiftUI

struct WorkspaceTaskAddComposer: View {
    @Binding var draft: String
    let placeholder: String
    let submitLabel: String
    var autoFocus = false
    let submit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(magnified: "plus", pointSize: 12, weight: .medium)
                .foregroundStyle(taskAccent)
                .frame(width: 18, height: 22)
                .accessibilityHidden(true)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submit)

            Button(action: submit) {
                CmuxSystemSymbolImage(magnified: "arrow.up", pointSize: 11, weight: .semibold)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(WorkspaceTask.isValidTitle(draft) ? taskAccent : Color.secondary.opacity(0.48))
            .disabled(!WorkspaceTask.isValidTitle(draft))
            .help(submitLabel)
            .accessibilityLabel(submitLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isFocused ? 0.72 : 0.42))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isFocused ? taskAccent.opacity(0.52) : Color(nsColor: .separatorColor).opacity(0.26),
                    lineWidth: isFocused ? 1.25 : 1
                )
        }
        .onAppear {
            guard autoFocus else { return }
            isFocused = true
        }
        .animation(focusAnimation, value: isFocused)
    }

    private var focusAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    private var taskAccent: Color {
        Color(red: 0.86, green: 0.25, blue: 0.19)
    }
}
