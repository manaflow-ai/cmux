import SwiftUI

struct WorkspaceTaskAddComposer: View {
    @Binding var draft: String
    let placeholder: String
    let submitLabel: String
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
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
    }
}
