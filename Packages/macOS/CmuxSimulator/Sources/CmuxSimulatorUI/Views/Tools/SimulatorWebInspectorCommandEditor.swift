import SwiftUI

struct SimulatorWebInspectorCommandEditor: View {
    let isAttached: Bool
    let isHighlighted: Bool
    let setHighlight: (Bool) -> Void
    let send: (String) -> Void

    @State private var rawJSON =
        #"{"id":1,"method":"Runtime.evaluate","params":{"expression":"document.title"}}"#

    var body: some View {
        HStack {
            Button(
                isHighlighted ? simulatorStrings.unhighlightPage : simulatorStrings.highlightPage
            ) {
                setHighlight(!isHighlighted)
            }
            .disabled(!isAttached)
            Spacer()
            Button(simulatorStrings.sendInspectorCommand) { send(rawJSON) }
                .disabled(!isAttached || rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        TextEditor(text: $rawJSON)
            .font(.caption.monospaced())
            .frame(minHeight: 88)
            .accessibilityLabel(simulatorStrings.rawInspectorRequest)
    }
}
