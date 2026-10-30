#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import os // cmux: OSAllocatedUnfairLock
import CmuxSafeConcurrency // cmux: Mutex (p10-stability-055)

/// Long messages (agent output: logs, code, 100k-line pastes). shared/LONG-MESSAGES.md.
/// A long text part is cut into blocks of about 4 KB (index, width independent);
/// each block has an estimated line count until Core Text measures it (layout, per
/// width); the row's height is the sum in a Fenwick tree. TiledBubble.swift draws it.
enum LongText {
    static let minBytes = 8192
    static let minLines = 120
    static let blockBytes = 4096
    // cmux: constants for the process (nothing sets them after launch, and the row threads read
    // them: unsynchronized globals; p10-stability-040).
    static let enabled = !ProcessInfo.processInfo.arguments.contains("--no-long-text")
    /// Long markdown in tiles (MarkdownLong.swift). Off until its e2e and benches pass;
    /// `--long-markdown` turns it on for one run.
    static let markdownTiles = ProcessInfo.processInfo.arguments.contains("--long-markdown")
    /// Streaming tail measured and its end tiles drawn off main, published together (no empty
    /// tile). Off until its benches pass; `--long-tail-off-main` turns it on for one run.
    static let offMainTail = ProcessInfo.processInfo.arguments.contains("--long-tail-off-main")

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
        // checked writes ; tree has v.count + 1 slots, k and j stay inside.
        var tree = [Int](repeating: 0, count: v.count + 1)
        for (i, x) in v.enumerated() {
            let k = i + 1
            if let s = tree.checkedIndex(k) { tree[s] += Int(truncatingIfNeeded: x) }
            let j = k + (k & -k)
            if j <= v.count, let s = tree.checkedIndex(j), let add = tree[checked: k] { tree[s] += add }
        }
        self.tree = tree
    }
    var count: Int { values.count }
    mutating func set(_ i: Int, _ v: Int32) {
        guard let old = values[checked: i] else { return } // a block index from another layout sets nothing
        let d = Int(truncatingIfNeeded: v) - Int(truncatingIfNeeded: old)
        guard d != 0 else { return }
        if let slot = values.checkedIndex(i) { values[slot] = v }
        var k = i + 1
        while k <= values.count { if let s = tree.checkedIndex(k) { tree[s] += d }; k += k & -k }
    }
    /// Sum of values[0..<i].
    func prefix(_ i: Int) -> Int {
        var s = 0, k = min(i, values.count)
        while k > 0 { s += tree[checked: k] ?? 0; k -= k & -k } // checked
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
            if pos + step <= values.count, let t = tree[checked: pos + step], t <= rem { pos += step; rem -= t } // checked
            step /= 2
        }
        return min(pos, values.count - 1)
    }
}

/// Block index of one text (immutable, thread safe).
/// cmux: checked `Sendable` (p10-stability-055): every stored property is a let of a Sendable value.
final class LongTextIndex: Sendable {
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
    /// The text may hold markdown (MarkdownLong.swift): blocks are cut off fences and tables,
    /// and `carries` holds the parser state at each block start.
    let markdown: Bool
    let carries: [MDCarry]
    /// Selection offset of each block start (last: the selection length). Plain: the UTF-16
    /// starts. Markdown: a slot of 2 x the block's UTF-16 length + 64 per block, which holds
    /// the block's display string (markers, tabs, newlines) at any width, so offsets never move
    /// when a block is laid out (offsets past a block's display string are unused).
    let selStarts: [Int]
    func carry(_ b: Int) -> MDCarry { b >= 0 && b < carries.count ? carries[checked: b] ?? .none : .none } // checked

    init(lineage: Int, text: String, starts: [Int], u16Starts: [Int], pieces: [Int32], units: [Float], estRef: [Int32],
         newlines: [Int32] = [], ready: Bool, markdown: Bool = false, carries: [MDCarry] = [], selStarts: [Int]? = nil) {
        self.lineage = lineage; self.text = text; self.count = text.utf8.count
        self.starts = starts; self.u16Starts = u16Starts; self.pieces = pieces; self.units = units; self.estRef = estRef; self.ready = ready
        self.newlines = newlines
        self.markdown = markdown; self.carries = carries; self.selStarts = selStarts ?? u16Starts
        hardLines = newlines.reduce(1) { $0 + Int(truncatingIfNeeded: $1) } // Int32 widens exactly
    }

    static func placeholder(_ text: String, lineage: Int) -> LongTextIndex {
        LongTextIndex(lineage: lineage, text: text, starts: [0], u16Starts: [0], pieces: [], units: [], estRef: [], ready: false)
    }

    /// Whether a long text takes the markdown cut and layout (MarkdownLong.swift).
    static func isMarkdown(_ text: String) -> Bool { LongText.markdownTiles && Markdown.enabled && Markdown.mightContain(text) }

    /// cmux: `@safe` as the standard library's `withUnsafeBufferPointer`: the buffer exists only for `body`, and
    /// each use of it inside `body` is marked where it happens (strict memory safety, p10-stability-073).
    @safe func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        // SAFETY: body gets the text's contiguous UTF-8 (or a copy's), valid for the call only, and returns a value.
        if let r = unsafe text.utf8.withContiguousStorageIfAvailable(body) { return r }
        let a = Array(text.utf8)
        return unsafe a.withUnsafeBufferPointer(body)
    }

    /// Scan `text` into blocks; with `prefix`, keep its blocks before `keep` (streaming).
    static func build(_ text: String, lineage: Int, prefix: LongTextIndex? = nil, keep: Int = 0, markdown: Bool? = nil) -> LongTextIndex {
        var t = text
        t.makeContiguousUTF8()
        let md = markdown ?? prefix?.markdown ?? isMarkdown(t)
        var carries = md ? Array(prefix?.carries.prefix(keep) ?? []) : []
        var sel = Array(prefix?.selStarts.prefix(keep) ?? [])
        var selPos = prefix.map { keep < $0.selStarts.count ? $0.selStarts[keep] : 0 } ?? 0
        var st: MDCarry = md ? (prefix?.carry(keep) ?? .none) : .none
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
        // cmux: the scan reads the bytes as a generic collection (prefix, dropFirst and checked reads, each
        // bounds-checked), so only the hand-over below touches the buffer (strict memory safety, p10-stability-073).
        func scan<Bytes: RandomAccessCollection<UInt8>>(_ p: Bytes) where Bytes.Index == Int {
            let n = p.count
            var i = from
            while i < n {
                let limit = min(n, i + LongText.blockBytes)
                var end = limit
                if limit < n {
                    // searches on slices, no index math (p is an unsafe buffer: its subscript does not check in release).
                    if let j = p.prefix(limit).dropFirst(i).lastIndex(of: 10) {
                        end = j + 1
                    } else {
                        // One paragraph longer than a block: cut at a space, else at a character boundary.
                        let floor = max(i + 1, limit - 1024)
                        if let k = p.prefix(limit).dropFirst(floor).lastIndex(where: { $0 == 32 || $0 == 9 }) { end = k + 1 } else {
                            // The last byte in (i + 1, limit] that starts a character, else i + 1.
                            end = p.prefix(limit + 1).dropFirst(i + 2).lastIndex(where: { $0 & 0xC0 != 0x80 }) ?? (i + 1)
                        }
                    }
                }
                let carryHere = st
                if md { (end, st) = MarkdownLong.cut(p, from: i, plainEnd: end, block: starts.count, state: st) }
                var nl: Int32 = 0, w: Float = 0, c16 = 0, para: Float = 0, est: Int32 = 0
                for b in p.prefix(end).dropFirst(i) { // no index math
                    if b < 0x80 {
                        c16 += 1
                        if b == 10 { nl += 1; est += max(1, Int32(clamping: CrashGuard.int(Double((para / wrap).rounded(.up))))); para = 0 }
                        else if b == 9 { w += 4 * ascii; para += 4 * ascii } else { w += ascii; para += ascii }
                    } else if b >= 0xF0 { c16 += 2; w += emoji; para += emoji } else if b >= 0xE0 { c16 += 1; w += wide; para += wide }
                    else if b >= 0xC0 { c16 += 1; w += ascii; para += ascii }
                }
                let lastByte = p.prefix(end).last // the block's last byte, no index math
                if lastByte != 10 || end == n { est += max(1, Int32(clamping: CrashGuard.int(Double((para / wrap).rounded(.up))))) }
                let endsNL = lastByte == 10
                starts.append(i); u16.append(u16Pos); sel.append(selPos)
                if md { carries.append(carryHere) }
                selPos += md ? 2 * c16 + 64 : c16
                pieces.append(nl + (endsNL && end < n ? 0 : 1))
                units.append(w)
                estRef.append(est)
                newlines.append(nl)
                u16Pos += c16
                i = end
            }
            starts.append(n); u16.append(u16Pos); sel.append(selPos)
        }
        // SAFETY: p is the string's contiguous UTF-8 (made contiguous above), valid for this closure; scan reads it
        // only through bounds-checked collection operations and keeps no reference to it.
        t.utf8.withContiguousStorageIfAvailable { p in unsafe scan(p) }
        return LongTextIndex(lineage: lineage, text: t, starts: starts, u16Starts: u16, pieces: pieces, units: units, estRef: estRef, newlines: newlines, ready: true,
                             markdown: md, carries: carries, selStarts: sel)
    }

    func isFinal(_ b: Int) -> Bool { b == blockCount - 1 }

    /// The block's text as an NSString (UTF-16, for Core Text).
    func blockString(_ b: Int) -> NSString {
        guard let a = starts[checked: b], let e = starts[checked: b + 1], a <= e else { return "" } // a stale block is empty
        return withBytes { p in
            // SAFETY: p is the text's UTF-8, valid inside this closure; 0 <= a <= e <= p.count (the block's offsets,
            // the last bound checked here), so NSString copies e - a bytes from inside the buffer.
            guard let base = unsafe p.baseAddress, unsafe e <= p.count, a >= 0 else { return "" } // no force unwrap
            return unsafe NSString(bytes: base + a, length: e - a, encoding: String.Encoding.utf8.rawValue) ?? ""
        }
    }

    /// Block holding selection offset `o`.
    func block(sel o: Int) -> Int {
        var lo = 0, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (selStarts[checked: mid] ?? .max) <= o { lo = mid } else { hi = mid - 1 } // checked
        }
        return max(0, lo)
    }

    /// Block holding UTF-16 offset `o`.
    func block(u16 o: Int) -> Int {
        var lo = 0, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (u16Starts[checked: mid] ?? .max) <= o { lo = mid } else { hi = mid - 1 } // checked
        }
        return max(0, lo)
    }

    /// Find: the first UTF-8 range of `needle` at or after `from` (memmem, call off main).
    func find(_ needle: String, from: Int = 0) -> Range<Int>? {
        let n = Array(needle.utf8)
        guard !n.isEmpty, from < count else { return nil }
        return withBytes { p in
            n.withUnsafeBufferPointer { q in
                // no force unwraps
                // SAFETY: p (the text) and q (the needle) are valid inside these closures and no pointer leaves them;
                // 0 <= from < count <= p.count (checked above and here), so memmem searches the count - from bytes from
                // base + from, inside p, and a match it returns points into them.
                guard let base = unsafe p.baseAddress, let needle = unsafe q.baseAddress, unsafe count <= p.count, from >= 0,
                      let r = unsafe memmem(base + from, count - from, needle, q.count) else { return nil }
                let o = unsafe UnsafeRawPointer(r) - UnsafeRawPointer(base)
                return unsafe o..<(o + q.count)
            }
        }
    }

    /// UTF-16 offset of a UTF-8 offset (block start plus the block's prefix).
    func u16Offset(utf8 o: Int) -> Int {
        var lo = 0, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (starts[checked: mid] ?? .max) <= o { lo = mid } else { hi = mid - 1 } // checked
        }
        let a = starts[checked: lo] ?? 0
        let local = withBytes { p in
            // the slice is clamped to the buffer (an unsafe buffer does not check its range).
            // SAFETY: p is the text's UTF-8 inside this closure; 0 <= from <= to <= p.count (clamped), so the rebased
            // slice lies inside it, and String copies the bytes out.
            let from = unsafe min(max(0, a), p.count), to = unsafe min(max(from, o), p.count)
            return unsafe String(decoding: UnsafeBufferPointer(rebasing: p.prefix(to).dropFirst(from)), as: UTF8.self).utf16.count
        }
        return (u16Starts[checked: lo] ?? 0) + local
    }
}

/// Line breaks of one block (Core Text, the rules of `TextLayout.make`).
/// cmux: checked `Sendable` (p10-stability-055): the string is a shared immutable value and the drawing
/// attributes a checked lock's state (they were a var under an NSLock in an unchecked class).
final class BlockLayout: Sendable {
    var string: NSString { text.value }
    private let text: HomeShared<NSString>
    let lines: [NSRange]
    let widths: [CGFloat]
    /// A markdown block (MarkdownLong.layout): drawn and hit-tested from this; `string` is its
    /// display string and `lines` is empty.
    let md: MarkdownLayout?
    /// Its line count in the Fenwick tree (markdown: its height in 16 pt lines, rounded up).
    let lineCount: Int
    // Lock carve-out: the tile renderers read and fill two attributed strings per block; none is built under the lock.
    private let drawAttr = Mutex([Bool: HomeShared<NSAttributedString>]())

    init(md: MarkdownLayout, lines n: Int) {
        self.md = md
        text = HomeShared(md.plain as NSString)
        lines = []; widths = []
        lineCount = n
    }

    /// `reuse`: the same block before text was appended (streaming): its lines before its last
    /// paragraph are kept and only the rest is typeset (paragraphs break independently).
    init(string: NSString, column: CGFloat, final: Bool, reuse: BlockLayout? = nil) {
        text = HomeShared(string)
        var lines: [NSRange] = [], widths: [CGFloat] = []
        var from = 0
        if let r = reuse, r.string.length <= string.length, r.string.length > 0,
           string.substring(to: r.string.length) == r.string as String {
            let nl = r.string.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: r.string.length - 1))
            if nl.location != NSNotFound {
                from = nl.location + 1
                for (l, w) in zip(r.lines, r.widths) where l.location < from { lines.append(l); widths.append(w) } // no index math
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
            lines.append(NSRange(location: range.location + from, length: range.length))
            // A blank line is 0 pt (length 0 would lay out the whole rest of the text: TextLayout.make).
            widths.append(range.length > 0 ? CGFloat(CTTypesetterCreateLine(ts, CFRange(location: range.location, length: range.length)).typographicWidth) : 0)
            start += n
            if start == len && endsNL && final { lines.append(NSRange(location: len + from, length: 0)); widths.append(0) }
        }
        if lines.isEmpty { lines = [NSRange(location: 0, length: 0)]; widths = [0] }
        self.lines = lines
        self.widths = widths
        md = nil
        lineCount = lines.count
    }

    /// Drawing attributes (the bubble's text colour, kern, links detected in this block).
    func attributed(outgoing: Bool) -> NSAttributedString {
        if let a = drawAttr.withLock({ $0[outgoing] }) { return a.value }
        let color = outgoing ? Fixture.outgoingText : Fixture.incomingText
        let link = outgoing ? Fixture.outgoingText : Fixture.incomingLink // cmux: themed link tint
        let a = NSMutableAttributedString(string: string as String,
                                          attributes: [.font: Fixture.bodyFont, .foregroundColor: color, .kern: Fixture.bodyKern])
        if string.range(of: "http").location != NSNotFound || string.range(of: "www.").location != NSNotFound {
            // Long text is untrusted too: only URLs the link policy allows look like links
            // (MarkdownLinkPolicy, shared/MARKDOWN.md Security; same rule as TextParts.linkRuns).
            for m in BlockLayout.detector?.matches(in: string as String, range: NSRange(location: 0, length: string.length)) ?? [] {
                guard let url = m.url, MarkdownLinkPolicy.allows(url) else { continue }
                a.addAttributes([.foregroundColor: link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range)
            }
        }
        // cmux: built outside the lock; when two renderers build the same block at once, both draw the first one stored.
        let built = HomeShared<NSAttributedString>(a)
        return drawAttr.withLock { cache -> HomeShared<NSAttributedString> in
            if let first = cache[outgoing] { return first }
            cache[outgoing] = built
            return built
        }.value
    }
    // optional, no try! ; without it no link is underlined.
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

/// Block layouts by (lineage, byte range, column): LRU, 256 blocks.
/// cmux: checked `Sendable` (p10-stability-055): the map and its clock are one lock state.
final class BlockLayoutCache: Sendable { // cmux: memory: fixed at most capacity + 64 blocks of about 4 KB of text each (LRU)
    static let shared = BlockLayoutCache()
    struct Key: Hashable { var lineage: Int; var start: Int; var end: Int; var final: Bool; var column: CGFloat; var md: Bool = false }
    private struct State: Sendable {
        var map: [Key: (BlockLayout, Int)] = [:]
        var tick = 0
    }
    // Lock carve-out: the measure threads and main look up and insert blocks; the trim sorts at most 320 entries.
    private let state = Mutex(State())
    static let capacity = 256
    func get(_ k: Key) -> BlockLayout? {
        state.withLock { s -> BlockLayout? in
            guard let e = s.map[k] else { return nil }
            s.tick += 1
            s.map.updateValue((e.0, s.tick), forKey: k) // dictionary write
            return e.0
        }
    }
    func put(_ k: Key, _ v: BlockLayout) {
        state.withLock { s in
            s.tick += 1
            s.map.updateValue((v, s.tick), forKey: k) // dictionary write
            if s.map.count > BlockLayoutCache.capacity + 64 {
                let keep = s.map.sorted { $0.value.1 > $1.value.1 }.prefix(BlockLayoutCache.capacity)
                // cmux: keys come from `s.map`, so they are unique; no trapping init (p10-stability-096).
                s.map = Dictionary(keep.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            }
        }
    }
    var count: Int { state.withLock { $0.map.count } }
}

/// Line counts of one index at one width: estimates until measured.
/// cmux: checked `Sendable` (p10-stability-055): the counts, the measure bookkeeping, the tile hint, the
/// prerendered tiles and `retired` are one lock state (they were vars under an NSLock, and `retired` a
/// plain var the measure queues read, in an unchecked class).
final class LongTextLayout: Sendable {
    let index: LongTextIndex
    let width: CGFloat
    let column: CGFloat
    /// Markdown blocks render as markdown (false: the message is shown as source).
    let markdown: Bool
    /// What the row's tiles look like (TiledBody sets it): a streamed tail block is measured and
    /// its tiles near the end are drawn off main, then both reach the screen in one publish.
    struct TileHint: Sendable { var outgoing: Bool; var width: CGFloat; var scale: CGFloat; var palette: Int }
    var tileHint: TileHint? {
        get { state.withLock { $0.hint } }
        set { state.withLock { $0.hint = newValue } }
    }
    /// A tile drawn off main with its block's measurement, put in the TileCache by `applyPending`.
    private typealias PendingTile = (key: TileCache.Key, image: HomeShared<CGImage>)
    private struct State: Sendable {
        var hint: TileHint?
        var pendingTiles: [PendingTile] = []
        var tree: Fenwick
        var exact: [Bool]
        var pending: [Int: Int32] = [:]
        var inFlight = Set<Int>()
        var measured = 0
        var retired = false
    }
    // Lock carve-out: the measure and tail queues report counts and main applies them; no layout under the lock.
    private let state: Mutex<State>
    var measured: Int { state.withLock { $0.measured } }
    /// Replaced by a newer index (streaming) or a scanned one (placeholder).
    var retired: Bool {
        get { state.withLock { $0.retired } }
        set { state.withLock { $0.retired = newValue } }
    }
    private let placeholderLines: Int
    /// Lines from the index estimate alone (deterministic per text and width: the fold
    /// decision never flips when blocks are measured).
    let estimatedLines: Int

    static let measureQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        q.name = "longtext.measure"
        return q
    }()

    /// `provisional`: streaming. Blocks from `keep` on keep the previous layout's count for block
    /// `keep` and 0 for new blocks (not exact) until the tail is measured, so the row's height
    /// changes only in the publish that brings the measured tail and its tiles.
    init(index: LongTextIndex, width: CGFloat, carry: LongTextLayout? = nil, markdown: Bool? = nil, provisional keep: Int? = nil) {
        self.index = index
        self.width = width
        self.markdown = index.markdown && (markdown ?? true)
        column = Metrics(width: width).maxTextWidth
        let col = Float(column)
        var ex = [Bool](repeating: false, count: max(0, index.blockCount)) // cmux: a count the trap-api guardrail sees is never negative
        let k = LongTextIndex.refColumn / col
        // built with map and checked reads.
        var v = (0..<index.blockCount).map { (b: Int) -> Int32 in
            max(index.pieces[checked: b] ?? 1, Int32(clamping: CrashGuard.int(Double((Float(index.estRef[checked: b] ?? 0) * k).rounded()))))
        }
        var hint: TileHint?
        if let c = carry, c.column == column, c.markdown == self.markdown {
            // cmux: one consistent copy of the carried layout's counts (its lock was held for these reads).
            let (cExact, cValues, cHint) = c.state.withLock { ($0.exact, $0.tree.values, $0.hint) }
            let n = min(c.index.blockCount, index.blockCount)
            // checked reads and writes.
            for b in 0..<n where (cExact[checked: b] ?? false) && c.index.starts[checked: b] == index.starts[checked: b]
                && c.index.starts[checked: b + 1] == index.starts[checked: b + 1]
                && !(c.index.isFinal(b) != index.isFinal(b)) && c.index.carry(b + 1) == index.carry(b + 1) {
                if let vs = v.checkedIndex(b), let es = ex.checkedIndex(b), let kept = cValues[checked: b] { v[vs] = kept; ex[es] = true }
            }
            if let k = keep, k >= 0, k < index.blockCount {
                if let slot = v.checkedIndex(k) { v[slot] = k < c.index.blockCount ? cValues[checked: k] ?? 0 : 0 }
                v.replaceSubrange((k + 1)..<v.count, with: repeatElement(0, count: max(0, v.count - k - 1))) // no index writes; cmux: max(0, …) (trap-api)
            }
            hint = cHint
        }
        estimatedLines = v.reduce(0) { $0 + Int(truncatingIfNeeded: $1) } // Int32 widens exactly
        state = Mutex(State(hint: hint, tree: Fenwick(v), exact: ex, measured: ex.filter { $0 }.count))
        placeholderLines = index.ready ? 0 : max(1, CrashGuard.int(Double(index.count) * Double(Fixture.bodyFont.pointSize) * 0.5 * 1.06 / Double(column),
                                                                   in: CrashGuard.countRange)) // no trap on a zero column
        if index.ready, index.count <= 512 * 1024 { require(blocks: 0..<max(0, min(index.blockCount, keep ?? index.blockCount))) } // a negative keep built an inverted range
    }

    var totalLines: Int {
        index.ready ? max(1, state.withLock { $0.tree.total }) : placeholderLines
    }
    var textHeight: CGFloat { CGFloat(totalLines) * Fixture.lineHeight }
    var size: CGSize { size(scale: Fixture.renderScale) }
    /// At a view's scale (the balloon width ends on its device pixels).
    func size(scale: CGFloat) -> CGSize {
        CGSize(width: Sizing.textBalloonWidth(column, column: column, scale: scale), height: textHeight + 2 * Fixture.bubblePadY)
    }
    var blockCount: Int { index.blockCount }
    func lines(ofBlock b: Int) -> Int { Int(truncatingIfNeeded: state.withLock { $0.tree.values[checked: b] ?? 0 }) }
    func firstLine(ofBlock b: Int) -> Int { state.withLock { $0.tree.prefix(b) } }
    func block(containingLine l: Int) -> Int { state.withLock { $0.tree.find(max(0, l)) } }
    func isExact(_ b: Int) -> Bool { state.withLock { $0.exact[checked: b] ?? false } }
    var exactCount: Int { measured }

    func key(_ b: Int) -> BlockLayoutCache.Key {
        // A markdown block's layout also depends on whether the next block continues it.
        BlockLayoutCache.Key(lineage: index.lineage, start: index.starts[checked: b] ?? -1, end: index.starts[checked: b + 1] ?? -1,
                             final: index.isFinal(b) || (markdown && index.carry(b + 1).isOpen), column: column, md: markdown)
    }

    /// The block's line breaks or markdown layout (cached, else measured on this thread). Reports the count.
    func blockLayout(_ b: Int, reuse: BlockLayout? = nil) -> BlockLayout {
        let k = key(b)
        if let l = BlockLayoutCache.shared.get(k) { report(b, l.lineCount); return l }
        var l: BlockLayout?
        if markdown, let r = MarkdownLong.layout(index, b, column: column, tableColumns: { [self] s in
            blockLayout(s).md.flatMap(MarkdownLong.lastTableColumns)
        }) {
            l = BlockLayout(md: r.0, lines: r.lines)
        }
        let out = l ?? BlockLayout(string: index.blockString(b), column: column, final: index.isFinal(b), reuse: reuse)
        BlockLayoutCache.shared.put(k, out)
        LongTextStats.count(.blocksMeasured)
        report(b, out.lineCount)
        return out
    }
    /// The block's layout if it is cached (main thread: never measures).
    func cachedBlockLayout(_ b: Int) -> BlockLayout? { BlockLayoutCache.shared.get(key(b)) }

    static let tailQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        q.name = "longtext.tail"
        return q
    }()

    /// Streaming: measure the tail blocks off main and draw their tiles near the text's end
    /// (2 screens), then publish counts and tiles together.
    func measureTail(_ blocks: Range<Int>) {
        guard !blocks.isEmpty else { return }
        state.withLock { s in for b in blocks { s.inFlight.insert(b) } }
        LongTextLayout.tailQueue.addOperation { [weak self] in
            guard let self, !self.retired else { return }
            // Lines of the first tail block before this append: its tiles above them did not change.
            let oldFirst = self.lines(ofBlock: blocks.lowerBound)
            var counts: [(Int, Int)] = []
            var layouts: [Int: BlockLayout] = [:]
            for b in blocks {
                let k = self.key(b)
                let l: BlockLayout
                if let c = BlockLayoutCache.shared.get(k) { l = c } else {
                    l = self.blockLayoutNoReport(b)
                }
                layouts[b] = l
                counts.append((b, l.lineCount))
            }
            var tiles: [(TileCache.Key, CGImage)] = []
            if let h = self.tileHint {
                let n = TiledBubble.linesPerTile
                // Lines of the text after the tail is measured: the prefix before the tail plus the new counts.
                let first = self.firstLine(ofBlock: blocks.lowerBound)
                let total = first + counts.reduce(0) { $0 + $1.1 }
                var line = first
                for (b, c) in counts {
                    // Every block in `counts` has its layout; guard anyway (no force unwrap in vendored code).
                    guard let layout = layouts[b] else { line += c; continue }
                    let from = b == blocks.lowerBound ? max(0, oldFirst - 1) / n : 0
                    for chunk in from..<max(from, (c + n - 1) / n) where line + chunk * n + n > total - 80 {
                        let k = TiledBubble.tileKey(self, block: b, chunk: chunk, outgoing: h.outgoing, scale: h.scale, palette: h.palette)
                        // a tile that could not be allocated is not prerendered.
                        if let img = TiledBubble.render(layout, chunk: chunk, outgoing: h.outgoing, width: h.width, scale: h.scale) { tiles.append((k, img)) }
                    }
                    line += c
                }
            }
            let drawn: [PendingTile] = tiles.map { (key: $0.0, image: HomeShared($0.1)) }
            self.state.withLock { [counts] s in
                for (b, c) in counts { s.inFlight.remove(b); if !(s.exact[checked: b] ?? true) { s.pending.updateValue(Int32(clamping: c), forKey: b) } }
                s.pendingTiles += drawn
            }
            LongTextCenter.schedule(self)
        }
    }
    private func blockLayoutNoReport(_ b: Int) -> BlockLayout {
        var l: BlockLayout?
        if markdown, let r = MarkdownLong.layout(index, b, column: column, tableColumns: { [self] s in
            blockLayout(s).md.flatMap(MarkdownLong.lastTableColumns)
        }) {
            l = BlockLayout(md: r.0, lines: r.lines)
        }
        let out = l ?? BlockLayout(string: index.blockString(b), column: column, final: index.isFinal(b))
        BlockLayoutCache.shared.put(key(b), out)
        LongTextStats.count(.blocksMeasured)
        return out
    }

    /// Measure the unmeasured blocks holding these lines, off main.
    func require(lines: Range<Int>) {
        guard index.ready, !lines.isEmpty, blockCount > 0 else { return }
        let a = block(containingLine: lines.lowerBound), b = block(containingLine: lines.upperBound - 1)
        require(blocks: a..<(b + 1))
    }
    func require(blocks: Range<Int>) {
        let todo = state.withLock { s -> [Int] in
            var todo: [Int] = []
            for b in blocks where !(s.exact[checked: b] ?? true) && !s.pending.keys.contains(b) && !s.inFlight.contains(b) { s.inFlight.insert(b); todo.append(b) }
            return todo
        }
        guard !todo.isEmpty else { return }
        // Chunks of 8 blocks per operation (fewer queue hops).
        for i in stride(from: 0, to: todo.count, by: 8) {
            let chunk = Array(todo.dropFirst(i).prefix(8)) // no range subscript
            LongTextLayout.measureQueue.addOperation { [weak self] in
                guard let self, !self.retired else { return }
                for b in chunk { _ = self.blockLayout(b) }
            }
        }
    }

    /// Measure blocks now (tests).
    func measureNow(_ blocks: Range<Int>, reuse: BlockLayout? = nil) {
        for b in blocks { _ = blockLayout(b, reuse: b == blocks.lowerBound ? reuse : nil) }
        _ = applyPending()
    }

    func report(_ b: Int, _ n: Int) {
        let fresh = state.withLock { s -> Bool in
            s.inFlight.remove(b)
            let fresh = !(s.exact[checked: b] ?? true) && !s.pending.keys.contains(b) // checked
            if fresh { s.pending.updateValue(Int32(clamping: n), forKey: b) }
            return fresh
        }
        if fresh { LongTextCenter.schedule(self) }
    }

    /// Main thread: published counts take the measured ones. Returns whether a height changed.
    @discardableResult
    func applyPending() -> Bool {
        let (changed, tiles) = state.withLock { s -> (Bool, [PendingTile]) in
            var changed = false
            for (b, n) in s.pending where !(s.exact[checked: b] ?? true) { // checked
                if s.tree.values[checked: b] != n { changed = true }
                s.tree.set(b, n)
                if let slot = s.exact.checkedIndex(b) { s.exact[slot] = true }
                s.measured += 1
            }
            s.pending.removeAll()
            let tiles = s.pendingTiles
            s.pendingTiles.removeAll()
            return (changed, tiles)
        }
        // Tiles drawn with the measurement: in the cache before the new height is laid out.
        // (Keyed by scale too: tiles of a view at another scale stay out of this view's lookups.)
        let generation = Fixture.paletteGeneration
        for t in tiles where t.key.palette == generation { TileCache.shared.put(t.key, t.image.value) }
        return changed
    }
    var hasPending: Bool { state.withLock { !$0.pending.isEmpty || !$0.pendingTiles.isEmpty } }

    // MARK: Anchors (text-local y: 0 at the first line's slot top)

    struct Anchor { var start: Int; var dy: CGFloat; var fraction: CGFloat }
    func anchor(atTextY y: CGFloat) -> Anchor {
        let lh = Fixture.lineHeight
        let frac = y / max(1, textHeight)
        guard index.ready, blockCount > 0 else { return Anchor(start: -1, dy: 0, fraction: frac) }
        let line = CrashGuard.int(floor(max(0, y) / lh), in: CrashGuard.countRange) // no trap on NaN
        let b = block(containingLine: line)
        return Anchor(start: index.starts[checked: b] ?? -1, dy: y - CGFloat(firstLine(ofBlock: b)) * lh, fraction: frac)
    }
    func textY(of a: Anchor) -> CGFloat {
        guard index.ready, a.start >= 0, blockCount > 0 else { return a.fraction * textHeight }
        var lo = 0, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (index.starts[checked: mid] ?? .max) <= a.start { lo = mid } else { hi = mid - 1 } // checked
        }
        return CGFloat(firstLine(ofBlock: lo)) * Fixture.lineHeight + a.dy
    }

    // MARK: Selection, copy, accessibility (UTF-16 offsets of the whole text)

    /// Selection length: the UTF-16 length (plain), or the end of the last block's slot (markdown).
    var selectionLength: Int { index.selStarts.last ?? 0 }
    /// The selectable string of the block holding a selection offset, and its base offset
    /// (word and paragraph rules). Plain: the block's source; markdown: its display string.
    func selectionBlock(_ offset: Int) -> (NSString, Int) {
        let b = index.block(sel: max(0, min(offset, max(0, selectionLength - 1))))
        return (selectionString(b), index.selStarts[checked: b] ?? 0)
    }
    func selectionBlockIndex(_ offset: Int) -> Int { index.block(sel: max(0, min(offset, max(0, selectionLength - 1)))) }
    func selectionString(_ b: Int) -> NSString { markdown ? blockLayout(b).string : index.blockString(b) }

    /// Markdown block geometry: text-local y of the block's top (MarkdownLayout y = padY + local).
    private func mdTop(_ b: Int) -> CGFloat { CGFloat(firstLine(ofBlock: b)) * Fixture.lineHeight }

    /// Text offset at a text-local point (x from the text's left edge).
    func offset(at p: CGPoint) -> Int {
        guard index.ready, blockCount > 0 else { return 0 }
        let line = max(0, min(totalLines - 1, CrashGuard.int(floor(p.y / Fixture.lineHeight), in: CrashGuard.countRange)))
        let b = block(containingLine: line)
        let bl = blockLayout(b)
        if let md = bl.md {
            let local = CGPoint(x: p.x + Fixture.bubblePadX, y: p.y - mdTop(b) + Fixture.bubblePadY)
            return (index.selStarts[checked: b] ?? 0) + min(md.length, md.offset(at: local))
        }
        let j = max(0, min(bl.lines.count - 1, line - firstLine(ofBlock: b)))
        guard let r = bl.lines[checked: j] else { return index.selStarts[checked: b] ?? 0 } // a block with no lines
        let attr = NSAttributedString(string: bl.string.substring(with: r), attributes: [.font: Fixture.bodyFont])
        let ct = CTLineCreateWithAttributedString(attr)
        var i = CTLineGetStringIndexForPosition(ct, CGPoint(x: p.x, y: 0))
        if i == kCFNotFound { i = 0 }
        return (index.selStarts[checked: b] ?? 0) + r.location + min(i, r.length)
    }

    /// Selection rects (text-local) of `range`, only for lines in `visible` (text-local y).
    func rects(for range: NSRange, visible: ClosedRange<CGFloat>) -> [CGRect] {
        guard index.ready, blockCount > 0, range.length > 0 else { return [] }
        let lh = Fixture.lineHeight
        let l0 = max(0, CrashGuard.int(floor(visible.lowerBound / lh), in: CrashGuard.countRange)) // no trap on NaN
        let l1 = min(totalLines, CrashGuard.int(ceil(visible.upperBound / lh), in: CrashGuard.countRange))
        guard l0 < l1 else { return [] }
        var out: [CGRect] = []
        var line = l0
        while line < l1 {
            let b = block(containingLine: line)
            let first = firstLine(ofBlock: b)
            let bl = blockLayout(b)
            let base = index.selStarts[checked: b] ?? 0
            if let md = bl.md {
                let top = CGFloat(first) * lh
                let local = NSRange(location: range.location - base, length: range.length)
                let lo = max(0, local.location), hi = min(md.length, NSMaxRange(local))
                if lo < hi {
                    let v0 = max(visible.lowerBound, top) - top + Fixture.bubblePadY, v1 = min(visible.upperBound, CGFloat(l1) * lh) - top + Fixture.bubblePadY
                    for r in md.selectionRects(NSRange(location: lo, length: max(0, hi - lo)), visible: v0...max(v0, v1)) {
                        out.append(r.offsetBy(dx: -Fixture.bubblePadX, dy: top - Fixture.bubblePadY))
                    }
                }
                // Next block from the published counts, as the plain branch does: blockLayout reports
                // a measured count to main later (report -> LongTextCenter), so until then
                // first + lineCount can stop inside this block's estimated slot, and the loop drew
                // this block again and again (duplicate rects; minutes for a 70 KB report, headless).
                if b + 1 >= blockCount { break }
                line = max(first + max(1, bl.lineCount), firstLine(ofBlock: b + 1))
                continue
            }
            for (j, lr) in bl.lines.enumerated().dropFirst(max(0, line - first)) { // no range that can invert
                let gl = first + j
                if gl >= l1 { break }
                let lineRange = NSRange(location: base + lr.location, length: lr.length)
                // A hard line end owns its newline; a soft wrap does not (the next line starts there).
                let soft = bl.lines.dropFirst(j + 1).first.map { $0.location == NSMaxRange(lr) } ?? false
                let s = max(range.location, lineRange.location), e = min(NSMaxRange(range), NSMaxRange(lineRange) + (soft ? 0 : 1))
                if s < e || (lr.length == 0 && NSLocationInRange(lineRange.location, range)) {
                    let attr = NSAttributedString(string: bl.string.substring(with: lr), attributes: [.font: Fixture.bodyFont])
                    let ct = CTLineCreateWithAttributedString(attr)
                    let x0 = ct.offset(forStringIndex: max(0, s - lineRange.location))
                    let x1 = e > NSMaxRange(lineRange) ? (bl.widths[checked: j] ?? 0) + 4 : ct.offset(forStringIndex: min(lr.length, e - lineRange.location))
                    out.append(CGRect(x: x0, y: CGFloat(gl) * lh, width: max(1, x1 - x0), height: lh))
                }
            }
            line = first + max(1, bl.lines.count)
            if b + 1 >= blockCount { break }
            line = max(line, firstLine(ofBlock: b + 1))
        }
        return out
    }

    /// Text in a selection range (Copy, accessibility value ranges): the source (plain) or the
    /// display strings of the blocks (markdown: a table copies as TSV, code exactly).
    func substring(_ range: NSRange) -> String {
        guard index.ready, blockCount > 0, range.length > 0 else { return "" }
        var out = ""
        var b = index.block(sel: range.location)
        while b < blockCount, let base = index.selStarts[checked: b], base < NSMaxRange(range) { // checked
            let s = selectionString(b)
            let lo = max(0, range.location - base), hi = min(s.length, NSMaxRange(range) - base)
            if lo < hi { out += s.substring(with: NSRange(location: lo, length: hi - lo)) }
            b += 1
        }
        return out
    }
}

/// cmux: the counters live in LongTextCenter's lock (the measure threads bumped plain globals;
/// p10-stability-040): a bump or a read from any thread.
enum LongTextStats {
    enum Counter: Sendable { case blocksMeasured, publishes, indexBuilds, streamExtends }
    struct Counts: Sendable {
        var blocksMeasured = 0, publishes = 0, indexBuilds = 0, streamExtends = 0
        var lastFoldMs: [String: Double] = [:]
        mutating func count(_ counter: Counter) {
            switch counter {
            case .blocksMeasured: blocksMeasured += 1
            case .publishes: publishes += 1
            case .indexBuilds: indexBuilds += 1
            case .streamExtends: streamExtends += 1
            }
        }
    }
    /// One more of `counter`.
    static func count(_ counter: Counter) { LongTextCenter.lock.withLock { $0.stats.count(counter) } }
    static var blocksMeasured: Int { LongTextCenter.lock.withLock { $0.stats.blocksMeasured } }
    static var publishes: Int { LongTextCenter.lock.withLock { $0.stats.publishes } }
    static var indexBuilds: Int { LongTextCenter.lock.withLock { $0.stats.indexBuilds } }
    static var streamExtends: Int { LongTextCenter.lock.withLock { $0.stats.streamExtends } }
    /// Phases of the last fold change (ms), for the bench.
    static var lastFoldMs: [String: Double] {
        get { LongTextCenter.lock.withLock { $0.stats.lastFoldMs } }
        set { LongTextCenter.lock.withLock { $0.stats.lastFoldMs = newValue } }
    }
}

/// Main-thread delivery of measured line counts, in batches. `handler(lineages, apply)`
/// must call `apply` once (the window view keeps its anchor around it).
enum LongTextCenter {
    typealias Handler = (Set<Int>, () -> Void) -> Void
    /// cmux: the window view's handler as lock state (p10-stability-040). It holds the view, so it
    /// is not Sendable; it cannot be main-actor while its setter, MessagesWindowView.init, is not.
    // crash-allow: set on the main thread (MessagesWindowView.init) and called only by publish, which runs on main
    fileprivate struct MainHandler: @unchecked Sendable { let call: Handler }
    /// Set and called on the main thread only.
    static var handler: Handler? {
        get { lock.withLock { $0.handler }?.call }
        set {
            let held = newValue.map(MainHandler.init(call:))
            lock.withLock { $0.handler = held }
        }
    }
    /// cmux: the batch, the handler and the counters behind one checked lock (they were globals,
    /// the batch under an NSLock). Lock carve-out: the measure threads add to the batch and count,
    /// main takes the batch; none does work under the lock.
    fileprivate struct State: Sendable {
        var batch = Batch()
        var handler: MainHandler?
        var stats = LongTextStats.Counts()
    }
    fileprivate struct Batch: Sendable {
        var dirty: [ObjectIdentifier: LongTextLayout] = [:]
        var replaced: [@Sendable () -> Void] = []
        var replacedLineages = Set<Int>()
        var scheduled = false
    }
    fileprivate static let lock = OSAllocatedUnfairLock(initialState: State())

    static func schedule(_ l: LongTextLayout) {
        let go = lock.withLock { s -> Bool in
            s.batch.dirty.updateValue(l, forKey: ObjectIdentifier(l)) // dictionary write
            defer { s.batch.scheduled = true }
            return !s.batch.scheduled
        }
        if go { DispatchQueue.main.async { publish() } }
    }
    /// `apply` runs on the main thread, in the next publish.
    static func scheduleReplace(lineage: Int, _ apply: @escaping @Sendable () -> Void) {
        let go = lock.withLock { s -> Bool in
            s.batch.replaced.append(apply)
            s.batch.replacedLineages.insert(lineage)
            defer { s.batch.scheduled = true }
            return !s.batch.scheduled
        }
        if go { DispatchQueue.main.async { publish() } }
    }

    static func publish() {
        let taken = lock.withLock { s -> Batch in
            defer { s.batch = Batch() }
            return s.batch
        }
        let ls = Array(taken.dirty.values).filter { !$0.retired }
        let rs = taken.replaced
        var lineages = taken.replacedLineages
        lineages.formUnion(ls.map(\.index.lineage))
        guard !lineages.isEmpty else { return }
        LongTextStats.count(.publishes)
        let apply = {
            rs.forEach { $0() }
            ls.forEach { $0.applyPending() }
        }
        if let h = handler { h(lineages, apply) } else { apply() }
    }
}

/// Text to index and layouts (thread safe). Finds a streamed text's previous index by prefix.
/// cmux: checked `Sendable` (p10-stability-055): the maps, the clock and the lineage serial are one lock
/// state (they were vars under an NSLock in an unchecked class, and the serial was bumped outside it);
/// hashing, byte compares, index builds and layouts run outside the lock, and a layout is marked retired
/// after the lock is released.
final class LongTextStore: Sendable {
    static let shared = LongTextStore()
    private struct Addr: Hashable { var base: UInt; var count: Int }
    private struct Print: Hashable { var count: Int; var head: Int; var tail: Int }
    private struct State: Sendable {
        var byAddr: [Addr: LongTextIndex] = [:]
        var byPrint: [Print: LongTextIndex] = [:]
        var byHead: [Int: LongTextIndex] = [:]
        /// Per index: layouts by width, negative widths for markdown shown as source.
        var layouts: [ObjectIdentifier: [CGFloat: LongTextLayout]] = [:]
        var recent: [ObjectIdentifier: Int] = [:]
        var tick = 0
        var lineageSerial = 0
    }
    // Lock carve-out: rows on the loader queue and main look up and register indexes and layouts; no work under the lock.
    private let state = Mutex(State())
    static let maxIndexes = 12
    static let syncBytes = 512 << 10

    func size(_ text: String, width: CGFloat) -> CGSize { layout(text, width: width).size }
    /// The row size of a message's long text part: folded (LongTextFold) or full.
    /// `scale`: the view's (the balloon width ends on its device pixels).
    func size(_ text: String, width: CGFloat, message id: ID, markdown: Bool, scale: CGFloat = Fixture.renderScale) -> CGSize {
        let l = layout(text, width: width, message: id, markdown: markdown)
        if LongTextFold.isFolded(id, l) { return LongTextFold.size(l, scale: scale) }
        // Expanded: the "Show less" band follows the last line.
        let full = l.size(scale: scale)
        if LongTextFold.isFoldable(l) { return CGSize(width: full.width, height: full.height + LongTextFold.bandHeight) }
        return full
    }

    /// The layout of a long text at a width. Markdown tiles only for a message the host marked
    /// markdown (`markdown`, Message.format; plain by default) and not shown as source
    /// (MarkdownStore.showsSource); otherwise a markdown index is laid out as plain text.
    func layout(_ text: String, width: CGFloat, message: ID? = nil, markdown: Bool = false) -> LongTextLayout {
        // index(for:) builds one when asked to; an unregistered index stands in.
        let idx = index(for: text) ?? LongTextIndex.build(text, lineage: 0)
        let md = idx.markdown && markdown && !(message.map { MarkdownStore.shared.showsSource($0) } ?? false)
        let wk = md || !idx.markdown ? width : -width
        let id = ObjectIdentifier(idx)
        let (found, carry) = state.withLock { s -> (LongTextLayout?, LongTextLayout?) in
            s.tick += 1
            s.recent.updateValue(s.tick, forKey: id) // dictionary write
            if let l = s.layouts[id]?[wk] { return (l, nil) }
            return (nil, s.layouts[id]?.values.first { $0.markdown == md })
        }
        if let found { return found }
        let l = LongTextLayout(index: idx, width: width, carry: carry?.column == Metrics(width: width).maxTextWidth ? carry : nil, markdown: md)
        // cmux: a thread that laid out the same width first keeps its layout (every caller gets one), and
        // this one is retired with the layouts it would have pushed out (it was left measuring, unregistered).
        let (kept, dropped) = state.withLock { s -> (LongTextLayout, [LongTextLayout]) in
            var per = s.layouts[id] ?? [:]
            if let first = per[wk] { return (first, [l]) }
            var dropped: [LongTextLayout] = []
            if per.count >= 3 { dropped = Array(per.values); per.removeAll() }
            per.updateValue(l, forKey: wk) // dictionary write
            s.layouts[id] = per
            return (l, dropped)
        }
        dropped.forEach { $0.retired = true }
        return kept
    }

    /// cmux: the layouts registered for a text's index now, without registering anything (tests).
    func registeredLayouts(_ text: String) -> [LongTextLayout] { index(for: text, create: false).map(layoutsOf) ?? [] }

    /// The lineage of a text if it is indexed.
    func lineage(_ text: String) -> Int? { index(for: text, create: false)?.lineage }

    /// cmux: lineages this store issued, one per index built from a text's start (tests: unlike the
    /// process-wide LongTextStats, other stores on other threads never move it).
    var lineagesIssued: Int { state.withLock { $0.lineageSerial } }

    private static func print(_ p: UnsafeBufferPointer<UInt8>) -> Print {
        var h = Hasher(), t = Hasher()
        // SAFETY: p is the caller's buffer, valid for this call; prefix(k) and suffix(k) are clamped to it, so each
        // rebased slice lies inside it, and the hashers copy the bytes and keep no pointer.
        let n = unsafe p.count, k = min(n, 1024)
        unsafe h.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: p.prefix(k)))) // no range subscripts
        unsafe t.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: p.suffix(k))))
        return Print(count: n, head: h.finalize(), tail: t.finalize())
    }
    private static func head(_ p: UnsafeBufferPointer<UInt8>) -> Int {
        var h = Hasher()
        // SAFETY: as `print`: the clamped prefix lies inside the caller's buffer, which the hasher copies.
        unsafe h.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: p.prefix(512)))) // no range subscript
        return h.finalize()
    }

    /// cmux: whether index `i` holds exactly the bytes of `p`.
    private static func sameBytes(_ i: LongTextIndex, _ p: UnsafeBufferPointer<UInt8>) -> Bool {
        i.withBytes { q in // no force unwraps
            // SAFETY: q (the index's text) and p (the caller's buffer) are valid during this call; memcmp reads
            // q.count bytes of each, which both hold (equal counts, the first guard).
            guard unsafe q.count == p.count else { return false }
            guard let qb = unsafe q.baseAddress, let pb = unsafe p.baseAddress else { return unsafe q.count == 0 }
            return unsafe memcmp(qb, pb, q.count) == 0
        }
    }

    private func index(for text: String, create: Bool = true) -> LongTextIndex? {
        var t = text
        if t.utf8.withContiguousStorageIfAvailable({ _ in true }) == nil { t.makeContiguousUTF8() }
        return t.utf8.withContiguousStorageIfAvailable { p -> LongTextIndex? in
            // SAFETY: p is the text's contiguous UTF-8, valid inside this closure, and no pointer leaves it: the
            // address is kept only as an integer cache key, and every read below is bounded by p.count.
            let addr = unsafe Addr(base: UInt(bitPattern: p.baseAddress), count: p.count)
            if let i = state.withLock({ $0.byAddr[addr] }) { return i }
            let pr = unsafe LongTextStore.print(p)
            // cmux: the print (length, first and last KiB) only names a candidate; its bytes decide. A
            // same-length edit in the middle of a long text has the old text's print and drew the old text.
            if let i = state.withLock({ $0.byPrint[pr] }), unsafe LongTextStore.sameBytes(i, p) {
                // Still registered under that print (a register on another thread may have replaced it meanwhile).
                state.withLock { s in if s.byPrint[pr] === i { s.byAddr[addr] = i } }
                return i
            }
            let hd = unsafe LongTextStore.head(p)
            let prev = state.withLock { $0.byHead[hd] }
            guard create else { return nil }
            // Streaming: the same text with more at the end keeps every block but the last
            // (a plain stream that turns into markdown is indexed again from its start).
            // cmux: a stream whose end was rewritten (a Markdown style that closes rewrites its last
            // line, and can shorten the text a little) keeps every block before the change, and its
            // lineage (its tiles): a new index from the start cost every such token O(reply) on main
            // (plans/cmux-next/home-streaming-perf-DESIGN.md).
            if let prev, prev.ready, unsafe prev.count != p.count, unsafe p.count + 64 >= prev.count, prev.blockCount > 0,
               unsafe prev.markdown || !LongTextIndex.isMarkdown(String(decoding: UnsafeBufferPointer(rebasing: p.dropFirst(max(0, prev.starts.dropLast().last ?? 0))) /* the last block start, no index math */, as: UTF8.self)) {
                let last = prev.blockCount - 1
                let from = max(0, (prev.starts[checked: last] ?? 0) - 256) // checked
                // An append: the old text is the new one's start (the previous rule).
                let appended = unsafe prev.count < p.count && prev.withBytes { q in // no force unwraps
                    // SAFETY: q (the old text, prev.count bytes) and p (the new, longer one) are valid during this
                    // call; 0 <= from <= prev.count (a block start less 256, clamped at 0), so memcmp reads the
                    // prev.count - from bytes after from inside both.
                    guard let qb = unsafe q.baseAddress, let pb = unsafe p.baseAddress, unsafe from <= q.count else { return false }
                    return unsafe memcmp(qb + from, pb + from, prev.count - from) == 0
                }
                // cmux: else the last block whose start the texts share byte for byte (at least one block kept).
                var keepAt: Int? = appended ? last : nil
                if keepAt == nil {
                    var k = last
                    while k >= 1, keepAt == nil {
                        let end = prev.starts[checked: k] ?? 0 // checked
                        let shared = unsafe end <= p.count && prev.withBytes { q in // no force unwraps
                            // SAFETY: memcmp reads `end` bytes of each text: at most p.count (checked before the
                            // call) and q.count (checked here); both buffers are valid during this call.
                            guard let qb = unsafe q.baseAddress, let pb = unsafe p.baseAddress, unsafe end <= q.count else { return false }
                            return unsafe memcmp(qb, pb, end) == 0
                        }
                        if shared { keepAt = k }
                        k -= 1
                    }
                }
                if let keep = keepAt {
                    let i = LongTextIndex.build(t, lineage: prev.lineage, prefix: prev, keep: keep)
                    LongTextStats.count(.streamExtends)
                    let old = layoutsOf(prev)
                    register(i, addr: addr, print: pr, head: hd, replacing: prev)
                    // Layouts carry the measured blocks. The tail keeps its previous line count (and
                    // its tiles their pixels) until it is measured and its end tiles are drawn off
                    // main; then counts and tiles are published together (no empty tile, no main
                    // thread measurement).
                    for o in old {
                        let tailOffMain = LongText.offMainTail
                        let l = LongTextLayout(index: i, width: o.width, carry: o, markdown: o.markdown, provisional: tailOffMain ? keep : nil)
                        let iid = ObjectIdentifier(i), wk = o.markdown || !i.markdown ? o.width : -o.width
                        // cmux: a layout another thread registered for the new index meanwhile is retired, not left measuring.
                        let replaced = state.withLock { s in s.layouts[iid, default: [:]].updateValue(l, forKey: wk) }
                        replaced?.retired = true
                        if tailOffMain { l.measureTail(keep..<max(keep, i.blockCount)); continue } // never an inverted range
                        // The previous rule: the new tail is measured now (about 4 KB).
                        let reuse = BlockLayoutCache.shared.get(o.key(keep))
                        let tail = max(0, keep)..<max(max(0, keep), i.blockCount) // never an inverted range
                        if i.count - (i.starts[checked: tail.lowerBound] ?? 0) <= 16 * 1024 { l.measureNow(tail, reuse: reuse) } else { l.require(blocks: tail) }
                    }
                    return i
                }
            }
            let lineage = state.withLock { s -> Int in s.lineageSerial += 1; return s.lineageSerial }
            LongTextStats.count(.indexBuilds)
            if unsafe p.count <= LongTextStore.syncBytes {
                let i = LongTextIndex.build(t, lineage: lineage)
                // cmux: another thread that indexed the same text first keeps its index (registerFirst).
                return unsafe registerFirst(i, addr: addr, print: pr, head: hd, bytes: p)
            }
            // Large: a placeholder (estimated height, no tiles) until the scan finishes off main.
            let ph = LongTextIndex.placeholder(t, lineage: lineage)
            let registered = unsafe registerFirst(ph, addr: addr, print: pr, head: hd, bytes: p)
            guard registered === ph else { return registered } // cmux: that thread's scan replaces it
            let scanned = t // cmux: the scan takes a constant (a captured var is shared with this thread)
            DispatchQueue.global(qos: .userInitiated).async {
                let i = LongTextIndex.build(scanned, lineage: lineage)
                LongTextCenter.scheduleReplace(lineage: lineage) {
                    self.register(i, addr: addr, print: pr, head: hd, replacing: ph)
                }
            }
            return ph
        } ?? nil
    }

    private func layoutsOf(_ i: LongTextIndex) -> [LongTextLayout] {
        let id = ObjectIdentifier(i)
        return state.withLock { s in Array(s.layouts[id]?.values ?? [:].values) }
    }

    /// cmux: registers a new index of the bytes `p` unless another thread registered an index of the same
    /// bytes first, and returns the registered one. Threads that index one text at once each built an index
    /// and each registered it, the last one winning: the others' callers laid out on an index no lookup
    /// finds, so those layouts stayed measuring, never retired, and their entries were never evicted. The
    /// byte compare runs outside the lock; the register happens only if the print still names what was
    /// compared (else it compares again).
    private func registerFirst(_ i: LongTextIndex, addr: Addr, print: Print, head: Int,
                               bytes p: UnsafeBufferPointer<UInt8>) -> LongTextIndex {
        for _ in 0..<8 { // a retry only follows another thread's register of this print; never 8 in a row
            let seen = state.withLock { $0.byPrint[print] }
            if let seen, unsafe LongTextStore.sameBytes(seen, p) {
                // Taken only while still registered (a large text's scan may have replaced it meanwhile).
                let kept = state.withLock { s -> Bool in
                    guard s.byPrint[print] === seen else { return false }
                    s.byAddr[addr] = seen
                    return true
                }
                if kept { return seen }
                continue
            }
            let dropped = state.withLock { s -> [LongTextLayout]? in
                guard s.byPrint[print] === seen else { return nil }
                return LongTextStore.insert(i, into: &s, addr: addr, print: print, head: head, replacing: nil)
            }
            guard let dropped else { continue }
            dropped.forEach { $0.retired = true }
            return i
        }
        register(i, addr: addr, print: print, head: head, replacing: nil)
        return i
    }

    private func register(_ i: LongTextIndex, addr: Addr, print: Print, head: Int, replacing old: LongTextIndex?) {
        let dropped = state.withLock { s in
            LongTextStore.insert(i, into: &s, addr: addr, print: print, head: head, replacing: old)
        }
        dropped.forEach { $0.retired = true }
    }

    /// Registers `i` in the lock state (replacing `old`) and returns the layouts it dropped, for the caller
    /// to retire once the lock is released.
    private static func insert(_ i: LongTextIndex, into s: inout State, addr: Addr, print: Print, head: Int,
                               replacing old: LongTextIndex?) -> [LongTextLayout] {
        var dropped: [LongTextLayout] = []
        if let old {
            let oid = ObjectIdentifier(old)
            dropped += s.layouts[oid].map { Array($0.values) } ?? []
            s.layouts[oid] = nil
            s.recent.removeValue(forKey: oid) // dictionary write
            s.byAddr = s.byAddr.filter { $0.value !== old }
            s.byPrint = s.byPrint.filter { $0.value !== old }
        }
        s.byAddr[addr] = i
        s.byPrint[print] = i
        s.byHead[head] = i
        s.tick += 1
        s.recent.updateValue(s.tick, forKey: ObjectIdentifier(i)) // dictionary write
        // Bounded: the least recently used indexes go (their texts with them).
        let live = Set(s.byAddr.values.map { ObjectIdentifier($0) })
        if live.count > LongTextStore.maxIndexes {
            let recent = s.recent
            let drop = Set(live.sorted { (recent[$0] ?? 0) < (recent[$1] ?? 0) }.prefix(live.count - LongTextStore.maxIndexes))
            s.byAddr = s.byAddr.filter { !drop.contains(ObjectIdentifier($0.value)) }
            s.byPrint = s.byPrint.filter { !drop.contains(ObjectIdentifier($0.value)) }
            s.byHead = s.byHead.filter { !drop.contains(ObjectIdentifier($0.value)) }
            for d in drop { dropped += s.layouts[d].map { Array($0.values) } ?? []; s.layouts[d] = nil; s.recent.removeValue(forKey: d) }
        }
        return dropped
    }

    var indexCount: Int { state.withLock { s in Set(s.byAddr.values.map { ObjectIdentifier($0) }).count } }
}

/// Collapsed long messages (shared/LONG-MESSAGES.md, product rule): a message taller than
/// 3 screens shows its first and last 40 lines and a "Show all N lines" band between them,
/// until the band is clicked (`MessagesWindowView.expandLongText`). The folded height is
/// fixed (80 lines and the band), so measurement never changes it.
enum LongTextFold {
    static let headLines = 40, tailLines = 40
    /// cmux: the folded head and tail for `total` measured lines, valid for any total. The fold
    /// is decided from the scan's estimate and the measured total can be smaller (fewer than
    /// `headLines`): `tailFirst..<total` then had lowerBound > upperBound and trapped.
    static func head(_ total: Int) -> Range<Int> { 0..<min(max(0, total), headLines) }
    static func tailFirst(_ total: Int) -> Int { min(max(0, total), max(headLines, total - tailLines)) }
    /// 3 screens (the 1041 pt window).
    static var maxLines: Int { CrashGuard.int(3 * 1041 / Fixture.lineHeight, in: CrashGuard.countRange) }
    static var bandHeight: CGFloat { 2 * Fixture.lineHeight }
    static let defaultsKey = "messageslab.collapseLongMessages"
    /// Setting (UserDefaults, default on). `--no-collapse` turns it off for one run.
    private static let disabledByArgument = ProcessInfo.processInfo.arguments.contains("--no-collapse")
    static var enabled: Bool {
        if disabledByArgument { return false }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
    // cmux: a checked lock around the set (it was a global under an NSLock; p10-stability-040).
    // Lock carve-out: rows measure on the loader queue and main; one set read or write.
    private static let expanded = OSAllocatedUnfairLock(initialState: Set<ID>())
    /// Session only: expanded messages are not stored (they fold again at launch).
    static func expand(_ id: ID) { expanded.withLock { _ = $0.insert(id) } }
    static func collapse(_ id: ID) { expanded.withLock { _ = $0.remove(id) } }
    /// A text still scanned off main (above 512 KB, thousands of lines) folds from its first
    /// frame, so the end of the scan changes no height.
    static func isFoldable(_ l: LongTextLayout) -> Bool { enabled && (l.index.ready ? l.estimatedLines > maxLines : l.totalLines > maxLines) }
    static func isExpanded(_ id: ID) -> Bool { expanded.withLock { $0.contains(id) } }
    static func isFolded(_ id: ID, _ l: LongTextLayout) -> Bool { isFoldable(l) && !isExpanded(id) }
    static func size(_ l: LongTextLayout, scale: CGFloat = Fixture.renderScale) -> CGSize {
        CGSize(width: Sizing.textBalloonWidth(l.column, column: l.column, scale: scale),
               height: CGFloat(headLines + tailLines) * Fixture.lineHeight + bandHeight + 2 * Fixture.bubblePadY)
    }
    static func label(_ n: Int) -> String {
        String(format: MessagesLabLocalization.string("longtext.showAll", "Show all %lld lines"), n)
    }
    static var lessLabel: String { MessagesLabLocalization.string("longtext.showLess", "Show less") }
}
