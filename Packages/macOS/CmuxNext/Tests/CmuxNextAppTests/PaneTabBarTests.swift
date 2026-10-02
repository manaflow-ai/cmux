import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The tab strip's negative space is the window's own background unless
/// `appearance.tabBarBackground` is darker, and an unfocused pane's strip
/// draws in its scope's subtler colors.
@MainActor
@Suite(.serialized)
struct PaneTabBarTests {
    private func pane() -> PaneContentView {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "nvim")], selectedID: TabID("t0"))
        let pane = PaneContentView(stripModel: model)
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    @Test func theStripPaintsNoFillByDefaultAndADarkerOneOnRequest() {
        let saved = DesignSettings.shared.tabBarBackground
        defer { DesignSettings.shared.tabBarBackground = saved }
        DesignSettings.shared.tabBarBackground = .window
        let view = pane()
        #expect(!view.showsStripFill)
        DesignSettings.shared.tabBarBackground = .darker
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.showsStripFill)
    }

    @Test func anUnfocusedPanesStripDrawsSubtler() {
        let view = pane()
        let plain = view.themeTokens
        view.setChromeEmphasis(.subtle(.fade, strength: 0.45), animated: false)
        #expect(view.stripView.themeTokens == plain.emphasized(.subtle(.fade, strength: 0.45)))
        // The terminal below keeps its colors.
        #expect(view.themeTokens == plain)
        // A panel opened from the strip (group editor) draws at full strength.
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.adoptThemeScope(of: view.stripView)
        #expect(panel.themeScope.tokens == plain)
        view.setChromeEmphasis(.full, animated: false)
        #expect(view.stripView.themeTokens == plain)
    }
}
