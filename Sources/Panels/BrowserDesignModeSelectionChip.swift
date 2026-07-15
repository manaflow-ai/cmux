import CmuxBrowser
import SwiftUI

struct BrowserDesignModeSelectionChip: View {
    let selection: BrowserDesignModeSelection
    let onRemove: () -> Void

    @State private var isRemoveHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(selection.tagName)
                .cmuxFont(size: 11, weight: .semibold, design: .monospaced)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(isRemoveHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 14, height: 14)
                    .background(
                        Circle().fill(isRemoveHovered ? Color.primary.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isRemoveHovered = $0 }
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
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 20)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .safeHelp(selection.selector)
        .accessibilityElement(children: .combine)
    }
}

/// Left-aligned wrapping row layout for selection chips.
struct BrowserDesignModeChipFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(proposal: proposal, subviews: subviews)
        for (subview, position) in zip(subviews, arrangement.positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > maxWidth {
                cursor.x = 0
                cursor.y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(cursor)
            rowHeight = max(rowHeight, size.height)
            cursor.x += size.width + spacing
            totalWidth = max(totalWidth, cursor.x - spacing)
        }
        return (CGSize(width: totalWidth, height: cursor.y + rowHeight), positions)
    }
}
