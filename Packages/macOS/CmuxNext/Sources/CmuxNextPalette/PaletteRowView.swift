import CmuxNextDesign
import SwiftUI

/// One result row. Selection and hover are gray fills, never accent blue.
struct PaletteRowView: View {
    let row: PaletteRow
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let item = row.item
        HStack(spacing: Metrics.space4) {
            Image(systemName: item.symbol ?? "command")
                .font(.system(size: Metrics.iconSize, weight: .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: Metrics.iconSize + Metrics.space2, height: Metrics.iconSize + Metrics.space2)
            HStack(spacing: Metrics.space3) {
                Text(highlightedTitle)
                    .font(.token(Typography.body))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.token(Typography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Metrics.space5)
            if let accessory = item.accessory {
                Text(accessory)
                    .font(.token(Typography.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let keycaps = item.keycaps {
                KeycapsView(keycaps: keycaps)
            }
        }
        .padding(.horizontal, Metrics.space4)
        .frame(height: PaletteLayout.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: PaletteLayout.rowCornerRadius, style: .continuous)
                .fill(fill)
        }
        .opacity(item.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return .token(Palette.selectionFill) }
        if isHovered { return .token(Palette.hoverFill) }
        return .clear
    }

    /// Matched characters in full primary color and the emphasized weight;
    /// the rest slightly muted, so the match reads without a colored
    /// highlight.
    private var highlightedTitle: AttributedString {
        var text = AttributedString(row.item.title)
        guard !row.highlights.isEmpty else { return text }
        text.foregroundColor = .primary.opacity(0.78)
        let scalars = text.unicodeScalars
        var remaining = Set(row.highlights)
        var offset = 0
        var index = scalars.startIndex
        let emphasized = Font.token(Typography.bodyEmphasized)
        while index < scalars.endIndex, !remaining.isEmpty {
            let next = scalars.index(after: index)
            if remaining.remove(offset) != nil {
                text[index..<next].foregroundColor = .primary
                text[index..<next].font = emphasized
            }
            index = next
            offset += 1
        }
        return text
    }
}
