import AppKit
@testable import CmuxNextDesign
import Testing

/// Lawrence 2026-10-21: "vertical alignment here is still bad". A hover card row's icon and its
/// trailing mark center on the middle of the text's first line's capitals, on one line and when
/// the text wraps. Centering them on the whole label put a wrapped row's icon between its lines.
@MainActor @Suite(.serialized) struct HoverCardRowIconLineTests {
    /// A row of `text` (wrapping to `lines` at 200 pt) with an icon and a dot, laid out at its fitting size.
    private func row(_ text: String, lines: Int) -> HoverCardRowView {
        let row = HoverCardRowView()
        let image = NSImage(size: NSSize(width: HoverCardRowView.iconSize, height: HoverCardRowView.iconSize), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        row.configure(HoverCardRowContent(text: text, lines: lines, accessory: .dot(.success)), image: image, wrapWidth: 200)
        let width = row.widthAnchor.constraint(equalToConstant: 260)
        width.isActive = true
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        row.layoutSubtreeIfNeeded()
        return row
    }

    /// The middle of `label`'s first line's capitals, in `view`'s coordinates (y up or down as it is).
    static func firstLineCapMiddle(of label: any ShownText, in view: NSView) -> CGFloat {
        let frame = view.convert(label.bounds, from: label)
        let capHalf = (label.font?.capHeight ?? 0) / 2
        let baselineFromTop = label.firstBaselineOffsetFromTop
        return view.isFlipped ? frame.minY + baselineFromTop - capHalf : frame.maxY - baselineFromTop + capHalf
    }

    static func middle(of child: NSView, in view: NSView) -> CGFloat { view.convert(child.bounds, from: child).midY }

    @Test(arguments: [1, 2])
    func theIconAndTheMarkSitOnTheFirstLinesCapitals(lines: Int) throws {
        let text = lines == 1 ? "Claude Code · claude-opus-5-5"
            : "The work is logged in a file whose name is long enough to wrap onto a second line of the card"
        let row = row(text, lines: lines)
        let capMiddle = Self.firstLineCapMiddle(of: row.textLabel, in: row)
        if lines > 1 {
            try #require(row.textLabel.frame.height > 1.5 * (row.textLabel.font?.boundingRectForFont.height ?? 0) * 0.8,
                         "the text did not wrap: \(row.textLabel.frame)")
        }
        let icon = Self.middle(of: row.icon, in: row)
        #expect(abs(icon - capMiddle) <= 0.5, "\(lines) line(s): the icon's middle is \(icon - capMiddle) pt off the first line's capitals")
        let mark = Self.middle(of: row.accessoryView, in: row)
        #expect(abs(mark - capMiddle) <= 0.5, "\(lines) line(s): the dot's middle is \(mark - capMiddle) pt off the first line's capitals")
    }
}
