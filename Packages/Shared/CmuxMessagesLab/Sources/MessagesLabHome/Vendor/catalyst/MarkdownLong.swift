#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Long markdown messages (shared/MARKDOWN.md "Long messages"; shared/LONG-MESSAGES.md).
/// A long text is cut into blocks of about 4 KB (LongTextIndex). For a text that may hold
/// markdown, the cut is moved off fences and tables (a forced cut inside one carries its state
/// into the next block), and each block that renders differently from plain text gets its own
/// MarkdownLayout, laid out off main; its height in 16 pt lines (rounded up) goes into the
/// Fenwick tree like a plain block's line count. Tiles draw 256 pt y-slices of it.

/// Parser state at a block start: a forced cut inside a fence or a table carries it.
enum MDCarry: Hashable {
    case none
    /// Inside a fenced code block: its opening line.
    case fence(open: String, char: UInt8, count: Int)
    /// Inside a table (after its delimiter row): header and delimiter lines, and the block
    /// that holds them (its column widths are reused, so columns stay aligned across tiles).
    case table(head: String, start: Int)
    var isOpen: Bool { if case .none = self { return false }; return true }
}

enum MarkdownLong {
    // MARK: Cutting (index build, bytes)

    private struct Line { var start: Int; var end: Int }   // [start, end), end at the newline or n

    /// One scanned line: indentation and the leaf facts the cut rule needs.
    private static func indent(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> (cols: Int, first: Int) {
        var col = 0, i = l.start
        while i < l.end, p[i] == 32 || p[i] == 9 { col += p[i] == 9 ? 4 - col % 4 : 1; i += 1 }
        return (col, i)
    }
    private static func isBlank(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> Bool {
        var i = l.start
        while i < l.end { let b = p[i]; if b != 32, b != 9, b != 13 { return false }; i += 1 }
        return true
    }
    private static func fence(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> (UInt8, Int, Bool)? {
        let (cols, i) = indent(p, l)
        guard cols < 4, i < l.end, p[i] == 96 || p[i] == 126 else { return nil }
        let c = p[i]
        var n = 0
        while i + n < l.end, p[i + n] == c { n += 1 }
        guard n >= 3 else { return nil }
        var rest = true, tick = false
        var k = i + n
        while k < l.end { let b = p[k]; if b != 32, b != 9, b != 13 { rest = false }; if b == 96 { tick = true }; k += 1 }
        if c == 96, tick { return nil }
        return (c, n, rest)
    }
    private static func hasPipe(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> Bool {
        var i = l.start
        while i < l.end { if p[i] == 124 { return true }; i += 1 }
        return false
    }
    /// A GFM delimiter row ("|---|:--:|"): only | - : and spaces, at least one "-".
    private static func isDelimiter(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> Bool {
        let (cols, i) = indent(p, l)
        guard cols < 4, i < l.end else { return false }
        var dash = false
        var k = i
        while k < l.end {
            switch p[k] { case 45: dash = true; case 124, 58, 32, 9, 13: break; default: return false }
            k += 1
        }
        return dash
    }
    /// "===" or "---" alone (a setext underline after a paragraph line, or a rule).
    private static func isUnderline(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> Bool {
        let (cols, i) = indent(p, l)
        guard cols < 4, i < l.end, p[i] == 61 || p[i] == 45 else { return false }
        let c = p[i]
        var k = i
        while k < l.end { if p[k] != c, p[k] != 32, p[k] != 9, p[k] != 13 { return false }; k += 1 }
        return true
    }
    /// A line that ends a table (GFM: a blank line or the start of another block).
    private static func endsTable(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> Bool {
        if isBlank(p, l) || fence(p, l) != nil { return true }
        let (cols, i) = indent(p, l)
        guard cols < 4, i < l.end else { return false }
        return p[i] == 35 || p[i] == 62
    }
    private static func listOrIndented(_ p: UnsafeBufferPointer<UInt8>, _ l: Line) -> Bool {
        let (cols, i) = indent(p, l)
        if cols > 0 { return true }
        guard i < l.end else { return false }
        let b = p[i]
        if (b == 45 || b == 42 || b == 43), i + 1 < l.end, p[i + 1] == 32 { return true }
        var k = i
        while k < l.end, k - i < 9, p[k] >= 48, p[k] <= 57 { k += 1 }
        return k > i && k < l.end && (p[k] == 46 || p[k] == 41)
    }
    private static func string(_ p: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: p[a..<b]), as: UTF8.self)
    }

    /// The block end for a markdown text: the plain rule's `plainEnd` moved back to the last
    /// line start outside fences and tables (preferring a blank line followed by an unindented,
    /// non-list line, the boundary of top-level blocks), else `plainEnd` with the open state
    /// carried. Returns the end and the carry at it. `state` is the carry at `from`.
    static func cut(_ p: UnsafeBufferPointer<UInt8>, from: Int, plainEnd: Int, block: Int, state: MDCarry) -> (Int, MDCarry) {
        let n = p.count
        if plainEnd >= n { return (n, .none) }
        var st = state
        var prevBlank = true, prevPipe = false
        var prevStart = -1, prevEnd = -1
        var bestTop = -1, bestAny = -1
        var stAt: [Int: MDCarry] = [:]
        var i = from
        var stateAtEnd = st
        while i < n {
            var e = i
            // A line past the plain end is read at most 8 KB far (a 5 MB line is not rescanned per block).
            while e < n, e < plainEnd + 8192, p[e] != 10 { e += 1 }
            let l = Line(start: i, end: e)
            // A cut before this line (i > from) is allowed when nothing is open and this line does
            // not belong to the line before it (a delimiter row, a setext underline).
            if i > from, i <= plainEnd {
                let blank = isBlank(p, l)
                let joins = !prevBlank && (isUnderline(p, l) || (prevPipe && isDelimiter(p, l)))
                if !st.isOpen, !joins {
                    bestAny = i
                    if prevBlank, !blank, !listOrIndented(p, l) { bestTop = i }
                }
                stAt[i] = st
            }
            if i >= plainEnd { break }
            // The line's effect on the state.
            switch st {
            case let .fence(_, c, cnt):
                if let f = fence(p, l), f.0 == c, f.1 >= cnt, f.2 { st = .none }
            case .table:
                if endsTable(p, l) {
                    st = .none
                    if let f = fence(p, l) { st = .fence(open: string(p, l.start, l.end), char: f.0, count: f.1) }
                }
            case .none:
                if let f = fence(p, l) {
                    st = .fence(open: string(p, l.start, l.end), char: f.0, count: f.1)
                } else if !prevBlank, prevPipe, prevStart >= 0, isDelimiter(p, l), indent(p, Line(start: prevStart, end: prevEnd)).cols < 4 {
                    st = .table(head: string(p, prevStart, prevEnd) + "\n" + string(p, l.start, l.end) + "\n", start: block)
                }
            }
            prevBlank = isBlank(p, l)
            prevPipe = hasPipe(p, l)
            prevStart = l.start; prevEnd = l.end
            stateAtEnd = st
            i = e < n ? e + 1 : n
        }
        let span = plainEnd - from
        if bestTop > from, bestTop - from >= span / 2 { return (bestTop, stAt[bestTop] ?? .none) }
        if bestAny > from, bestAny - from >= span / 4 { return (bestAny, stAt[bestAny] ?? .none) }
        if plainEnd >= n { return (n, .none) }
        // Forced: the plain cut, the open state carried (a cut inside a line keeps that line's state).
        return (plainEnd, stAt[plainEnd] ?? stateAtEnd)
    }

    // MARK: Block layout (off main)

    /// The markdown layout of block `b`, in block-local body coordinates (x from the bubble's
    /// left edge with padding, y = Fixture.bubblePadY + the block's text y), with ranges in the
    /// block's display string (`plain`). Its height is `lines` x 16 pt plus the vertical padding.
    /// Nil when the block renders as plain text (no rich element and nothing carried).
    static func layout(_ idx: LongTextIndex, _ b: Int, column: CGFloat, tableColumns: (Int) -> [CGFloat]?) -> (MarkdownLayout, lines: Int)? {
        let src = idx.blockString(b) as String
        let carry = idx.carry(b)
        let next = b + 1 < idx.blockCount ? idx.carry(b + 1) : .none
        var openBottom = false
        switch next {
        case .fence: openBottom = true
        case let .table(_, s): openBottom = s <= b
        case .none: break
        }
        var content = Substring(src)
        var lead = 0, trail = ""
        if !carry.isOpen {
            // Leading blank lines: one 16 pt gap (a blank line at the top level).
            while let nl = content.firstIndex(of: "\n"), content[..<nl].allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                lead += 1; content = content[content.index(after: nl)...]
            }
        }
        if openBottom {
            if content.hasSuffix("\n") { trail = "\n"; content = content.dropLast() }
        } else {
            var k = 0
            while let last = content.last, last == "\n" || last == " " || last == "\t" || last == "\r" {
                if last == "\n" { k += 1 }
                content = content.dropLast()
            }
            trail = String(repeating: "\n", count: k)
        }
        var parseText = String(content)
        switch carry {
        case let .fence(open, _, _): parseText = open + "\n" + parseText
        case let .table(head, _): parseText = head + parseText
        case .none: break
        }
        let doc = Markdown.parse(parseText)
        guard carry.isOpen || openBottom || doc.isRich else { return nil }
        var cols: [CGFloat]?
        if case let .table(_, s) = carry, s < b { cols = tableColumns(s) }
        let md = MarkdownLayoutEngine.layout(doc, source: parseText, maxWidth: column, tableColumns: cols, fill: true)
        let padY = Fixture.bubblePadY
        var frags = md.frags, boxes = md.boxes, regions = md.regions, ax = md.ax
        var plain = md.plain
        var dy: CGFloat = lead > 0 ? Markdown.lineHeight : 0
        var dr = lead
        // Continuations: the carried header row is laid out (for the widths) but not shown.
        if case .table = carry, let t = ax.first, case .table = t.kind, let head = t.children.first {
            let hr = head.range, cut = NSMaxRange(hr) + 1
            frags.removeAll { $0.region == 0 && NSMaxRange($0.range) <= NSMaxRange(hr) && $0.range.location >= hr.location }
            boxes.removeAll { $0.kind == .tableHeader && $0.region == 0 }
            let ns = plain as NSString
            plain = cut <= ns.length ? ns.substring(from: cut) : ""
            dy -= head.frame.height
            dr -= cut
            var tnode = t
            tnode.children.removeFirst()
            tnode.range = NSRange(location: t.range.location + cut, length: max(0, t.range.length - cut))
            ax[0] = tnode
            if !regions.isEmpty { regions[0].range.location += cut; regions[0].range.length -= cut }
            if !regions.isEmpty, regions[0].kind == .table {
                let lines = regions[0].copyText.split(separator: "\n", omittingEmptySubsequences: false)
                regions[0].copyText = lines.dropFirst().joined(separator: "\n")
            }
        } else if case .fence = carry {
            dy -= Markdown.codePadY
        }
        let rangeShift = dr
        func moved(_ r: NSRange) -> NSRange { NSRange(location: max(0, r.location + rangeShift), length: r.length) }
        frags = frags.map { var f = $0; f.origin.y += dy; f.range = moved(f.range); return f }
        boxes = boxes.map { var x = $0; x.rect = x.rect.offsetBy(dx: 0, dy: dy); return x }
        regions = regions.map { var r = $0; r.frame = r.frame.offsetBy(dx: 0, dy: dy); r.range = moved(r.range); return r }
        func shift(_ n: MDAXNode) -> MDAXNode {
            var n = n; n.frame = n.frame.offsetBy(dx: 0, dy: dy); n.range = moved(n.range); n.children = n.children.map(shift); return n
        }
        ax = ax.map(shift)
        var textH = md.size.height - 2 * padY + dy
        if trail.count >= 2 { textH += Markdown.lineHeight }
        let lines = max(1, Int(ceil(textH / Markdown.lineHeight - 0.001)))
        let bottom = padY + CGFloat(lines) * Markdown.lineHeight
        // Open edges: the continuing block's background, border and grid reach past the block's
        // slice (tiles clip them at the seam), so a code block or table runs through the cut.
        if carry.isOpen, let r0 = regions.first {
            for i in boxes.indices where boxes[i].region == 0 {
                switch boxes[i].kind {
                case .codeBlock, .tableBorder, .gridV:
                    let maxY = boxes[i].rect.maxY
                    boxes[i].rect.origin.y = padY - 8; boxes[i].rect.size.height = maxY - (padY - 8)
                default: break
                }
            }
            regions[0].frame = CGRect(x: r0.frame.minX, y: padY, width: r0.frame.width, height: r0.frame.maxY - padY)
        }
        if openBottom, let ri = regions.indices.last {
            for i in boxes.indices where boxes[i].region == ri {
                switch boxes[i].kind {
                case .codeBlock, .tableBorder, .gridV: boxes[i].rect.size.height = bottom + 8 - boxes[i].rect.minY
                default: break
                }
            }
            regions[ri].frame.size.height = bottom - regions[ri].frame.minY
        }
        let display = String(repeating: "\n", count: lead) + plain + trail
        var h = Hasher(); h.combine(src); h.combine(column); h.combine(carry); h.combine(openBottom)
        let out = MarkdownLayout(size: CGSize(width: md.size.width, height: bottom + padY), frags: frags, boxes: boxes, regions: regions,
                                 plain: display, source: src, ax: ax, identity: h.finalize())
        return (out, lines)
    }

    /// Column widths of the last table of a block layout (its header row's cells).
    static func lastTableColumns(_ md: MarkdownLayout) -> [CGFloat]? {
        func find(_ ns: [MDAXNode]) -> MDAXNode? {
            for n in ns.reversed() { if case .table = n.kind { return n } }
            return nil
        }
        guard let t = find(md.ax), let row = t.children.first else { return nil }
        return row.children.map { $0.frame.width - 2 * Markdown.cellPadX }
    }

    // MARK: Drawing

    /// Tile `chunk` of a markdown block: its 256 pt y-slice (boxes clipped to the slice, text lines
    /// whose slot starts in it drawn whole), the tile's top at y `top` with the tile overflow.
    static func drawTile(_ md: MarkdownLayout, lines: Int, chunk: Int, outgoing: Bool, in ctx: CGContext, top: CGFloat) {
        let lh = Fixture.lineHeight, n = CGFloat(TiledBubble.linesPerTile)
        let a = CGFloat(chunk) * n * lh, b = min(CGFloat(lines), CGFloat(chunk + 1) * n) * lh
        guard a < b else { return }
        let padY = Fixture.bubblePadY
        let body = CGRect(x: 0, y: top + TiledBubble.overflow - a - padY, width: md.size.width, height: md.size.height)
        MarkdownDraw.draw(ctx, md, body: body, outgoing: outgoing, offsets: MarkdownScroll.all(md.identity), slice: (padY + a)..<(padY + b))
    }
}
