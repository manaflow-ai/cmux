// cmux: pictures and files in the Home message box sit IN the text, at the
// caret, as in Messages and Notes (Lawrence 2026-10-19: "I still don't have
// inline images inside the typing area for the iMessage thing"). Not a
// vendored file.
//
// The model: the draft text holds one U+FFFC mark per draft attachment, in
// the same order as `Draft.attachments` (the reducer keeps the two in step).
// The field shows each mark as a `ComposeInlineAttachment`; a send strips the
// marks (`Draft.plainText`).
import AppKit

extension Draft {
    /// The character that stands for one attachment in the draft text
    /// (NSTextAttachment's own character).
    static let mark: Unicode.Scalar = "\u{FFFC}"

    /// The draft text without its attachment marks.
    var plainText: String { Draft.stripMarks(text) }

    /// One piece of a draft as it goes out (`pieces`).
    enum Piece: Equatable {
        /// A run of text between attachments, trimmed of the white space around it.
        case text(String)
        /// The attachment of one mark.
        case attachment(Attachment)
    }

    /// The draft in the field's order, as a send says it (Lawrence 2026-10-20: text, a picture
    /// and more text went out as the picture, then both texts run together): the text between
    /// the marks, each run trimmed of the white space around it (an empty run is left out), and
    /// each mark's attachment. Attachments with no mark (text and attachments out of step)
    /// follow at the end.
    var pieces: [Piece] {
        var out: [Piece] = []
        var run = String.UnicodeScalarView()
        var next = 0
        func flush() {
            let t = String(run).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.text(t)) }
            run = String.UnicodeScalarView()
        }
        for u in text.unicodeScalars {
            guard u == Draft.mark else { run.append(u); continue }
            flush()
            if let a = attachments[checked: next] { out.append(.attachment(a)) }
            next += 1
        }
        flush()
        out += attachments.dropFirst(next).map { .attachment($0) }
        return out
    }

    static func stripMarks(_ s: String) -> String {
        guard s.unicodeScalars.contains(mark) else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.lazy.filter { $0 != mark })
        return String(out)
    }

    /// The UTF-16 offsets of the marks, in order.
    static func markOffsets(_ s: String) -> [Int] {
        var offsets: [Int] = []
        var o = 0
        for u in s.utf16 {
            if u == 0xFFFC { offsets.append(o) }
            o += 1
        }
        return offsets
    }

    /// An attachment enters at the UTF-16 offset `at` of the text (nil or
    /// out of range: the end), in the attachments' order of the marks.
    mutating func insert(_ a: Attachment, at: Int?) {
        let ns = text as NSString
        let o = min(max(0, at ?? ns.length), ns.length)
        let marks = Draft.markOffsets(text)
        if marks.count == attachments.count {
            let index = marks.filter { $0 < o }.count
            attachments.insert(a, at: min(index, attachments.count))
        } else {
            attachments.append(a)
        }
        text = ns.replacingCharacters(in: NSRange(location: o, length: 0), with: String(Character(Draft.mark)))
    }

    /// An attachment leaves; its mark goes with it while the text and the
    /// attachments agree (after the person deleted the mark in the field,
    /// the text is already one mark short).
    mutating func remove(_ id: ID) {
        guard let k = attachments.firstIndex(where: { $0.id == id }) else { return }
        let marks = Draft.markOffsets(text)
        attachments.remove(at: k)
        if marks.count == attachments.count + 1, let at = marks[checked: k] {
            text = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 1), with: "")
        }
    }
}
