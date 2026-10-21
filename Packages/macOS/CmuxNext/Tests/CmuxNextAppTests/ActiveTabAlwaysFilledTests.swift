import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Lawrence 2026-10-20 (screenshot 10.21.23 PM): a pane's active tab had a brighter title but
/// no selected pill, so it looked like its inactive neighbors. The active tab in every pane
/// always draws the selected fill: in a background window and in an unfocused pane it may be
/// dimmer, never absent. Read from the strip as drawn (the pill layer's fill), and from the
/// unfocused-pane tokens for every style and strength.
@MainActor @Suite(.serialized) struct ActiveTabAlwaysFilledTests {
    /// The pill fill alpha of each tab, as drawn.
    static func fillAlphas(_ strip: TabStripView, tabs: Int) throws -> [CGFloat] {
        try (0..<tabs).map { index in
            let cell = try #require(strip.cells[TabID("tab\(index)")])
            guard let cg = cell.backgroundLayer.backgroundColor, let color = NSColor(cgColor: cg) else { return 0 }
            return color.alphaComponent
        }
    }

    @Test func theActiveTabKeepsItsFillWhenTheWindowIsNotMain() throws {
        let (strip, window) = TabSeparatorTests.strip(tabs: 4)
        defer { window.orderOut(nil) }
        for isMain in [true, false, true, false] {
            strip.windowMain.changed(isMain: isMain)
            let alphas = try Self.fillAlphas(strip, tabs: 4)
            #expect(alphas[1] > 0, "main \(isMain): the active tab has no fill")
            #expect(alphas.enumerated().filter { $0.element > 0 }.map(\.offset) == [1],
                    "main \(isMain): exactly the active tab is filled, got \(alphas)")
        }
    }

    @Test func aBackgroundWindowsActiveTabIsDimmerNotGone() throws {
        let (strip, window) = TabSeparatorTests.strip(tabs: 3)
        defer { window.orderOut(nil) }
        strip.windowMain.changed(isMain: true)
        let front = try Self.fillAlphas(strip, tabs: 3)[1]
        strip.windowMain.changed(isMain: false)
        let back = try Self.fillAlphas(strip, tabs: 3)[1]
        #expect(back > 0 && back <= front, "front \(front), back \(back)")
    }

    @Test(arguments: InactiveTabStyle.allCases, [CGFloat(0), 0.35, 0.7, 1])
    func anUnfocusedPanesActiveTabKeepsAFill(style: InactiveTabStyle, strength: CGFloat) {
        let tokens = ThemeTokens.unresolved
        let subtle = tokens.emphasized(.subtle(style, strength: strength))
        #expect(subtle.selectionFill.alpha > 0, "\(style) at \(strength) drops the active tab's fill")
    }
}
