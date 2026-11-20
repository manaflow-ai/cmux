import CmuxNextActions
@testable import CmuxNextHomeEngine
import Testing

@MainActor struct ChiefWelcomeRegistryTests {
    @Test func unboundActionsLeaveNoEmptyShortcutAndReboundKeysShow() throws {
        let registry = ActionRegistry.standard()
        registry.setShortcutOverride(nil, for: ChiefWelcome.goToAction)
        for id in ChiefWelcome.shortcutActions + [ChiefWelcome.anyAppAction] { registry.setShortcutOverride(nil, for: id) }
        let unbound = ChiefWelcome.text(registry)
        #expect(!unbound.contains("**"))
        #expect(!unbound.contains(HomeStrings.chiefWelcomeShortcuts))
        #expect(unbound.contains(HomeStrings.chiefWelcomeExamples))
        registry.setShortcutOverride(Shortcut("g", modifiers: [.control]), for: ChiefWelcome.goToAction)
        registry.setShortcutOverride(Shortcut("t", modifiers: [.control]), for: "newTab")
        let rebound = ChiefWelcome.text(registry)
        let goToKeys = try #require(registry.shortcutDisplay(for: ChiefWelcome.goToAction))
        let tabKeys = try #require(registry.shortcutDisplay(for: "newTab"))
        let tabTitle = try #require(registry.descriptor(for: "newTab")?.title)
        #expect(rebound.contains(HomeStrings.chiefWelcomeGoTo(goToKeys)))
        #expect(rebound.contains("- `\(tabKeys)` \(tabTitle)"))
        #expect(!rebound.contains("⌘P"))
    }

    /// Start Agent from Any App ends the shortcut list: while its system-wide key is off, with the
    /// one-click link that turns it on (agent-shortcut-found); once it is on, with no link.
    @Test func startAgentFromAnyAppIsListedWithALinkThatTurnsItOnWhileOff() throws {
        let registry = ActionRegistry.standard()
        let keys = try #require(registry.shortcutDisplay(for: ChiefWelcome.anyAppAction))
        let title = try #require(registry.descriptor(for: ChiefWelcome.anyAppAction)?.title)
        let off = ChiefWelcome.text(registry)
        let line = "- " + HomeStrings.chiefWelcomeAnyApp("`\(keys)`", title, link: ChiefWelcome.anyAppLink)
        #expect(off.contains(line))
        #expect(off.contains("](cmux://settings/start-agent-from-any-app)"))
        let shortcuts = try #require(off.range(of: HomeStrings.chiefWelcomeShortcuts)), anyApp = try #require(off.range(of: line))
        let examples = try #require(off.range(of: HomeStrings.chiefWelcomeExamplesHeader))
        #expect(shortcuts.lowerBound < anyApp.lowerBound && anyApp.lowerBound < examples.lowerBound)
        let on = ChiefWelcome.text(registry, anyAppOn: true)
        #expect(on.contains("- `\(keys)` \(title)\n"))
        #expect(!on.contains(ChiefWelcome.anyAppLink))
        registry.setShortcutOverride(nil, for: ChiefWelcome.anyAppAction)
        #expect(!ChiefWelcome.text(registry).contains(title))
    }

    /// A leader chord (`⌘J` then `S`) reads as two keys: one code span `⌘J S` looked like a stray `S`
    /// after the shortcut.
    @Test func aLeaderChordReadsAsTwoKeysNotOneSpan() {
        let text = ChiefWelcome.text(goTo: nil, shortcuts: [.init(keys: "⌘J", then: "S", title: "New Agent Chat")])
        #expect(!text.contains("`⌘J S`"))
        #expect(text.contains("- " + HomeStrings.chiefWelcomeChord("⌘J", "S") + " New Agent Chat"))
    }

    /// The list leads with the daily workspace, split and browser shortcuts.
    @Test func listsTheDailyShortcuts() throws {
        let registry = ActionRegistry.standard()
        let text = ChiefWelcome.text(registry)
        for id in ChiefWelcome.shortcutActions {
            let keys = try #require(registry.shortcutDisplay(for: id))
            #expect(text.contains("`\(keys)`"))
        }
    }
}
