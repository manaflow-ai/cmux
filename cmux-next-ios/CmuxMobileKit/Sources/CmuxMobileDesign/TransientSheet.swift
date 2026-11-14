#if os(iOS)
import SwiftUI

/// A native sheet keeps its presentation, detents and accessibility fallback.
private struct TransientSheet: ViewModifier {
    let material: CmuxMobileTransientMaterial?
    let legacyBackground: Color?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if let material {
            content
                .scrollContentBackground(.hidden)
                .presentationBackground {
                    if reduceTransparency {
                        // An opaque system color, never a translucent veil without a base.
                        Color(uiColor: .systemBackground)
                    } else {
                        Rectangle().fill(.regularMaterial)
                            .overlay(material.tint(in: scheme))
                    }
                }
        } else if let legacyBackground {
            content.presentationBackground(legacyBackground)
        } else {
            content
        }
    }
}

extension View {
    /// Uses the common neutral material without replacing a native sheet.
    /// Nil leaves a held chat presentation exactly as authored.
    public func cmuxMobileTransientSheet(material: CmuxMobileTransientMaterial? = .standard, legacyBackground: Color? = nil) -> some View {
        modifier(TransientSheet(material: material, legacyBackground: legacyBackground))
    }
}
#endif
