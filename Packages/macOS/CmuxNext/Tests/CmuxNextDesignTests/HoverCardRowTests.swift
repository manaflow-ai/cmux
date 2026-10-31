import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo 2026-10-19 (the Codex sidebar card, Claude desktop's PR list): one hover card row for the
/// tab and session cards. A status word and +/− counts in the theme's colors, a trailing mark
/// (a dot, a context ring, CPU bars) as a symbol, never a fixed gray, and no fill of its own.
@MainActor @Suite(.serialized) struct HoverCardRowTests {
    private let input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))

    private func scoped(_ view: NSView) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Hover Row")), input: input, animated: false)
        scope.root(view)
        return scope
    }

    @Test func aRowReadsInOrder() {
        let row = HoverCardRowContent(text: "cmux #22231", status: "Merged", statusTone: .merged, additions: 69, deletions: 32,
                                      accessory: .ring(0.618, tone: .secondary))
        #expect(row.spoken == "Merged cmux #22231 +69 \u{2212}32 62%")
        #expect(HoverCardRowContent(text: "air-blue", accessory: .dot(.danger)).spoken == "air-blue")
    }

    @Test func theRowDrawsItsPartsInTheThemesColors() throws {
        let view = HoverCardRowView()
        let scope = try scoped(view)
        view.configure(HoverCardRowContent(text: "cmux #22231", status: "Conflict", statusTone: .attention, additions: 3, deletions: 1),
                       image: nil)
        #expect(view.shownText == "Conflict cmux #22231 +3 \u{2212}1")
        #expect(Self.same(try #require(view.statusLabel.textColor), scope.perform { Palette.attention }))
        #expect(Self.same(try #require(view.textLabel.textColor), scope.perform { Palette.textSecondary }))
        #expect(Self.same(try #require(view.additionsLabel.textColor), scope.perform { Palette.success }))
        #expect(Self.same(try #require(view.deletionsLabel.textColor), scope.perform { Palette.danger }))
        #expect(view.icon.isHidden && view.accessoryView.isHidden)
        #expect(view.layer?.backgroundColor == nil)
    }

    @Test func mergedIsTheThemesMagenta() throws {
        let view = NSView()
        let scope = try scoped(view)
        let magenta = try #require(scope.tokens.ansi.dropFirst(5).first).nsColor
        #expect(Self.same(view.performWithTheme { HoverCardTone.merged.color }, magenta))
    }

    @Test func theMarksSizeToTheirKind() {
        let mark = HoverCardAccessoryView()
        mark.accessory = .dot(.success)
        #expect(mark.intrinsicContentSize == NSSize(width: 8, height: 8))
        mark.accessory = .bars([0.2, 0.5, 1], tone: .attention)
        #expect(mark.intrinsicContentSize.height == 11)
        mark.accessory = .ring(0.5, tone: .secondary)
        #expect(mark.percentLabel.stringValue == "50%")
        #expect(!mark.percentLabel.isHidden)
        #expect(mark.intrinsicContentSize.width > 13)
        mark.accessory = .dot(.danger)
        #expect(mark.percentLabel.isHidden)
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}
