import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo 2026-10-21 on the workspace card ("this doesn't line up nor work very well"): a row's icon
/// can say a state in its color (a pull request's "Merged" icon in the merged ink), over a
/// machine's color pick, else the metadata ink. Where the icon sits on its line is
/// `HoverCardRowIconLineTests`.
@MainActor @Suite(.serialized) struct HoverCardRowIconToneTests {
    private static let image = NSImage(size: NSSize(width: 13, height: 13))

    /// A row painted in a fixed dark theme, so a tone's color is known.
    private func themedRow() throws -> (HoverCardRowView, ThemeScope) {
        let row = HoverCardRowView()
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Hover Row Icon Tone")),
                          input: ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4)), animated: false)
        scope.root(row)
        return (row, scope)
    }

    @Test func theIconsColorSaysAState() throws {
        let (row, scope) = try themedRow()
        row.configure(HoverCardRowContent(text: "#42 Fix the card", status: "Merged", statusTone: .merged, iconTone: .merged),
                      image: Self.image)
        let magenta = try #require(scope.tokens.ansi.dropFirst(5).first).nsColor
        #expect(Self.same(try #require(row.icon.contentTintColor), magenta))
        // Without a tone of its own the icon keeps the metadata ink.
        row.configure(HoverCardRowContent(text: "cmux"), image: Self.image)
        #expect(Self.same(try #require(row.icon.contentTintColor), scope.perform { Palette.textSecondary }))
    }

    @Test func aToneWinsOverAMachineWithNoPick() throws {
        let (row, scope) = try themedRow()
        let machine = "hover-row-icon-tone-\(UUID().uuidString)"
        // A machine nobody colored keeps the metadata ink, and a state's tone still colors the icon.
        row.configure(HoverCardRowContent(text: machine, iconMachine: machine), image: Self.image)
        #expect(Self.same(try #require(row.icon.contentTintColor), scope.perform { Palette.textSecondary }))
        row.configure(HoverCardRowContent(text: machine, iconTone: .merged, iconMachine: machine), image: Self.image)
        let magenta = try #require(scope.tokens.ansi.dropFirst(5).first).nsColor
        #expect(Self.same(try #require(row.icon.contentTintColor), magenta))
    }

    private static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}
