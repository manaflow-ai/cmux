import AppKit

/// The host status line (ask 9's `.notice`, the Chief's running indicator above its typing dots,
/// `HomeTurnProgress`): one caption line, whatever the turn did. The notice keeps its parts one per
/// text line (the folded steps, the narration, the step running now); they draw side by side as
/// "Reading › Starting agents · 7s" (a part ending in the "›" needs no dot after it), the parts
/// before the last quieter. When the column is too
/// narrow the earlier parts are cut with "…" first, so the step now and its time stay whole.
///
/// User 2026-10-29: "reading/starting agents should be one line": the row no longer grows a row per
/// part, so it keeps upstream's 16 pt as steps finish and thoughts arrive.
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

    /// The parts as drawn in `maxWidth`: the last whole while it fits, the lead cut with "…" into the
    /// room left (dropped when not even one character fits), the last cut only when it alone is too wide.
    static func fittedParts(_ notice: String, font: NSFont, maxWidth: CGFloat) -> (lead: String?, last: String) {
        let (lead, last) = parts(notice)
        guard maxWidth > 0, let lead else { return (lead, fitted(last, font: font, maxWidth: maxWidth)) }
        // A cut lead ends in "…", so the dot follows it.
        let room = maxWidth - TextDraw.width(last, font: font) - TextDraw.width(separator, font: font)
        guard room > 0 else { return (nil, fitted(last, font: font, maxWidth: maxWidth)) }
        let cut = fitted(lead, font: font, maxWidth: room)
        guard cut != "…", TextDraw.width(cut, font: font) <= room else { return (nil, last) }
        return (cut, last)
    }

    /// Draws `notice` from `x` with its baseline at `baseline`, cut to `maxWidth`.
    static func draw(_ notice: String, x: CGFloat, baseline: CGFloat, maxWidth: CGFloat, in ctx: CGContext) {
        let font = HomeFonts.system(ofSize: 11) // HomeFonts (cx-qpqs), upstream's notice face
        let (lead, last) = fittedParts(notice, font: font, maxWidth: maxWidth)
        var left = x
        if let lead {
            let quiet = Fixture.secondaryText.withAlphaComponent(0.72)
            let head = lead + gap(after: lead)
            TextDraw.line(head, font: font, color: quiet, x: left, baseline: baseline, in: ctx)
            left += TextDraw.width(head, font: font)
        }
        TextDraw.line(last, font: font, color: Fixture.secondaryText, x: left, baseline: baseline, in: ctx)
    }

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
