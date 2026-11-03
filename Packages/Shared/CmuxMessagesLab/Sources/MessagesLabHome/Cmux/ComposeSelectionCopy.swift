// cmux: what Copy, Cut and a drag of the message box's selection write (Draft+InlineMarks.swift).
// Not a vendored file.
import AppKit

/// The message box is a plain-text NSTextView, so its own Copy wrote only the selection's
/// string: an inline picture went out as an invisible U+FFFC and its file never left (the user,
/// msg 12179: copy and paste between other apps and Home's box is buggy). A selection with an
/// attachment instead writes its words without the marks, then each attachment's file as
/// ``HomeAttachmentPasteboard`` writes one (the file itself, and an image's own bytes and TIFF),
/// so Finder, Messages, Mail and Slack get the real files, and the box's own paste takes them
/// back with the words.
struct ComposeSelectionCopy {
    /// The file of the draft attachment with this id, named like it; nil when it has none here.
    var file: (ID) -> URL?

    /// The words of the selection, without attachment marks, and its attachments' files in order.
    struct Pieces: Equatable {
        var text: String
        var files: [URL]
    }

    /// The selection's pieces; nil when it holds no attachment character (NSTextView's own
    /// Copy is right then).
    func pieces(_ s: NSAttributedString, ranges: [NSRange]) -> Pieces? {
        let ns = s.string as NSString
        var text = "", files: [URL] = [], marks = 0
        for range in ranges where range.length > 0 && NSMaxRange(range) <= s.length {
            if !text.isEmpty { text += "\n" }
            var run = String.UnicodeScalarView()
            run.append(contentsOf: ns.substring(with: range).unicodeScalars.lazy.filter { $0 != Draft.mark })
            text += String(run)
            marks += Draft.markOffsets(ns.substring(with: range)).count
            s.enumerateAttribute(.attachment, in: range) { value, _, _ in
                if let a = value as? ComposeInlineAttachment, let url = file(a.attachmentID) { files.append(url) }
            }
        }
        return marks == 0 ? nil : Pieces(text: text, files: files)
    }

    /// The pasteboard items for `pieces`: the words first (when there are any), then one item per file.
    func items(_ pieces: Pieces) -> [NSPasteboardItem] {
        var out: [NSPasteboardItem] = []
        if !pieces.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let words = NSPasteboardItem()
            words.setString(pieces.text, forType: .string)
            out.append(words)
        }
        let writer = HomeAttachmentPasteboard()
        out += pieces.files.map { writer.item(for: $0) }
        return out
    }
}
