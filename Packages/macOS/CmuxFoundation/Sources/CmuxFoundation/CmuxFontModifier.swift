import SwiftUI

struct CmuxFontModifier: ViewModifier {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var percent
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    var monospacedDigit: Bool = false

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        // Inter for proportional UI text, Operator Mono for monospaced text
        // (paths, code). Font.custom falls back to the system font
        // automatically if a family is not installed.
        let familyName = (design == .monospaced) ? "Operator Mono Lig" : "Inter"
        var font = Font.custom(familyName, size: scaledSize).weight(weight)
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private var scaledSize: CGFloat {
        GlobalFontMagnification.scaledSize(baseSize, percent: percent)
    }
}
