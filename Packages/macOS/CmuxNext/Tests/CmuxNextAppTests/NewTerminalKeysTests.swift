import AppKit
@testable import CmuxNextFocusUI
import Foundation
import Observation
import Testing

/// The keys typed for a New Terminal Tab while its create waits (`CreationInputBuffer.open(…, newTerminal: true)`,
/// `NewTerminalKeys`), at the level of the hold: which keys are the new terminal's, and where they go when the daemon
/// refuses the tab, makes it, or makes it and the store never lists its tab. `NewTerminalTabRefusedKeysTests` shows the
/// same in the app on a real daemon.
@MainActor @Suite struct NewTerminalKeysTests {
    /// The daemon's tab of a made terminal, as the store lists it later. Observable, as the store's tab list is: the
    /// hold's wake-up is a change of what this read.
    @MainActor @Observable final class Store {
        var tab: String?
        /// How many times a hold read ``tab`` through ``read()``.
        @ObservationIgnored private(set) var reads = 0

        func read() -> String? {
            reads += 1
            return tab
        }
    }

    /// The wake-ups a hold gave, and a wait for the first one.
    @MainActor final class Wakes {
        private(set) var count = 0
        private var waiter: CheckedContinuation<Void, Never>?

        func note() {
            count += 1
            waiter?.resume()
            waiter = nil
        }

        /// Returns after the first wake-up (at once when it came before).
        func first() async {
            if count == 0 { await withCheckedContinuation { waiter = $0 } }
        }
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

    /// The daemon made the tab and the store lists it: the keys go into that tab's terminal (typed into it when it is not
    /// the focused one, run as typed when it is). The stand-in's id names no tab then. Until the store lists the tab the
    /// hold waits for it, with a stand-in too: the reply can settle the create at once, and the stand-in is gone then.
    @Test func theKeysOfAMadeTerminalGoIntoItsTab() throws {
        for focused in ["press", "tab_9"] {
            let buffer = CreationInputBuffer(began: .now), store = Store()
            let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "local", newTerminal: true)
            buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
            buffer.capture(try Self.key("s"), focusedTab: "pending_tab_1")
            buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab })
            #expect(buffer.awaitsMadeTerminal, "the hold does not wait for the tab of a made terminal that has a stand-in")
            store.tab = "tab_9"
            #expect(!buffer.awaitsMadeTerminal, "the hold still waits after the store listed the tab")
            let ends = Self.ends(buffer.take(focused: focused) { _, _ in false })
            #expect(ends == (focused == "tab_9" ? ["run", "run"] : ["type 2 into tab_9"]), "focused \(focused): \(ends)")
        }
    }

    /// No stand-in (an older daemon), the daemon made the tab and the store does not list it yet: the hold waits for the
    /// tab only while it holds a key of the new terminal. A key typed after the person moved does not make it wait.
    @Test func theHoldWaitsForAMadeTerminalsTabOnlyWhileItHoldsAKeyOfIt() throws {
        let buffer = CreationInputBuffer(began: .now), store = Store()
        let ticket = buffer.open(generation: 7, machine: "local", newTerminal: true)
        buffer.capture(try Self.key("s"), focusedTab: "other", forNewestIntent: false)
        buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab })
        #expect(!buffer.awaitsMadeTerminal, "the hold waits for a made terminal that has no key in it")
        buffer.capture(try Self.key("l"), focusedTab: "press", forNewestIntent: true)
        #expect(buffer.awaitsMadeTerminal, "the hold does not wait for the tab of a made terminal whose key it holds")
        store.tab = "tab_9"
        #expect(!buffer.awaitsMadeTerminal, "the hold still waits after the store listed the tab")
        let ends = Self.ends(buffer.take(focused: "other") { _, _ in false })
        #expect(ends == ["run", "type 1 into tab_9"], "\(ends)")
    }

    /// A stand-in whose view sends no key before its terminal exists (a daemon that does not queue such input: another
    /// machine's): typed into that view, the keys are dropped with it. So the hold waits for the daemon's tab as with no
    /// stand-in, the keys go into that tab, and with no tab at the hold's end they are counted and go into no terminal
    /// (review of the fix: with no wait, they went into the stand-in's view and were lost with no count).
    @Test func theKeysOfAStandInThatSendsNothingWaitForTheMadeTerminalsTab() throws {
        for listed in [true, false] {
            let buffer = CreationInputBuffer(began: .now), store = Store()
            let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "remote", newTerminal: true, standInSends: false)
            buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
            #expect(!buffer.awaitsMadeTerminal, "the hold waits for a tab before the create's reply")
            buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab })
            #expect(buffer.awaitsMadeTerminal, "the hold does not wait for the tab of a made terminal whose stand-in sends nothing")
            if listed { store.tab = "tab_9" }
            #expect(buffer.awaitsMadeTerminal == !listed, "listed \(listed): the wait does not follow the store")
            let ends = Self.ends(buffer.take(focused: "other") { _, _ in false })
            #expect(ends == (listed ? ["type 1 into tab_9"] : []) && buffer.untypedTerminalKeys == (listed ? 0 : 1), "listed \(listed): \(ends), \(buffer.untypedTerminalKeys) counted")
        }
    }

    /// The daemon made the tab, the store does not list it by the hold's end, and there is no stand-in (an older daemon):
    /// no terminal is the keys' own. They are lost: counted, and no terminal gets them (not the terminal of the press).
    @Test func theKeysOfAMadeTerminalWithNoTabAndNoStandInAreLostAndGoIntoNoTerminal() throws {
        let buffer = CreationInputBuffer(began: .now), store = Store()
        let ticket = buffer.open(generation: 7, machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "press", forNewestIntent: true)
        buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab })
        let ends = Self.ends(buffer.take(focused: "press") { _, _ in false })
        #expect(ends.isEmpty && buffer.untypedTerminalKeys == 1, "\(ends), \(buffer.untypedTerminalKeys) counted")
    }

    /// The same end (the hold's limit: the hold waited for the tab, and it did not come) with a stand-in: its view is the
    /// new terminal's own, so the keys go into it (run as typed when it has the keyboard, typed into it when not). The
    /// hold counts none as lost here; the view sends them by the terminal's id.
    @Test func theKeysOfAMadeTerminalWithNoTabYetGoIntoItsStandIn() throws {
        for focused in ["press", "pending_tab_1"] {
            let buffer = CreationInputBuffer(began: .now), store = Store()
            let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "local", newTerminal: true)
            buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
            buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab })
            #expect(buffer.awaitsMadeTerminal, "the hold does not wait for the tab of a made terminal that has a stand-in")
            let ends = Self.ends(buffer.take(focused: focused) { _, _ in false })
            #expect(ends == (focused == "press" ? ["type 1 into pending_tab_1"] : ["run"]) && buffer.untypedTerminalKeys == 0, "focused \(focused): \(ends), \(buffer.untypedTerminalKeys) counted")
        }
    }

    /// The id of the made terminal, as the create's reply named it, goes with the keys of its lane (`HeldLane.madeSurface`).
    /// The hold's end has it while the store lists no tab (the app sends the keys to that id when the stand-in's view is
    /// gone: NewTerminalTabRefusedKeysTests shows that on a real daemon), when the store lists the tab, and when another
    /// hold holds the keys again (a key that ran again opened a creation there). The lane of a split has none.
    @Test func theLaneOfAMadeTerminalCarriesTheIdThatTheReplyNamed() throws {
        typealias Lane = CreationInputBuffer.HeldLane
        let buffer = CreationInputBuffer(began: .now), store = Store()
        let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
        buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.tab }, madeSurface: 77)
        let taken = buffer.take(focused: "other") { _, _ in false }
        let lanes: [Lane?] = taken.map(\.lane)
        let notListed: [Lane?] = [Lane(tab: "pending_tab_1", machine: "local", madeSurface: 77)]
        #expect(lanes == notListed, "no tab in the store: \(lanes)")

        let next = CreationInputBuffer(began: .now)
        next.prepend(taken.flatMap(\.keys), issuer: nil)
        let again: [Lane?] = next.take(focused: "other") { _, _ in false }.map(\.lane)
        #expect(again == notListed, "held again by another hold: \(again)")

        let second = CreationInputBuffer(began: .now)
        let made = second.open(generation: 8, tab: "pending_tab_2", machine: "local", newTerminal: true)
        second.capture(try Self.key("s"), focusedTab: "pending_tab_2")
        second.resolve(made, awaitsFocus: true, madeTab: { "tab_9" }, madeSurface: 78)
        let named: [Lane?] = second.take(focused: "other") { _, _ in false }.map(\.lane)
        let listed: [Lane?] = [Lane(tab: "tab_9", machine: "local", madeSurface: 78)]
        #expect(named == listed, "the store lists the tab: \(named)")

        let third = CreationInputBuffer(began: .now)
        let split = third.open(generation: 9, tab: "split_tab", machine: "local")
        third.capture(try Self.key("x"), focusedTab: "split_tab")
        third.resolve(split, awaitsFocus: true)
        let plain: [Lane?] = third.take(focused: "other") { _, _ in false }.map(\.lane)
        let noId: [Lane?] = [Lane(tab: "split_tab", machine: "local")]
        #expect(plain == noId, "a split's lane: \(plain)")
    }

    /// The wake-up. The hold waits for a made terminal's tab and the flush's gate asked it (`holdsForMadeTab(wake:)`): the
    /// change of the store that lists the tab wakes the hold one time, with no poll and no timer. A second ask while it
    /// waits arms no second observation. Before the create's reply the hold waits for no tab and arms nothing.
    @Test(.timeLimit(.minutes(1))) func theStoresListingOfTheMadeTabWakesTheHoldOneTime() async throws {
        let buffer = CreationInputBuffer(began: .now), store = Store(), wakes = Wakes()
        let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
        let beforeTheReply = buffer.holdsForMadeTab(wake: { wakes.note() })
        #expect(!beforeTheReply && !buffer.watchesMadeTab, "the hold waits for a tab before the create's reply")
        buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.read() })
        let armed = buffer.holdsForMadeTab(wake: { wakes.note() })
        #expect(armed && buffer.watchesMadeTab, "the hold armed no wake-up for the made terminal's tab")
        let watch = try #require(buffer.newTerminals.tabWatch)
        let again = buffer.holdsForMadeTab(wake: { wakes.note() })
        let sameWatch = buffer.newTerminals.tabWatch == watch
        #expect(again && sameWatch, "a second ask armed a second observation")
        // The observation reads the store one time before it waits for a change: the listing below is then a change
        // that it hears, not its first value. The time limit of the test is the only bound of these two waits.
        let reads = store.reads
        while store.reads == reads { await Task.yield() }
        #expect(wakes.count == 0, "the hold woke before the store listed the tab")
        store.tab = "tab_9"
        await wakes.first()
        await watch.value
        #expect(wakes.count == 1 && !buffer.awaitsMadeTerminal && !buffer.watchesMadeTab, "\(wakes.count) wake-ups, waits \(buffer.awaitsMadeTerminal), armed \(buffer.watchesMadeTab)")
        let ends = Self.ends(buffer.take(focused: "other") { _, _ in false })
        #expect(ends == ["type 1 into tab_9"], "\(ends)")
    }

    /// The hold ended by its limit or by a close of its window while it waited for the tab: the observation is cancelled,
    /// its task ends, and a tab that the store lists later wakes nothing.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aHoldThatEndsByItsLimitOrByACloseCancelsItsWaitForTheTab(_ closes: Bool) async throws {
        let buffer = CreationInputBuffer(began: .now), store = Store(), wakes = Wakes()
        let ticket = buffer.open(generation: 7, tab: "pending_tab_1", machine: "local", newTerminal: true)
        buffer.capture(try Self.key("l"), focusedTab: "pending_tab_1")
        buffer.resolve(ticket, awaitsFocus: true, madeTab: { store.read() })
        let armed = buffer.holdsForMadeTab(wake: { wakes.note() })
        #expect(armed, "the hold armed no wake-up for the made terminal's tab")
        let watch = try #require(buffer.newTerminals.tabWatch)
        // The hold's end gives the key to the stand-in's view (the hold-level result: one run of 1 key for its tab).
        var given: [String] = []
        if closes {
            for run in buffer.takeForClosedWindow(window: 1) { given.append("type \(run.0.count) into \(run.1.tab)") }
        } else {
            given = Self.ends(buffer.take(focused: "other") { _, _ in false })
        }
        #expect(given == ["type 1 into pending_tab_1"], "closes \(closes): \(given)")
        #expect(watch.isCancelled && !buffer.watchesMadeTab, "closes \(closes): the hold's end left its observation armed")
        await watch.value // the cancelled observation ends: nothing waits for the store any more
        store.tab = "tab_9"
        #expect(wakes.count == 0, "closes \(closes): the ended hold woke \(wakes.count) time(s)")
    }

    /// The hold's count of lost keys (`CreationHoldLog.lostKeys`, the number in the log line of the hold's end): the keys
    /// that no terminal could take (the hold's own count) and the keys that the hold's end gave to a terminal that was
    /// gone (the person closed it; a made New Terminal Tab's with no listed tab are not of this kind: they go to the made
    /// terminal by its id). Before this, the second kind was in no count. Keys that a gone terminal took before this end began are not this hold's,
    /// and the next hold starts at 0.
    @Test func theHoldsEndCountsTheKeysThatAGoneTerminalTook() {
        var log = CreationHoldLog()
        log.wentWithTerminal(5)
        let end = log.end(in: 7, forced: .limitReached)
        log.wentWithTerminal(33)
        log.noteEnded(end, window: 7, keys: 1, lastAction: nil, untyped: 2)
        #expect(end == .limitReached && log.lostKeys[7] == 35, "the hold ended \(end) with \(String(describing: log.lostKeys[7])) keys in its count")
        #expect(log.lostKeys[8] == nil, "a window with no hold has a count")
        let next = log.end(in: 7, forced: nil)
        log.noteEnded(next, window: 7, keys: 4, lastAction: nil)
        #expect(next == .focusLanded && log.lostKeys[7] == 0, "the next hold ended \(next) with \(String(describing: log.lostKeys[7])) keys in its count")
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
