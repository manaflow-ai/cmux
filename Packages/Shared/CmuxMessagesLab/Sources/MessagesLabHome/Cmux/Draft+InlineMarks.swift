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

    /// The draft text without its attachment marks (what a send says).
    var plainText: String { Draft.stripMarks(text) }

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
