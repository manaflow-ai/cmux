import AppKit

/// The host status line (ask 9's `.notice`, the Chief's running indicator above its typing dots,
/// `HomeTurnProgress`): one caption line, whatever the turn did. The notice keeps its parts one per
/// text line (the folded steps, the narration, the step running now); they draw side by side as
/// "Reading › Starting agents · 7s" (a part ending in the "›" needs no dot after it), the parts
/// before the last quieter. When the column is too narrow the earlier parts give way first, whole
/// parts at a time, so the step now and its time stay whole and no stub ("Ran 3 co…") is drawn.
///
/// User 2026-10-29: "reading/starting agents should be one line": the row no longer grows a row per
/// part, so it keeps upstream's 16 pt as steps finish and thoughts arrive. User 2026-10-30: "make it
/// just one line with shimmer text": it is the whole running indicator (no typing bubble under it) and
/// a light band sweeps its text (`HomeNoticeShimmer`).
enum HomeNoticeRows {
    /// The row's height: upstream's one-line status row, for every notice.
    static let firstHeight: CGFloat = 16
    /// Between the parts on the line, the same dot the step and its time use.
    static let separator = " · "

    /// What follows `part` on the line: a space after the folded steps' "›", else ``separator``.
    static func gap(after part: String) -> String { part.hasSuffix("›") ? " " : separator }

    /// `parts` side by side on the line.
    static func joined<S: Sequence<String>>(_ parts: S) -> String {
        parts.reduce(into: "") { line, part in line += line.isEmpty ? part : gap(after: line) + part }
    }

    static func lines(_ notice: String) -> [String] {
        notice.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The row's height for `notice`: always one line.
    static func height(_ notice: String) -> CGFloat { firstHeight }

    /// The line's two parts: the earlier ones joined (`lead`, nil when there are none) and the last.
    static func parts(_ notice: String) -> (lead: String?, last: String) {
        let rows = lines(notice)
        guard let last = rows.last else { return (nil, "") }
        let lead = joined(rows.dropLast())
        return (lead.isEmpty ? nil : lead, last)
    }

    /// The whole line uncut: "Reading › Starting agents · 7s".
    static func line(_ notice: String) -> String {
        let (lead, last) = parts(notice)
        return lead.map { joined([$0, last]) } ?? last
    }

    /// The parts as drawn in `maxWidth`: the last whole while it fits; the lead whole, else its longest
    /// head of whole parts that fits ("Ran 3 commands…", or the fold "… files ›" with no "…" after its
    /// chevron), else dropped: never a stub cut mid-word ("Ran 3 co…"). The last is cut only when it
    /// alone is too wide.
    static func fittedParts(_ notice: String, font: NSFont, maxWidth: CGFloat) -> (lead: String?, last: String) {
        let (lead, last) = parts(notice)
        guard maxWidth > 0, let lead else { return (lead, fitted(last, font: font, maxWidth: maxWidth)) }
        let lastWidth = TextDraw.width(last, font: font)
        guard lastWidth <= maxWidth else { return (nil, fitted(last, font: font, maxWidth: maxWidth)) }
        let fits = { (head: String) in
            TextDraw.width(head + gap(after: head), font: font) + lastWidth <= maxWidth
        }
        return (leadHeads(notice).last(where: fits), last)
    }

    /// The lead's heads as it may be drawn, shortest first: each whole part ("Ran 3 commands") of each
    /// row in turn, ending in "…" unless it ends at the fold's "›" or is the whole lead.
    static func leadHeads(_ notice: String) -> [String] {
        let rows = lines(notice).dropLast()
        var heads: [String] = []
        var done: [String] = []
        for (index, row) in rows.enumerated() {
            let pieces = row.components(separatedBy: separator)
            for count in 1...pieces.count {
                let head = joined(done + [pieces.prefix(count).joined(separator: separator)])
                let whole = index == rows.count - 1 && count == pieces.count
                heads.append(whole || head.hasSuffix("›") ? head : head + "…")
            }
            done.append(row)
        }
        return heads
    }

    /// Draws `notice` from `x` with its baseline at `baseline`, cut to `maxWidth`.
    static func draw(_ notice: String, x: CGFloat, baseline: CGFloat, maxWidth: CGFloat, in ctx: CGContext) {
        let font = HomeFonts.system(ofSize: 11) // HomeFonts (cx-qpqs), upstream's notice face
        let (lead, last) = fittedParts(notice, font: font, maxWidth: maxWidth)
        // The text color at full strength: the cell's shimmer mask (HomeNoticeShimmer) dims it to the caption
        // grey and its sweeping band lifts it back.
        let color = textColor
        var left = x
        if let lead {
            let quiet = color.withAlphaComponent(0.72)
            let head = lead + gap(after: lead)
            TextDraw.line(head, font: font, color: quiet, x: left, baseline: baseline, in: ctx)
            left += TextDraw.width(head, font: font)
        }
        TextDraw.line(last, font: font, color: color, x: left, baseline: baseline, in: ctx)
    }

    /// The line's text color under the shimmer's band (a message's text color); elsewhere the mask's
    /// ``HomeNoticeShimmer/restAlpha`` makes it the caption grey.
    static var textColor: NSColor { Fixture.incomingText }

    /// `line`, or its head and "…" when it is wider than `maxWidth`.
    static func fitted(_ line: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 0, TextDraw.width(line, font: font) > maxWidth else { return line }
        var head = Substring(line)
        while !head.isEmpty, TextDraw.width(String(head) + "…", font: font) > maxWidth { head = head.dropLast() }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The whole line's width, for the clickable status line frame.
    static func width(_ notice: String) -> CGFloat {
        TextDraw.width(line(notice), font: HomeFonts.system(ofSize: 11)) // HomeFonts (cx-qpqs)
    }
}
