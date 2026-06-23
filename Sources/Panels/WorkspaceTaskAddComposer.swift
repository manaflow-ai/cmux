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
            Image(systemName: "plus.circle.fill")
                .cmuxSymbolRasterSize(14)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "plus")
                    .cmuxSymbolRasterSize(13)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!WorkspaceTask.isValidTitle(draft))
            .help(submitLabel)
            .accessibilityLabel(submitLabel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isFocused ? 0.92 : 0.68))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isFocused ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.3),
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
}
