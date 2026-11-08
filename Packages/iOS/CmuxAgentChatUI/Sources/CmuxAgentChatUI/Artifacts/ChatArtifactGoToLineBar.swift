import SwiftUI

/// Inline numeric controls for jumping to a currently loaded text line.
struct ChatArtifactGoToLineBar: View {
    @Binding var lineText: String
    let onGo: (Int) -> Void
    let onClose: () -> Void

    @FocusState private var isLineFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            lineField

            Button {
                submit()
            } label: {
                Text(String(
                    localized: "chat.artifact.line.go",
                    defaultValue: "Go",
                    bundle: .module
                ))
            }
            .buttonStyle(.borderedProminent)
            .disabled(Int(lineText) == nil)

            Button {
                isLineFieldFocused = false
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "chat.artifact.line.close",
                defaultValue: "Close go to line",
                bundle: .module
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            isLineFieldFocused = true
        }
        .onDisappear {
            isLineFieldFocused = false
        }
    }

    @ViewBuilder
    private var lineField: some View {
        #if os(iOS)
        baseLineField
            .keyboardType(.numberPad)
        #else
        baseLineField
        #endif
    }

    private var baseLineField: some View {
        TextField(
            String(
                localized: "chat.artifact.line.placeholder",
                defaultValue: "Line number",
                bundle: .module
            ),
            text: $lineText
        )
        .textFieldStyle(.roundedBorder)
        .focused($isLineFieldFocused)
        .onSubmit {
            submit()
        }
    }

    private func submit() {
        guard let line = Int(lineText) else { return }
        isLineFieldFocused = false
        onGo(line)
    }
}
