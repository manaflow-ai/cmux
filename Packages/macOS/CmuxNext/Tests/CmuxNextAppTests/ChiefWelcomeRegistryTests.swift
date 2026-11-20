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
        registry.setShortcutOverride(Shortcut("t", modifiers: [.control]), for: "newTab.default")
        let rebound = ChiefWelcome.text(registry)
        let goToKeys = try #require(registry.shortcutDisplay(for: ChiefWelcome.goToAction))
        let tabKeys = try #require(registry.shortcutDisplay(for: "newTab.default"))
        let tabTitle = try #require(registry.descriptor(for: "newTab.default")?.title)
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

    /// A leader chord (New Agent Chat's `⌘J` then `S`, since ⌘I went to Open Chief Dock) reads as two keys:
    /// one code span `⌘J S` looked like a stray `S` after the shortcut.
    @Test func aLeaderChordReadsAsTwoKeysNotOneSpan() throws {
        let registry = ActionRegistry.standard()
        let id: ActionID = "palette.newAgentChat"
        #expect(registry.effectiveShortcut(for: id) == nil)
        let chord = try #require(registry.effectiveChord(for: id))
        let title = try #require(registry.descriptor(for: id)?.title)
        let first = chord.first.displayString, second = registry.shortcutDisplay(chord.second, for: id)
        let text = ChiefWelcome.text(registry)
        #expect(!text.contains("`\(first) \(second)`"))
        #expect(text.contains("- `\(first)` then `\(second)` \(title)"))
    }
}
