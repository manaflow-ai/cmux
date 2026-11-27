import SwiftUI

extension View {
    func copyOnlyTextSelection(for text: String) -> some View {
        textSelection(.disabled)
            .contextMenu {
                Button {
                    WorkspaceSurfaceIdentifierClipboardText.copy(text)
                } label: {
                    Text(String(localized: "textSelection.copyText", defaultValue: "Copy Text"))
                }
            }
    }
}
