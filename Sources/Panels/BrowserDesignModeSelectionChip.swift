import CmuxBrowser
import SwiftUI

/// Cursor-style inline selection chip: a pointer glyph plus the tag name in
/// accent blue, no pill background. The remove control appears on hover.
struct BrowserDesignModeSelectionChip: View {
    let selection: BrowserDesignModeSelection
    let onRemove: () -> Void
    var onReveal: () -> Void = {}

    @State private var isHovered = false

    /// Middle-truncates the element identity for tooltips.
    private var identityHelp: String {
        let identity = selection.xpath.isEmpty ? selection.selector : selection.xpath
        let max = 120
        guard identity.count > max else { return identity }
        return "\(identity.prefix(max / 2 - 1))…\(identity.suffix(max / 2))"
    }

    private static let chipBlue = Color(red: 0.35, green: 0.62, blue: 1.0)

    /// SF Symbol describing the kind of element the chip references, so a
    /// stack of chips reads at a glance (photo vs text vs button vs container).
    private static func symbol(forTag tag: String) -> String {
        switch tag.lowercased() {
        case "img", "picture": "photo"
        case "video": "play.rectangle"
        case "audio": "speaker.wave.2"
        case "a": "link"
        case "button": "cursorarrow.click"
        case "input", "textarea", "select", "form": "character.cursor.ibeam"
        case "h1", "h2", "h3", "h4", "h5", "h6": "textformat.size"
        case "p", "span", "label", "strong", "em", "b", "i", "blockquote": "text.alignleft"
        case "ul", "ol", "li": "list.bullet"
        case "table", "thead", "tbody", "tr", "td", "th": "tablecells"
        case "svg", "canvas", "path": "paintbrush.pointed"
        case "iframe": "globe"
        case "region": "crop"
        default: "square.dashed"
        }
    }

    var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: Self.symbol(forTag: selection.tagName))
                .font(.system(size: 9.5, weight: .semibold))
            Text(selection.tagName)
                .cmuxFont(size: 12.5, weight: .medium)
                .lineLimit(1)
            // Always laid out, faded in on hover: revealing it must not change
            // the chip's width, or the whole composer row reflows under the
            // pointer.
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(Color.white.opacity(0.16)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
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
        .foregroundStyle(Self.chipBlue)
        .padding(.horizontal, 4)
        .frame(height: 21)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onReveal() }
        .onHover { isHovered = $0 }
        .safeHelp(identityHelp)
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
        var height: CGFloat
        var row: Int
    }

    private func arrange(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, slots: [Slot]) {
        let maxWidth = proposal.width ?? 400
        var slots: [Slot] = []
        var rowHeights: [CGFloat] = [0]
        var cursor = CGPoint.zero
        var row = 0
        func wrapRow() {
            cursor.x = 0
            cursor.y += rowHeights[row] + rowSpacing
            row += 1
            rowHeights.append(0)
        }
        for (index, subview) in subviews.enumerated() {
            let isField = index == subviews.count - 1
            if isField {
                var available = maxWidth - cursor.x
                if available < minimumFieldWidth, cursor.x > 0 {
                    wrapRow()
                    available = maxWidth
                }
                let size = subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
                slots.append(Slot(origin: cursor, width: available, height: size.height, row: row))
                rowHeights[row] = max(rowHeights[row], size.height)
                cursor.x += available
            } else {
                let size = subview.sizeThatFits(.unspecified)
                if cursor.x > 0, cursor.x + size.width > maxWidth {
                    wrapRow()
                }
                slots.append(Slot(origin: cursor, width: nil, height: size.height, row: row))
                rowHeights[row] = max(rowHeights[row], size.height)
                cursor.x += size.width + spacing
            }
        }
        // Center every subview vertically within its row.
        for index in slots.indices {
            slots[index].origin.y += (rowHeights[slots[index].row] - slots[index].height) / 2
        }
        return (CGSize(width: maxWidth, height: cursor.y + rowHeights[row]), slots)
    }
}
