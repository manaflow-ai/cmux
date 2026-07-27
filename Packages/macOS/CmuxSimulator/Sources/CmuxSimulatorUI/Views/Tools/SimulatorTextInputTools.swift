import SwiftUI

struct SimulatorTextInputTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var text = ""
    @State private var isTyping = false

    var body: some View {
        SimulatorToolSection(simulatorStrings.textInput) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .frame(minHeight: 64)
                if text.isEmpty {
                    Text(simulatorStrings.textInputPlaceholder)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(.separator) }

            HStack {
                Button(simulatorStrings.typeText) {
                    isTyping = true
                    if case .failure = coordinator.beginTypeText(text, completion: { succeeded in
                        isTyping = false
                        if succeeded { text = "" }
                    }) {
                        isTyping = false
                    }
                }
                .disabled(
                    text.isEmpty || isTyping || !coordinator.capabilities.contains(.keyboard)
                )
                if isTyping {
                    ProgressView()
                        .controlSize(.mini)
                    Text(simulatorStrings.loading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
