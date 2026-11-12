import AppKit
@testable import CmuxNextFocusUI
import Foundation
import Testing

/// The keys typed for a New Terminal Tab while its create waits (`CreationInputBuffer.open(…, newTerminal: true)`,
/// `NewTerminalKeys`), at the level of the hold: which keys are the new terminal's, and where they go when the daemon
/// refuses the tab, makes it, or makes it and the store never lists its tab. `NewTerminalTabRefusedKeysTests` shows the
/// same in the app on a real daemon.
@MainActor @Suite struct NewTerminalKeysTests {
    /// The daemon's tab of a made terminal, as the store lists it later.
    @MainActor private final class Store {
        var tab: String?
    }

    private static func key(_ character: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                                      isARepeat: false, keyCode: 0))
    }

    /// What the hold's end gives for each key: `run` (as typed, in what has the keyboard) or `type <tab>` (into that tab's terminal).
    private static func ends(_ keys: [CreationInputBuffer.HeldKey]) -> [String] {
        keys.map { key in
            switch key {
            case .run: "run"
            case .type(let events, let lane): "type \(events.count) into \(lane.tab)"
            case .command(_, let lane): "command in \(lane.tab)"
            }
        }
    }

    /// No stand-in (a daemon from before `terminal-placement-env-v1`): the focus names the terminal of the press. A key
    /// typed while the create is the person's newest intent is the new terminal's, and goes with a refused create.
    @Test func aKeyTypedForARefusedNewTerminalTabWithNoStandInGoesIntoNoTerminal() throws {
        let buffer = CreationInputBuffer(began: .now)
        let ticket = buffer.open(generation: 7, machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "press", forNewestIntent: true)
        buffer.resolve(ticket, awaitsFocus: false)
        #expect(buffer.isEmpty, "the refused create left its key in the hold")
        #expect(Self.ends(buffer.take(focused: "press") { _, _ in false }).isEmpty)
    }

    /// The same create, and the person moved to another pane before they typed (not their newest intent any more): the
    /// key is not the new terminal's. It stays, and runs as typed where the keyboard is.
    @Test func aKeyTypedAfterThePersonMovedIsNotTheNewTerminals() throws {
        let buffer = CreationInputBuffer(began: .now)
        let ticket = buffer.open(generation: 7, machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "other", forNewestIntent: false)
        buffer.resolve(ticket, awaitsFocus: false)
        #expect(Self.ends(buffer.take(focused: "other") { _, _ in false }) == ["run"], "the key typed after the person moved went with the refused create")
    }

    /// A create that is no New Terminal Tab keeps its rule: a key typed for no creation's tab has no lane.
    @Test func aKeyTypedWhileAnotherCreationWaitsKeepsNoLane() throws {
        let buffer = CreationInputBuffer(began: .now)
        let ticket = buffer.open(generation: 7, machine: "local")
        buffer.capture(try Self.key("l"), focusedTab: "press", forNewestIntent: true)
        buffer.resolve(ticket, awaitsFocus: false)
        #expect(Self.ends(buffer.take(focused: "press") { _, _ in false }) == ["run"], "a failed split dropped a key typed in the terminal of the press")
    }

    /// With a stand-in: the focus names the stand-in while the person types, and the daemon refuses the tab.
    @Test func aKeyTypedForARefusedStandInGoesIntoNoTerminal() throws {
        let buffer = CreationInputBuffer(began: .now)
        let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
        buffer.capture(try Self.key("s"), focusedTab: "other") // typed after the person moved to another pane
        buffer.resolve(ticket, awaitsFocus: false)
        #expect(Self.ends(buffer.take(focused: "other") { _, _ in false }) == ["run"], "only the key typed after the move stays")
    }

    /// The daemon made the tab: the keys wait for the store to list it, then go into that tab's terminal (typed into it
    /// when it is not the focused one, run as typed when it is). The stand-in's id names no tab then.
    @Test func theKeysOfAMadeTerminalGoIntoItsTab() throws {
        for focused in ["press", "tab_9"] {
            let buffer = CreationInputBuffer(began: .now), store = Store()
            let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "local", newTerminal: true)
            buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
            buffer.capture(try Self.key("s"), focusedTab: "pending_tab_1")
            buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab })
            #expect(buffer.awaitsMadeTerminal, "the hold does not wait for the made terminal's tab")
            store.tab = "tab_9"
            #expect(!buffer.awaitsMadeTerminal, "the hold still waits after the store listed the tab")
            let ends = Self.ends(buffer.take(focused: focused) { _, _ in false })
            #expect(ends == (focused == "tab_9" ? ["run", "run"] : ["type 2 into tab_9"]), "focused \(focused): \(ends)")
        }
    }

    /// The daemon made the tab and the store never lists it by the hold's end: the keys are counted and go nowhere, with
    /// a stand-in or with none.
    @Test func theKeysOfAMadeTerminalWithNoTabGoNowhere() throws {
        for standIn in ["pending_tab_1", nil] {
            let buffer = CreationInputBuffer(began: .now), store = Store()
            let ticket = buffer.open(generation: 7, tab: standIn, machine: "local", newTerminal: true)
            buffer.capture(try Self.key("l"), focusedTab: standIn ?? "press", forNewestIntent: true)
            buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab })
            let ends = Self.ends(buffer.take(focused: "press") { _, _ in false })
            #expect(ends.isEmpty && buffer.untypedTerminalKeys == 1, "stand-in \(standIn ?? "none"): \(ends), \(buffer.untypedTerminalKeys) counted")
        }
    }

    /// Past the reply bound the create is off the list: its keys run as typed, as every creation's do (cmux-ad m12).
    @Test func pastTheReplyBoundTheKeysRunAsTyped() throws {
        let buffer = CreationInputBuffer(began: .now)
        _ = buffer.open(generation: 7, machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "press", forNewestIntent: true)
        buffer.endReplyWait(personMoves: nil) { _ in true }
        #expect(Self.ends(buffer.take(focused: "press") { _, _ in false }) == ["run"])
    }
}
