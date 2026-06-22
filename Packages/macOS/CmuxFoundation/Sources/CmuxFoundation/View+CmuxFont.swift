public import SwiftUI

public extension View {
    /// Injects the global font magnification percent into this view subtree.
    ///
    /// Apply this once near each cmux-owned SwiftUI root. Descendant
    /// ``cmuxFont(size:weight:design:monospacedDigit:)`` calls then read the
    /// environment value without creating per-label `UserDefaults`
    /// subscriptions.
    func cmuxFontMagnificationEnvironment() -> some View {
        modifier(CmuxFontMagnificationEnvironmentModifier())
    }

    /// Apply a system font at `size` points, scaled by the global magnification.
    func cmuxFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(
            CmuxFontModifier(
                baseSize: size,
                weight: weight,
                design: design,
                monospacedDigit: monospacedDigit
            )
        )
    }

    /// Apply a text-style-sized system font, scaled by the global magnification.
    func cmuxFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        let metrics = CmuxTextStyleMetrics(style: style)
        return modifier(
            CmuxFontModifier(
                baseSize: metrics.baseSize,
                weight: weight ?? metrics.baseWeight,
                design: design,
                monospacedDigit: monospacedDigit
            )
        )
    }
}
