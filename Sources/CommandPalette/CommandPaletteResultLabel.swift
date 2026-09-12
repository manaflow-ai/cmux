import CmuxFoundation
import CmuxSettings
import SwiftUI

struct CommandPaletteResultLabel: View {
    let title: String
    let matchedIndices: Set<Int>
    let trailingLabel: CommandPaletteRenderTrailingLabel?
    let chromePalette: ChromePalette
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            highlightedTitleText
                .cmuxFont(size: 13, weight: .regular)
                .lineLimit(1)
            Spacer()
            trailingLabelView
        }
    }

    private var highlightedTitleText: Text {
        let baseForeground = isSelected ? chromePalette.textOnSelected : chromePalette.textPrimary
        let rowBackground = isSelected ? chromePalette.surfaceSelected : chromePalette.surface
        let matchedForeground = chromePalette.accent.contrastRatio(with: rowBackground) >= 3
            ? chromePalette.accent
            : baseForeground
        guard !matchedIndices.isEmpty else {
            return Text(title).foregroundColor(baseForeground.swiftUIColor)
        }

        let characters = Array(title)
        var index = 0
        var result = Text("")

        while index < characters.count {
            let isMatched = matchedIndices.contains(index)
            var end = index + 1
            while end < characters.count, matchedIndices.contains(end) == isMatched {
                end += 1
            }

            let segment = String(characters[index..<end])
            let foreground = isMatched ? matchedForeground : baseForeground
            result = result + Text(segment).foregroundColor(foreground.swiftUIColor)
            index = end
        }

        return result
    }

    @ViewBuilder
    private var trailingLabelView: some View {
        if let trailingLabel {
            switch trailingLabel.style {
            case .shortcut:
                Text(trailingLabel.text)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundStyle(trailingForeground.swiftUIColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        shortcutPillBackground,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            case .kind:
                Text(trailingLabel.text)
                    .cmuxFont(size: 11, weight: .regular)
                    .foregroundStyle(trailingForeground.swiftUIColor)
                    .lineLimit(1)
            }
        }
    }

    private var trailingForeground: ChromeColor {
        isSelected ? chromePalette.textOnSelected : chromePalette.textSecondary
    }

    private var shortcutPillBackground: Color {
        // `textOnSelected` is contrast-repaired against the full selected
        // surface. Keep that exact surface behind selected-row shortcut
        // hints; applying a translucent hover wash would invalidate the
        // guarantee for independently overridden tokens.
        isSelected
            ? chromePalette.surfaceSelected.swiftUIColor
            : chromePalette.surfaceHover.swiftUIColor.opacity(0.65)
    }
}
