import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextTerminal
import Testing

/// GHOSTTY-CONFIG keybind precedence (plans/cmux-next/ghostty-config.md,
/// "Keybinds"; PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS): cmux.json
/// shortcuts > user Ghostty keybinds (app-wide; a terminal action or
/// `unbind` takes the key from cmux's defaults) > cmux defaults > Ghostty
/// defaults, all resolved by the one binding table.
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

    /// The user's Ghostty keybind for an action cmux owns wins over cmux's
    /// default app-wide (PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS
    /// amendment 3): in a page the routed action (Split Down) runs.
    @Test func outsideATerminalTheUserGhosttyKeybindAlsoWins() throws {
        let services = Self.services(user: [Self.userLine])
        #expect(Self.owner(services, try Self.commandD(), M.page) == .action("splitDown"))
        let sidebar = M.focused(.terminal, tab: "t1", target: .sidebar(keyboard: false))
        #expect(Self.owner(services, try Self.commandD(), sidebar) == .action("splitDown"))
    }

    /// Copy mode takes every key before Ghostty, so the dispatcher runs the
    /// user's Ghostty keybind as its routed action there.
    @Test func inCopyModeTheUserGhosttyKeybindRunsAsItsRoutedAction() throws {
        let services = Self.services(user: [Self.userLine])
        #expect(Self.owner(services, try Self.commandD(), M.terminal, copyMode: true) == .action("splitDown"))
    }

    // MARK: Terminal actions and unbind (claims)

    static let controlShiftH = Shortcut("h", modifiers: [.control, .shift])
    static func controlShiftHEvent() throws -> NSEvent { try K.key("H", keyCode: 4, [.control, .shift]) }

    /// A Ghostty keybind that maps Ctrl-Shift-H to a terminal action (or
    /// unbinds it) beats cmux's default Resize Pane Left on that key: the
    /// terminal gets the key, and no cmux default runs anywhere else.
    @Test func aGhosttyTerminalActionOrUnbindBeatsTheCmuxDefaultOnThatKey() throws {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(Self.owner(services, try Self.controlShiftHEvent(), M.terminal) == .action("resizePaneLeft"))
        services.keyRouter.loadGhosttyKeybinds([], defaults: [], claims: [Self.controlShiftH])
        #expect(Self.owner(services, try Self.controlShiftHEvent(), M.terminal) == .surface)
        #expect(Self.owner(services, try Self.controlShiftHEvent(), M.page) == .surface)
        // The action keeps its other default key (Cmd-Ctrl-Left).
        let arrow = try K.key(K.left, keyCode: 123, [.command, .control, .numericPad, .function])
        #expect(Self.owner(services, arrow, M.terminal) == .action("resizePaneLeft"))
    }

    /// cmux.json still wins over a Ghostty claim on the same key.
    @Test func aCmuxJsonShortcutBeatsAGhosttyClaim() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.keyRouter.loadGhosttyKeybinds([], defaults: [], claims: [Self.controlShiftH])
        services.registry.setShortcutOverride(Self.controlShiftH, for: "equalizeSplits")
        #expect(Self.owner(services, try Self.controlShiftHEvent(), M.terminal) == .action("equalizeSplits"))
    }

    /// Settings lists a claimed default as overridden by the Ghostty config,
    /// read-only, with its source.
    @Test func theKeyboardShortcutsPageListsAClaimedDefaultWithItsSource() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.keyRouter.loadGhosttyKeybinds([], defaults: [], claims: [Self.controlShiftH])
        let list = KeybindingReports.pageList(["command": .string("resizePaneLeft")], registry: services.registry)
        let rows = try #require(list.objectValue?["bindings"]?.arrayValue).compactMap(\.objectValue)
        let claimed = try #require(rows.first { $0["key"]?.stringValue == "shift+ctrl+h" })
        #expect(claimed["removed"] == .bool(true))
        #expect(claimed["removedBy"] == .string("ghostty"))
        #expect(claimed["source"] == .string("default"))
    }

    // MARK: Live layer

    /// A Ghostty config reload that moves `goto_split:left` to another key
    /// moves the binding, with no cmux.json change (the sync reloads the
    /// layer from the config on every change; nothing is imported).
    @Test func aConfigReloadChangingGotoSplitMovesTheBinding() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let y = GhosttyHostKeybind(key: .unicode(121), modifiers: [.command, .control], action: .gotoSplit(.left))
        let u = GhosttyHostKeybind(key: .unicode(117), modifiers: [.command, .control], action: .gotoSplit(.left))
        let commandControlY = try K.key("y", keyCode: 16, [.command, .control])
        let commandControlU = try K.key("u", keyCode: 32, [.command, .control])
        services.keyRouter.loadGhosttyKeybinds([y], defaults: [])
        #expect(Self.owner(services, commandControlY, M.page) == .action("focusLeft"))
        services.keyRouter.loadGhosttyKeybinds([u], defaults: [])
        #expect(Self.owner(services, commandControlU, M.page) == .action("focusLeft"))
        #expect(Self.owner(services, commandControlY, M.page) != .action("focusLeft"))
        #expect(services.registry.shortcutOverrides.isEmpty)
        #expect(services.registry.keyBindingLayers.user.isEmpty)
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
