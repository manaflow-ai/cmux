import AppKit
import CmuxNextActions
import Testing

/// The palette's shortcut recorder asks the registry whether a chord can
/// become an action's shortcut (plans/cmux-next/focus.md section 5 for the
/// tiers and the Chrome and Ghostty rules).
@MainActor
@Suite struct ShortcutAssessmentTests {
    static func action(_ id: ActionID, _ shortcut: Shortcut? = nil, requires: ActionContext = [],
                       family: ShortcutFamily? = nil) -> ActionDescriptor {
        ActionDescriptor(id: id, title: id.rawValue, defaultShortcut: shortcut, shortcutFamily: family, category: .workspace,
                         requires: requires)
    }

    /// Owners: a terminal action (⌘E), a browser action (⌘J), a plain one
    /// (⌘G), Quit (⌘Q, tier 0), a numbered family (⌘1…9); targets with no
    /// shortcut in each context.
    static func registry() -> ActionRegistry {
        ActionRegistry(catalog: [
            action("a.terminal", Shortcut("e"), requires: [.terminalFocused]),
            action("a.browser", Shortcut("j"), requires: [.browserFocused]),
            action("a.plain", Shortcut("g")),
            action("quit", Shortcut("q")),
            action("fam", Shortcut("1"), family: .digits),
            action("t.plain"),
            action("t.terminal", requires: [.terminalFocused]),
            action("t.browser", requires: [.browserFocused]),
        ])
    }

    static let none = ShortcutEditEnvironment()

    @Test func aChordNeedsCommandOrControl() {
        let registry = Self.registry()
        for modifiers: NSEvent.ModifierFlags in [[], [.option], [.shift], [.option, .shift]] {
            #expect(registry.assessShortcut(Shortcut("x", modifiers: modifiers), for: "t.plain", environment: Self.none) == .refused(.needsModifier))
        }
        #expect(registry.assessShortcut(Shortcut("x", modifiers: [.control]), for: "t.plain", environment: Self.none) == .available(notes: []))
    }

    @Test func macOSChordsAreRefused() {
        let assessment = Self.registry().assessShortcut(Shortcut(" ", modifiers: [.command]), for: "t.plain", environment: Self.none)
        #expect(assessment == .refused(.reservedByMacOS(name: "Spotlight")))
    }

    @Test func aSystemActionsChordIsRefused() {
        #expect(Self.registry().assessShortcut(Shortcut("q"), for: "t.plain", environment: Self.none) == .refused(.systemAction("quit")))
    }

    @Test func aNumberedFamilyIsRefusedBothWays() {
        let registry = Self.registry()
        #expect(registry.assessShortcut(Shortcut("3"), for: "t.plain", environment: Self.none) == .refused(.numberedFamily("fam")))
        #expect(registry.assessShortcut(Shortcut("k", modifiers: [.command, .shift]), for: "fam", environment: Self.none)
            == .refused(.editsNumberedFamily))
    }

    /// Control-1…6 switch the right sidebar there while Control-1…9 select a
    /// tab elsewhere: a family in another context can share, never be replaced.
    @Test func aNumberedFamilyInAnotherContextCanOnlyBeShared() {
        let registry = ActionRegistry(catalog: Self.registry().descriptors + [
            Self.action("t.sidebar", requires: [.rightSidebarFocused]),
        ])
        #expect(registry.assessShortcut(Shortcut("3"), for: "t.sidebar", environment: Self.none)
            == .conflict(owners: ["fam"], canKeepBoth: true, canReplace: false, notes: []))
    }

    @Test func sameContextConflictCannotKeepBoth() {
        let registry = Self.registry()
        #expect(registry.assessShortcut(Shortcut("g"), for: "t.plain", environment: Self.none)
            == .conflict(owners: ["a.plain"], canKeepBoth: false, canReplace: true, notes: []))
        #expect(registry.assessShortcut(Shortcut("e"), for: "t.terminal", environment: Self.none)
            == .conflict(owners: ["a.terminal"], canKeepBoth: false, canReplace: true, notes: []))
    }

    @Test func differentContextsCanKeepBoth() {
        #expect(Self.registry().assessShortcut(Shortcut("j"), for: "t.terminal", environment: Self.none)
            == .conflict(owners: ["a.browser"], canKeepBoth: true, canReplace: true, notes: []))
    }

    @Test func anActionsOwnShortcutIsNoConflict() {
        #expect(Self.registry().assessShortcut(Shortcut("g"), for: "a.plain", environment: Self.none) == .available(notes: []))
    }

    @Test func userOverridesCountAsOwners() {
        let registry = Self.registry()
        registry.setShortcutOverride(Shortcut("u"), for: "a.plain")
        #expect(registry.assessShortcut(Shortcut("g"), for: "t.plain", environment: Self.none) == .available(notes: []))
        #expect(registry.assessShortcut(Shortcut("u"), for: "t.plain", environment: Self.none)
            == .conflict(owners: ["a.plain"], canKeepBoth: false, canReplace: true, notes: []))
    }

    /// Tiers 0 and 1 run before a page; a tier 2 action only in its own
    /// context, so a terminal-only action leaves a page its Chrome chord.
    @Test func chromeChordsSayWhoWinsInAPage() {
        let registry = Self.registry()
        let chrome = ShortcutEditEnvironment(chromeChords: [Shortcut("y")])
        #expect(registry.assessShortcut(Shortcut("y"), for: "t.plain", environment: chrome) == .available(notes: [.chromeChord(cmuxWins: true)]))
        #expect(registry.assessShortcut(Shortcut("y"), for: "t.browser", environment: chrome) == .available(notes: [.chromeChord(cmuxWins: true)]))
        #expect(registry.assessShortcut(Shortcut("y"), for: "t.terminal", environment: chrome) == .available(notes: [.chromeChord(cmuxWins: false)]))
    }

    @Test func aGhosttyKeybindIsNamed() {
        let ghostty = ShortcutEditEnvironment(ghosttyBinding: { $0 == Shortcut("h", modifiers: [.command, .control]) ? "Focus Pane Left" : nil })
        #expect(Self.registry().assessShortcut(Shortcut("h", modifiers: [.command, .control]), for: "t.plain", environment: ghostty)
            == .available(notes: [.ghosttyKeybind("Focus Pane Left")]))
    }

    /// The catalog's own defaults never trip the recorder's refusals (a
    /// restored default saves without a detour).
    @Test func catalogDefaultsAreNotRefused() {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors where descriptor.shortcutFamily == nil {
            guard let shortcut = descriptor.defaultShortcut, !shortcut.modifiers.isDisjoint(with: [.command, .control]) else { continue }
            if case .refused(let refusal) = registry.assessShortcut(shortcut, for: descriptor.id, environment: Self.none) {
                guard case .reservedByMacOS = refusal else {
                    Issue.record("\(descriptor.id.rawValue) default \(shortcut.displayString) refused: \(refusal)")
                    continue
                }
            }
        }
    }
}
