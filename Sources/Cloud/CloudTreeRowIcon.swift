import CmuxFoundation
import SwiftUI

/// A row glyph in the shared icon slot, drawn per the style's icon treatment:
/// monochrome label color, semantic tint, or a Settings-style filled squircle
/// with a white glyph. Symbol pixels are materialized by the shared AppKit
/// renderer so SwiftUI's intermittent Intel template-image path is not used.
struct CloudTreeRowIcon: View {
    let style: CloudTreeStyle
    let systemName: String
    let tint: Color
    var dimmed: Bool = false
    var weight: Font.Weight = .regular
    var size: CGFloat? = nil
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        switch style.iconTreatment {
        case .monochrome:
            // `Color.tertiary` needs macOS 15; the label colors match the
            // hierarchical styles and stay available on macOS 14.
            symbol(
                tint: Color(nsColor: dimmed ? .tertiaryLabelColor : .secondaryLabelColor),
                weight: weight
            )
        case .tinted:
            symbol(tint: tint.opacity(dimmed ? 0.45 : 0.85), weight: weight)
        case .chips:
            let side = scaled(max(0, style.iconSlot - 4))
            RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                .fill(tint.opacity(dimmed ? 0.4 : 0.9))
                .frame(width: side, height: side)
                .overlay {
                    symbol(tint: .white, weight: .medium, slotWidth: side)
                }
                .frame(width: scaled(style.iconSlot), alignment: .center)
        }
    }

    private func symbol(tint: Color, weight: Font.Weight, slotWidth: CGFloat? = nil) -> some View {
        CmuxSystemSymbolImage(
            magnified: systemName,
            pointSize: size ?? style.iconSize,
            weight: weight,
            tint: tint
        )
        .frame(width: slotWidth ?? scaled(style.iconSlot), alignment: .center)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }
}
