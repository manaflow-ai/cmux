import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The pane toolbar's more button is the app's one overflow button (⋮, Leo 2026-10-20, #22972):
/// a pointer press opens its menu on mouse-down, and VoiceOver's press opens the same menu. Its menu
/// is a standard macOS menu, like every right-click menu.
@MainActor @Suite struct PaneMoreOverflowButtonTests {
    @Test func voiceOversPressOpensThePanesMenu() {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.show(more: true, lit: false)
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab", action: nil, keyEquivalent: "")
        view.moreMenu = { menu }
        var shown: NSMenu?
        view.moreButton.presentMenu = { menu, _ in shown = menu }
        #expect(view.moreButton.accessibilityPerformPress())
        #expect(shown === menu)
        #expect(view.moreButton.accessibilityLabel() == view.moreButton.label)
    }

    @Test func aLitMenuDrawsInTheAccent() {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.show(more: true, lit: true)
        #expect(view.moreButton.tintOverride != nil)
        view.show(more: true, lit: false)
        #expect(view.moreButton.tintOverride == nil)
    }

    /// The menu starts with the New Tab rows and adds the tab's actions, Search Tabs and Show in Tab
    /// Bar: every one a standard macOS row.
    @Test func everyRowOfTheMenuIsNative() throws {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        let menu = try #require(toolbar.view.moreMenu?())
        let rows = menu.items.filter { !$0.isSeparatorItem }
        #expect(!rows.isEmpty)
        for item in rows {
            #expect(item.view == nil, "\(item.title) is custom-drawn, not a standard macOS row")
        }
    }
}
