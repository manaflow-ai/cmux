import CmuxFoundation
import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// A row glyph in the shared icon slot, drawn per the style's icon treatment:
/// monochrome label color, semantic tint, or a Settings-style filled squircle
/// with a white glyph.
struct CloudTreeRowIcon: View {
    let style: CloudTreeStyle
    let systemName: String
    let tint: Color
    var assetName: String? = nil
    var dimmed: Bool = false
    var weight: Font.Weight = .regular
    var size: CGFloat? = nil
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        if let assetName {
            CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                source: .asset(name: assetName, bundle: .main),
                size: NSSize(width: style.iconSize, height: style.iconSize),
                fallbackSource: .systemSymbol(name: systemName, accessibilityDescription: nil),
                fallbackTintColor: .secondaryLabelColor
            ))
            .frame(width: style.iconSlot, height: style.iconSize, alignment: .center)
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
        } else {
            systemIcon
        }
    }

    @ViewBuilder
    private var systemIcon: some View {
        switch style.iconTreatment {
        case .monochrome:
            Image(systemName: systemName)
                .cmuxFont(size: size ?? style.iconSize, weight: weight)
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: scaled(style.iconSlot), alignment: .center)
        case .tinted:
            Image(systemName: systemName)
                .cmuxFont(size: size ?? style.iconSize, weight: weight)
                .foregroundStyle(tint.opacity(dimmed ? 0.45 : 0.85))
                .frame(width: scaled(style.iconSlot), alignment: .center)
        case .chips:
            let side = scaled(max(0, style.iconSlot - 4))
            RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                .fill(tint.opacity(dimmed ? 0.4 : 0.9))
                .frame(width: side, height: side)
                .overlay {
                    Image(systemName: systemName)
                        .cmuxFont(size: size ?? style.iconSize, weight: .medium)
                        .foregroundStyle(.white)
                }
                .frame(width: scaled(style.iconSlot), alignment: .center)
        }
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }
}
