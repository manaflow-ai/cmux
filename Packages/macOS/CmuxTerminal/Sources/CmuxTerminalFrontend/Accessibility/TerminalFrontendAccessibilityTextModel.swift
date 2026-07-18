internal import AppKit
internal import CmuxTerminalDomain

/// Pure UTF-16 projection used by AppKit accessibility parameterized attributes.
struct TerminalFrontendAccessibilityTextModel {
    struct CellMapping: Equatable {
        let row: UInt64
        let column: Int
        let columnSpan: Int
        let range: NSRange
    }

    let snapshot: TerminalAccessibilitySnapshot

    var utf16Length: Int {
        (snapshot.text as NSString).length
    }

    var selectedRanges: [NSRange] {
        snapshot.selections.flatMap(\.utf16Ranges).compactMap {
            validNSRange($0, maximum: utf16Length)
        }
    }

    var selectedRange: NSRange {
        Self.union(selectedRanges)
            ?? snapshot.cursor.flatMap {
                validNSRange($0.insertionRange, maximum: utf16Length)
            }
            ?? NSRange(location: 0, length: 0)
    }

    func string(for range: NSRange) -> String? {
        let text = snapshot.text as NSString
        guard Self.isValid(range, maximum: text.length) else { return nil }
        return text.substring(with: range)
    }

    func line(for index: Int) -> Int {
        guard index >= 0, index <= utf16Length else { return NSNotFound }
        for lineIndex in snapshot.lines.indices {
            let nextStart = snapshot.lines.indices.contains(lineIndex + 1)
                ? snapshot.lines[lineIndex + 1].utf16Range.location
                : utf16Length + 1
            if index < nextStart { return lineIndex }
        }
        return snapshot.lines.isEmpty ? NSNotFound : snapshot.lines.count - 1
    }

    func range(forLine line: Int) -> NSRange {
        guard snapshot.lines.indices.contains(line),
              let range = validNSRange(
                snapshot.lines[line].utf16Range,
                maximum: utf16Length
              )
        else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return range
    }

    func composedRange(for index: Int) -> NSRange {
        let text = snapshot.text as NSString
        guard index >= 0, index < text.length else {
            return index == text.length
                ? NSRange(location: index, length: 0)
                : NSRange(location: NSNotFound, length: 0)
        }
        return text.rangeOfComposedCharacterSequence(at: index)
    }

    func range(viewportRow: Int, column: Int) -> NSRange? {
        guard viewportRow >= 0, viewportRow < snapshot.rows,
              column >= 0, column < snapshot.columns else { return nil }
        let row = snapshot.viewportOffset.addingReportingOverflow(UInt64(viewportRow))
        guard !row.overflow,
              let line = snapshot.lines.first(where: { $0.row == row.partialValue }),
              let cell = line.cells.first(where: {
                  column >= $0.column && column < $0.column + max($0.columnSpan, 1)
              })
        else { return nil }
        return validNSRange(cell.utf16Range, maximum: utf16Length)
    }

    func cells(intersecting range: NSRange) -> [CellMapping] {
        guard Self.isValid(range, maximum: utf16Length) else { return [] }
        let rangeEnd = range.location + range.length
        var result: [CellMapping] = []
        for line in snapshot.lines {
            for cell in line.cells {
                guard let cellRange = validNSRange(
                    cell.utf16Range,
                    maximum: utf16Length
                ) else { continue }
                let cellEnd = cellRange.location + cellRange.length
                let intersects: Bool
                if range.length == 0 {
                    let includesTrailingEdge = range.location == utf16Length
                    intersects = range.location >= cellRange.location
                        && (includesTrailingEdge
                            ? range.location <= cellEnd
                            : range.location < cellEnd)
                } else {
                    intersects = range.location < cellEnd && rangeEnd > cellRange.location
                }
                guard intersects else { continue }
                result.append(CellMapping(
                    row: line.row,
                    column: cell.column,
                    columnSpan: cell.columnSpan,
                    range: cellRange
                ))
                if range.length == 0 { return result }
            }
        }
        return result
    }

    static func isValid(_ range: NSRange, maximum: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= maximum
            && range.length <= maximum - range.location
    }

    static func union(_ ranges: [NSRange]) -> NSRange? {
        let validRanges = ranges.filter {
            $0.location != NSNotFound && $0.location >= 0 && $0.length >= 0
        }
        guard let first = validRanges.first else { return nil }
        var lower = first.location
        var upper = first.location + first.length
        for range in validRanges.dropFirst() {
            lower = min(lower, range.location)
            upper = max(upper, range.location + range.length)
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private func validNSRange(
        _ range: TerminalAccessibilityRange,
        maximum: Int
    ) -> NSRange? {
        let value = NSRange(location: range.location, length: range.length)
        return Self.isValid(value, maximum: maximum) ? value : nil
    }
}
