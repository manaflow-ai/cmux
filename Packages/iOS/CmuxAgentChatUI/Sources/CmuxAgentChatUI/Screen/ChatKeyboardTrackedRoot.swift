#if os(iOS)
import SwiftUI

struct ChatKeyboardTrackedRoot<Content: View>: View {
    let content: Content
    var ignoredContainerEdges: Edge.Set = []
    var onScrollButtonFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        content
            .ignoresSafeArea(.container, edges: ignoredContainerEdges)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onPreferenceChange(ChatScrollButtonFramePreferenceKey.self) { frame in
                onScrollButtonFrameChange(frame)
            }
    }
}
#endif
