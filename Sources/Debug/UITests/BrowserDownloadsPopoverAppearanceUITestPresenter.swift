#if DEBUG
import SwiftUI

/// Debug-only modifier that opens the downloads popover for its appearance UI test.
struct BrowserDownloadsPopoverAppearanceUITestPresenter: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                presentIfReady()
            }
            .onChange(of: colorScheme) { _, _ in
                presentIfReady()
            }
    }

    private func presentIfReady() {
        guard BrowserDownloadsPopoverAppearanceUITestSupport().shouldPresent(for: colorScheme) else {
            return
        }
        isPresented = true
    }
}
#endif
