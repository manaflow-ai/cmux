import CoreGraphics

// Frame layout for pane chrome (p03-rendering.md R4: pane and window chrome
// uses frame layout, not Auto Layout). Each view sets its subviews' frames in
// `layout()` from these pure functions of its bounds and its content's
// measured sizes, as Chromium's views do with views::BoxLayout
// (ui/views/layout/box_layout.cc) and mirror under RTL with
// View::GetMirroredXForRect (ui/views/view.cc). Rects are alignment rects in
// an unflipped view (y up); `setChromeLayoutRect` (ChromeColumnItem.swift)
// turns them into frames.

/// Edge insets in reading order: leading and trailing swap sides in a
/// right-to-left layout.
nonisolated struct ChromeInsets: Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        (self.top, self.leading, self.bottom, self.trailing) = (top, leading, bottom, trailing)
    }

    init(all value: CGFloat) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }

    var horizontal: CGFloat { leading + trailing }
    var vertical: CGFloat { top + bottom }

    /// The inset at the left edge in a layout of that direction.
    func left(rightToLeft: Bool) -> CGFloat { rightToLeft ? trailing : leading }
}

/// Items stacked top to bottom with a fixed gap, each as wide as it measures
/// (at most the inner width), at the leading edge or centered: what replaces
/// a vertical `NSStackView` in pane chrome (views::BoxLayout, kVertical).
nonisolated struct ChromeColumnLayout: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading
        case center
    }

    var spacing: CGFloat
    var insets = ChromeInsets()
    var alignment = Alignment.center
    var rightToLeft = false

    /// The size of a column that holds `items`, insets included.
    func size(of items: [CGSize]) -> CGSize {
        let width = items.reduce(0) { max($0, $1.width) }
        let height = items.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(items.count - 1, 0))
        return CGSize(width: width + insets.horizontal, height: height + insets.vertical)
    }

    /// Each item's rect in `box`, the first at the top. An item wider than
    /// the inner width is cut to it.
    func place(_ items: [CGSize], in box: CGRect) -> [CGRect] {
        let inner = max(box.width - insets.horizontal, 0)
        let left = box.minX + insets.left(rightToLeft: rightToLeft)
        var top = box.maxY - insets.top
        var rects: [CGRect] = []
        rects.reserveCapacity(items.count)
        for item in items {
            let width = min(item.width, inner)
            let x: CGFloat = switch alignment {
            case .leading: rightToLeft ? left + inner - width : left
            case .center: left + ((inner - width) / 2).rounded(.down)
            }
            rects.append(CGRect(x: x, y: top - item.height, width: width, height: item.height))
            top -= item.height + spacing
        }
        return rects
    }
}

/// Items side by side in reading order with a fixed gap, centered
/// vertically: what replaces a horizontal `NSStackView` in pane chrome
/// (views::BoxLayout, kHorizontal). Under RTL the first item is at the right.
nonisolated struct ChromeRowLayout: Equatable, Sendable {
    var spacing: CGFloat
    var insets = ChromeInsets()
    var rightToLeft = false

    /// The width that fits every item at its size, insets included.
    func width(of items: [CGSize]) -> CGFloat {
        items.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(items.count - 1, 0)) + insets.horizontal
    }

    /// The tallest item's height, insets included.
    func height(of items: [CGSize]) -> CGFloat {
        items.reduce(0) { max($0, $1.height) } + insets.vertical
    }

    /// Each item's rect in `box`, from the leading edge. When the items do
    /// not fit, the item at `flexible` gives up the width they lack (down to
    /// 0); the others keep theirs.
    func place(_ items: [CGSize], in box: CGRect, flexible: Int? = nil) -> [CGRect] {
        var widths = items.map(\.width)
        let lack = width(of: items) - box.width
        if lack > 0, let flexible, widths.indices.contains(flexible) {
            widths[flexible] = max(widths[flexible] - lack, 0)
        }
        let midY = (box.minY + insets.bottom + box.maxY - insets.top) / 2
        var offset = insets.leading
        var rects: [CGRect] = []
        rects.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let width = widths[index]
            let x = rightToLeft ? box.maxX - offset - width : box.minX + offset
            rects.append(CGRect(x: x, y: (midY - item.height / 2).rounded(.down), width: width, height: item.height))
            offset += width + spacing
        }
        return rects
    }

    // A row of answers (a prompt's, a card's) that does not fit side by side
    // stacks them in reading order, each as wide as the row, as Chrome's
    // one-time permission bubble stacks its three answers
    // (chrome/browser/ui/views/permissions/permission_prompt_bubble_base_view.cc).

    /// The row's size at most `maxWidth` wide: side by side when the items
    /// fit there, else stacked, as wide as `maxWidth`.
    func size(of items: [CGSize], maxWidth: CGFloat) -> CGSize {
        guard width(of: items) > maxWidth else { return CGSize(width: width(of: items), height: height(of: items)) }
        return CGSize(width: max(maxWidth, 0), height: stack.size(of: items).height)
    }

    /// Each item's rect in `box`: side by side when the items fit in its
    /// width, else stacked top to bottom, each as wide as the box less the
    /// insets.
    func placeFitting(_ items: [CGSize], in box: CGRect) -> [CGRect] {
        guard width(of: items) > box.width else { return place(items, in: box) }
        let inner = max(box.width - insets.horizontal, 0)
        return stack.place(items.map { CGSize(width: inner, height: $0.height) }, in: box)
    }

    /// The row's items stacked: its gap between them, its insets around them.
    private var stack: ChromeColumnLayout {
        ChromeColumnLayout(spacing: spacing, insets: insets, alignment: .leading, rightToLeft: rightToLeft)
    }
}
