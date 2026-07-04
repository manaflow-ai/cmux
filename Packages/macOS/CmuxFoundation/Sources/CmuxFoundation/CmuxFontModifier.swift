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
        var font = Font.system(size: scaledSize, weight: weight, design: design)
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private var scaledSize: CGFloat {
        GlobalFontMagnification.scaledSize(baseSize, percent: percent)
    }
}
