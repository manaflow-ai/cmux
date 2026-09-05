import SwiftUI

/// Centers one fixed-size Computer Use visual in a window's visible safe area.
///
/// A full-size-content AppKit window includes its transparent title bar in the
/// hosting view's bounds. ``ComputerUseOnboardingHostingView`` exposes the
/// title-bar-safe rect to SwiftUI, so this container receives the visible area
/// as its proposal and centers the child's measured frame in that proposal.
@MainActor
struct ComputerUseVisibleContentCenter<Content: View>: View {
    let content: Content

    /// Creates a visible-content centering container.
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// Lays out the fixed-size child in the safe-area proposal supplied by AppKit.
    var body: some View {
        // SwiftUI proposes a root view's safe-area size to this container. A
        // ZStack therefore centers in the exact visible content rect, while
        // `fixedSize` keeps the child's authored visual frame from being
        // stretched before alignment.
        ZStack {
            content
                .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
