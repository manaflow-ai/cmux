import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-07: "make it all concentric with macos windows by default (but still
/// configurable)". The curved main pane follows the window's corner (`WindowConcentricCornerTests`);
/// under the floating and blocks styles there is no main pane card: every pane is its own card,
/// and the panes in the window's corners sit the gutter plus the pane padding inside it. Those
/// cards kept the one 8 pt outer radius 4 pt inside a 16 pt window corner (concentric: 12 pt), so
/// the gap widened toward the corner.
@MainActor @Suite(.serialized, .closesItsWindows) struct FloatingPaneConcentricCornerTests {
    private func load(_ style: ChromeStyle, radius: Double? = nil) {
        var layout: [String: JSONValue] = [:]
        if let radius { layout["paneCornerRadius"] = .number(radius) }
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": .object(["chromeStyle": .string(style.rawValue)]),
                                                         "layout": .object(layout)]),
                                                validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
        DesignSettings.shared.density = .compact
    }

    private func reset() { load(.card) }

    /// How far a corner pane's card sits inside the window: the gutter (at least the window's lit
    /// rim) to the pane's cell, then the padding to its card.
    private var cornerPaneInset: CGFloat { max(Metrics.mainPaneGutter, PaneTabRowRim.height) + Metrics.panePadding }

    /// Every pane card is concentric with the window's corner: its radius less the corner pane's inset.
    @Test(arguments: [ChromeStyle.floating, .blocks])
    func thePaneCardsAreConcentricWithTheWindow(style: ChromeStyle) {
        defer { reset() }
        load(style)
        #expect(Metrics.floatingPanes)
        let inset = cornerPaneInset
        #expect(inset > 0)
        let concentric = max(0, Metrics.standardWindowCornerRadius - inset)
        #expect(Metrics.paneCornerRadius == concentric, "\(style): a \(inset) pt inset in a \(Metrics.standardWindowCornerRadius) pt window")
        #expect(LayoutStyle().applyingDesignMetrics().paneCornerRadius == concentric, "the layout draws that radius")
        #expect(Metrics.tabStripCardRadius == concentric, "the tabs nest in it")
        // At Default the tab takes the workspace row's Codex corner instead (Metrics.tabRowCornerRadius, tabs follow rows).
        #expect(Metrics.tabCornerRadius == Metrics.tabRowCornerRadius ?? min(max(0, concentric - Metrics.tabStripCardInset), Metrics.tabHeight / 2))
    }

    /// `layout.paneCornerRadius` still sets the pane cards, at most the window's own radius.
    @Test(arguments: [(ChromeStyle.floating, 6.0, 6.0), (.blocks, 6.0, 6.0), (.floating, 20.0, 16.0)])
    func theSettingStillWins(style: ChromeStyle, radius: Double, expected: Double) {
        defer { reset() }
        load(style, radius: radius)
        #expect(Metrics.paneCornerRadius == min(CGFloat(expected), Metrics.standardWindowCornerRadius))
    }

    /// The other styles keep the one outer radius for their pane cards (the curved main pane, not
    /// its panes, meets the window's corner).
    @Test func panesInsideTheMainPaneKeepTheOuterRadius() {
        defer { reset() }
        load(.panes)
        #expect(!Metrics.floatingPanes)
        #expect(Metrics.paneCornerRadius == Metrics.cornerRadius)
    }
}
