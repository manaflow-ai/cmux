#if os(iOS)
import SwiftUI

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
