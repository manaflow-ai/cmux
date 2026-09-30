import SwiftUI

struct CmuxFontModifier: ViewModifier {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var percent
    @Environment(\.cmuxChromeTypeface) private var typeface
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    var monospacedDigit: Bool = false

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        // The size is still `scaledSize`, whatever the typeface: the chrome font
        // setting chooses a family, never a point size, so global font
        // magnification and accessibility sizing keep applying as before.
        var font: Font
        switch typeface {
        case .system:
            font = Font.system(size: scaledSize, weight: weight, design: design)
        case .monospacedSystem:
            // The terminal's own fallback. Following the terminal means
            // following it here too, so monospaced outranks a `.default`
            // design request.
            font = Font.system(size: scaledSize, weight: weight, design: .monospaced)
        case .family:
            font = typeface.swiftUIFont(
                size: scaledSize,
                swiftUIWeight: weight,
                needs: fixedPitchNeed
            )
        }
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    /// A call site that asked for a monospaced design wants every glyph to keep
    /// one advance, and `monospacedDigit` asks for the same of digits only. Both
    /// outrank the chrome family, which is why they are carried into resolution
    /// rather than dropped when the family branch is taken.
    private var fixedPitchNeed: CmuxChromeTypeface.FixedPitchNeed {
        if design == .monospaced { return .allGlyphs }
        return monospacedDigit ? .digits : .none
    }

    private var scaledSize: CGFloat {
        GlobalFontMagnification.scaledSize(baseSize, percent: percent)
    }
}
