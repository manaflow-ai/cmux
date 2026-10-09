#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Markdown layout (shared/MARKDOWN.md): a parsed document at a column width becomes
// a display list in body-local points (origin = the bubble's top-left; text starts
// at bubblePadX, bubblePadY). Layout holds no colours, so one layout serves both
// bubble colours and both appearances; MarkdownDraw picks colours by role.
// Every top-level block is laid out alone (cached, LRU) and then stacked, so a
// stream lays out only its tail block.

/// Custom attribute keys (layout only; drawing maps them to colours).
extension NSAttributedString.Key {
    static let mdRole = NSAttributedString.Key("mdRole")
    static let mdStyle = NSAttributedString.Key("mdStyle")
    static let mdToken = NSAttributedString.Key("mdToken")
}

enum MDRole: UInt8 { case body, quote, code, marker, header, more }

/// One laid-out line of text.
struct MDFrag {
    var attr: NSAttributedString
    var line: CTLine
    /// Left edge of the line and top of its 16 pt slot.
    var origin: CGPoint
    var width: CGFloat
    /// Baseline below `origin.y`.
    var baseline: CGFloat
    /// UTF-16 range in `MarkdownLayout.plain`.
    var range: NSRange
    /// Scroll region index, or -1.
    var region: Int
    var role: MDRole
    /// Link at a string index of this line (link runs).
    var links: [(NSRange, String)]
    var height: CGFloat { Markdown.lineHeight }
}

struct MDBox {
    enum Kind: Equatable { case codeBlock, inlineCode, tableHeader, tableBorder, gridH, gridV, quoteBar, rule, checkbox(Bool), strike, fadeHint }
    var rect: CGRect
    var kind: Kind
    var region: Int
    /// Grows to the bubble's inner width minus this inset (code blocks, rules).
    var stretch: Bool = false
}

struct MDRegion {
    enum Kind { case code, table }
    var kind: Kind
    /// Visible frame (body-local). Its width is final after stretching.
    var frame: CGRect
    /// Width of everything inside, from the frame's left edge.
    var contentWidth: CGFloat
    var range: NSRange
    var stretch: Bool
    /// Code: the exact text (copy button). Table: TSV.
    var copyText: String
    var lang: String
    var scrollable: Bool { contentWidth > frame.width + 0.5 }
    var maxOffset: CGFloat { max(0, contentWidth - frame.width) }
}

/// Accessibility structure (MarkdownAccess.swift turns it into elements).
struct MDAXNode {
    enum Kind { case paragraph, heading(Int), list(ordered: Bool), item, code(String), quote, table(rows: Int, cols: Int), row, cell(header: Bool), rule, link(String) }
    var kind: Kind
    var range: NSRange
    var frame: CGRect
    var children: [MDAXNode] = []
}

final class MarkdownLayout: Hashable, @unchecked Sendable {
    let size: CGSize
    let frags: [MDFrag]
    let boxes: [MDBox]
    let regions: [MDRegion]
    /// Display text: what selection offsets index and what Copy returns.
    let plain: String
    let source: String
    let ax: [MDAXNode]
    let identity: Int
    /// A TextLayout of `plain` so code that only reads `PartRow.text` (copy, long-row
    /// tests) keeps working. Geometry comes from this object, never from it.
    let proxy: TextLayout

    init(size: CGSize, frags: [MDFrag], boxes: [MDBox], regions: [MDRegion], plain: String, source: String, ax: [MDAXNode], identity: Int) {
        self.size = size; self.frags = frags; self.boxes = boxes; self.regions = regions
        self.plain = plain; self.source = source; self.ax = ax; self.identity = identity
        let n = (plain as NSString).length
        proxy = TextLayout(text: plain, runs: [], lines: [TextLayout.Line(range: NSRange(location: 0, length: n), width: size.width)], width: size.width)
    }
    static func == (a: MarkdownLayout, b: MarkdownLayout) -> Bool { a === b || (a.identity == b.identity && a.size == b.size && a.source == b.source) }
    func hash(into h: inout Hasher) { h.combine(identity) }
}

extension Markdown {
    static let lineHeight: CGFloat = 16
    /// Body text baseline below a line top (13 pt SF in a 16 pt line; Fixture.textBaseline - bubblePadY).
    static let bodyBaseline: CGFloat = 13
    static let codeBaseline: CGFloat = 12.5
    static let codeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let codeBoldFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let inlineCodeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Headings are body size (Lawrence, 2026-10-06): weight only, one step.
    static func headingFont(_ level: Int) -> UIFont { .systemFont(ofSize: Fixture.bodyFont.pointSize, weight: level <= 2 ? .bold : .semibold) }
    static let codePadX: CGFloat = 8
    /// Space under a scrollable block's content for its scroll indicator.
    static let indicatorRoom: CGFloat = 5
    static let codePadY: CGFloat = 6
    static let cellPadX: CGFloat = 7
    static let cellPadY: CGFloat = 3
    static let quoteIndent: CGFloat = 12
    static let markerGap: CGFloat = 5
    /// Code lines longer than this many UTF-16 units draw up to it and a marker
    /// (the copy text keeps everything). Bounds the scroll width and the bitmap.
    static let maxCodeLine = 1000
    /// Nesting past this many levels does not indent further (the marker still shows depth).
    static let maxIndentLevels = 6
}

// MARK: - Layout

enum MarkdownLayoutEngine {
    /// Laid-out top-level blocks, keyed by block content and width (streams re-use all but the tail).
    private static let cache = MDLRU<BlockKey, BlockLayout>(capacity: 2048)
    struct BlockKey: Hashable { var block: MDBlock; var width: CGFloat; var columns: [CGFloat]? = nil }

    /// A block laid out at y = 0, x = 0 (content-local).
    final class BlockLayout {
        var frags: [MDFrag] = []
        var boxes: [MDBox] = []
        var regions: [MDRegion] = []
        var plain = ""
        var height: CGFloat = 0
        /// Rightmost drawn extent of content outside stretchable boxes.
        var extent: CGFloat = 0
        var ax: [MDAXNode] = []
    }

    /// `tableColumns`: fixed column widths for the first table (a long message's table continued
    /// from an earlier block). `fill`: the inner width is the whole column (long rows are always
    /// column wide), not the widest content.
    static func layout(_ doc: MDDocument, source: String, maxWidth: CGFloat, tableColumns: [CGFloat]? = nil, fill: Bool = false) -> MarkdownLayout {
        let padX = Fixture.bubblePadX, padY = Fixture.bubblePadY
        var frags: [MDFrag] = [], boxes: [MDBox] = [], regions: [MDRegion] = [], ax: [MDAXNode] = []
        var plain = ""
        var plainLen = 0
        var y: CGFloat = 0
        var extent: CGFloat = 0
        var prev: MDBlock?
        var fixed = tableColumns
        for b in doc.blocks {
            var cols: [CGFloat]?
            if fixed != nil, case .table = b.kind { cols = fixed; fixed = nil }
            let key = BlockKey(block: MDBlock(kind: b.kind), width: maxWidth, columns: cols)
            let bl: BlockLayout
            if let c = cache.get(key) { bl = c } else {
                bl = BlockLayout()
                var w = Writer(out: bl, width: maxWidth)
                w.fixedColumns = cols
                w.block(b.kind, x: 0, width: maxWidth, depth: 0, listDepth: 0)
                bl.height = w.y
                cache.set(key, bl)
            }
            if let p = prev {
                y += gap(p, b, nested: false)
                let sep = b.blankBefore ? "\n\n" : "\n"
                plain += sep; plainLen += (sep as NSString).length
            }
            let dx = padX, dy = padY + y
            let r0 = regions.count
            for f in bl.frags {
                var f = f
                f.origin.x += dx; f.origin.y += dy
                f.range.location += plainLen
                if f.region >= 0 { f.region += r0 }
                frags.append(f)
            }
            for bx in bl.boxes {
                var bx = bx
                bx.rect = bx.rect.offsetBy(dx: dx, dy: dy)
                if bx.region >= 0 { bx.region += r0 }
                boxes.append(bx)
            }
            for r in bl.regions {
                var r = r
                r.frame = r.frame.offsetBy(dx: dx, dy: dy)
                r.range.location += plainLen
                regions.append(r)
            }
            for n in bl.ax { ax.append(shift(n, dx: dx, dy: dy, by: plainLen)) }
            plain += bl.plain
            plainLen += (bl.plain as NSString).length
            y += bl.height
            extent = max(extent, bl.extent)
            prev = b
        }
        // Inner width: the widest content, at most the column. Stretchable boxes and
        // regions fill it; wider regions scroll.
        let inner = fill ? maxWidth : min(maxWidth, max(extent, 1).rounded(.up))
        for i in boxes.indices where boxes[i].stretch {
            let left = boxes[i].rect.minX - padX
            boxes[i].rect.size.width = max(boxes[i].rect.width, inner - left)
        }
        for i in regions.indices {
            let left = regions[i].frame.minX - padX
            let avail = max(0, inner - left)
            regions[i].frame.size.width = regions[i].stretch ? avail : min(regions[i].contentWidth, avail)
            if regions[i].kind == .code { regions[i].frame.size.width = avail }
        }
        // Region boxes that span the region (code background) follow the frame.
        for i in boxes.indices where boxes[i].kind == .codeBlock && boxes[i].region >= 0 {
            let r = regions[boxes[i].region]
            boxes[i].rect.size.width = max(r.frame.width, r.contentWidth)
        }
        let size = CGSize(width: inner + 2 * padX, height: (y + 2 * padY).rounded(.up))
        var h = Hasher(); h.combine(source); h.combine(maxWidth)
        return MarkdownLayout(size: size, frags: frags, boxes: boxes, regions: regions, plain: plain, source: source, ax: ax, identity: h.finalize())
    }

    private static func shift(_ n: MDAXNode, dx: CGFloat, dy: CGFloat, by: Int) -> MDAXNode {
        var n = n
        n.frame = n.frame.offsetBy(dx: dx, dy: dy)
        n.range.location += by
        n.children = n.children.map { shift($0, dx: dx, dy: dy, by: by) }
        return n
    }

    /// Space between two blocks of one container. Chat rule: a blank line in the
    /// source is a visible empty line (16 pt) at the top level, 8 pt inside lists and
    /// quotes; no blank line is no space, except around boxes (code, tables, rules)
    /// and above headings (a small space marks a heading, not a bigger font).
    static func gap(_ a: MDBlock, _ b: MDBlock, nested: Bool) -> CGFloat {
        let boxed: (MDBlock) -> Bool = { if case .code = $0.kind { return true }; if case .table = $0.kind { return true }; if case .rule = $0.kind { return true }; return false }
        var g: CGFloat = b.blankBefore ? (nested ? 8 : Markdown.lineHeight) : 0
        if boxed(a) || boxed(b) { g = max(g, 6) }
        if case .heading = b.kind { g = max(g, b.blankBefore ? g : 6) }
        return g
    }

    // MARK: Writer

    struct Writer {
        let out: BlockLayout
        let width: CGFloat
        var y: CGFloat = 0
        var plainLen = 0
        var region = -1
        /// Fixed table column widths (long-message continuation), used by the first table.
        var fixedColumns: [CGFloat]?
        init(out: BlockLayout, width: CGFloat) { self.out = out; self.width = width }

        mutating func appendPlain(_ s: String) { out.plain += s; plainLen += (s as NSString).length }

        mutating func blocks(_ bs: [MDBlock], x: CGFloat, width w: CGFloat, depth: Int, listDepth: Int, tight: Bool = false) {
            var prev: MDBlock?
            for b in bs {
                if let p = prev {
                    y += tight ? 0 : MarkdownLayoutEngine.gap(p, b, nested: true)
                    appendPlain("\n")
                }
                block(b.kind, x: x, width: w, depth: depth, listDepth: listDepth)
                prev = b
            }
        }

        mutating func block(_ k: MDBlock.Kind, x: CGFloat, width w: CGFloat, depth: Int, listDepth: Int) {
            let top = y, p0 = plainLen
            switch k {
            case let .paragraph(t):
                text(t, x: x, width: w, font: Fixture.bodyFont, role: depth > 0 && quoteDepth > 0 ? .quote : .body)
                out.ax.append(MDAXNode(kind: .paragraph, range: NSRange(location: p0, length: plainLen - p0), frame: CGRect(x: x, y: top, width: w, height: y - top)))
            case let .heading(level, t):
                text(t, x: x, width: w, font: Markdown.headingFont(level), role: .body)
                out.ax.append(MDAXNode(kind: .heading(level), range: NSRange(location: p0, length: plainLen - p0), frame: CGRect(x: x, y: top, width: w, height: y - top)))
            case let .code(lang, code, _, _):
                codeBlock(code, lang: lang, x: x, width: w)
                out.ax.append(MDAXNode(kind: .code(lang), range: NSRange(location: p0, length: plainLen - p0), frame: CGRect(x: x, y: top, width: w, height: y - top)))
            case let .quote(bs):
                quoteDepth += 1
                let inner = MarkdownLayoutEngine.indent(x: x, wanted: Markdown.quoteIndent, width: w, level: depth)
                let children0 = out.ax.count
                blocks(bs, x: x + inner, width: w - inner, depth: depth + 1, listDepth: listDepth)
                quoteDepth -= 1
                out.boxes.append(MDBox(rect: CGRect(x: x + 1, y: top + 1, width: 3, height: max(14, y - top - 2)), kind: .quoteBar, region: -1))
                let kids = Array(out.ax[children0...]); out.ax.removeSubrange(children0...)
                out.ax.append(MDAXNode(kind: .quote, range: NSRange(location: p0, length: plainLen - p0), frame: CGRect(x: x, y: top, width: w, height: y - top), children: kids))
            case let .list(l):
                list(l, x: x, width: w, depth: depth, listDepth: listDepth)
            case let .table(t):
                table(t, x: x, width: w)
            case .rule:
                out.boxes.append(MDBox(rect: CGRect(x: x, y: top + 7.5, width: max(1, w > 0 ? 24 : 0), height: 1), kind: .rule, region: -1, stretch: true))
                y += Markdown.lineHeight
                out.extent = max(out.extent, x + 24)
                out.ax.append(MDAXNode(kind: .rule, range: NSRange(location: p0, length: 0), frame: CGRect(x: x, y: top, width: w, height: 16)))
            }
        }
        var quoteDepth = 0

        // MARK: Text

        /// Wrapped inline text at (x, y); returns nothing, advances y.
        mutating func text(_ t: MDText, x: CGFloat, width w: CGFloat, font: UIFont, role: MDRole, align: MDAlign = .none, kern: CGFloat = Fixture.bodyKern) {
            let attr = MarkdownLayoutEngine.attributed(t, font: font, role: role, kern: kern)
            lines(attr, x: x, width: w, role: role, align: align, baseline: Markdown.bodyBaseline)
            appendPlain(t.string)
        }

        /// Lines of an attributed string at (x, y); "\n" breaks a line. Frag ranges are
        /// relative to the current plain length.
        mutating func lines(_ attr: NSAttributedString, x: CGFloat, width w: CGFloat, role: MDRole, align: MDAlign, baseline: CGFloat, wrap: Bool = true) {
            let ns = attr.string as NSString
            let len = ns.length
            if len == 0 { y += Markdown.lineHeight; return }
            let ts = CTTypesetterCreateWithAttributedString(attr)
            var start = 0
            while start < len {
                var n = wrap ? CTTypesetterSuggestLineBreak(ts, start, Double(max(1, w))) : lineLength(ns, from: start)
                if n <= 0 { n = 1 }
                var range = NSRange(location: start, length: n)
                let endsNewline = ns.character(at: start + n - 1) == 10
                if endsNewline { range.length -= 1 }
                // The line from the substring (string indices from 0, as drawing creates it); the
                // typesetter only chooses the break.
                let sub = attr.attributedSubstring(from: range)
                let line = CTLineCreateWithAttributedString(sub)
                let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                // A wrapped line's trailing space is not part of its drawn width.
                let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                var lx = x
                switch align {
                case .center: lx = x + max(0, (w - tw) / 2)
                case .right: lx = x + max(0, w - tw)
                default: break
                }
                var links: [(NSRange, String)] = []
                sub.enumerateAttribute(.link, in: NSRange(location: 0, length: sub.length)) { v, r, _ in
                    if let s = v as? String { links.append((r, s)) }
                }
                let frag = MDFrag(attr: sub, line: line, origin: CGPoint(x: lx, y: y), width: lw, baseline: baseline,
                                  range: NSRange(location: plainLen + range.location, length: range.length), region: region, role: role, links: links)
                decorate(frag, sub)
                out.frags.append(frag)
                if region < 0 { out.extent = max(out.extent, lx + tw) }
                y += Markdown.lineHeight
                start += n
                if start == len, endsNewline { y += Markdown.lineHeight }
            }
        }

        private func lineLength(_ ns: NSString, from: Int) -> Int {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: from, length: ns.length - from))
            return r.location == NSNotFound ? ns.length - from : r.location - from + 1
        }

        /// Inline code backgrounds and strikethrough lines of one line.
        mutating func decorate(_ f: MDFrag, _ sub: NSAttributedString) {
            sub.enumerateAttribute(.mdStyle, in: NSRange(location: 0, length: sub.length)) { v, r, _ in
                guard let raw = v as? UInt16 else { return }
                let st = MDStyle(rawValue: raw)
                let x0 = CTLineGetOffsetForStringIndex(f.line, r.location, nil)
                let x1 = CTLineGetOffsetForStringIndex(f.line, NSMaxRange(r), nil)
                if st.contains(.code) {
                    out.boxes.append(MDBox(rect: CGRect(x: f.origin.x + x0 - 1.5, y: f.origin.y + 1, width: x1 - x0 + 3, height: 14.5), kind: .inlineCode, region: f.region))
                }
                if st.contains(.strike) {
                    out.boxes.append(MDBox(rect: CGRect(x: f.origin.x + x0, y: f.origin.y + f.baseline - 4.5, width: x1 - x0, height: 1), kind: .strike, region: f.region))
                }
            }
        }

        // MARK: Code

        mutating func codeBlock(_ code: String, lang: String, x: CGFloat, width w: CGFloat) {
            let top = y
            let rid = out.regions.count
            let p0 = plainLen
            region = rid
            y += Markdown.codePadY
            let attr = MarkdownHighlight.attributed(code, lang: lang)
            let ns = attr.string as NSString
            var maxW: CGFloat = 0
            var lineStart = 0
            let total = ns.length
            repeat {
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: lineStart, length: total - lineStart))
                let end = nl.location == NSNotFound ? total : nl.location
                var r = NSRange(location: lineStart, length: end - lineStart)
                var more = 0
                if r.length > Markdown.maxCodeLine {
                    // Keep whole surrogate pairs.
                    var cut = Markdown.maxCodeLine
                    if CFStringIsSurrogateHighCharacter(ns.character(at: lineStart + cut - 1)) { cut -= 1 }
                    more = r.length - cut; r.length = cut
                }
                let sub = r.length > 0 ? attr.attributedSubstring(from: r) : NSAttributedString(string: "")
                let line = CTLineCreateWithAttributedString(sub)
                let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                out.frags.append(MDFrag(attr: sub, line: line, origin: CGPoint(x: x + Markdown.codePadX, y: y), width: lw, baseline: Markdown.codeBaseline,
                                        range: NSRange(location: plainLen + r.location, length: r.length), region: rid, role: .code, links: []))
                var lineW = lw
                if more > 0 {
                    let label = NSAttributedString(string: "  " + Markdown.moreCharacters(more), attributes: [.font: Fixture.bodyFont, .mdRole: MDRole.more.rawValue])
                    let ml = CTLineCreateWithAttributedString(label)
                    let mw = CGFloat(CTLineGetTypographicBounds(ml, nil, nil, nil))
                    out.frags.append(MDFrag(attr: label, line: ml, origin: CGPoint(x: x + Markdown.codePadX + lw, y: y), width: mw, baseline: Markdown.bodyBaseline,
                                            range: NSRange(location: plainLen + NSMaxRange(r), length: 0), region: rid, role: .more, links: []))
                    lineW += mw
                }
                maxW = max(maxW, lineW)
                y += Markdown.lineHeight
                if nl.location == NSNotFound { break }
                lineStart = end + 1
            } while true
            y += Markdown.codePadY
            let content = maxW + 2 * Markdown.codePadX
            if content > w + 0.5 { y += Markdown.indicatorRoom }
            out.boxes.append(MDBox(rect: CGRect(x: x, y: top, width: content, height: y - top), kind: .codeBlock, region: rid, stretch: true))
            out.regions.append(MDRegion(kind: .code, frame: CGRect(x: x, y: top, width: min(w, content), height: y - top), contentWidth: content,
                                        range: NSRange(location: p0, length: ns.length), stretch: true, copyText: code, lang: lang))
            out.extent = max(out.extent, x + min(w, content))
            appendPlain(code)
            region = -1
        }

        // MARK: Lists

        mutating func list(_ l: MDList, x: CGFloat, width w: CGFloat, depth: Int, listDepth: Int) {
            let top = y, p0 = plainLen
            let markerFont = Fixture.bodyFont
            let anyTask = l.items.contains { $0.task != nil }
            func markerText(_ i: Int, _ it: MDItem) -> String {
                if l.ordered { return "\(l.start + i)" + (it.marker.last == ")" ? ")" : ".") }
                return ["•", "◦", "▪"][min(listDepth, 2)]
            }
            let widest = l.items.indices.map { TextDraw.width(markerText($0, l.items[$0]), font: markerFont) }.max() ?? 0
            let markerW = max(anyTask ? 14 : 0, widest)
            let wanted = markerW + Markdown.markerGap + (listDepth == 0 && depth == 0 ? 2 : 0)
            let ind = MarkdownLayoutEngine.indent(x: x, wanted: wanted, width: w, level: listDepth + depth)
            var kids: [MDAXNode] = []
            for (i, it) in l.items.enumerated() {
                if i > 0 {
                    y += l.loose ? 8 : 2
                    appendPlain("\n")
                }
                let itTop = y, ip0 = plainLen
                // Marker: right-aligned in the marker column on the first line.
                let mx = x + (ind - Markdown.markerGap - markerW)
                if let checked = it.task {
                    out.boxes.append(MDBox(rect: CGRect(x: mx + markerW - 12, y: y + 2.5, width: 11, height: 11), kind: .checkbox(checked), region: -1))
                    appendPlain(checked ? "☑ " : "☐ ")
                } else {
                    let m = markerText(i, it)
                    let attr = NSAttributedString(string: m, attributes: [.font: markerFont, .kern: Fixture.bodyKern, .mdRole: MDRole.marker.rawValue])
                    let line = CTLineCreateWithAttributedString(attr)
                    let mw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    out.frags.append(MDFrag(attr: attr, line: line, origin: CGPoint(x: x + ind - Markdown.markerGap - mw, y: y), width: mw, baseline: Markdown.bodyBaseline,
                                            range: NSRange(location: plainLen, length: (m as NSString).length), region: -1, role: .marker, links: []))
                    appendPlain(m + " ")
                }
                let n0 = out.ax.count
                if it.blocks.isEmpty { y += Markdown.lineHeight }
                else { blocks(it.blocks, x: x + ind, width: w - ind, depth: depth, listDepth: listDepth + 1, tight: !l.loose) }
                let sub = Array(out.ax[n0...]); out.ax.removeSubrange(n0...)
                kids.append(MDAXNode(kind: .item, range: NSRange(location: ip0, length: plainLen - ip0), frame: CGRect(x: x, y: itTop, width: w, height: y - itTop), children: sub))
                out.extent = max(out.extent, x + ind + 4)
            }
            out.ax.append(MDAXNode(kind: .list(ordered: l.ordered), range: NSRange(location: p0, length: plainLen - p0), frame: CGRect(x: x, y: top, width: w, height: y - top), children: kids))
        }

        // MARK: Tables

        mutating func table(_ t: MDTable, x: CGFloat, width w: CGFloat) {
            let top = y, p0 = plainLen
            let rid = out.regions.count
            let cols = max(1, t.columns)
            let pad = Markdown.cellPadX
            let headFont = UIFont.systemFont(ofSize: Fixture.bodyFont.pointSize, weight: .semibold)
            let all: [[MDText]] = [t.header] + t.rows
            // Column widths: min = widest unbreakable word (capped), max = widest one-line cell.
            var minW = [CGFloat](repeating: 16, count: cols), maxW = [CGFloat](repeating: 16, count: cols)
            var wordW = [CGFloat](repeating: 16, count: cols)
            var attrs: [[NSAttributedString]] = []
            // Very large tables: measure at most 2,000 rows for widths (the rest wraps to them).
            for (ri, row) in all.enumerated() {
                var ra: [NSAttributedString] = []
                for c in 0..<cols {
                    let cell = c < row.count ? row[c] : MDText()
                    let a = MarkdownLayoutEngine.attributed(cell, font: ri == 0 ? headFont : Fixture.bodyFont, role: ri == 0 ? .header : .body, kern: Fixture.bodyKern)
                    ra.append(a)
                    if ri < 2000, a.length > 0 {
                        let line = CTLineCreateWithAttributedString(a)
                        maxW[c] = max(maxW[c], CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up))
                        let word = MarkdownLayoutEngine.longestWord(a, line)
                        wordW[c] = max(wordW[c], word)
                        minW[c] = max(minW[c], min(140, word))
                    }
                }
                attrs.append(ra)
            }
            let chrome = CGFloat(cols) * 2 * pad + 1
            let avail = max(40, w - chrome)
            let sumMax = maxW.reduce(0, +), sumMin = minW.reduce(0, +)
            var colW: [CGFloat]
            if let fixed = fixedColumns, !fixed.isEmpty {
                // Continued table: the first block's widths; extra columns get their one-line width.
                colW = (0..<cols).map { $0 < fixed.count ? fixed[$0] : min(maxW[$0], 200) }
                fixedColumns = nil
            } else if sumMax <= avail { colW = maxW }
            else if sumMin >= avail {
                // The table scrolls anyway: no column narrower than its longest word (up to
                // 320 pt) or 200 pt, so cells do not break inside words.
                colW = (0..<cols).map { min(maxW[$0], max(min(wordW[$0], 320), 200)) }
            }
            else {
                // Auto layout: every column gets its minimum, the rest in proportion to (max - min).
                let extra = avail - sumMin, want = sumMax - sumMin
                colW = (0..<cols).map { (minW[$0] + (maxW[$0] - minW[$0]) * extra / want).rounded(.down) }
            }
            let tableW = colW.reduce(0, +) + chrome
            region = rid
            var rowTops: [CGFloat] = []
            var axRows: [MDAXNode] = []
            var tsv = ""
            for (ri, ra) in attrs.enumerated() {
                if ri > 0 { appendPlain("\n"); tsv += "\n" }
                let rowTop = y
                rowTops.append(rowTop)
                var cx = x + 0.5
                var rowH: CGFloat = Markdown.lineHeight
                var cellNodes: [MDAXNode] = []
                let rp0 = plainLen
                for c in 0..<cols {
                    if c > 0 { appendPlain("\t"); tsv += "\t" }
                    let save = y
                    y = rowTop + Markdown.cellPadY
                    let cp0 = plainLen
                    let align = c < t.aligns.count ? t.aligns[c] : .none
                    lines(ra[c], x: cx + pad, width: colW[c], role: ri == 0 ? .header : .body, align: align, baseline: Markdown.bodyBaseline)
                    if ra[c].length == 0 { y = rowTop + Markdown.cellPadY + Markdown.lineHeight }
                    appendPlain(ra[c].string)
                    tsv += ra[c].string
                    rowH = max(rowH, y - rowTop - Markdown.cellPadY)
                    cellNodes.append(MDAXNode(kind: .cell(header: ri == 0), range: NSRange(location: cp0, length: plainLen - cp0),
                                              frame: CGRect(x: cx, y: rowTop, width: colW[c] + 2 * pad, height: 0)))
                    y = save
                    cx += colW[c] + 2 * pad
                }
                let h = rowH + 2 * Markdown.cellPadY
                for k in cellNodes.indices { cellNodes[k].frame.size.height = h }
                axRows.append(MDAXNode(kind: .row, range: NSRange(location: rp0, length: plainLen - rp0), frame: CGRect(x: x, y: rowTop, width: tableW, height: h), children: cellNodes))
                y = rowTop + h
            }
            if tableW > w + 0.5 { y += Markdown.indicatorRoom }
            let bottom = y
            // Header fill, grid, border (region content coordinates = body-local before scrolling).
            if let h1 = rowTops.dropFirst().first ?? Optional(bottom) {
                out.boxes.append(MDBox(rect: CGRect(x: x, y: top, width: tableW, height: h1 - top), kind: .tableHeader, region: rid))
            }
            for rt in rowTops.dropFirst() { out.boxes.append(MDBox(rect: CGRect(x: x, y: rt - 0.25, width: tableW, height: 0.5), kind: .gridH, region: rid)) }
            var gx = x + 0.5
            for c in 0..<(cols - 1) { gx += colW[c] + 2 * pad; out.boxes.append(MDBox(rect: CGRect(x: gx - 0.25, y: top, width: 0.5, height: bottom - top), kind: .gridV, region: rid)) }
            out.boxes.append(MDBox(rect: CGRect(x: x, y: top, width: tableW, height: bottom - top), kind: .tableBorder, region: rid))
            out.regions.append(MDRegion(kind: .table, frame: CGRect(x: x, y: top, width: min(w, tableW), height: bottom - top), contentWidth: tableW,
                                        range: NSRange(location: p0, length: plainLen - p0), stretch: false, copyText: tsv, lang: ""))
            out.extent = max(out.extent, x + min(w, tableW))
            out.ax.append(MDAXNode(kind: .table(rows: attrs.count, cols: cols), range: NSRange(location: p0, length: plainLen - p0),
                                   frame: CGRect(x: x, y: top, width: min(w, tableW), height: bottom - top), children: axRows))
            region = -1
        }
    }

    /// Indentation for a nested container: the wanted amount until `maxIndentLevels`,
    /// and never leaving less than 120 pt of text.
    static func indent(x: CGFloat, wanted: CGFloat, width: CGFloat, level: Int) -> CGFloat {
        if level >= Markdown.maxIndentLevels { return min(4, max(0, width - 120)) }
        return min(wanted, max(0, width - 120))
    }

    /// The widest space-separated word, measured on the cell's one-line CTLine (no line per word).
    static func longestWord(_ a: NSAttributedString, _ line: CTLine) -> CGFloat {
        let s = a.string as NSString
        var best: CGFloat = 0
        var start = 0
        let n = s.length
        func measure(_ lo: Int, _ hi: Int) {
            guard hi > lo else { return }
            best = max(best, CTLineGetOffsetForStringIndex(line, hi, nil) - CTLineGetOffsetForStringIndex(line, lo, nil))
        }
        for i in 0..<n {
            let c = s.character(at: i)
            if c == 32 || c == 10 || c == 9 { measure(start, i); start = i + 1 }
        }
        measure(start, n)
        return best.rounded(.up)
    }

    /// Attributed inline text: fonts, links, markdown styles (colours come at draw time).
    static func attributed(_ t: MDText, font: UIFont, role: MDRole, kern: CGFloat) -> NSAttributedString {
        let a = NSMutableAttributedString(string: t.string, attributes: [.font: font, .kern: kern, .mdRole: role.rawValue])
        for s in t.spans {
            let r = NSRange(location: s.location, length: s.length)
            guard NSMaxRange(r) <= a.length else { continue }
            if s.style.contains(.code) {
                a.addAttribute(.font, value: Markdown.inlineCodeFont, range: r)
                a.addAttribute(.kern, value: 0, range: r)
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if s.style.contains(.strong) { traits.insert(.traitBold) }
                if s.style.contains(.emphasis) { traits.insert(.traitItalic) }
                if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                    a.addAttribute(.font, value: UIFont(descriptor: d, size: font.pointSize), range: r)
                }
            }
            if let l = s.link { a.addAttribute(.link, value: l, range: r) }
            a.addAttribute(.mdStyle, value: s.style.rawValue, range: r)
        }
        return a
    }
}

extension Markdown {
    static func moreCharacters(_ n: Int) -> String {
        String(format: String(localized: "markdown.code.more", defaultValue: "… %@ more characters"),
               NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal))
    }
}

// MARK: - LRU

final class MDLRU<K: Hashable, V>: @unchecked Sendable {
    private var map: [K: (V, Int)] = [:]
    private var tick = 0
    private let lock = NSLock()
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    func get(_ k: K) -> V? {
        lock.lock(); defer { lock.unlock() }
        guard let v = map[k] else { return nil }
        tick += 1; map[k] = (v.0, tick)
        return v.0
    }
    func set(_ k: K, _ v: V) {
        lock.lock(); defer { lock.unlock() }
        tick += 1
        map[k] = (v, tick)
        if map.count > capacity {
            // Drop the older half (amortized O(1) per insert).
            let cut = map.values.map(\.1).sorted()[map.count / 2]
            map = map.filter { $0.value.1 >= cut }
        }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }
}
