import SwiftUI

struct MobileToastSurfaceModifier: ViewModifier {
    let isCompact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if isCompact {
                content.glassEffect(.regular, in: .capsule)
            } else {
                content.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            }
        } else {
            fallbackSurface(content: content)
        }
        #else
        fallbackSurface(content: content)
        #endif
    }

    @ViewBuilder
    private func fallbackSurface(content: Content) -> some View {
        if isCompact {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        } else {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
    }
}
