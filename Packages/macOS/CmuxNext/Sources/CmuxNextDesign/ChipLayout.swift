public import CoreGraphics

/// The frames of a one-line chip (a status banner, a badge, a pill with a button): its items side
/// by side in reading order between insets, each centered on the chip's height, and a flexible
/// item (a truncating label) taking the width the chip lacks or has to spare. A pure function of
/// the items' sizes and the chip's size, so the chip lays out in `layout()` and a pane resized every
/// frame solves no constraints: Chromium's `views::BoxLayout` (ui/views/layout/box_layout.cc), where a
/// view reports its preferred size and frames its children in `Layout()`.
///
/// Sizes and frames are alignment rects in the chip's own unflipped coordinates
/// (`NSView.frame(forAlignmentRect:)` turns one into a frame).
public nonisolated struct ChipLayout: Equatable, Sendable {
    /// One child: its preferred alignment size, and whether it gives up or takes width.
    public nonisolated struct Item: Equatable, Sendable {
        public var size: CGSize
        public var flexible: Bool

        public init(_ size: CGSize, flexible: Bool = false) {
            self.size = size
            self.flexible = flexible
        }
    }

    /// The space between the chip's edges and its items; leading and trailing follow reading order.
    public nonisolated struct Insets: Equatable, Sendable {
        public var top: CGFloat
        public var leading: CGFloat
        public var bottom: CGFloat
        public var trailing: CGFloat

        public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }

        public init(horizontal: CGFloat, vertical: CGFloat) {
            self.init(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
        }
    }

    public var items: [Item]
    public var spacing: CGFloat
    public var insets: Insets
    /// The chip is at least this tall.
    public var minHeight: CGFloat
    /// The chip is at most this wide; its flexible item gives up the rest.
    public var maxWidth: CGFloat

    public init(items: [Item], spacing: CGFloat = 0, insets: Insets, minHeight: CGFloat = 0, maxWidth: CGFloat = .greatestFiniteMagnitude) {
        self.items = items
        self.spacing = spacing
        self.insets = insets
        self.minHeight = minHeight
        self.maxWidth = maxWidth
    }

    /// The items, their spacing and the insets, in whole points: at least `minHeight` tall, at most `maxWidth` wide.
    public var preferredSize: CGSize {
        let height = max(minHeight, insets.top + insets.bottom + (items.map(\.size.height).max() ?? 0))
        return CGSize(width: min(maxWidth, naturalWidth).rounded(.up), height: height.rounded(.up))
    }

    /// Each item's frame in a chip of `size`, in the order of `items`. The flexible items, first
    /// first, absorb the difference from the natural width (none narrower than zero); with
    /// `rightToLeft` the row reads from the trailing edge.
    public func frames(in size: CGSize, rightToLeft: Bool = false) -> [CGRect] {
        var slack = size.width - naturalWidth
        var x = insets.leading
        let inner = size.height - insets.top - insets.bottom
        return items.map { item in
            var width = item.size.width
            if item.flexible, slack != 0 {
                let adjusted = max(0, width + slack)
                slack -= adjusted - width
                width = adjusted
            }
            let y = insets.bottom + ((inner - item.size.height) / 2).rounded()
            let frame = CGRect(x: x, y: y, width: width, height: item.size.height)
            x += width + spacing
            return rightToLeft ? CGRect(x: size.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
        }
    }

    /// Each item's frame with the chip placed in `bounds` at its natural width (no wider than
    /// `maxWidth` or `bounds`, its flexible item giving up the rest) and on the full height: at the
    /// leading edge, or `centered`. A row inside a surface that resizes every frame (the drop
    /// overlay's card) frames its items with this.
    public func frames(placedIn bounds: CGRect, centered: Bool = false, rightToLeft: Bool = false) -> [CGRect] {
        let width = max(0, min(naturalWidth, maxWidth, bounds.width))
        let x = centered ? ((bounds.width - width) / 2).rounded() : (rightToLeft ? bounds.width - width : 0)
        return frames(in: CGSize(width: width, height: bounds.height), rightToLeft: rightToLeft)
            .map { $0.offsetBy(dx: bounds.minX + x, dy: bounds.minY) }
    }

    private var naturalWidth: CGFloat {
        insets.leading + insets.trailing + items.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, items.count - 1))
    }
}
