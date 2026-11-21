import CmuxHomeCore
import CoreGraphics
import Foundation

/// cmux (Lawrence, 2026-11-20, "this preview thing is not very good"): what a reply's quote of its root shows. The
/// vendored `ThreadPreview` drew a root part's raw text: the Chief's before/after table quoted as
/// "| | Before | After ||---|…" beside an empty grey square. A quote shows the root's words (``MessagePreview``): an
/// agent's Markdown text as its words, a table card by its columns with its first picture as the thumbnail, and a
/// card with no picture has no square at all.
struct HomeQuotePreview {
    /// A card's text inset when it has no thumbnail (the thumbnail's own inset, 8 pt, plus the card's 4 pt radius room).
    static let textInsetWithoutPicture: CGFloat = 12
    /// A card's text inset beside its 26 pt thumbnail (vendored: 8 + 26 + 5).
    static let textInsetWithPicture: CGFloat = 39
    /// The card's right padding (vendored).
    static let trailingPad: CGFloat = 15
    /// The widest card (vendored).
    static let maxCardWidth: CGFloat = 300

    /// The root part as the quote draws it. An agent's text part arrives rendered (HomeMarkdown: no markers left)
    /// with its inline pictures in it as their alt text (tagged runs): the quote leaves the pictures out, and a
    /// text of only pictures says how many ("2 images"). Any other part is itself.
    static func part(_ part: Part?, markdown: Bool) -> Part? {
        guard markdown, case let .text(t, runs) = part else { return part }
        let pictures = runs.filter { ($0.style ?? []).contains(HomeMarkdown.imageMark) }.count
        guard pictures > 0 else { return part }
        let text = NSMutableString(string: t)
        // Last run first, so each cut leaves the earlier offsets as they were.
        for r in runs.reversed() where (r.style ?? []).contains(HomeMarkdown.imageAlt) {
            guard r.start >= 0, r.length > 0, r.start + r.length <= text.length else { continue }
            text.replaceCharacters(in: NSRange(location: r.start, length: r.length), with: "")
        }
        // The spaces a cut picture leaves fold; the text's own lines stay.
        let lines = (text as String).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        let words = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.isEmpty else { return .text(words, runs: []) }
        return .text(pictures == 1 ? MessagePreview.Words.home.image : MessagePreview.Words.home.images(pictures), runs: [])
    }

    /// A drawn row's card: its title and second line, in words.
    static func lines(_ c: CustomPart) -> (String, String) {
        switch c.kind {
        case HomeTableRowProvider.kind:
            guard let payload = HomeTableRowProvider.payload(c) else { break }
            return tableLines(MessagePreview(markdown: payload.raw))
        case HomePlanRowProvider.kind:
            guard let payload = HomePlanRowProvider.payload(c) else { break }
            return tableLines(MessagePreview(markdown: payload.raw))
        case HomeDiagramRowProvider.kind:
            return (CmuxStrings.previewDiagram, "")
        default:
            break
        }
        let words = MessagePreview(markdown: CustomRows.plainText(c)).text(.home)
        return (fit(words, maxWidth: maxCardWidth - textInsetWithoutPicture - trailingPad), "")
    }

    /// A table's card lines: "Table: Before / After" over its picture count, else its row count.
    private static func tableLines(_ preview: MessagePreview) -> (String, String) {
        let title = fit(preview.text(.home), maxWidth: maxCardWidth - textInsetWithPicture - trailingPad)
        let pictures = preview.images.count
        if pictures > 0 { return (title, pictures == 1 ? MessagePreview.Words.home.image : MessagePreview.Words.home.images(pictures)) }
        let rows = preview.tables.reduce(0) { $0 + $1.rows }
        return (title, rows == 1 ? CmuxStrings.previewOneRow : CmuxStrings.previewRows(rows))
    }

    /// The card's thumbnail: a table's first picture that has its file; nil for any other part.
    static func thumbnail(_ part: Part?) -> CGImage? {
        guard case let .custom(c) = part, c.kind == HomeTableRowProvider.kind, let payload = HomeTableRowProvider.payload(c) else { return nil }
        for image in MessagePreview(markdown: payload.raw).images {
            if let slot = HomeTableGrid.slot(HomeTableCell.Image(alt: image.alt, source: image.source), in: payload.table),
               let picture = slot.image {
                return picture
            }
        }
        return nil
    }

    /// Whether the card draws a picture at its left (a link's image, a table's first picture).
    static func hasPicture(_ part: Part?) -> Bool {
        if case .link(_, _, _, .some, _) = part { return true }
        return thumbnail(part) != nil
    }

    /// The card's text inset for `part`.
    static func textInset(_ part: Part?) -> CGFloat { hasPicture(part) ? textInsetWithPicture : textInsetWithoutPicture }

    /// `s` cut with "…" to fit `maxWidth` in the card's title font.
    static func fit(_ s: String, maxWidth: CGFloat) -> String {
        guard TextDraw.width(s, font: ThreadPreview.titleFont) > maxWidth else { return s }
        // No 12 pt glyph is narrower than 2 pt: more characters than this never fit. A width that is not finite or
        // does not fit an Int keeps every character (no trap); a negative one keeps none but the first.
        let fits = Int(exactly: (maxWidth / 2).rounded(.down)) ?? s.count
        var head = s.prefix(max(0, min(fits, s.count)) + 1)
        while !head.isEmpty, TextDraw.width(head.trimmingCharacters(in: .whitespaces) + "…", font: ThreadPreview.titleFont) > maxWidth {
            head = head.dropLast()
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension MessagePreview.Words {
    /// The preview words in Home's language (Resources/CmuxHome.xcstrings).
    static var home: MessagePreview.Words {
        MessagePreview.Words(table: { CmuxStrings.previewTable($0) }, untitledTable: CmuxStrings.previewTableUntitled,
                             image: CmuxStrings.previewImage, images: { CmuxStrings.previewImages($0) })
    }
}
