public import SwiftUI

/// Adds cmux-owned font scaling modifiers to SwiftUI views.
public extension View {
    /// Injects the global font magnification percent into this view subtree.
    ///
    /// Apply this once near each cmux-owned SwiftUI root. Descendant
    /// ``cmuxFont(size:weight:design:monospacedDigit:)`` calls then read the
    /// environment value without creating per-label `UserDefaults`
    /// subscriptions.
    ///
    /// - Returns: A view that supplies the current magnification percent to descendants.
    func cmuxFontMagnificationEnvironment() -> some View {
        modifier(CmuxFontMagnificationEnvironmentModifier())
    }

    /// Apply a system font at `size` points, scaled by the global magnification.
    ///
    /// - Parameters:
    ///   - size: The unscaled base point size.
    ///   - weight: The system font weight to apply.
    ///   - design: The system font design to apply.
    ///   - monospacedDigit: Whether numeric glyphs should use tabular widths.
    /// - Returns: A view with a magnification-aware system font.
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
    ///
    /// - Parameters:
    ///   - style: The SwiftUI text style whose cmux base metrics should be used.
    ///   - weight: An optional weight override. When `nil`, cmux uses the style's default weight.
    ///   - design: The system font design to apply.
    ///   - monospacedDigit: Whether numeric glyphs should use tabular widths.
    /// - Returns: A view with a magnification-aware font for the requested text style.
    func cmuxFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        cmuxFont(
            size: CmuxTextStyleMetrics(style: style).baseSize,
            weight: weight ?? CmuxTextStyleMetrics(style: style).baseWeight,
            design: design,
            monospacedDigit: monospacedDigit
        )
    }
}
