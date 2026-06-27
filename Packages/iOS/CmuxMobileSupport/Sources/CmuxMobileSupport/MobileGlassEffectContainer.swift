public import SwiftUI

/// Compatibility wrapper for grouping Liquid Glass controls when the SDK supports it.
public struct MobileGlassEffectContainer<Content: View, Fallback: View>: View {
    private let content: Content
    private let fallback: Fallback

    /// Creates a container with separate fallback content for older SDKs or OSes.
    public init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.content = content()
        self.fallback = fallback()
    }

    /// Creates a container that renders the same content on every SDK and OS.
    public init(@ViewBuilder content: () -> Content) where Fallback == Content {
        let content = content()
        self.content = content
        fallback = content
    }

    /// The rendered glass grouping or its fallback content.
    public var body: some View {
        #if compiler(>=6.2) && os(iOS)
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
