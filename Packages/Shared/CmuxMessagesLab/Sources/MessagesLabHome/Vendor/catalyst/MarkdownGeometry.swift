#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Text geometry of a part row for selection, copy, links and accessibility
/// (agreed with the selection agent, 2026-10-06). Points are body-local: the
/// origin is the bubble's top-left, padding included. Offsets are UTF-16 into
/// the row's display string.
protocol RowTextGeometry {
    /// UTF-16 length of the display string.
    var length: Int { get }
    func substring(_ r: NSRange) -> String
    /// Nearest offset, clamped to [0, length].
    func offset(at p: CGPoint) -> Int
    /// One rect per line fragment, only lines whose y is in `visible` (body-local y).
    /// A hard line end inside the range gets a short tail rect.
    func selectionRects(_ r: NSRange, visible: ClosedRange<CGFloat>) -> [CGRect]
    /// NSAttributedString.doubleClick rules.
    func wordRange(at offset: Int) -> NSRange
    /// Triple-click.
    func paragraphRange(at offset: Int) -> NSRange
    func link(at p: CGPoint) -> String?
    /// Pasteboard representations of a range: plain text first, then richer types.
    func pasteboardItems(_ r: NSRange) -> [(type: String, data: Data)]
}

extension PartRow {
    /// Markdown rows answer with their markdown layout, plain rows with their text layout
    /// (long rows have neither: the selection agent's accessor covers them).
    var markdownGeometry: RowTextGeometry? { markdown }
}

extension MarkdownLayout: RowTextGeometry {
    var length: Int { (plain as NSString).length }

    func substring(_ r: NSRange) -> String {
        let ns = plain as NSString
        let lo = max(0, min(r.location, ns.length)), hi = max(lo, min(NSMaxRange(r), ns.length))
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }

    /// Scroll offsets of regions (main thread state; MarkdownScroll).
    private func offsetX(_ region: Int) -> CGFloat { region < 0 ? 0 : MarkdownScroll.offset(identity: identity, region: region) }

    /// The frag's rect on screen (scrolled), clipped to its region.
    func visibleRect(_ f: MDFrag) -> CGRect {
        let dx = offsetX(f.region)
        var r = CGRect(x: f.origin.x - dx, y: f.origin.y, width: f.width, height: f.height)
        if f.region >= 0 { r = r.intersection(regions[f.region].frame.insetBy(dx: 0, dy: -1)) }
        return r
    }

    func offset(at p: CGPoint) -> Int {
        // Selectable frags (markers and "more" labels are not text positions of their own).
        guard !frags.isEmpty else { return 0 }
        var best: MDFrag?
        var bestD = CGFloat.greatestFiniteMagnitude
        for f in frags where f.role != .more {
            let dx0 = offsetX(f.region)
            let top = f.origin.y, bottom = top + f.height
            let dy = p.y < top ? top - p.y : p.y > bottom ? p.y - bottom : 0
            let left = f.origin.x - dx0, right = left + f.width
            let dx = p.x < left ? left - p.x : p.x > right ? p.x - right : 0
            let d = dy * 1000 + dx
            if d < bestD { bestD = d; best = f }
        }
        guard let f = best else { return 0 }
        let x = p.x - (f.origin.x - offsetX(f.region))
        let idx = CTLineGetStringIndexForPosition(f.line, CGPoint(x: max(0, x), y: 0))
        let local = idx == kCFNotFound ? 0 : min(idx, f.range.length)
        return min(length, f.range.location + local)
    }

    func selectionRects(_ r: NSRange, visible: ClosedRange<CGFloat>) -> [CGRect] {
        var out: [CGRect] = []
        let ns = plain as NSString
        for f in frags where f.role != .more {
            guard f.origin.y + f.height >= visible.lowerBound, f.origin.y <= visible.upperBound else { continue }
            let inter = NSIntersectionRange(r, f.range)
            let end = NSMaxRange(f.range)
            // The line's ending separator ("\n" or "\t") is selected: a short tail.
            let tail = end < ns.length && NSLocationInRange(end, r)
            let empty = f.range.length == 0 && NSLocationInRange(f.range.location, r)
            guard inter.length > 0 || tail || empty else { continue }
            let dx = offsetX(f.region)
            let a = inter.length > 0 ? inter.location - f.range.location : f.range.length
            let b = inter.length > 0 ? NSMaxRange(inter) - f.range.location : f.range.length
            let x0 = inter.length > 0 || empty ? CTLineGetOffsetForStringIndex(f.line, a, nil) : f.width
            let x1 = CTLineGetOffsetForStringIndex(f.line, b, nil) + (tail ? 4 : 0)
            var rect = CGRect(x: f.origin.x - dx + x0, y: f.origin.y, width: max(2, x1 - x0), height: f.height)
            if f.region >= 0 { rect = rect.intersection(regions[f.region].frame) }
            if !rect.isNull, rect.width > 0 { out.append(rect) }
        }
        return out
    }

    func wordRange(at offset: Int) -> NSRange {
        let s = NSAttributedString(string: plain)
        guard s.length > 0 else { return NSRange(location: 0, length: 0) }
        #if canImport(UIKit) && !APPKIT_NATIVE
        let ns = plain as NSString
        var lo = min(offset, ns.length - 1), hi = lo
        let set = CharacterSet.alphanumerics
        func isWord(_ i: Int) -> Bool { guard let u = Unicode.Scalar(ns.character(at: i)) else { return true }; return set.contains(u) || u == "_" }
        while lo > 0, isWord(lo - 1) { lo -= 1 }
        while hi < ns.length, isWord(hi) { hi += 1 }
        return NSRange(location: lo, length: max(hi - lo, 1))
        #else
        return s.doubleClick(at: min(offset, s.length - 1))
        #endif
    }

    /// Triple-click: the innermost block at the offset. Paragraphs, headings and list
    /// items select their text; a table selects the row; a code block selects the line.
    func paragraphRange(at offset: Int) -> NSRange {
        func find(_ ns: [MDAXNode]) -> NSRange? {
            for n in ns where NSLocationInRange(offset, n.range) || (n.range.length == 0 && n.range.location == offset) {
                switch n.kind {
                case .code:
                    let s = plain as NSString
                    let line = s.lineRange(for: NSRange(location: offset, length: 0))
                    var r = NSIntersectionRange(line, n.range)
                    if r.length > 0, NSMaxRange(r) <= s.length, s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
                    return r
                case .table:
                    for row in n.children where NSLocationInRange(offset, row.range) { return row.range }
                    return n.range
                case .list, .item, .quote:
                    if let inner = find(n.children) { return inner }
                    return n.range
                default: return n.range
                }
            }
            return nil
        }
        return find(ax) ?? (plain as NSString).paragraphRange(for: NSRange(location: min(offset, length), length: 0))
    }

    func link(at p: CGPoint) -> String? {
        for f in frags where !f.links.isEmpty {
            let r = visibleRect(f)
            guard r.contains(p) else { continue }
            let x = p.x - (f.origin.x - offsetX(f.region))
            let idx = CTLineGetStringIndexForPosition(f.line, CGPoint(x: x, y: 0))
            guard idx != kCFNotFound else { continue }
            // The index is a caret position: the glyph under x is the one before it when x is past its middle.
            let x0 = CTLineGetOffsetForStringIndex(f.line, idx, nil)
            let glyph = x < x0 ? max(0, idx - 1) : idx
            if let hit = f.links.first(where: { NSLocationInRange(glyph, $0.0) }) { return hit.1 }
        }
        return nil
    }

    func pasteboardItems(_ r: NSRange) -> [(type: String, data: Data)] {
        let text = MarkdownCopy.plain(self, r)
        var items: [(String, Data)] = [("public.utf8-plain-text", Data(text.utf8))]
        if let html = MarkdownCopy.html(self, r) { items.append(("public.html", Data(html.utf8))) }
        if r.location == 0, r.length >= length { items.append(("net.daringfireball.markdown", Data(source.utf8))) }
        return items
    }

    /// The scroll region at a body-local point.
    func region(at p: CGPoint) -> Int? { regions.firstIndex { $0.frame.contains(p) } }
}

/// Horizontal scroll offsets of markdown regions (code blocks, wide tables), keyed by
/// layout identity (source and width) and region index. Main thread.
enum MarkdownScroll {
    private static var offsets: [Int: [Int: CGFloat]] = [:]
    private static let lock = NSLock()
    static func offset(identity: Int, region: Int) -> CGFloat {
        lock.lock(); defer { lock.unlock() }
        return offsets[identity]?[region] ?? 0
    }
    static func set(identity: Int, region: Int, _ x: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        offsets[identity, default: [:]][region] = x
        if offsets.count > 4096 { offsets.removeAll() }
    }
    static func all(_ identity: Int) -> [Int: CGFloat] { lock.lock(); defer { lock.unlock() }; return offsets[identity] ?? [:] }
}
