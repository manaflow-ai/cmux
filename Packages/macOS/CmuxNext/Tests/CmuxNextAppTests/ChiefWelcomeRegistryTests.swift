import CmuxNextActions
@testable import CmuxNextHomeEngine
import Testing

@MainActor struct ChiefWelcomeRegistryTests {
    @Test func unboundActionsLeaveNoEmptyShortcutAndReboundKeysShow() throws {
        let registry = ActionRegistry.standard()
        for id in ChiefWelcome.shortcutActions + [ChiefWelcome.anyAppAction] { registry.setShortcutOverride(nil, for: id) }
        let unbound = ChiefWelcome.text(registry)
        #expect(!unbound.contains("**"))
        #expect(!unbound.contains(HomeStrings.chiefWelcomeShortcuts))
        #expect(unbound == ChiefWelcome.aboutText)
        registry.setShortcutOverride(Shortcut("g", modifiers: [.control]), for: ChiefWelcome.goToAction)
        registry.setShortcutOverride(Shortcut("t", modifiers: [.control]), for: "newTab.default")
        let rebound = ChiefWelcome.text(registry)
        let goToKeys = try #require(registry.shortcutDisplay(for: ChiefWelcome.goToAction))
        let goToTitle = try #require(registry.descriptor(for: ChiefWelcome.goToAction)?.title)
        let tabKeys = try #require(registry.shortcutDisplay(for: "newTab.default"))
        let tabTitle = try #require(registry.descriptor(for: "newTab.default")?.title)
        #expect(rebound.contains("- `\(goToKeys)` \(goToTitle.hasSuffix("…") ? String(goToTitle.dropLast()) : goToTitle)"))
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
        #expect(shortcuts.lowerBound < anyApp.lowerBound && off.hasSuffix(line))
        let on = ChiefWelcome.text(registry, anyAppOn: true)
        #expect(on.hasSuffix("- `\(keys)` \(title)"))
        #expect(!on.contains(ChiefWelcome.anyAppLink))
        registry.setShortcutOverride(nil, for: ChiefWelcome.anyAppAction)
        #expect(!ChiefWelcome.text(registry).contains(title))
    }

    /// A leader chord (`⌘J` then `S`) reads as two keys: one code span `⌘J S` looked like a stray `S`
    /// after the shortcut.
    @Test func aLeaderChordReadsAsTwoKeysNotOneSpan() {
        let text = ChiefWelcome.text(shortcuts: [.init(keys: "⌘J", then: "S", title: "New Agent Chat")])
        #expect(!text.contains("`⌘J S`"))
        #expect(text.contains("- " + HomeStrings.chiefWelcomeChord("⌘J", "S") + " New Agent Chat"))
    }

    /// The welcome lists the shortcuts people use every day, with the keys the real keymap gives them, in that
    /// order (cmux#48416): not rarely used ones such as Show/Hide Chief or New Agent Chat.
    @Test func listsTheDailyShortcutsFromTheRealKeymap() throws {
        let registry = ActionRegistry.standard()
        let text = ChiefWelcome.text(registry)
        let expected: [(ActionID, String)] = [("newTab", "⌘N"), ("newTab.default", "⌘T"), ("splitRight", "⌘D"), ("splitDown", "⇧⌘D"),
                                               ("focusLocation", "⌘L"), ("openBrowser", "⇧⌘L"), (ChiefWelcome.goToAction, "⌘P"), ("commandPalette", "⇧⌘P")]
        var last = text.startIndex
        for (id, keys) in expected {
            #expect(registry.shortcutDisplay(for: id) == keys, "\(id)")
            // The welcome drops a title's trailing "…" (Command Palette…): it names the command, it opens nothing.
            let full = try #require(registry.descriptor(for: id)?.title)
            let title = full.hasSuffix("…") ? String(full.dropLast()) : full
            let line = try #require(text.range(of: "- `\(keys)` \(title)"), "\(id)")
            #expect(line.upperBound == text.endIndex || text[line.upperBound] == "\n", "\(id) is the whole line")
            #expect(line.lowerBound > last, "\(id) is in order")
            last = line.lowerBound
        }
        for rare: ActionID in ["home.openChiefDock", "palette.newAgentChat", "newSurface", "search.chats"] {
            let title = try #require(registry.descriptor(for: rare)?.title)
            #expect(!text.contains(title.hasSuffix("…") ? String(title.dropLast()) : title), "\(rare) is not listed")
        }
    }
}
