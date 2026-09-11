import SwiftUI

struct CmuxFontModifier: ViewModifier {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var percent
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let family: String?
    var monospacedDigit: Bool = false

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        CmuxFontResolver.swiftUIFont(
            family: family,
            size: scaledSize,
            weight: weight,
            design: design,
            monospacedDigit: monospacedDigit
        )
    }

    private var scaledSize: CGFloat {
        GlobalFontMagnification.scaledSize(baseSize, percent: percent)
    }
}
