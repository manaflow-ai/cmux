import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// GHOSTTY-CONFIG keybind precedence (plans/cmux-next/ghostty-config.md,
/// "Keybinds"): cmux.json shortcuts > user Ghostty keybinds (focused
/// terminal) > cmux defaults > Ghostty defaults, all resolved by the one
/// binding table.
@MainActor
struct GhosttyKeybindPrecedenceTests {
    typealias K = KeyInterceptionTests
    typealias M = KeyOwnershipMatrixTests

    /// Ghostty's macOS default `super+d=new_split:right`.
    static let ghosttyDefault = GhosttyHostKeybind(key: .unicode(100), modifiers: [.command], action: .newSplit(.right))
    /// The user's Ghostty config line `keybind = super+d=new_split:down`.
    static let userLine = GhosttyHostKeybind(key: .unicode(100), modifiers: [.command], action: .newSplit(.down))

    static func commandD() throws -> NSEvent { try K.key("d", keyCode: 2, [.command]) }

    static func services(user: [GhosttyHostKeybind], defaults: [GhosttyHostKeybind] = [ghosttyDefault]) -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.keyRouter.loadGhosttyKeybinds(user, defaults: defaults)
        return services
    }

    static func owner(_ services: AppServices, _ event: NSEvent, _ focus: FocusState, copyMode: Bool = false) -> KeyOwner {
        M.owner(services, event, M.Surface(name: "", focus: focus, facts: KeyOwnershipFacts(terminalCopyMode: copyMode)))
    }

    /// The user's Ghostty `super+d` beats cmux's default Cmd-D (Split Right)
    /// while a terminal has the keyboard: the terminal gets the key and
    /// Ghostty runs the user's `new_split:down`.
    @Test func aUserGhosttyKeybindBeatsTheCmuxDefaultInAFocusedTerminal() throws {
        let services = Self.services(user: [Self.userLine])
        #expect(Self.owner(services, try Self.commandD(), M.terminal) == .surface)
    }

    /// Outside a terminal the user's Ghostty keybind is a fallback only:
    /// cmux's default still runs.
    @Test func outsideATerminalTheCmuxDefaultStillWins() throws {
        let services = Self.services(user: [Self.userLine])
        #expect(Self.owner(services, try Self.commandD(), M.page) == .action("splitRight"))
    }

    /// Copy mode takes every key before Ghostty, so a Ghostty keybind
    /// cannot win there.
    @Test func inCopyModeTheCmuxDefaultStillWins() throws {
        let services = Self.services(user: [Self.userLine])
        #expect(Self.owner(services, try Self.commandD(), M.terminal, copyMode: true) == .action("splitRight"))
    }

    /// A cmux.json shortcut beats the user's Ghostty keybind, also in a terminal.
    @Test func aCmuxJsonShortcutBeatsTheUserGhosttyKeybind() throws {
        let services = Self.services(user: [Self.userLine])
        services.registry.setShortcutOverride(Shortcut("d", modifiers: [.command]), for: "newSurface")
        #expect(Self.owner(services, try Self.commandD(), M.terminal) == .action("newSurface"))
    }

    /// A trigger equal to Ghostty's own default is a Ghostty default: cmux's
    /// default for the same chord wins over it, also in a terminal.
    @Test func aGhosttyDefaultKeybindLosesToTheCmuxDefault() throws {
        let services = Self.services(user: [Self.ghosttyDefault])
        #expect(Self.owner(services, try Self.commandD(), M.terminal) == .action("splitRight"))
    }

    /// The Ghostty keybinds are entries of the one binding table (so
    /// `keybinding.list`, which-key and the hints see them), not a second
    /// lookup after it.
    @Test func ghosttyKeybindsAreEntriesOfTheBindingTable() {
        let services = Self.services(user: [Self.userLine])
        let entries = RegistryKeyBindings(services.registry).table.entries
        #expect(entries.contains { $0.command == "splitDown" && $0.keys == [Shortcut("d", modifiers: [.command])] })
    }

    // MARK: R88 with Ghostty entries (regression lock, coordinator 2026-10-05: option A)

    /// A cmux entry whose `when` is false does not match: the user's Ghostty
    /// keybind on the same chord gets the key (Cmd-Y is Show History only in
    /// a page; in a terminal the user's `super+y=toggle_split_zoom` wins).
    @Test func aCmuxEntryWhoseWhenIsFalseLetsTheGhosttyKeybindHaveTheKey() throws {
        let zoom = GhosttyHostKeybind(key: .unicode(121), modifiers: [.command], action: .toggleSplitZoom)
        let services = Self.services(user: [zoom], defaults: [])
        let candidate = try #require(services.keyRouter.candidate(for: try K.key("y", keyCode: 16, [.command]), focus: M.terminal))
        #expect(candidate.id == "toggleSplitZoom")
        #expect(candidate.source == .ghostty(arguments: [:]))
    }

    /// The table rule both cases rest on: a `when`-false cmux entry lets the
    /// Ghostty entries below it win; a cmux entry whose `when` holds but
    /// whose action cannot run stops the search (R88), so no Ghostty entry
    /// runs and the dispatcher delivers the key to the focused surface.
    @Test func aBlockedCmuxEntryStopsTheSearchBeforeTheGhosttyEntries() {
        let key = Shortcut("y", modifiers: [.command])
        let terminal = KeyContext([KeyContext.surfaceKind: .string("terminal")])
        let table = KeyBindingTable([
            KeyBinding(keys: [key], command: "fallback", source: .ghosttyFallback),
            KeyBinding(keys: [key], command: "cmux", when: .equals(KeyContext.surfaceKind, .string("page"))),
            KeyBinding(keys: [key], command: "ghostty", when: GhosttyKeyBindingLayer.terminalFocused, source: .ghostty),
        ])
        let whenFalse = table.resolve([key], in: KeyContext([KeyContext.surfaceKind: .string("sidebar")])) { _ in true }
        #expect(whenFalse.winner?.command == "fallback")
        #expect(whenFalse.candidates.map(\.verdict) == [.whenFalse, .whenFalse, .won])
        #expect(table.resolve([key], in: terminal) { _ in true }.winner?.command == "ghostty")

        let blocked = KeyBindingTable([
            KeyBinding(keys: [key], command: "fallback", source: .ghosttyFallback),
            KeyBinding(keys: [key], command: "cmux", when: .equals(KeyContext.surfaceKind, .string("terminal"))),
        ]).resolve([key], in: terminal) { $0 != "cmux" }
        #expect(blocked.winner == nil)
        #expect(blocked.candidates.map(\.verdict) == [.notRunnable, .shadowed])
    }
}
