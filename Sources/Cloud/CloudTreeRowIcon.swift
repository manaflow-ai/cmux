import SwiftUI

/// A row glyph in the shared icon slot, drawn per the style's icon treatment:
/// monochrome label color, semantic tint, or a Settings-style filled squircle
/// with a white glyph.
struct CloudTreeRowIcon: View {
    let style: CloudTreeStyle
    let systemName: String
    let tint: Color
    var dimmed: Bool = false

    var body: some View {
        switch style.iconTreatment {
        case .monochrome:
            Image(systemName: systemName)
                .font(.system(size: style.iconSize, weight: .regular))
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: style.iconSlot, alignment: .center)
        case .tinted:
            Image(systemName: systemName)
                .font(.system(size: style.iconSize, weight: .regular))
                .foregroundStyle(tint.opacity(dimmed ? 0.45 : 0.85))
                .frame(width: style.iconSlot, alignment: .center)
        case .chips:
            let side = style.iconSlot - 4
            RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                .fill(tint.opacity(dimmed ? 0.4 : 0.9))
                .frame(width: side, height: side)
                .overlay {
                    Image(systemName: systemName)
                        .font(.system(size: style.iconSize, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: style.iconSlot, alignment: .center)
        }
    }
}
