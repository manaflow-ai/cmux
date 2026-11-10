import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import CmuxNextTestSupport
import Foundation
import Testing
import CmuxNextHomeEngine

/// Home's first-run Switching card (Lawrence 2026-10-19: make Ctrl-1…9 for
/// tabs explicit at first run): its keys follow the live binding table, it
/// hides for good, and a Mission Control conflict adds a note, never a block.
@MainActor @Suite struct HomeFirstRunSwitchCardTests {
    private func defaults() -> UserDefaults {
        let name = "HomeFirstRunSwitchCardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: name)!
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
}
