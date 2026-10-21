import AppKit

/// The host status line's rows (ask 9's `.notice`, the Chief's running indicator above its typing
/// dots, `HomeTurnProgress`): one caption row per line of the notice, each cut with "…" to the
/// transcript column. The rows above the last are quieter: the last is the step running now.
enum HomeNoticeRows {
    /// The first row's height (upstream's one-line status row) and each further row's.
    static let firstHeight: CGFloat = 16
    static let rowHeight: CGFloat = 15

    static func lines(_ notice: String) -> [String] {
        notice.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The row's height for `notice`: one line is upstream's 16 pt.
    static func height(_ notice: String) -> CGFloat {
        firstHeight + rowHeight * CGFloat(max(lines(notice).count - 1, 0))
    }

    /// Draws `notice` from `x` with its first baseline at `baseline`, each line cut to `maxWidth`.
    static func draw(_ notice: String, x: CGFloat, baseline: CGFloat, maxWidth: CGFloat, in ctx: CGContext) {
        let font = HomeFonts.system(ofSize: 11) // HomeFonts (cx-qpqs), upstream's notice face
        let rows = lines(notice)
        for (index, line) in rows.enumerated() {
            let last = index == rows.count - 1
            let color = last ? Fixture.secondaryText : Fixture.secondaryText.withAlphaComponent(0.72)
            let text = fitted(line, font: font, maxWidth: maxWidth)
            TextDraw.line(text, font: font, color: color, x: x, baseline: baseline + rowHeight * CGFloat(index), in: ctx)
        }
    }

    /// `line`, or its head and "…" when it is wider than `maxWidth`.
    static func fitted(_ line: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 0, TextDraw.width(line, font: font) > maxWidth else { return line }
        var head = Substring(line)
        while !head.isEmpty, TextDraw.width(String(head) + "…", font: font) > maxWidth { head = head.dropLast() }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The widest line's width, for the clickable status line frame.
    static func width(_ notice: String) -> CGFloat {
        let font = HomeFonts.system(ofSize: 11) // HomeFonts (cx-qpqs)
        return lines(notice).map { TextDraw.width($0, font: font) }.max() ?? 0
    }
}
