import Foundation

/// Accumulates styled runs into lines and applies SGR parameters.
struct ANSIArtBuilder {
    let maxLines: Int
    let maxColumns: Int
    let tabWidth: Int

    /// The most scalars one cell keeps. Real emoji sequences need about
    /// ten; the cap stops a stack of combining marks from costing layout time.
    static let maxScalarsPerCell = 16

    private var style = ANSIArtStyle()
    private var lines: [ANSIArtLine] = []
    private var runs: [ANSIArtRun] = []
    private var pending = ""
    private var pendingStyle = ANSIArtStyle()
    private var column = 0
    /// The grapheme cluster being read. It is placed once the next scalar
    /// starts a new cluster, because a later scalar (VS16, ZWJ, a mark) can
    /// still change its width.
    private var cluster = ""
    private var clusterScalarCount = 0
    private var clusterStyle = ANSIArtStyle()
    /// The last character placed, which `CSI n b` repeats.
    private var lastPlaced: Character?

    init(maxLines: Int, maxColumns: Int, tabWidth: Int) {
        self.maxLines = maxLines
        self.maxColumns = maxColumns
        self.tabWidth = tabWidth
    }

    var isFull: Bool { lines.count >= maxLines }

    mutating func append(_ scalar: Unicode.Scalar) {
        // No ASCII scalar extends a cluster (CR, the one exception before LF,
        // never reaches the builder), so most art skips the cluster check.
        if !cluster.isEmpty, !scalar.isASCII {
            var extended = cluster
            extended.unicodeScalars.append(scalar)
            if extended.count == 1 {
                if clusterScalarCount < Self.maxScalarsPerCell {
                    cluster = extended
                    clusterScalarCount += 1
                }
                return
            }
        }
        placeCluster()
        cluster = String(scalar)
        clusterScalarCount = 1
        clusterStyle = style
    }

    /// Advances to the next tab stop over blank cells.
    mutating func appendTab() {
        placeCluster()
        appendBlankCells(tabWidth - column % tabWidth)
    }

    /// Moves `count` cells right over blank cells (`CSI n C`). The cells are
    /// unpainted, as in a terminal, so they take the default style.
    mutating func appendBlankCells(_ count: Int) {
        placeCluster()
        let count = min(count, maxColumns - column)
        guard count > 0 else { return }
        place(String(repeating: " ", count: count), width: count, style: ANSIArtStyle())
    }

    /// Repeats the last placed character `count` times (`CSI n b`).
    mutating func repeatLastCharacter(_ count: Int) {
        placeCluster()
        guard let lastPlaced else { return }
        let width = ANSIArt.cellWidth(of: lastPlaced)
        guard width > 0 else { return }
        let count = min(count, (maxColumns - column) / width)
        guard count > 0 else { return }
        place(String(repeating: String(lastPlaced), count: count), width: count * width, style: style)
    }

    mutating func newLine() {
        placeCluster()
        flushRun()
        if !isFull {
            lines.append(ANSIArtLine(runs: Self.trimmingTrailingBlankCells(runs)))
        }
        runs = []
        column = 0
    }

    func finish() -> ANSIArt? {
        var copy = self
        copy.placeCluster()
        if !copy.pending.isEmpty || !copy.runs.isEmpty {
            copy.newLine()
        }
        var lines = copy.lines
        while let first = lines.first, first.runs.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.runs.isEmpty { lines.removeLast() }
        return lines.isEmpty ? nil : ANSIArt(lines: lines)
    }

    /// Places the cluster being read. A cluster with no base character (a
    /// mark at the start of a line) has no cell and is dropped, as is one
    /// past ``maxColumns``.
    private mutating func placeCluster() {
        guard !cluster.isEmpty else { return }
        defer {
            cluster = ""
            clusterScalarCount = 0
        }
        let character = Character(cluster)
        let width = ANSIArt.cellWidth(of: character)
        guard width > 0, column + width <= maxColumns else { return }
        place(cluster, width: width, style: clusterStyle)
        lastPlaced = character
    }

    private mutating func place(_ text: String, width: Int, style: ANSIArtStyle) {
        if style != pendingStyle {
            flushRun()
            pendingStyle = style
        }
        pending += text
        column += width
    }

    private mutating func flushRun() {
        guard !pending.isEmpty else { return }
        runs.append(ANSIArtRun(text: pending, style: pendingStyle))
        pending = ""
    }

    // MARK: SGR

    mutating func applySGR(_ parameters: String) {
        // `ESC [ > … m` and friends are private-mode requests, not SGR.
        if let first = parameters.unicodeScalars.first, "<=>?".unicodeScalars.contains(first) {
            return
        }
        let groups = parameters.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < groups.count {
            let group = groups[index]
            if group.contains(":") {
                applyColonGroup(group)
                index += 1
                continue
            }
            guard let code = group.isEmpty ? 0 : Int(group) else {
                index += 1
                continue
            }
            switch code {
            case 0: style = ANSIArtStyle()
            case 1: style.isBold = true
            case 2: style.isDim = true
            case 7: style.isInverse = true
            case 22:
                style.isBold = false
                style.isDim = false
            case 27: style.isInverse = false
            case 30...37: style.foreground = .indexed(code - 30)
            case 39: style.foreground = nil
            case 40...47: style.background = .indexed(code - 40)
            case 49: style.background = nil
            case 90...97: style.foreground = .indexed(code - 90 + 8)
            case 100...107: style.background = .indexed(code - 100 + 8)
            case 38, 48:
                guard let (color, consumed) = Self.extendedColor(groups[(index + 1)...]) else {
                    // A truncated or out-of-range color makes the rest of the
                    // sequence ambiguous; keep what was already applied.
                    return
                }
                if code == 38 { style.foreground = color } else { style.background = color }
                index += consumed
            default:
                break
            }
            index += 1
        }
    }

    /// Applies an ITU T.416 colon group: `38:5:n`, `38:2:r:g:b` or
    /// `38:2:colorspace:r:g:b`. Other colon groups (underline styles) are
    /// ignored.
    private mutating func applyColonGroup(_ group: String) {
        let parts = group.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count >= 3, let code = parts[0], code == 38 || code == 48 else { return }
        let color: ANSIArtColor?
        switch parts[1] {
        case 5:
            color = parts[2].flatMap(Self.paletteIndex)
        case 2 where parts.count >= 5:
            // `38:2:r:g:b`, or `38:2:colorspace:r:g:b` (plus ignored extras).
            let first = parts.count == 5 ? 2 : 3
            color = Self.rgb(parts[first], parts[first + 1], parts[first + 2])
        default:
            color = nil
        }
        guard let color else { return }
        if code == 38 { style.foreground = color } else { style.background = color }
    }

    /// Reads the parameters after a `38`/`48`, returning the color and how
    /// many parameters it used.
    private static func extendedColor(_ rest: ArraySlice<String>) -> (ANSIArtColor, Int)? {
        let values = rest.prefix(4).map { Int($0) }
        guard let mode = values.first ?? nil else { return nil }
        switch mode {
        case 5:
            guard values.count >= 2, let index = values[1].flatMap(paletteIndex) else { return nil }
            return (index, 2)
        case 2:
            guard values.count >= 4, let color = rgb(values[1], values[2], values[3]) else { return nil }
            return (color, 4)
        default:
            return nil
        }
    }

    private static func paletteIndex(_ value: Int) -> ANSIArtColor? {
        (0...255).contains(value) ? .indexed(value) : nil
    }

    private static func rgb(_ red: Int?, _ green: Int?, _ blue: Int?) -> ANSIArtColor? {
        guard let red, let green, let blue,
              let r = UInt8(exactly: red), let g = UInt8(exactly: green), let b = UInt8(exactly: blue) else {
            return nil
        }
        return .rgb(ANSIArtRGB(r, g, b))
    }

    // MARK: Cells

    /// Drops trailing spaces that have no visible background, so the art's
    /// width is its drawn width.
    private static func trimmingTrailingBlankCells(_ runs: [ANSIArtRun]) -> [ANSIArtRun] {
        var runs = runs
        while var last = runs.last {
            guard last.style.background == nil, !last.style.isInverse else { break }
            let trimmed = Self.trimmingTrailingWhitespace(last.text)
            if trimmed.isEmpty {
                runs.removeLast()
                continue
            }
            last.text = trimmed
            runs[runs.count - 1] = last
            break
        }
        return runs
    }

    /// Drops trailing whitespace in one backward pass (a regex here was
    /// quadratic on long blank lines).
    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex {
            let before = scalars.index(before: end)
            guard scalars[before].properties.isWhitespace else { break }
            end = before
        }
        return String(scalars[..<end])
    }
}
