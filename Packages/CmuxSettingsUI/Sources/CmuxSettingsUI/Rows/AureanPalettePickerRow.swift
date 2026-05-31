import CmuxAppearance
import SwiftUI

/// Visual picker row for the active ``AureanPaletteVariant``.
///
/// Mirrors ``ThemePickerRow``: a leading "Palette" title and a trailing row of tappable
/// swatches, one per temperature (cool / dune / warm / obsidian). Each swatch previews the
/// variant's negative space, sand text, and the accent/ok signal dots; the selected swatch
/// gets an accent border and tinted background.
@MainActor
struct AureanPalettePickerRow: View {
    let selectedVariant: AureanPaletteVariant
    let onSelect: (AureanPaletteVariant) -> Void

    private let swatchWidth: CGFloat = 60
    private let swatchHeight: CGFloat = 44

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(localized: "settings.app.aureanPalette", defaultValue: "Palette"))
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(AureanPaletteVariant.allCases, id: \.self) { variant in
                    let isSelected = selectedVariant == variant
                    Button {
                        onSelect(variant)
                    } label: {
                        VStack(spacing: 4) {
                            swatch(for: variant.palette)
                                .frame(width: swatchWidth, height: swatchHeight)

                            Text(variantDisplayName(variant))
                                .font(.system(size: 10))
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundColor(isSelected ? .primary : .secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatch(for palette: AureanPalette) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(palette.surfacePrimary.color)
            .overlay(
                HStack(spacing: 4) {
                    Circle().fill(palette.accent.color).frame(width: 7, height: 7)
                    Circle().fill(palette.ok.color).frame(width: 7, height: 7)
                    Circle().fill(palette.warn.color).frame(width: 7, height: 7)
                }
                .padding(.horizontal, 6),
                alignment: .bottomLeading
            )
            .overlay(
                Rectangle()
                    .fill(palette.text.color)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .padding(.top, 6),
                alignment: .top
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(palette.text.opacity(0.145).color, lineWidth: 1)
            )
    }

    private func variantDisplayName(_ variant: AureanPaletteVariant) -> String {
        switch variant {
        case .cool: return String(localized: "aurean.palette.cool", defaultValue: "Cool")
        case .dune: return String(localized: "aurean.palette.dune", defaultValue: "Dune")
        case .warm: return String(localized: "aurean.palette.warm", defaultValue: "Warm")
        case .obsidian: return String(localized: "aurean.palette.obsidian", defaultValue: "Obsidian")
        }
    }
}
