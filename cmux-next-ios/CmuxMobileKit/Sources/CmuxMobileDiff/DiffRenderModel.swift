#if os(iOS)
import CmuxMobileDesign
import Observation
import SwiftUI
import UIKit

/// The look a render model is built for: changes rebuild the cell content.
struct DiffRenderStyle: Hashable, Sendable {
    var codeSize: CGFloat
    var wrap: Bool
    var split: Bool
    /// The list's width; only wrap and split heights depend on it (0 otherwise).
    var width: CGFloat
}

/// Identifies one render model: the file's content, what is shown of it and how.
struct DiffRenderKey: Hashable, Sendable {
    var fileID: String
    var contentHash: UInt64
    var options: DiffRows.Options
    var style: DiffRenderStyle

    /// Everything but the expanded ranges and the width: two models with the same content
    /// key show every shared row id with the same content (expanding only adds rows).
    var contentKey: ContentKey {
        ContentKey(fileID: fileID, contentHash: contentHash, hideWhitespace: options.hideWhitespace, split: options.split,
                   codeSize: style.codeSize, wrap: style.wrap)
    }

    struct ContentKey: Hashable {
        var fileID: String
        var contentHash: UInt64
        var hideWhitespace: Bool
        var split: Bool
        var codeSize: CGFloat
        var wrap: Bool
    }
}

/// Everything the diff list draws, prepared once per (file, options, style) off the main
/// thread: the rows, each line's attributed code text (word highlights, tabs expanded), the
/// wrap indent, and every row's height. Cells only read it, so scrolling and horizontal
/// panning cost O(visible rows). Immutable after init.
final class DiffRenderModel: @unchecked Sendable {
    let key: DiffRenderKey
    let rows: DiffRows
    let ids: [String]
    let indexByID: [String: Int]
    /// Per row.
    let heights: [CGFloat]
    /// Per line: the code as drawn (wrap mode drops the leading spaces the indent replaces).
    let texts: [NSAttributedString]
    /// Per line, wrap mode: the hanging indent in points.
    let indents: [CGFloat]
    /// Per line: the leading characters `texts` drops (wrap mode's indent).
    let dropped: [Int]
    /// Each shown line's row (a split pair is the row of both its lines): a jump's target.
    let rowByLine: [Int: Int]
    /// Unwrapped: the code column's natural width (the longest line and trailing room).
    let codeWidth: CGFloat
    let fonts: DiffFonts

    var style: DiffRenderStyle { key.style }
    var isPinned: Bool { !style.wrap && !style.split }

    init(rows: DiffRows, key: DiffRenderKey) {
        self.key = key
        self.rows = rows
        let style = key.style
        let fonts = DiffFonts(codeSize: style.codeSize)
        self.fonts = fonts
        let ids = rows.rows.map(\.id)
        self.ids = ids
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() { indexByID[id] = index }
        self.indexByID = indexByID
        let charWidth = fonts.advancement
        codeWidth = (CGFloat(rows.longestColumns) * charWidth + DiffLayout.codeTrailingPadding).rounded(.up)

        // Text and indents per line.
        let wrapsUnified = style.wrap && !style.split
        let unifiedCodeWidth = DiffLayout.codeViewport(width: style.width) - DiffLayout.codeTrailingPadding
        var texts: [NSAttributedString] = []
        var indents: [CGFloat] = []
        var droppedPerLine: [Int] = []
        texts.reserveCapacity(rows.lines.count)
        indents.reserveCapacity(rows.lines.count)
        droppedPerLine.reserveCapacity(rows.lines.count)
        for (index, display) in rows.displays.enumerated() {
            var dropped = 0
            var indent: CGFloat = 0
            if wrapsUnified {
                indent = DiffLayout.hangingIndent(display, charWidth: charWidth, codeWidth: unifiedCodeWidth)
                dropped = min(display.indent, Int((indent / max(charWidth, 1)).rounded(.down)))
            }
            texts.append(Self.attributed(display, kind: rows.lines[index].kind, dropping: dropped, font: fonts.code))
            indents.append(indent)
            droppedPerLine.append(dropped)
        }
        self.texts = texts
        self.indents = indents
        dropped = droppedPerLine
        var rowByLine: [Int: Int] = [:]
        rowByLine.reserveCapacity(rows.lines.count)
        for (index, row) in rows.rows.enumerated() {
            switch row {
            case .line(let line): rowByLine[line] = index
            case .split(let left, let right):
                if let left, rowByLine[left] == nil { rowByLine[left] = index }
                if let right, rowByLine[right] == nil { rowByLine[right] = index }
            default: break
            }
        }
        self.rowByLine = rowByLine

        // Heights per row.
        let lineRow = DiffLayout.rowHeight(lineHeight: fonts.code.lineHeight)
        let codeLine = ceil(fonts.code.lineHeight)
        let numberLine = 2 + ceil(fonts.number.lineHeight)
        func textHeight(_ line: Int, width: CGFloat) -> CGFloat {
            let text = texts[line]
            // Monospaced: a line that fits is one line, no measuring.
            if CGFloat(text.length) * charWidth <= width { return codeLine }
            let rect = text.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], context: nil)
            return max(codeLine, ceil(rect.height))
        }
        let splitText = (style.width - 1) / 2 - DiffRenderModel.splitNumberColumn
        heights = rows.rows.map { row in
            switch row {
            case .header, .gap, .collapsed:
                return DiffLayout.headerRowHeight
            case .line(let line):
                guard style.wrap else { return lineRow }
                return max(textHeight(line, width: unifiedCodeWidth - indents[line]), codeLine) + 4
            case .split(let left, let right):
                guard style.wrap else { return max(codeLine, numberLine) }
                let sides = [left, right].compactMap { $0 }.map { textHeight($0, width: splitText) }
                return max(numberLine, sides.max() ?? codeLine)
            }
        }
    }

    /// Line `line`'s code text with Search in File's matches of `query` painted (the shown
    /// cells only, as they are configured): the prepared text when there is no query.
    func text(_ line: Int, search query: String) -> NSAttributedString {
        let base = texts[line]
        let ranges = DiffNavigation.ranges(of: query, in: rows.displays[line].text)
        guard !ranges.isEmpty else { return base }
        return Self.painted(base, ranges: ranges, dropping: dropped[line], color: UIColor(diffSearchMatch))
    }

    /// `ranges` (characters of the displayed line) painted on `text`, which drops the line's
    /// first `prefix` characters.
    static func painted(_ text: NSAttributedString, ranges: [Range<Int>], dropping prefix: Int, color: UIColor) -> NSAttributedString {
        let string = text.string
        let characters = Array(string)
        let painted = NSMutableAttributedString(attributedString: text)
        let ascii = string.utf8.count == characters.count
        var utf16: [Int] = []
        if !ascii {
            utf16.reserveCapacity(characters.count + 1)
            var offset = 0
            for character in characters {
                utf16.append(offset)
                offset += character.utf16.count
            }
            utf16.append(offset)
        }
        for range in ranges {
            let lower = max(0, range.lowerBound - prefix)
            let upper = min(characters.count, range.upperBound - prefix)
            guard lower < upper else { continue }
            let start = ascii ? lower : utf16[lower]
            let end = ascii ? upper : utf16[upper]
            painted.addAttribute(.backgroundColor, value: color, range: NSRange(location: start, length: end - start))
        }
        return painted
    }

    /// Split: the number column (32 pt and 6 pt of padding) before each side's code.
    static let splitNumberColumn: CGFloat = 38

    /// Code text with word-level highlights (tabs expanded, see `DiffLayout.display`).
    static func attributed(_ display: DiffLayout.DisplayLine, kind: DiffLine.Kind, dropping prefix: Int, font: UIFont) -> NSAttributedString {
        let characters = Array(display.text.dropFirst(prefix))
        let string = characters.isEmpty ? " " : String(characters)
        let text = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: UIColor.label])
        guard !display.highlights.isEmpty, !characters.isEmpty else { return text }
        let color: UIColor = kind == .added ? .cmuxMobileDiffAddWord : .cmuxMobileDiffDelWord
        // Character offsets to UTF-16 offsets (identical for ASCII).
        let ascii = string.utf8.count == characters.count
        var utf16: [Int] = []
        if !ascii {
            utf16.reserveCapacity(characters.count + 1)
            var offset = 0
            for character in characters {
                utf16.append(offset)
                offset += character.utf16.count
            }
            utf16.append(offset)
        }
        for range in display.highlights {
            let lower = max(0, range.lowerBound - prefix)
            let upper = min(characters.count, range.upperBound - prefix)
            guard lower < upper else { continue }
            let start = ascii ? lower : utf16[lower]
            let end = ascii ? upper : utf16[upper]
            text.addAttribute(.backgroundColor, value: color, range: NSRange(location: start, length: end - start))
        }
        return text
    }
}

/// The diff list's fonts for one code size.
struct DiffFonts: @unchecked Sendable {
    let code: UIFont
    let number: UIFont
    let marker: UIFont
    let header: UIFont
    let advancement: CGFloat

    init(codeSize: CGFloat) {
        code = UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        number = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        marker = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        header = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        advancement = ("M" as NSString).size(withAttributes: [.font: code]).width
    }
}

/// Builds the file screen's render model off the main thread, once per key, and keeps the
/// rows of the last (file, options) so a width or wrap change only re-measures.
@MainActor
@Observable
final class DiffRenderer {
    private(set) var model: DiffRenderModel?
    @ObservationIgnored private var lastRows: (key: RowsKey, rows: DiffRows)?
    /// Models built (the memoization tests read it).
    @ObservationIgnored private(set) var builds = 0

    struct RowsKey: Hashable {
        var fileID: String
        var contentHash: UInt64
        var options: DiffRows.Options
    }

    /// Files up to this many lines are prepared in place (no blank frame); longer ones off main.
    static let inlineLineLimit = 300

    func update(file: DiffFile, key: DiffRenderKey) async {
        guard model?.key != key else { return }
        let rowsKey = RowsKey(fileID: key.fileID, contentHash: key.contentHash, options: key.options)
        let cachedRows = lastRows?.key == rowsKey ? lastRows?.rows : nil
        let options = key.options
        let build: @Sendable () -> DiffRenderModel = {
            DiffRenderModel(rows: cachedRows ?? DiffRows(file: file, options: options), key: key)
        }
        let made: DiffRenderModel
        if file.lines.count <= Self.inlineLineLimit {
            made = build()
        } else {
            made = await Task.detached(priority: .userInitiated, operation: build).value
            guard !Task.isCancelled else { return }
        }
        builds += 1
        lastRows = (rowsKey, made.rows)
        model = made
    }
}
#endif
