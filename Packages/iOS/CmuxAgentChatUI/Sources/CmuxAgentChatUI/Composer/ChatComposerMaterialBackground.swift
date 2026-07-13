import SwiftUI

struct ChatComposerMaterialBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
        #else
        content.background {
            Rectangle()
                .fill(.thinMaterial)
        }
        #endif
    }
}
