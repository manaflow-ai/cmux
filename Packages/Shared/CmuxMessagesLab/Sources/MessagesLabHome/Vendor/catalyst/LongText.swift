#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Long messages (agent output: logs, code, 100k-line pastes). shared/LONG-MESSAGES.md.
/// A long text part is cut into blocks of about 4 KB (index, width independent);
/// each block has an estimated line count until Core Text measures it (layout, per
/// width); the row's height is the sum in a Fenwick tree. TiledBubble.swift draws it.
enum LongText {
    static let minBytes = 8192
    static let minLines = 120
    static let blockBytes = 4096
    static var enabled = !ProcessInfo.processInfo.arguments.contains("--no-long-text")

    /// O(1) above 8 KB; scans at most 8 KB below.
    static func isLong(_ t: String) -> Bool {
        guard enabled else { return false }
        let n = t.utf8.count
        if n > minBytes { return true }
        if n < minLines { return false }
        var nl = 0
        for b in t.utf8 where b == 10 {
            nl += 1
            if nl >= minLines { return true }
        }
        return false
    }

    /// Whether a row is a long text row (O(1): long text rows carry no TextLayout).
    static func isLongRow(_ spec: RowSpec) -> Bool {
        guard case let .part(p) = spec.kind, case .text = p.part else { return false }
        return p.text == nil
    }
}

/// Prefix sums of line counts per block.
struct Fenwick {
    private(set) var values: [Int32]
    private var tree: [Int]
    init(_ v: [Int32]) {
        values = v
        tree = [Int](repeating: 0, count: v.count + 1)
        for i in 0..<v.count {
            let k = i + 1
            tree[k] += Int(v[i])
            let j = k + (k & -k)
            if j <= v.count { tree[j] += tree[k] }
        }
    }
    var count: Int { values.count }
    mutating func set(_ i: Int, _ v: Int32) {
        let d = Int(v) - Int(values[i])
        guard d != 0 else { return }
        values[i] = v
        var k = i + 1
        while k <= values.count { tree[k] += d; k += k & -k }
    }
    /// Sum of values[0..<i].
    func prefix(_ i: Int) -> Int {
        var s = 0, k = min(i, values.count)
        while k > 0 { s += tree[k]; k -= k & -k }
        return s
    }
    var total: Int { prefix(values.count) }
    /// The index whose range [prefix(i), prefix(i+1)) holds `x` (clamped).
    func find(_ x: Int) -> Int {
        guard !values.isEmpty else { return 0 }
        var pos = 0, rem = x
        var step = 1
        while step * 2 <= values.count { step *= 2 }
        while step > 0 {
            if pos + step <= values.count, tree[pos + step] <= rem { pos += step; rem -= tree[pos] }
            step /= 2
        }
        return min(pos, values.count - 1)
    }
}

/// Block index of one text (immutable, thread safe).
final class LongTextIndex: @unchecked Sendable {
    let lineage: Int
    let text: String
    let count: Int
    /// Block b is UTF-8 [starts[b], starts[b + 1]); starts.last == count.
    let starts: [Int]
    /// UTF-16 offset of each block start (last: the UTF-16 length).
    let u16Starts: [Int]
    /// Paragraph pieces per block (its minimum line count).
    let pieces: [Int32]
    /// Estimated advance per block (points at the body font).
    let units: [Float]
    /// Estimated lines per block at `refColumn` (per paragraph, with wrap waste).
    let estRef: [Int32]
    /// Newlines per block, and the text's hard line count ("Show all N lines").
    let newlines: [Int32]
    let hardLines: Int
    static var refColumn: Float { Float(Metrics(width: Fixture.windowWidth).maxTextWidth) }
    /// False while a large text is scanned off main (placeholder).
    let ready: Bool
    var blockCount: Int { max(0, starts.count - 1) }

    init(lineage: Int, text: String, starts: [Int], u16Starts: [Int], pieces: [Int32], units: [Float], estRef: [Int32],
         newlines: [Int32] = [], ready: Bool) {
        self.lineage = lineage; self.text = text; self.count = text.utf8.count
        self.starts = starts; self.u16Starts = u16Starts; self.pieces = pieces; self.units = units; self.estRef = estRef; self.ready = ready
        self.newlines = newlines
        hardLines = newlines.reduce(1) { $0 + Int($1) }
    }

    static func placeholder(_ text: String, lineage: Int) -> LongTextIndex {
        LongTextIndex(lineage: lineage, text: text, starts: [0], u16Starts: [0], pieces: [], units: [], estRef: [], ready: false)
    }

    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let r = text.utf8.withContiguousStorageIfAvailable(body) { return r }
        let a = Array(text.utf8)
        return a.withUnsafeBufferPointer(body)
    }

    /// Scan `text` into blocks; with `prefix`, keep its blocks before `keep` (streaming).
    static func build(_ text: String, lineage: Int, prefix: LongTextIndex? = nil, keep: Int = 0) -> LongTextIndex {
        var t = text
        t.makeContiguousUTF8()
        var starts = Array(prefix?.starts.prefix(keep) ?? [])
        var u16 = Array(prefix?.u16Starts.prefix(keep) ?? [])
        var pieces = Array(prefix?.pieces.prefix(keep) ?? [])
        var units = Array(prefix?.units.prefix(keep) ?? [])
        var estRef = Array(prefix?.estRef.prefix(keep) ?? [])
        var newlines = Array(prefix?.newlines.prefix(keep) ?? [])
        let wrap = LongTextIndex.refColumn * 0.93
        let from = prefix.map { keep < $0.starts.count ? $0.starts[keep] : $0.count } ?? 0
        var u16Pos = prefix.map { keep < $0.u16Starts.count ? $0.u16Starts[keep] : 0 } ?? 0
        let size = Fixture.bodyFont.pointSize
        let ascii = Float(size * 0.5), wide = Float(size), emoji = Float(size * 1.25)
        t.utf8.withContiguousStorageIfAvailable { p in
            let n = p.count
            var i = from
            while i < n {
                let limit = min(n, i + LongText.blockBytes)
                var end = limit
                if limit < n {
                    var j = limit - 1
                    while j >= i, p[j] != 10 { j -= 1 }
                    if j >= i {
                        end = j + 1
                    } else {
                        // One paragraph longer than a block: cut at a space, else at a character boundary.
                        var k = limit - 1
                        let floor = max(i + 1, limit - 1024)
                        while k >= floor, p[k] != 32, p[k] != 9 { k -= 1 }
                        if k >= floor { end = k + 1 } else {
                            k = limit
                            while k > i + 1, p[k] & 0xC0 == 0x80 { k -= 1 }
                            end = k
                        }
                    }
                }
                var nl: Int32 = 0, w: Float = 0, c16 = 0, para: Float = 0, est: Int32 = 0
                for k in i..<end {
                    let b = p[k]
                    if b < 0x80 {
                        c16 += 1
                        if b == 10 { nl += 1; est += max(1, Int32((para / wrap).rounded(.up))); para = 0 }
                        else if b == 9 { w += 4 * ascii; para += 4 * ascii } else { w += ascii; para += ascii }
                    } else if b >= 0xF0 { c16 += 2; w += emoji; para += emoji } else if b >= 0xE0 { c16 += 1; w += wide; para += wide }
                    else if b >= 0xC0 { c16 += 1; w += ascii; para += ascii }
                }
                if p[end - 1] != 10 || end == n { est += max(1, Int32((para / wrap).rounded(.up))) }
                let endsNL = p[end - 1] == 10
                starts.append(i); u16.append(u16Pos)
                pieces.append(nl + (endsNL && end < n ? 0 : 1))
                units.append(w)
                estRef.append(est)
                newlines.append(nl)
                u16Pos += c16
                i = end
            }
            starts.append(n); u16.append(u16Pos)
        }
        return LongTextIndex(lineage: lineage, text: t, starts: starts, u16Starts: u16, pieces: pieces, units: units, estRef: estRef, newlines: newlines, ready: true)
    }

    func isFinal(_ b: Int) -> Bool { b == blockCount - 1 }

    /// The block's text as an NSString (UTF-16, for Core Text).
    func blockString(_ b: Int) -> NSString {
        let a = starts[b], e = starts[b + 1]
        return withBytes { p in
            NSString(bytes: p.baseAddress! + a, length: e - a, encoding: String.Encoding.utf8.rawValue) ?? ""
        }
    }

    /// Block holding UTF-16 offset `o`.
    func block(u16 o: Int) -> Int {
        var lo = 0, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if u16Starts[mid] <= o { lo = mid } else { hi = mid - 1 }
        }
        return max(0, lo)
    }

    /// Find: the first UTF-8 range of `needle` at or after `from` (memmem, call off main).
    func find(_ needle: String, from: Int = 0) -> Range<Int>? {
        let n = Array(needle.utf8)
        guard !n.isEmpty, from < count else { return nil }
        return withBytes { p in
            n.withUnsafeBufferPointer { q in
                guard let r = memmem(p.baseAddress! + from, count - from, q.baseAddress!, q.count) else { return nil }
                let o = UnsafeRawPointer(r) - UnsafeRawPointer(p.baseAddress!)
                return o..<(o + q.count)
            }
        }
    }

    /// UTF-16 offset of a UTF-8 offset (block start plus the block's prefix).
    func u16Offset(utf8 o: Int) -> Int {
        var lo = 0, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= o { lo = mid } else { hi = mid - 1 }
        }
        let a = starts[lo]
        let local = withBytes { p in
            String(decoding: UnsafeBufferPointer(rebasing: p[a..<o]), as: UTF8.self).utf16.count
        }
        return u16Starts[lo] + local
    }
}

/// Line breaks of one block (Core Text, the rules of `TextLayout.make`).
final class BlockLayout: @unchecked Sendable {
    let string: NSString
    let lines: [NSRange]
    let widths: [CGFloat]
    private let lock = NSLock()
    private var drawAttr: [Bool: NSAttributedString] = [:]

    /// `reuse`: the same block before text was appended (streaming): its lines before its last
    /// paragraph are kept and only the rest is typeset (paragraphs break independently).
    init(string: NSString, column: CGFloat, final: Bool, reuse: BlockLayout? = nil) {
        self.string = string
        var lines: [NSRange] = [], widths: [CGFloat] = []
        var from = 0
        if let r = reuse, r.string.length <= string.length, r.string.length > 0,
           string.substring(to: r.string.length) == r.string as String {
            let nl = r.string.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: r.string.length - 1))
            if nl.location != NSNotFound {
                from = nl.location + 1
                for (i, l) in r.lines.enumerated() where l.location < from { lines.append(l); widths.append(r.widths[i]) }
            }
        }
        let tail = from == 0 ? string : string.substring(from: from) as NSString
        let attr = NSAttributedString(string: tail as String, attributes: [.font: Fixture.bodyFont])
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let len = tail.length
        var start = 0
        while start < len {
            var n = CTTypesetterSuggestLineBreak(ts, start, Double(column))
            if n <= 0 { n = 1 }
            var range = NSRange(location: start, length: n)
            let endsNL = tail.character(at: start + n - 1) == 10
            if endsNL { range.length -= 1 }
            let line = CTTypesetterCreateLine(ts, CFRange(location: range.location, length: range.length))
            lines.append(NSRange(location: range.location + from, length: range.length))
            widths.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            start += n
            if start == len && endsNL && final { lines.append(NSRange(location: len + from, length: 0)); widths.append(0) }
        }
        if lines.isEmpty { lines = [NSRange(location: 0, length: 0)]; widths = [0] }
        self.lines = lines
        self.widths = widths
    }

    /// Drawing attributes (the bubble's text colour, kern, links detected in this block).
    func attributed(outgoing: Bool) -> NSAttributedString {
        lock.lock(); defer { lock.unlock() }
        if let a = drawAttr[outgoing] { return a }
        let color = outgoing ? Fixture.outgoingText : Fixture.incomingText
        let link = outgoing ? Fixture.outgoingText : UIColor(red: 0.27, green: 0.55, blue: 1, alpha: 1)
        let a = NSMutableAttributedString(string: string as String,
                                          attributes: [.font: Fixture.bodyFont, .foregroundColor: color, .kern: Fixture.bodyKern])
        if string.range(of: "http").location != NSNotFound || string.range(of: "www.").location != NSNotFound {
            for m in BlockLayout.detector.matches(in: string as String, range: NSRange(location: 0, length: string.length)) {
                a.addAttributes([.foregroundColor: link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range)
            }
        }
        drawAttr[outgoing] = a
        return a
    }
    static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

/// Block layouts by (lineage, byte range, column): LRU, 256 blocks.
final class BlockLayoutCache: @unchecked Sendable {
    static let shared = BlockLayoutCache()
    struct Key: Hashable { var lineage: Int; var start: Int; var end: Int; var final: Bool; var column: CGFloat }
    private var map: [Key: (BlockLayout, Int)] = [:]
    private var tick = 0
    private let lock = NSLock()
    static let capacity = 256
    func get(_ k: Key) -> BlockLayout? {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[k] else { return nil }
        tick += 1
        map[k] = (e.0, tick)
        return e.0
    }
    func put(_ k: Key, _ v: BlockLayout) {
        lock.lock(); defer { lock.unlock() }
        tick += 1
        map[k] = (v, tick)
        if map.count > BlockLayoutCache.capacity + 64 {
            let keep = map.sorted { $0.value.1 > $1.value.1 }.prefix(BlockLayoutCache.capacity)
            map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }
}

/// Line counts of one index at one width: estimates until measured.
final class LongTextLayout: @unchecked Sendable {
    let index: LongTextIndex
    let width: CGFloat
    let column: CGFloat
    private let lock = NSLock()
    private var tree: Fenwick
    private var exact: [Bool]
    private var pending: [Int: Int32] = [:]
    private var inFlight = Set<Int>()
    private(set) var measured = 0
    /// Replaced by a newer index (streaming) or a scanned one (placeholder).
    var retired = false
    private let placeholderLines: Int
    /// Lines from the index estimate alone (deterministic per text and width: the fold
    /// decision never flips when blocks are measured).
    private(set) var estimatedLines = 0

    static let measureQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        q.name = "longtext.measure"
        return q
    }()

    init(index: LongTextIndex, width: CGFloat, carry: LongTextLayout? = nil) {
        self.index = index
        self.width = width
        column = Metrics(width: width).maxTextWidth
        let col = Float(column)
        var v = [Int32](repeating: 1, count: index.blockCount)
        var ex = [Bool](repeating: false, count: index.blockCount)
        let k = LongTextIndex.refColumn / col
        for b in 0..<index.blockCount {
            v[b] = max(index.pieces[b], Int32((Float(index.estRef[b]) * k).rounded()))
        }
        if let c = carry, c.column == column {
            c.lock.lock()
            let n = min(c.index.blockCount, index.blockCount)
            for b in 0..<n where c.exact[b] && c.index.starts[b] == index.starts[b] && c.index.starts[b + 1] == index.starts[b + 1]
                && !(c.index.isFinal(b) != index.isFinal(b)) {
                v[b] = c.tree.values[b]; ex[b] = true
            }
            c.lock.unlock()
        }
        tree = Fenwick(v)
        estimatedLines = v.reduce(0) { $0 + Int($1) }
        exact = ex
        measured = ex.filter { $0 }.count
        placeholderLines = index.ready ? 0 : max(1, Int(Double(index.count) * Double(Fixture.bodyFont.pointSize) * 0.5 * 1.06 / Double(column)))
        if index.ready, index.count <= 512 * 1024 { require(blocks: 0..<index.blockCount) }
    }

    var totalLines: Int {
        lock.lock(); defer { lock.unlock() }
        return index.ready ? max(1, tree.total) : placeholderLines
    }
    var textHeight: CGFloat { CGFloat(totalLines) * Fixture.lineHeight }
    var size: CGSize {
        CGSize(width: column + 2 * Fixture.bubblePadX, height: textHeight + 2 * Fixture.bubblePadY)
    }
    var blockCount: Int { index.blockCount }
    func lines(ofBlock b: Int) -> Int { lock.lock(); defer { lock.unlock() }; return Int(tree.values[b]) }
    func firstLine(ofBlock b: Int) -> Int { lock.lock(); defer { lock.unlock() }; return tree.prefix(b) }
    func block(containingLine l: Int) -> Int { lock.lock(); defer { lock.unlock() }; return tree.find(max(0, l)) }
    func isExact(_ b: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return exact[b] }
    var exactCount: Int { lock.lock(); defer { lock.unlock() }; return measured }

    func key(_ b: Int) -> BlockLayoutCache.Key {
        BlockLayoutCache.Key(lineage: index.lineage, start: index.starts[b], end: index.starts[b + 1], final: index.isFinal(b), column: column)
    }

    /// The block's line breaks (cached, else measured on this thread). Reports the count.
    func blockLayout(_ b: Int, reuse: BlockLayout? = nil) -> BlockLayout {
        let k = key(b)
        if let l = BlockLayoutCache.shared.get(k) { report(b, l.lines.count); return l }
        let l = BlockLayout(string: index.blockString(b), column: column, final: index.isFinal(b), reuse: reuse)
        BlockLayoutCache.shared.put(k, l)
        LongTextStats.blocksMeasured += 1
        report(b, l.lines.count)
        return l
    }

    /// Measure the unmeasured blocks holding these lines, off main.
    func require(lines: Range<Int>) {
        guard index.ready, !lines.isEmpty, blockCount > 0 else { return }
        let a = block(containingLine: lines.lowerBound), b = block(containingLine: lines.upperBound - 1)
        require(blocks: a..<(b + 1))
    }
    func require(blocks: Range<Int>) {
        var todo: [Int] = []
        lock.lock()
        for b in blocks where !exact[b] && pending[b] == nil && !inFlight.contains(b) { inFlight.insert(b); todo.append(b) }
        lock.unlock()
        guard !todo.isEmpty else { return }
        // Chunks of 8 blocks per operation (fewer queue hops).
        for i in stride(from: 0, to: todo.count, by: 8) {
            let chunk = Array(todo[i..<min(todo.count, i + 8)])
            LongTextLayout.measureQueue.addOperation { [weak self] in
                guard let self, !self.retired else { return }
                for b in chunk { _ = self.blockLayout(b) }
            }
        }
    }

    /// Measure blocks now (streaming tail, tests).
    func measureNow(_ blocks: Range<Int>, reuse: BlockLayout? = nil) {
        for b in blocks { _ = blockLayout(b, reuse: b == blocks.lowerBound ? reuse : nil) }
        _ = applyPending()
    }

    func report(_ b: Int, _ n: Int) {
        lock.lock()
        inFlight.remove(b)
        let fresh = !exact[b] && pending[b] == nil
        if fresh { pending[b] = Int32(n) }
        lock.unlock()
        if fresh { LongTextCenter.schedule(self) }
    }

    /// Main thread: published counts take the measured ones. Returns whether a height changed.
    @discardableResult
    func applyPending() -> Bool {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for (b, n) in pending where !exact[b] {
            if tree.values[b] != n { changed = true }
            tree.set(b, n)
            exact[b] = true
            measured += 1
        }
        pending.removeAll()
        return changed
    }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }

    // MARK: Anchors (text-local y: 0 at the first line's slot top)

    struct Anchor { var start: Int; var dy: CGFloat; var fraction: CGFloat }
    func anchor(atTextY y: CGFloat) -> Anchor {
        let lh = Fixture.lineHeight
        let frac = y / max(1, textHeight)
        guard index.ready, blockCount > 0 else { return Anchor(start: -1, dy: 0, fraction: frac) }
        let line = Int(floor(max(0, y) / lh))
        let b = block(containingLine: line)
        return Anchor(start: index.starts[b], dy: y - CGFloat(firstLine(ofBlock: b)) * lh, fraction: frac)
    }
    func textY(of a: Anchor) -> CGFloat {
        guard index.ready, a.start >= 0, blockCount > 0 else { return a.fraction * textHeight }
        var lo = 0, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if index.starts[mid] <= a.start { lo = mid } else { hi = mid - 1 }
        }
        return CGFloat(firstLine(ofBlock: lo)) * Fixture.lineHeight + a.dy
    }

    // MARK: Selection, copy, accessibility (UTF-16 offsets of the whole text)

    /// Text offset at a text-local point (x from the text's left edge).
    func offset(at p: CGPoint) -> Int {
        guard index.ready, blockCount > 0 else { return 0 }
        let line = max(0, min(totalLines - 1, Int(floor(p.y / Fixture.lineHeight))))
        let b = block(containingLine: line)
        let bl = blockLayout(b)
        let j = max(0, min(bl.lines.count - 1, line - firstLine(ofBlock: b)))
        let r = bl.lines[j]
        let attr = NSAttributedString(string: bl.string.substring(with: r), attributes: [.font: Fixture.bodyFont])
        let ct = CTLineCreateWithAttributedString(attr)
        var i = CTLineGetStringIndexForPosition(ct, CGPoint(x: p.x, y: 0))
        if i == kCFNotFound { i = 0 }
        return index.u16Starts[b] + r.location + min(i, r.length)
    }

    /// Selection rects (text-local) of `range`, only for lines in `visible` (text-local y).
    func rects(for range: NSRange, visible: ClosedRange<CGFloat>) -> [CGRect] {
        guard index.ready, blockCount > 0, range.length > 0 else { return [] }
        let lh = Fixture.lineHeight
        let l0 = max(0, Int(floor(visible.lowerBound / lh))), l1 = min(totalLines, Int(ceil(visible.upperBound / lh)))
        guard l0 < l1 else { return [] }
        var out: [CGRect] = []
        var line = l0
        while line < l1 {
            let b = block(containingLine: line)
            let first = firstLine(ofBlock: b)
            let bl = blockLayout(b)
            let base = index.u16Starts[b]
            for j in max(0, line - first)..<bl.lines.count {
                let gl = first + j
                if gl >= l1 { break }
                let lr = bl.lines[j]
                let lineRange = NSRange(location: base + lr.location, length: lr.length)
                // A hard line end owns its newline; a soft wrap does not (the next line starts there).
                let soft = j + 1 < bl.lines.count && bl.lines[j + 1].location == NSMaxRange(lr)
                let s = max(range.location, lineRange.location), e = min(NSMaxRange(range), NSMaxRange(lineRange) + (soft ? 0 : 1))
                if s < e || (lr.length == 0 && NSLocationInRange(lineRange.location, range)) {
                    let attr = NSAttributedString(string: bl.string.substring(with: lr), attributes: [.font: Fixture.bodyFont])
                    let ct = CTLineCreateWithAttributedString(attr)
                    let x0 = CTLineGetOffsetForStringIndex(ct, max(0, s - lineRange.location), nil)
                    let x1 = e > NSMaxRange(lineRange) ? bl.widths[j] + 4 : CTLineGetOffsetForStringIndex(ct, min(lr.length, e - lineRange.location), nil)
                    out.append(CGRect(x: x0, y: CGFloat(gl) * lh, width: max(1, x1 - x0), height: lh))
                }
            }
            line = first + max(1, bl.lines.count)
            if b + 1 >= blockCount { break }
            line = max(line, firstLine(ofBlock: b + 1))
        }
        return out
    }

    /// Text in a UTF-16 range (Copy, accessibility value ranges).
    func substring(_ range: NSRange) -> String {
        guard index.ready, blockCount > 0, range.length > 0 else { return "" }
        var out = ""
        var b = index.block(u16: range.location)
        while b < blockCount, index.u16Starts[b] < NSMaxRange(range) {
            let s = index.blockString(b)
            let base = index.u16Starts[b]
            let lo = max(0, range.location - base), hi = min(s.length, NSMaxRange(range) - base)
            if lo < hi { out += s.substring(with: NSRange(location: lo, length: hi - lo)) }
            b += 1
        }
        return out
    }
}

enum LongTextStats {
    static var blocksMeasured = 0
    static var publishes = 0
    static var indexBuilds = 0
    static var streamExtends = 0
}

/// Main-thread delivery of measured line counts, in batches. `handler(lineages, apply)`
/// must call `apply` once (the window view keeps its anchor around it).
enum LongTextCenter {
    static var handler: ((Set<Int>, () -> Void) -> Void)?
    private static let lock = NSLock()
    private static var dirty: [ObjectIdentifier: LongTextLayout] = [:]
    private static var replaced: [() -> Void] = []
    private static var replacedLineages = Set<Int>()
    private static var scheduled = false

    static func schedule(_ l: LongTextLayout) {
        lock.lock()
        dirty[ObjectIdentifier(l)] = l
        let go = !scheduled
        scheduled = true
        lock.unlock()
        if go { DispatchQueue.main.async { publish() } }
    }
    static func scheduleReplace(lineage: Int, _ apply: @escaping () -> Void) {
        lock.lock()
        replaced.append(apply)
        replacedLineages.insert(lineage)
        let go = !scheduled
        scheduled = true
        lock.unlock()
        if go { DispatchQueue.main.async { publish() } }
    }

    static func publish() {
        lock.lock()
        let ls = Array(dirty.values).filter { !$0.retired }
        let rs = replaced
        var lineages = replacedLineages
        dirty.removeAll(); replaced.removeAll(); replacedLineages.removeAll()
        scheduled = false
        lock.unlock()
        lineages.formUnion(ls.map(\.index.lineage))
        guard !lineages.isEmpty else { return }
        LongTextStats.publishes += 1
        let apply = {
            rs.forEach { $0() }
            ls.forEach { $0.applyPending() }
        }
        if let h = handler { h(lineages, apply) } else { apply() }
    }
}

/// Text to index and layouts (thread safe). Finds a streamed text's previous index by prefix.
final class LongTextStore: @unchecked Sendable {
    static let shared = LongTextStore()
    private let lock = NSLock()
    private struct Addr: Hashable { var base: UInt; var count: Int }
    private struct Print: Hashable { var count: Int; var head: Int; var tail: Int }
    private var byAddr: [Addr: LongTextIndex] = [:]
    private var byPrint: [Print: LongTextIndex] = [:]
    private var byHead: [Int: LongTextIndex] = [:]
    private var layouts: [ObjectIdentifier: [CGFloat: LongTextLayout]] = [:]
    private var recent: [ObjectIdentifier: Int] = [:]
    private var tick = 0
    private var lineageSerial = 0
    static let maxIndexes = 12
    static let syncBytes = 512 << 10

    func size(_ text: String, width: CGFloat) -> CGSize { layout(text, width: width).size }
    /// The row size of a message's long text part: folded (LongTextFold) or full.
    func size(_ text: String, width: CGFloat, message id: ID) -> CGSize {
        let l = layout(text, width: width)
        if LongTextFold.isFolded(id, l) { return LongTextFold.size(l) }
        // Expanded: the "Show less" band follows the last line.
        if LongTextFold.isFoldable(l) { return CGSize(width: l.size.width, height: l.size.height + LongTextFold.bandHeight) }
        return l.size
    }

    func layout(_ text: String, width: CGFloat) -> LongTextLayout {
        let idx = index(for: text)!
        lock.lock()
        let id = ObjectIdentifier(idx)
        tick += 1
        recent[id] = tick
        if let l = layouts[id]?[width] { lock.unlock(); return l }
        let carry = layouts[id]?.values.first
        lock.unlock()
        let l = LongTextLayout(index: idx, width: width, carry: carry?.column == Metrics(width: width).maxTextWidth ? carry : nil)
        lock.lock()
        var per = layouts[id] ?? [:]
        if per.count >= 3 { per.values.forEach { $0.retired = true }; per.removeAll() }
        per[width] = l
        layouts[id] = per
        lock.unlock()
        return l
    }

    /// The lineage of a text if it is indexed.
    func lineage(_ text: String) -> Int? { index(for: text, create: false)?.lineage }

    private static func print(_ p: UnsafeBufferPointer<UInt8>) -> Print {
        var h = Hasher(), t = Hasher()
        let n = p.count, k = min(n, 1024)
        h.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: p[0..<k])))
        t.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: p[(n - k)..<n])))
        return Print(count: n, head: h.finalize(), tail: t.finalize())
    }
    private static func head(_ p: UnsafeBufferPointer<UInt8>) -> Int {
        var h = Hasher()
        h.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: p[0..<min(p.count, 512)])))
        return h.finalize()
    }

    private func index(for text: String, create: Bool = true) -> LongTextIndex? {
        var t = text
        if t.utf8.withContiguousStorageIfAvailable({ _ in true }) == nil { t.makeContiguousUTF8() }
        return t.utf8.withContiguousStorageIfAvailable { p -> LongTextIndex? in
            let addr = Addr(base: UInt(bitPattern: p.baseAddress), count: p.count)
            lock.lock()
            if let i = byAddr[addr] { lock.unlock(); return i }
            let pr = LongTextStore.print(p)
            if let i = byPrint[pr] { byAddr[addr] = i; lock.unlock(); return i }
            let hd = LongTextStore.head(p)
            let prev = byHead[hd]
            lock.unlock()
            guard create else { return nil }
            // Streaming: the same text with more at the end keeps every block but the last.
            if let prev, prev.ready, prev.count < p.count, prev.blockCount > 0 {
                let keep = prev.blockCount - 1
                let from = max(0, prev.starts[keep] - 256)
                let same = prev.withBytes { q in memcmp(q.baseAddress! + from, p.baseAddress! + from, prev.count - from) == 0 }
                if same {
                    let i = LongTextIndex.build(t, lineage: prev.lineage, prefix: prev, keep: keep)
                    LongTextStats.streamExtends += 1
                    let old = layoutsOf(prev)
                    register(i, addr: addr, print: pr, head: hd, replacing: prev)
                    // Layouts carry the measured blocks; the new tail is measured now (about 4 KB).
                    for o in old {
                        let reuse = BlockLayoutCache.shared.get(o.key(keep))
                        let l = LongTextLayout(index: i, width: o.width, carry: o)
                        lock.lock(); layouts[ObjectIdentifier(i), default: [:]][o.width] = l; lock.unlock()
                        let tail = max(0, keep)..<i.blockCount
                        if i.count - i.starts[tail.lowerBound] <= 16 * 1024 { l.measureNow(tail, reuse: reuse) } else { l.require(blocks: tail) }
                    }
                    return i
                }
            }
            lineageSerial += 1
            let lineage = lineageSerial
            LongTextStats.indexBuilds += 1
            if p.count <= LongTextStore.syncBytes {
                let i = LongTextIndex.build(t, lineage: lineage)
                register(i, addr: addr, print: pr, head: hd, replacing: nil)
                return i
            }
            // Large: a placeholder (estimated height, no tiles) until the scan finishes off main.
            let ph = LongTextIndex.placeholder(t, lineage: lineage)
            register(ph, addr: addr, print: pr, head: hd, replacing: nil)
            DispatchQueue.global(qos: .userInitiated).async {
                let i = LongTextIndex.build(t, lineage: lineage)
                LongTextCenter.scheduleReplace(lineage: lineage) {
                    self.register(i, addr: addr, print: pr, head: hd, replacing: ph)
                }
            }
            return ph
        } ?? nil
    }

    private func layoutsOf(_ i: LongTextIndex) -> [LongTextLayout] {
        lock.lock(); defer { lock.unlock() }
        return Array(layouts[ObjectIdentifier(i)]?.values ?? [:].values)
    }

    private func register(_ i: LongTextIndex, addr: Addr, print: Print, head: Int, replacing old: LongTextIndex?) {
        lock.lock(); defer { lock.unlock() }
        if let old {
            let oid = ObjectIdentifier(old)
            layouts[oid]?.values.forEach { $0.retired = true }
            layouts[oid] = nil
            recent[oid] = nil
            byAddr = byAddr.filter { $0.value !== old }
            byPrint = byPrint.filter { $0.value !== old }
        }
        byAddr[addr] = i
        byPrint[print] = i
        byHead[head] = i
        tick += 1
        recent[ObjectIdentifier(i)] = tick
        // Bounded: the least recently used indexes go (their texts with them).
        let live = Set(byAddr.values.map { ObjectIdentifier($0) })
        if live.count > LongTextStore.maxIndexes {
            let drop = Set(live.sorted { (recent[$0] ?? 0) < (recent[$1] ?? 0) }.prefix(live.count - LongTextStore.maxIndexes))
            byAddr = byAddr.filter { !drop.contains(ObjectIdentifier($0.value)) }
            byPrint = byPrint.filter { !drop.contains(ObjectIdentifier($0.value)) }
            byHead = byHead.filter { !drop.contains(ObjectIdentifier($0.value)) }
            for d in drop { layouts[d]?.values.forEach { $0.retired = true }; layouts[d] = nil; recent[d] = nil }
        }
    }

    var indexCount: Int { lock.lock(); defer { lock.unlock() }; return Set(byAddr.values.map { ObjectIdentifier($0) }).count }
}

/// Collapsed long messages (shared/LONG-MESSAGES.md, product rule): a message taller than
/// 3 screens shows its first and last 40 lines and a "Show all N lines" band between them,
/// until the band is clicked (`MessagesWindowView.expandLongText`). The folded height is
/// fixed (80 lines and the band), so measurement never changes it.
enum LongTextFold {
    static let headLines = 40, tailLines = 40
    /// 3 screens (the 1041 pt window).
    static var maxLines: Int { Int(3 * 1041 / Fixture.lineHeight) }
    static var bandHeight: CGFloat { 2 * Fixture.lineHeight }
    static let defaultsKey = "messageslab.collapseLongMessages"
    /// Setting (UserDefaults, default on). `--no-collapse` turns it off for one run.
    static var enabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("--no-collapse") { return false }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
    private static let lock = NSLock()
    private static var expanded = Set<ID>()
    /// Session only: expanded messages are not stored (they fold again at launch).
    static func expand(_ id: ID) { lock.lock(); expanded.insert(id); lock.unlock() }
    static func collapse(_ id: ID) { lock.lock(); expanded.remove(id); lock.unlock() }
    static func isFoldable(_ l: LongTextLayout) -> Bool { enabled && l.index.ready && l.estimatedLines > maxLines }
    static func isExpanded(_ id: ID) -> Bool { lock.lock(); defer { lock.unlock() }; return expanded.contains(id) }
    static func isFolded(_ id: ID, _ l: LongTextLayout) -> Bool { isFoldable(l) && !isExpanded(id) }
    static func size(_ l: LongTextLayout) -> CGSize {
        CGSize(width: l.column + 2 * Fixture.bubblePadX,
               height: CGFloat(headLines + tailLines) * Fixture.lineHeight + bandHeight + 2 * Fixture.bubblePadY)
    }
    static func label(_ n: Int) -> String {
        String(format: String(localized: "longtext.showAll", defaultValue: "Show all %lld lines"), n)
    }
    static var lessLabel: String { String(localized: "longtext.showLess", defaultValue: "Show less") }
}
