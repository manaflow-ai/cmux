import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextHome
import Foundation
import Testing
import CmuxNextHomeEngine

/// Home's first-run Switching card (Lawrence 2026-10-19: make Ctrl-1…9 for
/// tabs explicit at first run): its keys follow the live binding table, it
/// hides for good, and a Mission Control conflict adds a note, never a block.
@MainActor @Suite struct HomeFirstRunSwitchCardTests {
    private func defaults() -> UserDefaults {
        let name = "HomeFirstRunSwitchCardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static let desktopOn: [String: Any] = ["118": ["enabled": true, "value": ["parameters": [49, 18, 262_144]]]]

    @Test func sourceGivesTheLiveKeysAndHideSticks() throws {
        let store = defaults()
        let source = HomeSwitchKeysSource(defaults: store, symbolicHotKeys: { nil })
        let registry = ActionRegistry.standard()
        let keys = try #require(source.keys(registry: registry))
        #expect(keys.tabByNumber == "⌃1…9")
        #expect(keys.workspaceByNumber == "⌘1…9")
        #expect(!keys.desktopConflict)
        registry.setShortcutOverride(Shortcut("1", modifiers: [.control, .option]), for: "selectSurfaceByNumber")
        #expect(source.keys(registry: registry)?.tabByNumber == "⌃⌥1…9")
        source.hide()
        #expect(source.keys(registry: registry) == nil)
        #expect(HomeSwitchKeysSource(defaults: store, symbolicHotKeys: { nil }).isHidden, "Hide is kept across launches")
    }

    @Test func missionControlConflictFollowsTheTabKeysModifiers() {
        let registry = ActionRegistry.standard()
        let source = HomeSwitchKeysSource(defaults: defaults(), symbolicHotKeys: { Self.desktopOn })
        #expect(source.keys(registry: registry)?.desktopConflict == true)
        // Moved off Ctrl-1…9: Switch to Desktop no longer takes them.
        registry.setShortcutOverride(Shortcut("1", modifiers: [.control, .option]), for: "selectSurfaceByNumber")
        #expect(source.keys(registry: registry)?.desktopConflict == false)
    }

    @Test func cardShowsLinesNoteOnlyOnConflictAndButtonsCallBack() {
        let card = HomeFirstRunSwitchCard(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        var keys = HomeSwitchKeys(tabByNumber: "⌃1…9", workspaceByNumber: "⌘1…9", nextPreviousTab: "⇧⌘[ ⇧⌘]",
                                  nextPreviousWorkspace: nil, focusBackForward: "⌘[ ⌘]")
        card.apply(keys)
        #expect(!card.isHidden)
        #expect(card.lineViews.map(\.keys.stringValue) == ["⌃1…9", "⌘1…9", "⇧⌘[ ⇧⌘]", "⌘[ ⌘]"], "an unbound key has no line")
        #expect(card.note.isHidden && card.openSettings.isHidden)
        let plain = card.height(for: 340)
        keys.desktopConflict = true
        card.apply(keys)
        #expect(!card.note.isHidden && !card.openSettings.isHidden)
        #expect(card.height(for: 340) > plain)
        var hid = false, opened = false
        card.onHide = { hid = true }
        card.onOpenSettings = { opened = true }
        card.openSettings.performClick(nil)
        card.hide.performClick(nil)
        #expect(hid && opened)
        card.apply(nil)
        #expect(card.isHidden)
    }

    @Test func firstRunPanelHidesTheCardAfterHide() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        panel.setShortcuts(terminal: "⌘T", agent: nil, switching: HomeSwitchKeys(
            tabByNumber: "⌃1…9", workspaceByNumber: nil, nextPreviousTab: nil, nextPreviousWorkspace: nil, focusBackForward: nil))
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.switchCard.isHidden)
        #expect(panel.switchCard.frame.height > 0)
        panel.setShortcuts(terminal: "⌘T", agent: nil, switching: nil)
        #expect(panel.switchCard.isHidden)
    }
}
