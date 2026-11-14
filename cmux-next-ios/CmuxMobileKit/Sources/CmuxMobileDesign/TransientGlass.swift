#if os(iOS)
import SwiftUI

/// One material adapter, with shape owned by the surface that presents it.
private struct TransientGlass<S: Shape>: ViewModifier {
    let shape: S
    let material: CmuxMobileTransientMaterial?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        // Keep the system's opaque accessibility fallback free of a translucent tint.
        let glass = reduceTransparency ? Glass.regular : material.map { Glass.regular.tint($0.tint(in: scheme)) } ?? Glass.regular
        content.glassEffect(glass, in: shape)
    }
}

extension View {
    /// Applies the shared transient glass, preserving regular glass when nil.
    /// Pass nil for a chat-owned consumer whose design is held.
    public func cmuxMobileTransientGlass<S: Shape>(in shape: S, material: CmuxMobileTransientMaterial? = .standard) -> some View {
        modifier(TransientGlass(shape: shape, material: material))
    }
}
#endif
