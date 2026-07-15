import CmuxBrowser
import SwiftUI

/// Cursor-style inline selection chip: a pointer glyph plus the tag name in
/// accent blue, no pill background. The remove control appears on hover.
struct BrowserDesignModeSelectionChip: View {
    let selection: BrowserDesignModeSelection
    let onRemove: () -> Void

    @State private var isHovered = false

    private static let chipBlue = Color(red: 0.35, green: 0.62, blue: 1.0)

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 9, weight: .semibold))
            Text(selection.tagName)
                .cmuxFont(size: 13, weight: .medium)
                .lineLimit(1)
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .safeHelp(
                    String(
                        localized: "browser.designMode.composer.removeSelection",
                        defaultValue: "Remove selected element"
                    )
                )
                .accessibilityLabel(
                    String(
                        localized: "browser.designMode.composer.removeSelection",
                        defaultValue: "Remove selected element"
                    )
                )
            }
        }
        .foregroundStyle(Self.chipBlue)
        .padding(.horizontal, 3)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .safeHelp(selection.selector)
        .accessibilityElement(children: .combine)
    }
}

/// Single-row-first layout for the composer: chips keep their intrinsic size
/// and the LAST subview (the text field) takes the remaining row width, or
/// wraps to its own full-width row when less than `minimumFieldWidth` is left.
struct BrowserDesignModeComposerRowLayout: Layout {
    var spacing: CGFloat = 5
    var rowSpacing: CGFloat = 4
    var minimumFieldWidth: CGFloat = 150

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let slot = arrangement.slots[index]
            subview.place(
                at: CGPoint(x: bounds.minX + slot.origin.x, y: bounds.minY + slot.origin.y),
                proposal: ProposedViewSize(width: slot.width, height: nil)
            )
        }
    }

    private struct Slot {
        var origin: CGPoint
        var width: CGFloat?
    }

    private func arrange(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, slots: [Slot]) {
        let maxWidth = proposal.width ?? 400
        var slots: [Slot] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let isField = index == subviews.count - 1
            if isField {
                var available = maxWidth - cursor.x
                if available < minimumFieldWidth, cursor.x > 0 {
                    cursor.x = 0
                    cursor.y += rowHeight + rowSpacing
                    rowHeight = 0
                    available = maxWidth
                }
                let fieldSize = subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
                slots.append(Slot(origin: cursor, width: available))
                rowHeight = max(rowHeight, fieldSize.height)
                cursor.x += available
            } else {
                let size = subview.sizeThatFits(.unspecified)
                if cursor.x > 0, cursor.x + size.width > maxWidth {
                    cursor.x = 0
                    cursor.y += rowHeight + rowSpacing
                    rowHeight = 0
                }
                slots.append(Slot(origin: cursor, width: nil))
                rowHeight = max(rowHeight, size.height)
                cursor.x += size.width + spacing
            }
        }
        return (CGSize(width: maxWidth, height: cursor.y + rowHeight), slots)
    }
}
