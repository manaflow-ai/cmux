import Foundation

/// Locates complete math in a viewport without changing its terminal text or geometry.
public struct TerminalLatexScanner: Sendable {
    /// Creates a scanner for dollar and backslash math delimiters.
    public init() {}

    /// Finds inline and display equations, excluding code and the input cursor.
    ///
    /// - Parameter frame: A full snapshot anchored to the visible viewport.
    /// - Returns: Bounded equation previews with cell coordinates and terminal colors.
    public func equations(in frame: MobileTerminalRenderGridFrame) -> [TerminalLatexEquation] {
        guard frame.full, frame.anchor == .viewport,
              frame.columns > 0, frame.rows > 0,
              frame.columns <= 1000, frame.rows <= 500 else { return [] }
        let cells = cells(in: frame)
        var rowContentPrefixes = Array(
            repeating: Array(repeating: 0, count: frame.columns + 1),
            count: frame.rows
        )
        for cell in cells where cell.width > 0 && !cell.character.isWhitespace {
            guard rowContentPrefixes.indices.contains(cell.row),
                  (0..<frame.columns).contains(cell.column) else { continue }
            rowContentPrefixes[cell.row][cell.column + 1] += 1
        }
        for row in rowContentPrefixes.indices {
            for column in 1...frame.columns {
                rowContentPrefixes[row][column] += rowContentPrefixes[row][column - 1]
            }
        }
        // ponytail: cap preview DOM work at 64 equations; raise only after profiling dense math output.
        var results: [TerminalLatexEquation] = []
        var index = 0
        var codeMarker: String?
        while index < cells.count, results.count < 64 {
            let character = cells[index].character
            if character == "`" || character == "~" {
                var end = index + 1
                while end < cells.count, cells[end].character == character { end += 1 }
                let marker = String(repeating: String(character), count: end - index)
                if let openingMarker = codeMarker,
                   openingMarker == marker ||
                   (openingMarker.count >= 3
                       && openingMarker.first == marker.first
                       && marker.count >= openingMarker.count) {
                    codeMarker = nil
                } else if codeMarker == nil, character == "`" || marker.count >= 3 { codeMarker = marker }
                index = end
                continue
            }
            guard codeMarker == nil else { index += 1; continue }
            if character == "\\", index + 1 < cells.count,
               !["(", "["].contains(cells[index + 1].character) {
                index += 2
                continue
            }
            let display: Bool
            let close: [Character]
            let openingLength: Int
            if character == "$" {
                display = index + 1 < cells.count && cells[index + 1].character == "$"
                openingLength = display ? 2 : 1
                close = display ? ["$", "$"] : ["$"]
                // Currency and shell variables must not swallow subsequent math.
                if !display, index + 1 == cells.count || cells[index + 1].character.isWhitespace {
                    index += 1
                    continue
                }
            } else if character == "\\", index + 1 < cells.count,
                      ["(", "["].contains(cells[index + 1].character) {
                display = cells[index + 1].character == "["
                openingLength = 2
                close = ["\\", display ? "]" : ")"]
            } else {
                index += 1
                continue
            }
            let start = index
            var end = start + openingLength
            while end < cells.count, end - start <= 4096 {
                if cells[end].character == close[0],
                   close.count == 1 || (end + 1 < cells.count && cells[end + 1].character == close[1]) {
                    break
                }
                if !display, cells[end].character == "\n" { break }
                end += cells[end].character == "\\" && end + 1 < cells.count ? 2 : 1
            }
            guard end < cells.count, end - start <= 4096,
                  cells[end].character == close[0],
                  close.count == 1 || (end + 1 < cells.count && cells[end + 1].character == close[1]) else {
                index += openingLength
                continue
            }
            let source = String(cells[(start + openingLength)..<end].map(\.character))
            if character == "$", !display,
               (source.last?.isWhitespace == true || !source.contains(where: { $0.isLetter || "\\=^_+*/<>".contains($0) })) {
                index += openingLength
                continue
            }
            let finish = end + close.count
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let equation = equation(
                   source: source, display: display, cells: cells, range: start..<finish,
                   rowContentPrefixes: rowContentPrefixes, frame: frame
               ) {
                results.append(equation)
            }
            index = finish
        }
        return results
    }

    private struct Cell {
        var character: Character
        var row: Int
        var column: Int
        var width: Int
        var style: MobileTerminalRenderGridFrame.Style
    }

    /// Expands sparse row spans into ordered cells with stable grid coordinates.
    private func cells(in frame: MobileTerminalRenderGridFrame) -> [Cell] {
        let styles = Dictionary(frame.styles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = Dictionary(grouping: frame.rowSpans, by: \.row)
        var result: [Cell] = []
        for row in 0..<frame.rows {
            var column = 0
            for span in (rows[row] ?? []).sorted(by: { $0.column < $1.column }) {
                let style = styles[span.styleID] ?? .default
                while column < span.column {
                    result.append(Cell(character: " ", row: row, column: column, width: 1, style: style))
                    column += 1
                }
                // If the runtime's width differs (e.g. an ambiguous-width font),
                // omit that span instead of placing a preview over unrelated text.
                let reliableWidth = span.text.renderGridEstimatedCellWidth == span.gridCellWidth
                for character in span.text {
                    let width = character.renderGridEstimatedCellWidth
                    result.append(Cell(character: reliableWidth && !style.invisible ? character : " ",
                                       row: row, column: column, width: width, style: style))
                    column += width
                }
                column = span.column + span.gridCellWidth
            }
            // Full physical rows can split a command in the middle of its name.
            if column < frame.columns {
                result.append(Cell(character: "\n", row: row, column: column, width: 0, style: .default))
            }
        }
        return result
    }

    /// Builds one preview while preserving prose that shares its source rows.
    private func equation(
        source: String, display: Bool, cells: [Cell], range: Range<Int>,
        rowContentPrefixes: [[Int]], frame: MobileTerminalRenderGridFrame
    ) -> TerminalLatexEquation? {
        let selected = cells[range].filter { $0.width > 0 }
        guard let first = selected.first, let last = selected.last else { return nil }
        let rows = Dictionary(grouping: selected, by: \.row)
        let regions: [TerminalLatexEquation.Region] = rows.keys.sorted().compactMap { row in
            guard let cells = rows[row],
                  let first = cells.first(where: { !$0.character.isWhitespace }),
                  let last = cells.last(where: { !$0.character.isWhitespace }) else { return nil }
            return .init(column: first.column, row: row, width: last.column + last.width - first.column, height: 1)
        }
        if let cursor = frame.cursor, cursor.visible,
           (first.row...last.row).contains(cursor.row) {
            return nil
        }
        guard var layout = regions.max(by: { $0.width < $1.width }) else { return nil }
        let left = regions.map(\.column).min() ?? first.column
        let right = regions.map { $0.column + $0.width }.max() ?? last.column + last.width
        let leadingStart = max(0, min(left, frame.columns))
        let leadingEnd = max(leadingStart, min(first.column, frame.columns))
        let trailingStart = max(0, min(last.column + last.width, frame.columns))
        let trailingEnd = max(trailingStart, min(right, frame.columns))
        let overlapsProse = rowContentPrefixes[first.row][leadingEnd] > rowContentPrefixes[first.row][leadingStart]
            || rowContentPrefixes[last.row][trailingEnd] > rowContentPrefixes[last.row][trailingStart]
        if display, !overlapsProse {
            layout = .init(column: left, row: first.row, width: right - left, height: last.row - first.row + 1)
        }
        let foreground = first.style.foreground ?? frame.terminalForeground
        let background = first.style.background ?? frame.terminalBackground
        return TerminalLatexEquation(source: source, display: display, regions: regions, layout: layout,
                                     foreground: first.style.inverse ? background : foreground,
                                     background: first.style.inverse ? foreground : background)
    }
}
