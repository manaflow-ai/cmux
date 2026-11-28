import CoreGraphics

/// Centered lines of suggestion chips (the first-run starters above the
/// message box, like Messages' suggested replies and the Codex prompt
/// starters): one row when every chip fits, else as many chips per line as
/// fit, in order, each line centered in the available width. Three chips
/// that do not fit in one row wrap 2 + 1, the third centered under the pair.
///
/// Chips keep their natural width (a starter's text is never cut); a chip
/// wider than the whole width takes a line of its own at the full width.
///
/// ```swift
/// let lines = ChipLines(gap: 8).layout(widths: [120, 140, 90], available: 300)
/// ```
public struct ChipLines: Equatable, Sendable {
    /// One placed chip: its index in the input and its frame's x and width
    /// (left to right; the caller mirrors for right-to-left).
    public struct Placement: Equatable, Sendable {
        public var index: Int
        public var x: CGFloat
        public var width: CGFloat

        public init(index: Int, x: CGFloat, width: CGFloat) {
            self.index = index
            self.x = x
            self.width = width
        }
    }

    /// The space between chips on a line.
    public var gap: CGFloat

    /// Creates a layout with `gap` between chips on a line.
    public init(gap: CGFloat) {
        self.gap = gap
    }

    /// The lines, top to bottom.
    /// - Parameters:
    ///   - widths: Each chip's natural width, in order.
    ///   - available: The width the lines are centered in.
    public func layout(widths: [CGFloat], available: CGFloat) -> [[Placement]] {
        let available = max(0, available)
        var lines: [[(index: Int, width: CGFloat)]] = []
        var lineWidth: CGFloat = 0
        for (index, natural) in widths.enumerated() {
            let width = min(max(0, natural), available)
            if let last = lines.last, !last.isEmpty, lineWidth + gap + width <= available {
                lines[lines.count - 1].append((index, width))
                lineWidth += gap + width
            } else {
                lines.append([(index, width)])
                lineWidth = width
            }
        }
        return lines.map { line in
            let total = line.reduce(0) { $0 + $1.width } + CGFloat(max(0, line.count - 1)) * gap
            var x = floor((available - total) / 2)
            return line.map { chip in
                defer { x += chip.width + gap }
                return Placement(index: chip.index, x: x, width: chip.width)
            }
        }
    }
}
