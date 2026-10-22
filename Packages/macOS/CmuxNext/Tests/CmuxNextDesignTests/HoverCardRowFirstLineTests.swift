import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Leo 2026-10-21 on the workspace card ("this doesn't line up"): the two-line preview's icon sat
/// centered beside both lines. A hover card row lines up on its text's first baseline, so the
/// icon and the trailing mark sit on the first line, and an icon's color can say a state.
@MainActor @Suite(.serialized) struct HoverCardRowFirstLineTests {
    private static let long = "Done: the card lines up now, its icons share one column and the preview wraps to a second line."

    /// A row of `width` with `content`, laid out.
    private func laidOut(_ content: HoverCardRowContent, width: CGFloat = 220) -> HoverCardRowView {
        let row = HoverCardRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.widthAnchor.constraint(equalToConstant: width),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        row.configure(content, image: NSImage(size: NSSize(width: 13, height: 13)), wrapWidth: width - 13 - Metrics.space2)
        host.layoutSubtreeIfNeeded()
        return row
    }

    @Test func theIconSitsOnTheFirstLineOfAWrappedText() throws {
        let row = laidOut(HoverCardRowContent(text: Self.long, ink: .primary, lines: 2))
        let label = row.convert(row.textLabel.bounds, from: row.textLabel)
        let icon = row.convert(row.icon.bounds, from: row.icon)
        let font = try #require(row.textLabel.font)
        let line = font.ascender - font.descender + font.leading
        try #require(label.height > 1.5 * line, "the text wraps: \(label.height) for a \(line) pt line")
        // y grows up: the first line is the label's top band. The icon's center is in it, well
        // above the label's middle (where a centered icon would float, between the lines).
        #expect(icon.midY > label.maxY - line, "icon \(icon) label \(label)")
        #expect(icon.midY > label.midY + line / 4, "icon \(icon) label \(label)")
        // And it never sticks out above the text.
        #expect(icon.maxY <= label.maxY + 1, "icon \(icon) label \(label)")
    }

    @Test func aOneLineRowCentersItsIconOnTheLine() throws {
        let row = laidOut(HoverCardRowContent(text: "cmux · feat-cmux-next"))
        let label = row.convert(row.textLabel.bounds, from: row.textLabel)
        let icon = row.convert(row.icon.bounds, from: row.icon)
        // A single line: the icon sits within the line, its center near the line's middle.
        #expect(icon.minY >= label.minY - 1 && icon.maxY <= label.maxY + 1, "icon \(icon) label \(label)")
        #expect(abs(icon.midY - label.midY) <= 2.5, "icon \(icon) label \(label)")
    }

    @Test func theTrailingMarkSitsOnTheFirstLineToo() throws {
        let row = laidOut(HoverCardRowContent(text: Self.long, lines: 2, accessory: .dot(.success)))
        let label = row.convert(row.textLabel.bounds, from: row.textLabel)
        let mark = row.convert(row.accessoryView.bounds, from: row.accessoryView)
        let font = try #require(row.textLabel.font)
        let line = font.ascender - font.descender + font.leading
        try #require(label.height > 1.5 * line)
        #expect(mark.midY > label.maxY - line, "mark \(mark) label \(label)")
    }

    @Test func theCenterSitsMidwayBetweenAscenderAndDescender() {
        let font = Typography.body
        let offset = FirstLineIconView.baselineOffset(side: 13, font: font)
        // From the icon's top: half the icon down to its center, then down to the baseline by the
        // distance between the line's middle (between ascender and descender) and the baseline.
        #expect(abs(offset - (6.5 + (font.ascender + font.descender) / 2)) < 0.001)
    }

    @Test func theIconsColorSaysAState() throws {
        let row = HoverCardRowView()
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Hover Row First Line")),
                          input: ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4)), animated: false)
        scope.root(row)
        row.configure(HoverCardRowContent(text: "#42 Fix the card", status: "Merged", statusTone: .merged, iconTone: .merged),
                      image: NSImage(size: NSSize(width: 13, height: 13)))
        let magenta = try #require(scope.tokens.ansi.dropFirst(5).first).nsColor
        #expect(Self.same(try #require(row.icon.contentTintColor), magenta))
        // Without a tone of its own the icon keeps the metadata ink.
        row.configure(HoverCardRowContent(text: "cmux"), image: NSImage(size: NSSize(width: 13, height: 13)))
        #expect(Self.same(try #require(row.icon.contentTintColor), scope.perform { Palette.textSecondary }))
    }

    @Test func theIconIsDecorative() {
        let row = HoverCardRowView()
        #expect(!row.icon.isAccessibilityElement())
        #expect(row.icon.cell?.isAccessibilityElement() == false)
    }

    private static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}
