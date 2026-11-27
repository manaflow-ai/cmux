/// Hides the cursor in a still of the terminal and keeps the character under
/// it (VERIFY-round8 claim 8: the saved frame filled the cursor's cell with
/// the background, so `› Ask Codex` read `› sk Codex`).
///
/// Works on the cell's pixels (RGBA8, opaque), whatever cursor Ghostty drew:
///
/// - A block (most of the cell far from the background): Ghostty draws the
///   glyph in the background colour over the cursor's colour. Each pixel's
///   mix between the two is read back and drawn reversed, the glyph in the
///   cursor's colour (the text colour) over the background, antialiasing kept.
/// - A hollow box (unfocused), a bar or an underline: lines at the cell's
///   edges that are almost all cursor are set to the background; the glyph
///   inside is left as drawn.
/// - Nothing drawn (the blink's off phase): the cell is left alone.
public enum TerminalCursorErase {
    public struct Rect: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Sum of the channel differences above which a pixel is not background.
    static let farThreshold = 60

    /// `bounds` (the buffer's size in pixels) lets the erase look for the
    /// block Ghostty drew within one cell of `rect` (round 11 N5: the cell
    /// reported was half a cell off the block drawn, and the block stayed).
    public static func erase(pixels: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, rect: Rect,
                             background: (UInt8, UInt8, UInt8), bounds: (width: Int, height: Int)? = nil) {
        guard rect.width > 0, rect.height > 0 else { return }
        if let bounds, let block = drawnBlock(pixels: pixels, bytesPerRow: bytesPerRow, near: rect, background: background,
                                              bounds: bounds), block != rect {
            return erase(pixels: pixels, bytesPerRow: bytesPerRow, rect: block, background: background)
        }
        let b = (Int(background.0), Int(background.1), Int(background.2))
        func pixel(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> {
            pixels + (rect.y + y) * bytesPerRow + (rect.x + x) * 4
        }
        func far(_ p: UnsafeMutablePointer<UInt8>) -> Bool {
            abs(Int(p[0]) - b.0) + abs(Int(p[1]) - b.1) + abs(Int(p[2]) - b.2) > farThreshold
        }
        var farCount = 0
        var counts: [UInt32: Int] = [:]
        for y in 0..<rect.height {
            for x in 0..<rect.width {
                let p = pixel(x, y)
                guard far(p) else { continue }
                farCount += 1
                counts[UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]), default: 0] += 1
            }
        }
        if farCount * 2 >= rect.width * rect.height, let key = counts.max(by: { $0.value < $1.value })?.key {
            // A block: p = C + a (B - C), a = the glyph's coverage; drawn as B + a (C - B).
            let c = (Int(key >> 16 & 0xFF), Int(key >> 8 & 0xFF), Int(key & 0xFF))
            let d = (b.0 - c.0, b.1 - c.1, b.2 - c.2)
            let dd = Double(d.0 * d.0 + d.1 * d.1 + d.2 * d.2)
            guard dd > 0 else { return }
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let p = pixel(x, y)
                    let dot = Double((Int(p[0]) - c.0) * d.0 + (Int(p[1]) - c.1) * d.1 + (Int(p[2]) - c.2) * d.2)
                    let a = min(1, max(0, dot / dd))
                    p[0] = UInt8((Double(b.0) - a * Double(d.0)).rounded())
                    p[1] = UInt8((Double(b.1) - a * Double(d.1)).rounded())
                    p[2] = UInt8((Double(b.2) - a * Double(d.2)).rounded())
                }
            }
            return
        }
        // Edge lines (an outline, a bar, an underline), decided on the cell
        // as drawn, then cleared.
        func lineIsCursor(_ points: [(Int, Int)]) -> Bool {
            !points.isEmpty && points.filter { far(pixel($0.0, $0.1)) }.count * 5 >= points.count * 4
        }
        var cleared: [(Int, Int)] = []
        let rows = (0..<rect.height).map { y in (0..<rect.width).map { ($0, y) } }
        let columns = (0..<rect.width).map { x in (0..<rect.height).map { (x, $0) } }
        for edge in [Array(rows), Array(rows.reversed()), Array(columns), Array(columns.reversed())] {
            let depth = max(1, min(3, edge.count / 4))
            for line in edge.prefix(depth) {
                guard lineIsCursor(line) else { break }
                cleared += line
            }
        }
        for (x, y) in cleared {
            let p = pixel(x, y)
            p[0] = background.0
            p[1] = background.1
            p[2] = background.2
        }
    }

    /// Where a block cursor is drawn near `rect`: the cell-sized window,
    /// at most one cell sideways and half a cell up or down, holding the
    /// most pixels of the dominant non-background colour of `rect` itself,
    /// when at least half the window is that colour. Nil when there is no
    /// block (an outline, a bar, the blink's off phase).
    static func drawnBlock(pixels: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, near rect: Rect,
                           background: (UInt8, UInt8, UInt8), bounds: (width: Int, height: Int)) -> Rect? {
        let b = (Int(background.0), Int(background.1), Int(background.2))
        func at(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> { pixels + y * bytesPerRow + x * 4 }
        // The colour most of the reported cell's non-background pixels have.
        var counts: [UInt32: Int] = [:]
        for y in max(0, rect.y)..<min(bounds.height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(bounds.width, rect.x + rect.width) {
                let p = at(x, y)
                guard abs(Int(p[0]) - b.0) + abs(Int(p[1]) - b.1) + abs(Int(p[2]) - b.2) > farThreshold else { continue }
                counts[UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]), default: 0] += 1
            }
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let c = (Int(key >> 16 & 0xFF), Int(key >> 8 & 0xFF), Int(key & 0xFF))
        // A summed-area table of "is the block's colour" over the search area.
        let x0 = max(0, rect.x - rect.width), x1 = min(bounds.width, rect.x + 2 * rect.width)
        let y0 = max(0, rect.y - rect.height / 2), y1 = min(bounds.height, rect.y + rect.height + rect.height / 2)
        let w = x1 - x0, h = y1 - y0
        guard w >= rect.width, h >= rect.height else { return nil }
        var table = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var run = 0
            for x in 0..<w {
                let p = at(x0 + x, y0 + y)
                if abs(Int(p[0]) - c.0) + abs(Int(p[1]) - c.1) + abs(Int(p[2]) - c.2) <= 24 { run += 1 }
                table[(y + 1) * (w + 1) + x + 1] = table[y * (w + 1) + x + 1] + run
            }
        }
        func count(_ x: Int, _ y: Int) -> Int {
            let a = y * (w + 1) + x, d = (y + rect.height) * (w + 1) + x + rect.width
            return table[d] - table[d - rect.width] - table[a + rect.width] + table[a]
        }
        var best: (count: Int, x: Int, y: Int, distance: Int)?
        for y in 0...(h - rect.height) {
            for x in 0...(w - rect.width) {
                let n = count(x, y)
                let distance = abs(x0 + x - rect.x) + abs(y0 + y - rect.y)
                if best.map({ n > $0.count || (n == $0.count && distance < $0.distance) }) ?? true {
                    best = (n, x, y, distance)
                }
            }
        }
        guard let best, best.count * 2 >= rect.width * rect.height else { return nil }
        return Rect(x: x0 + best.x, y: y0 + best.y, width: rect.width, height: rect.height)
    }
}
