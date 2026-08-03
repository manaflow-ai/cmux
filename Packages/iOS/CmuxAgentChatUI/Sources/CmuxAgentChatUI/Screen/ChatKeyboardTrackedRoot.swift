#if os(iOS)
import SwiftUI

/// Reports the floating scroll-to-bottom control so the controller's
/// window-level keyboard-dismiss recognizer can exclude its hit region.
struct ChatScrollButtonFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    func excludedFromKeyboardDismiss() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChatScrollButtonFramePreferenceKey.self,
                    value: proxy.frame(in: .global).insetBy(dx: -3, dy: -3)
                )
            }
        )
    }
}

struct ChatKeyboardTrackedRoot<Content: View>: View {
    let content: Content
    var ignoredContainerEdges: Edge.Set = []
    var overlayGeometry: ChatTranscriptOverlayGeometry?
    var onScrollButtonFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        content
            .environment(\.chatTranscriptOverlayGeometry, overlayGeometry)
            .ignoresSafeArea(.container, edges: ignoredContainerEdges)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onPreferenceChange(ChatScrollButtonFramePreferenceKey.self) { frame in
                onScrollButtonFrameChange(frame)
            }
    }
}
#endif
