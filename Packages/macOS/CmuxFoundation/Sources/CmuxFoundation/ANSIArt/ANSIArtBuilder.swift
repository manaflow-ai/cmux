import Foundation

/// Accumulates styled runs into lines and applies SGR parameters.
struct ANSIArtBuilder {
    let maxLines: Int
    let maxColumns: Int
    let tabWidth: Int

    private var style = ANSIArtStyle()
    private var lines: [ANSIArtLine] = []
    private var runs: [ANSIArtRun] = []
    private var pending = String.UnicodeScalarView()
    private var pendingStyle = ANSIArtStyle()
    private var column = 0

    init(maxLines: Int, maxColumns: Int, tabWidth: Int) {
        self.maxLines = maxLines
        self.maxColumns = maxColumns
        self.tabWidth = tabWidth
    }

    var isFull: Bool { lines.count >= maxLines }

    mutating func append(_ scalar: Unicode.Scalar) {
        let width = ANSIArt.cellWidth(of: scalar)
        guard column + width <= maxColumns else { return }
        if style != pendingStyle {
            flushRun()
            pendingStyle = style
        }
        pending.append(scalar)
        column += width
    }

    mutating func appendTab() {
        let spaces = tabWidth - column % tabWidth
        for _ in 0..<spaces {
            append(" ")
        }
    }

    mutating func newLine() {
        flushRun()
        if !isFull {
            lines.append(ANSIArtLine(runs: Self.trimmingTrailingBlankCells(runs)))
        }
        runs = []
        column = 0
    }

    func finish() -> ANSIArt? {
        var copy = self
        if !copy.pending.isEmpty || !copy.runs.isEmpty {
            copy.newLine()
        }
        var lines = copy.lines
        while let first = lines.first, first.runs.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.runs.isEmpty { lines.removeLast() }
        return lines.isEmpty ? nil : ANSIArt(lines: lines)
    }

    private mutating func flushRun() {
        guard !pending.isEmpty else { return }
        runs.append(ANSIArtRun(text: String(pending), style: pendingStyle))
        pending = String.UnicodeScalarView()
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
            let trimmed = last.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
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
}
