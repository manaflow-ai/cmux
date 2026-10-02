import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import Testing

/// Pane chrome alignment: the tab pill, the content border and the
/// terminal's first cell, in both densities.
@MainActor
@Suite(.serialized)
struct PaneAlignmentTests {
    /// The first tab pill's frame and the strip's height in a pane of
    /// `width` (pane-local, flipped: y grows down).
    private func firstPill(width: CGFloat) -> (pill: CGRect, strip: CGRect) {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "nvim")], selectedID: TabID("t0"))
        let pane = PaneContentView(stripModel: model)
        pane.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        pane.layoutSubtreeIfNeeded()
        pane.stripView.sync(fromModel: true)
        pane.stripView.layoutSubtreeIfNeeded()
        pane.stripView.relayout(animated: false)
        let strip = pane.stripView
        let cell = strip.cells[TabID("t0")]!
        cell.layoutLayers()
        let pill = strip.tabsClip.convert(cell.frame.origin, to: pane)
        let background = cell.pillFrameInCell
        return (CGRect(x: pill.x + background.minX, y: pill.y + background.minY, width: background.width, height: background.height),
                strip.frame)
    }

    /// Dogfood (2026-10-01): "spacing above/below tab is not perfectly
    /// equal ... left side of first tab and terminal main content border
    /// must align too." The pane's strip and content sit in its cell inset
    /// by the pane padding; the content border starts where the strip ends.
    @Test(arguments: Density.allCases)
    func theTabPillSitsInEqualGapsAndOnTheBorderLine(density: Density) {
        let saved = DesignSettings.shared.density
        DesignSettings.shared.density = density
        defer { DesignSettings.shared.density = saved }
        let (pill, strip) = firstPill(width: 600)
        let padding = Metrics.panePadding
        // Above: from the cell's top edge (window top for the top row).
        let above = padding + pill.minY
        // Below: to the content border, which starts at the strip's bottom.
        let below = strip.maxY - pill.maxY
        #expect(above == below, "above \(above) below \(below)")
        #expect(pill.minX == 0, "the pill starts on the content border's left edge")
    }

    /// "weird left padding inside each terminal": the host fills the
    /// content border and Ghostty's padding (cmux default 4 pt, loaded
    /// before the user's files) is the only inset.
    @Test func theFirstTerminalCellIsNearTheBorder() throws {
        _ = GhosttyRuntime.shared
        let plain = try #require(GhosttyRuntime.terminalPadding(configText: ""))
        #expect(plain == .cmuxDefault)
        #expect(plain.leading == PaneChromeMetrics.terminalTextInset && plain.top == PaneChromeMetrics.terminalTextInset)
        #expect(!plain.balanced, "the grid's leftover goes right and bottom")
        let host = TerminalHostView()
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        // The host adds nothing to the (machine's) Ghostty padding.
        #expect(host.firstCellOrigin.x == GhosttyRuntime.shared.terminalPadding.leading)
    }

    /// A user's own window-padding wins over cmux's default, as written.
    @Test func theUsersPaddingWins() throws {
        _ = GhosttyRuntime.shared
        let none = try #require(GhosttyRuntime.terminalPadding(configText: "window-padding-x = 0\nwindow-padding-y = 0\n"))
        #expect(none.leading == 0 && none.top == 0)
    }

    /// The user's window-padding-x comes from libghostty's config API
    /// (manaflow-ai/ghostty `c_get` for WindowPadding), not a guessed default.
    @Test func theTerminalPaddingIsReadFromTheGhosttyConfig() throws {
        _ = GhosttyRuntime.shared
        let padding = try #require(GhosttyRuntime.terminalPadding(
            configText: "window-padding-x = 6,4\nwindow-padding-y = 3\nwindow-padding-balance = true\n"))
        #expect(padding == TerminalPadding(leading: 6, trailing: 4, top: 3, bottom: 3, balanced: true))
    }
}
