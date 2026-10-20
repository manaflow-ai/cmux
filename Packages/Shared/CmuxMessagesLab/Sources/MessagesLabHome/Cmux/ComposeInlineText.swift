// cmux: the message box's text with its attachments (Draft+InlineMarks.swift). Not a vendored file.
import AppKit

/// How the field's text holds the draft: marks become attachments.
struct ComposeInlineText {
    /// The paragraph style with attachments in the text: the line grows to hold a thumbnail
    /// (the typing style caps every line at one text line).
    static func attributes(inline: Bool) -> [NSAttributedString.Key: Any] {
        var a = ComposeView.typing
        guard inline else { return a }
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = Fixture.lineHeight
        p.maximumLineHeight = 0
        a.updateValue(p, forKey: .paragraphStyle)
        return a
    }

    /// The field's text for TEXT and ATTACHMENTS: each mark is the next
    /// attachment's view (made once per id and kept in `cache`); a mark with
    /// no attachment is left out.
    static func build(_ text: String, attachments: [Attachment], cache: inout [ID: ComposeInlineAttachment], scale: CGFloat,
                      onRemove: @escaping (ID) -> Void) -> NSAttributedString {
        let attrs = attributes(inline: !attachments.isEmpty)
        guard !attachments.isEmpty else {
            cache = [:]
            return NSAttributedString(string: Draft.stripMarks(text), attributes: attrs)
        }
        let out = NSMutableAttributedString()
        var next = 0
        var run = String.UnicodeScalarView()
        func flush() {
            guard !run.isEmpty else { return }
            out.append(NSAttributedString(string: String(run), attributes: attrs))
            run = String.UnicodeScalarView()
        }
        var live = Set<ID>()
        for u in text.unicodeScalars {
            guard u == Draft.mark else { run.append(u); continue }
            flush()
            guard let a = attachments[checked: next] else { continue }
            next += 1
            let att = cache.value(for: a.id) ?? ComposeInlineAttachment(a, scale: scale)
            att.update(a, scale: scale)
            att.onRemove = onRemove
            cache.updateValue(att, forKey: a.id)
            live.insert(a.id)
            var aa = attrs
            aa.updateValue(att, forKey: .attachment)
            out.append(NSAttributedString(string: String(Character(Draft.mark)), attributes: aa))
        }
        flush()
        cache = cache.filter { live.contains($0.key) }
        return out
    }

    /// The ids of the attachments the field's text holds, in order.
    static func ids(in s: NSAttributedString) -> [ID] {
        var ids: [ID] = []
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let a = v as? ComposeInlineAttachment { ids.append(a.attachmentID) }
        }
        return ids
    }

    /// Ranges of attachment characters that stand for no draft attachment (a
    /// plain U+FFFC pasted as text, an undo that brought a removed one back),
    /// last first so they can be deleted in order.
    static func orphanRanges(in s: NSAttributedString, keeping ids: Set<ID>) -> [NSRange] {
        var out: [NSRange] = []
        let ns = s.string as NSString
        for i in 0..<ns.length where ns.character(at: i) == 0xFFFC {
            let a = s.attribute(.attachment, at: i, effectiveRange: nil) as? ComposeInlineAttachment
            if !(a.map { ids.contains($0.attachmentID) } ?? false) { out.append(NSRange(location: i, length: 1)) }
        }
        return out.reversed()
    }

    /// The text's height at WIDTH beyond one text line (0 without attachments taller than a line).
    static func extraHeight(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        guard s.length > 0, width > 0 else { return 0 }
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let full = s.boundingRect(with: size, options: opts).height
        let line = NSAttributedString(string: " ", attributes: ComposeView.typing).boundingRect(with: size, options: opts).height
        return max(0, ceil(full - line))
    }
}
