import CmuxNextActions
@testable import CmuxNextHomeEngine
import Testing

@MainActor struct ChiefWelcomeRegistryTests {
    @Test func unboundActionsLeaveNoEmptyShortcutAndReboundKeysShow() throws {
        let registry = ActionRegistry.standard()
        registry.setShortcutOverride(nil, for: ChiefWelcome.goToAction)
        for id in ChiefWelcome.shortcutActions { registry.setShortcutOverride(nil, for: id) }
        let unbound = ChiefWelcome.text(registry)
        #expect(!unbound.contains("**"))
        #expect(!unbound.contains(HomeStrings.chiefWelcomeShortcuts))
        #expect(unbound.contains(HomeStrings.chiefWelcomeExamples))
        registry.setShortcutOverride(Shortcut("g", modifiers: [.control]), for: ChiefWelcome.goToAction)
        registry.setShortcutOverride(Shortcut("t", modifiers: [.control]), for: "newTab.default")
        let rebound = ChiefWelcome.text(registry)
        let goToKeys = try #require(registry.shortcutDisplay(for: ChiefWelcome.goToAction))
        let tabKeys = try #require(registry.shortcutDisplay(for: "newTab.default"))
        let tabTitle = try #require(registry.descriptor(for: "newTab.default")?.title)
        #expect(rebound.contains(HomeStrings.chiefWelcomeGoTo(goToKeys)))
        #expect(rebound.contains("- `\(tabKeys)` \(tabTitle)"))
        #expect(!rebound.contains("⌘P"))
    }
}
