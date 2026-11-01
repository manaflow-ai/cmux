#if os(iOS)
import CmuxMobileDesign
import Observation
import UIKit

/// The look a render model is built for: changes rebuild the cell content.
struct DiffRenderStyle: Hashable, Sendable {
    var codeSize: CGFloat
    var wrap: Bool
    var split: Bool
    /// The list's width; only wrap and split heights depend on it (0 otherwise).
    var width: CGFloat
    /// Search in File: every match in the code is highlighted (empty: no search).
    var search = ""
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
                   codeSize: style.codeSize, wrap: style.wrap, search: style.search)
    }

    struct ContentKey: Hashable {
        var fileID: String
        var contentHash: UInt64
        var hideWhitespace: Bool
        var split: Bool
        var codeSize: CGFloat
        var wrap: Bool
        var search: String
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
        texts.reserveCapacity(rows.lines.count)
        indents.reserveCapacity(rows.lines.count)
        for (index, display) in rows.displays.enumerated() {
            var dropped = 0
            var indent: CGFloat = 0
            if wrapsUnified {
                indent = DiffLayout.hangingIndent(display, charWidth: charWidth, codeWidth: unifiedCodeWidth)
                dropped = min(display.indent, Int((indent / max(charWidth, 1)).rounded(.down)))
            }
            texts.append(Self.attributed(display, kind: rows.lines[index].kind, dropping: dropped, font: fonts.code, search: style.search))
            indents.append(indent)
        }
        self.texts = texts
        self.indents = indents

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

    /// Split: the number column (32 pt and 6 pt of padding) before each side's code.
    static let splitNumberColumn: CGFloat = 38

    /// The background of a Search in File match.
    static let searchMatch = UIColor.systemYellow.withAlphaComponent(0.45)

    /// Code text with word-level highlights (tabs expanded, see `DiffLayout.display`), and the
    /// matches of `search`.
    static func attributed(_ display: DiffLayout.DisplayLine, kind: DiffLine.Kind, dropping prefix: Int, font: UIFont,
                           search: String = "") -> NSAttributedString {
        let characters = Array(display.text.dropFirst(prefix))
        let string = characters.isEmpty ? " " : String(characters)
        let text = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: UIColor.label])
        let matches = search.isEmpty ? [] : DiffNavigation.ranges(of: search, in: display.text)
        guard !display.highlights.isEmpty || !matches.isEmpty, !characters.isEmpty else { return text }
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
        func paint(_ ranges: [Range<Int>], _ color: UIColor) {
            for range in ranges {
                let lower = max(0, range.lowerBound - prefix)
                let upper = min(characters.count, range.upperBound - prefix)
                guard lower < upper else { continue }
                let start = ascii ? lower : utf16[lower]
                let end = ascii ? upper : utf16[upper]
                text.addAttribute(.backgroundColor, value: color, range: NSRange(location: start, length: end - start))
            }
        }
        paint(display.highlights, color)
        paint(matches, searchMatch)
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

    /// Files up to this many lines and characters are prepared in place (no blank frame);
    /// longer ones (a minified line too) off main.
    nonisolated static let inlineLineLimit = 300
    nonisolated static let inlineCharacterLimit = 24_000

    /// A pure size check (no renderer state): callable from any context.
    nonisolated static func preparesInPlace(_ file: DiffFile) -> Bool {
        guard file.lines.count <= inlineLineLimit else { return false }
        var characters = 0
        for line in file.lines {
            characters += line.text.utf8.count
            if characters > inlineCharacterLimit { return false }
        }
        return true
    }

    func update(file: DiffFile, key: DiffRenderKey) async {
        guard model?.key != key else { return }
        let rowsKey = RowsKey(fileID: key.fileID, contentHash: key.contentHash, options: key.options)
        let cachedRows = lastRows?.key == rowsKey ? lastRows?.rows : nil
        let options = key.options
        let build: @Sendable () -> DiffRenderModel = {
            DiffRenderModel(rows: cachedRows ?? DiffRows(file: file, options: options), key: key)
        }
        let made: DiffRenderModel
        if Self.preparesInPlace(file) {
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
