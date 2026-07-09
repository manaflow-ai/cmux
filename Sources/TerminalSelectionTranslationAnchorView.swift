#if canImport(Translation)
import SwiftUI
import Translation

/// Invisible anchor for the system Translation popover.
@available(macOS 15.0, *)
@MainActor
struct TerminalSelectionTranslationAnchorView: View {
    let text: String
    let onDismiss: @MainActor () -> Void
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .translationPresentation(isPresented: $isPresented, text: text)
            .task {
                isPresented = true
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { onDismiss() }
            }
    }
}
#endif
