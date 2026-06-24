#if os(iOS)
import SwiftUI

struct ChatKeyboardTrackedRoot<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
#endif
