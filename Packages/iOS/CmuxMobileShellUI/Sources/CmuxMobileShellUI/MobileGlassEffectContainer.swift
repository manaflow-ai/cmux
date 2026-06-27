import SwiftUI

/// Uses SwiftUI's glass container when the compiler SDK exposes it.
struct MobileGlassEffectContainer<Content: View, Fallback: View>: View {
    private let content: Content
    private let fallback: Fallback

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.content = content()
        self.fallback = fallback()
    }

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }
}
