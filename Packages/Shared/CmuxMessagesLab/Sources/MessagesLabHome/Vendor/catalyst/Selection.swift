#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Transcript text selection in MODEL space (selection lane, SELECTION.md).
//
// A position is (message sequence in the whole history, part, UTF-16 offset in the
// part's display string). The sequence is stable for the life of the store: deletes are
// tombstones and new messages append, so a position survives cell recycling, paging
// (rows evicted and loaded again), long-message tiling and folding, live inserts and
// edits (offsets clamp to the current text), and resize reflow (offsets are text, not
// points). The views only map points to positions and positions to rects on screen.

/// A text position in the transcript.
struct SelPos: Comparable, Hashable, CustomStringConvertible {
    /// Absolute message index in the history (State.windowStart + loaded index).
    var seq: Int
    var part: Int
    /// UTF-16 offset in the part's display string; non-text parts have length 1.
    var offset: Int
    static func < (a: SelPos, b: SelPos) -> Bool { (a.seq, a.part, a.offset) < (b.seq, b.part, b.offset) }
    var description: String { "\(seq).\(part).\(offset)" }
}

/// What a click count selects and a drag extends by.
enum SelUnit { case character, word, paragraph }

/// A selection: the unit the gesture started with, the range it started on (a word or
/// paragraph for a double or triple click, empty for a single press), and the current
/// range (lo < hi when anything is selected).
struct SelState: Equatable {
    var unit: SelUnit = .character
    var origin: ClosedRange<SelPos>
    var lo: SelPos
    var hi: SelPos
    var isEmpty: Bool { lo >= hi }

    init(unit: SelUnit, origin: ClosedRange<SelPos>) {
        self.unit = unit; self.origin = origin; lo = origin.lowerBound; hi = origin.upperBound
    }

    /// Extend to a focus unit (AppKit: the original word or paragraph stays selected,
    /// the other end moves by whole units).
    mutating func extend(to focus: ClosedRange<SelPos>) {
        if focus.lowerBound < origin.lowerBound { lo = focus.lowerBound; hi = origin.upperBound }
        else { lo = origin.lowerBound; hi = max(origin.upperBound, focus.upperBound) }
    }

    /// Selected range of one part (nil when the part is outside), clamped to `length`.
    func range(seq: Int, part: Int, length: Int) -> NSRange? {
        guard !isEmpty else { return nil }
        let a = SelPos(seq: seq, part: part, offset: 0), b = SelPos(seq: seq, part: part, offset: Int.max)
        guard hi > a, lo < b else { return nil }
        let s = lo.seq == seq && lo.part == part ? min(lo.offset, length) : 0
        let e = hi.seq == seq && hi.part == part ? min(hi.offset, length) : length
        return e > s ? NSRange(location: s, length: e - s) : nil
    }
}

// MARK: Geometry of the text rows

/// The display string of a part for selection and copy: text parts are their text, every
/// other part is one atomic unit (length 1) that copies as a placeholder (SELECTION.md).
enum SelText {
    static func length(_ part: Part) -> Int {
        if case let .text(t, _) = part { return (t as NSString).length }
        return 1
    }
    static func isText(_ part: Part) -> Bool { if case .text = part { return true }; return false }

    static var photo: String { String(localized: "selection.copy.photo", defaultValue: "[Photo]") }
    static var video: String { String(localized: "selection.copy.video", defaultValue: "[Video]") }
    static var audio: String { String(localized: "selection.copy.audio", defaultValue: "[Audio Message]") }
    static var contact: String { String(localized: "selection.copy.contact", defaultValue: "[Contact]") }
    /// "[Attachment: %@]"
    static var attachmentFormat: String { String(localized: "selection.copy.attachment", defaultValue: "[Attachment: %@]") }
    /// "[Location: %@]"
    static var locationFormat: String { String(localized: "selection.copy.location", defaultValue: "[Location: %@]") }
    static var location: String { String(localized: "selection.copy.locationBare", defaultValue: "[Location]") }
    /// Sender header before each sender's run when a selection spans several senders: "%@:".
    static var senderFormat: String { String(localized: "selection.copy.sender", defaultValue: "%@:") }

    /// Placeholder of a non-text part.
    static func placeholder(_ part: Part) -> String {
        switch part {
        case let .text(t, _): return t
        case let .link(url, _, _, _, _): return url
        case let .attachment(a):
            switch a.kind {
            case "image": return photo
            case "video": return video
            case "audio", "voiceMemo": return audio
            case "contact": return contact
            default: return String(format: attachmentFormat, a.fileName)
            }
        case let .location(_, _, title, _):
            return title.map { String(format: locationFormat, $0) } ?? location
        case let .custom(c): return CustomRows.plainText(c)
        }
    }
}

/// Short text rows: the row's TextLayout, drawn at (bubblePadX, bubblePadY + 16 pt per line)
/// with the body font and kern (RowDraw). A wrapper: TextLayout's own `link(at:)` is
/// text-local, the protocol's is body-local.
struct ShortTextGeometry: RowTextGeometry {
    let tl: TextLayout
    private var text: String { tl.text }
    private var lines: [TextLayout.Line] { tl.lines }
    var length: Int { (text as NSString).length }
    func substring(_ r: NSRange) -> String {
        let ns = text as NSString
        let lo = max(0, min(r.location, ns.length)), hi = max(lo, min(NSMaxRange(r), ns.length))
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }
    /// Line i's CTLine with the drawing attributes (kern included: caret x matches the glyphs).
    func ctLine(_ i: Int) -> CTLine {
        let attr = tl.attributed(color: .white, linkColor: .white)
        return CTLineCreateWithAttributedString(attr.attributedSubstring(from: lines[i].range))
    }
    func offset(at p: CGPoint) -> Int {
        let x = p.x - Fixture.bubblePadX, y = p.y - Fixture.bubblePadY
        if y < 0 { return x <= 0 ? 0 : offsetInLine(0, x: x) }
        if y >= CGFloat(lines.count) * Fixture.lineHeight { return length }
        return offsetInLine(min(lines.count - 1, Int(floor(y / Fixture.lineHeight))), x: x)
    }
    private func offsetInLine(_ i: Int, x: CGFloat) -> Int {
        let r = lines[i].range
        guard r.length > 0 else { return r.location }
        let idx = CTLineGetStringIndexForPosition(ctLine(i), CGPoint(x: max(0, x), y: 0))
        return idx == kCFNotFound ? r.location : r.location + min(max(0, idx), r.length)
    }
    func selectionRects(_ r: NSRange, visible: ClosedRange<CGFloat>) -> [CGRect] {
        guard r.length > 0 else { return [] }
        let ns = text as NSString
        var out: [CGRect] = []
        for (i, line) in lines.enumerated() {
            let y = Fixture.bubblePadY + CGFloat(i) * Fixture.lineHeight
            guard y + Fixture.lineHeight >= visible.lowerBound, y <= visible.upperBound else { continue }
            let lr = line.range
            // A hard line end owns its newline (selected: a short tail); a soft wrap does not.
            let hard = NSMaxRange(lr) < ns.length && ns.character(at: NSMaxRange(lr)) == 10
            let s = max(r.location, lr.location), e = min(NSMaxRange(r), NSMaxRange(lr) + (hard ? 1 : 0))
            guard s < e || (lr.length == 0 && NSLocationInRange(lr.location, r)) else { continue }
            var x0: CGFloat = 0, x1: CGFloat = SelectionLook.newlineTail
            if lr.length > 0 {
                let ct = ctLine(i)
                x0 = CTLineGetOffsetForStringIndex(ct, s - lr.location, nil)
                x1 = e > NSMaxRange(lr) ? line.width + SelectionLook.newlineTail
                    : CTLineGetOffsetForStringIndex(ct, min(lr.length, e - lr.location), nil)
            }
            out.append(CGRect(x: Fixture.bubblePadX + x0, y: y, width: max(1, x1 - x0), height: Fixture.lineHeight))
        }
        return out
    }
    func wordRange(at offset: Int) -> NSRange { SelWords.word(in: text as NSString, at: offset) }
    func paragraphRange(at offset: Int) -> NSRange { SelWords.paragraph(in: text as NSString, at: offset) }
    func link(at p: CGPoint) -> String? { tl.link(at: CGPoint(x: p.x - Fixture.bubblePadX, y: p.y - Fixture.bubblePadY)) }
    func pasteboardItems(_ r: NSRange) -> [(type: String, data: Data)] { [] }
}

/// Long (tiled) text rows: LongTextLayout's text-local geometry moved by the padding;
/// a folded row shows its head lines, the band, then its tail lines (TiledBody.update).
struct LongTextGeometry: RowTextGeometry {
    let layout: LongTextLayout
    let folded: Bool
    var length: Int { layout.index.u16Starts.last ?? 0 }
    private var lh: CGFloat { Fixture.lineHeight }
    /// Folded: text line of a text-local display y, and the display shift of the tail.
    private var tailFirst: Int { max(LongTextFold.headLines, layout.totalLines - LongTextFold.tailLines) }
    private var tailShift: CGFloat { CGFloat(LongTextFold.headLines - tailFirst) * lh + LongTextFold.bandHeight }
    private func textY(display y: CGFloat) -> CGFloat {
        guard folded else { return y }
        let headEnd = CGFloat(LongTextFold.headLines) * lh
        if y < headEnd { return y }
        if y < headEnd + LongTextFold.bandHeight { return headEnd - 0.5 }
        return y - tailShift
    }
    func substring(_ r: NSRange) -> String { layout.substring(r) }
    func offset(at p: CGPoint) -> Int {
        let x = p.x - Fixture.bubblePadX, y = p.y - Fixture.bubblePadY
        if y < 0 { return 0 }
        if y >= layout.textHeight + (folded ? tailShift : 0) { return length }
        return layout.offset(at: CGPoint(x: max(0, x), y: textY(display: y)))
    }
    func selectionRects(_ r: NSRange, visible: ClosedRange<CGFloat>) -> [CGRect] {
        let v0 = visible.lowerBound - Fixture.bubblePadY, v1 = visible.upperBound - Fixture.bubblePadY
        let move = { (rs: [CGRect], dy: CGFloat) in rs.map { $0.offsetBy(dx: Fixture.bubblePadX, dy: Fixture.bubblePadY + dy) } }
        guard folded else { return move(layout.rects(for: r, visible: max(0, v0)...max(0, v1)), 0) }
        let headEnd = CGFloat(LongTextFold.headLines) * lh
        var out: [CGRect] = []
        if v0 < headEnd { out += move(layout.rects(for: r, visible: max(0, v0)...min(v1, headEnd - 1)), 0) }
        let t0 = max(CGFloat(tailFirst) * lh, v0 - tailShift), t1 = v1 - tailShift
        if t1 > t0 { out += move(layout.rects(for: r, visible: t0...t1), tailShift) }
        return out
    }
    /// Word and paragraph rules run on the block that holds the offset (blocks end at a
    /// line end, so a word never spans two blocks).
    func wordRange(at offset: Int) -> NSRange {
        let (s, base) = block(offset)
        let w = SelWords.word(in: s, at: offset - base)
        return NSRange(location: w.location + base, length: w.length)
    }
    func paragraphRange(at offset: Int) -> NSRange {
        var (s, base) = block(offset)
        var p = SelWords.paragraph(in: s, at: offset - base)
        // A paragraph may run past its block: join the next blocks until a newline.
        var b = layout.index.block(u16: offset)
        var end = NSMaxRange(p) + base
        while NSMaxRange(p) == s.length, s.length > 0, s.character(at: s.length - 1) != 10, b + 1 < layout.blockCount {
            b += 1
            s = layout.index.blockString(b); base = layout.index.u16Starts[b]
            p = SelWords.paragraph(in: s, at: 0)
            end = base + NSMaxRange(p)
        }
        let start = SelWords.paragraph(in: block(offset).0, at: offset - block(offset).1).location + block(offset).1
        return NSRange(location: start, length: end - start)
    }
    private func block(_ offset: Int) -> (NSString, Int) {
        let b = layout.index.block(u16: max(0, min(offset, max(0, length - 1))))
        return (layout.index.blockString(b), layout.index.u16Starts[b])
    }
    func link(at p: CGPoint) -> String? { nil }
    func pasteboardItems(_ r: NSRange) -> [(type: String, data: Data)] { [] }
}

extension PartRow {
    /// Selectable text geometry: markdown, else the short text layout, else the long
    /// (tiled) layout at the row's width. Nil for non-text parts (atomic units).
    func geometry(width: CGFloat) -> RowTextGeometry? {
        if let g = markdownGeometry { return g }
        if let text { return ShortTextGeometry(tl: text) }
        guard case let .text(t, _) = part else { return nil }
        let l = LongTextStore.shared.layout(t, width: width)
        return LongTextGeometry(layout: l, folded: LongTextFold.isFolded(ref.messageId, l))
    }
}

/// Word and paragraph boundaries (AppKit's double-click rules on the Mac; ICU word
/// boundaries elsewhere). Graphemes stay whole (emoji, CJK, combining marks).
enum SelWords {
    static func word(in s: NSString, at offset: Int) -> NSRange {
        guard s.length > 0 else { return NSRange(location: 0, length: 0) }
        let i = max(0, min(offset, s.length - 1))
        #if canImport(UIKit)
        let tok = CFStringTokenizerCreate(nil, s, CFRange(location: 0, length: s.length), kCFStringTokenizerUnitWordBoundary, nil)
        CFStringTokenizerGoToTokenAtIndex(tok, i)
        let r = CFStringTokenizerGetCurrentTokenRange(tok)
        if r.location != kCFNotFound { return NSRange(location: r.location, length: r.length) }
        return s.rangeOfComposedCharacterSequence(at: i)
        #else
        return NSAttributedString(string: s as String).doubleClick(at: i)
        #endif
    }
    /// The paragraph holding `offset`, with its newline (AppKit's triple-click).
    static func paragraph(in s: NSString, at offset: Int) -> NSRange {
        guard s.length > 0 else { return NSRange(location: 0, length: 0) }
        return s.paragraphRange(for: NSRange(location: max(0, min(offset, s.length - 1)), length: 0))
    }
}

/// Selection look constants (measured against real Messages; SELECTION.md).
enum SelectionLook {
    /// Width of the highlight past a selected hard line end.
    static var newlineTail: CGFloat = 4
}

// MARK: Copy

/// Formats a selection for the pasteboard as real Messages does (macOS 27; SELECTION.md "Copy",
/// takes sel-real-real-drag-in-bubble, -drag-cross-sender, -autoscroll-top):
/// - inside one part: exactly the selected substring (rich: the bubble font, 13 pt);
/// - across parts: one block per run of one sender, "Name:" then each part on its own line,
///   text parts indented by a tab, a photo or other attachment as an empty line in the plain
///   text (an attachment character in the rich text), runs separated by a blank line; lines end
///   with CR in the plain text and LF in the rich text, which has no font (Helvetica 12).
/// Deleted and unsent messages are skipped.
enum SelectionCopy {
    /// `isAttachment`: a file part (photo, video, audio, file): an empty line in the plain text.
    struct Piece: Equatable { var seq: Int; var sender: ID; var text: String; var isText: Bool; var isAttachment = false }

    /// Pieces of the selection from messages `msgs` (seq, message) in order.
    static func pieces(_ sel: SelState, _ msgs: [(Int, Message)]) -> [Piece] {
        var out: [Piece] = []
        for (seq, m) in msgs where seq >= sel.lo.seq && seq <= sel.hi.seq {
            guard m.deletedAt == nil, m.retractedAt == nil else { continue }
            for (pi, part) in m.parts.enumerated() {
                let len = SelText.length(part)
                guard let r = sel.range(seq: seq, part: pi, length: len) else { continue }
                if case let .text(t, _) = part {
                    out.append(Piece(seq: seq, sender: m.senderId, text: (t as NSString).substring(with: r), isText: true))
                } else {
                    var isFile = false
                    if case .attachment = part { isFile = true }
                    out.append(Piece(seq: seq, sender: m.senderId, text: SelText.placeholder(part), isText: false, isAttachment: isFile))
                }
            }
        }
        return out
    }

    /// Lines of the multi-part form: (text, isAttachment).
    private static func lines(_ pieces: [Piece], names: (ID) -> String) -> [[(String, Bool)]] {
        var runs: [[(String, Bool)]] = []
        var last: ID?
        for p in pieces {
            if p.sender != last { runs.append([(String(format: SelText.senderFormat, names(p.sender)), false)]); last = p.sender }
            // Messages: text parts get a tab; an attachment is its own (empty) line. Other parts
            // (a link card: its URL; locations, custom rows) copy their text with a tab like text.
            runs[runs.count - 1].append(p.isAttachment ? (p.text, true) : ("\t" + p.text, false))
        }
        return runs
    }

    static func plain(_ pieces: [Piece], names: (ID) -> String) -> String {
        guard pieces.count > 1 else { return pieces.first.map { $0.isText ? $0.text : $0.text } ?? "" }
        return lines(pieces, names: names).map { run in run.map { $0.1 ? SelectionLook.attachmentPlain($0.0) : $0.0 }.joined(separator: "\r") }
            .joined(separator: "\r\r")
    }

    static func rich(_ pieces: [Piece], names: (ID) -> String) -> NSAttributedString {
        guard pieces.count > 1 else {
            return NSAttributedString(string: pieces.first?.text ?? "", attributes: [.font: Fixture.bodyFont])
        }
        let s = lines(pieces, names: names).map { run in run.map { $0.1 ? "\u{FFFC}" : $0.0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        return NSAttributedString(string: s)
    }
}

extension SelText {
    static func isURL(_ s: String) -> Bool { s.hasPrefix("http://") || s.hasPrefix("https://") }
}

extension SelectionLook {
    /// An attachment's line in the plain text: empty, as Messages (its rich text carries the image).
    /// Set `placeholders` to write "[Photo]" and the like instead (SELECTION.md, decision).
    static var placeholders = false
    static func attachmentPlain(_ placeholder: String) -> String { placeholders ? placeholder : "" }
}
