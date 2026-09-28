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
            font = CmuxChromeFont.swiftUIFont(
                typeface: typeface,
                size: scaledSize,
                swiftUIWeight: weight
            )
        }
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private var scaledSize: CGFloat {
        GlobalFontMagnification.scaledSize(baseSize, percent: percent)
    }
}
