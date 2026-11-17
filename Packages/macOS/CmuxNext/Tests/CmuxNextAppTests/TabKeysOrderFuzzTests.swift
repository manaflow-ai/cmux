import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextFocus
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// New Tab and Close Tab keys in one pane, mixed and as a held key, against a pure oracle (``TabKeysOracle``): the
/// effect of key N is computed on the tabs that keys 1 to N-1 made, and the daemon's replies, in any order and at any
/// delay, never change that. Each key is a key-down event through the app's key router (`KeyRouter.interceptKeyDown`),
/// as the app gets a key, in a whole window (the `large` session). A key directly after the same key can have the
/// repeat flag, as a held key has it. The daemon is a model (``TabKeysModelDaemon``) whose events and replies the
/// seed hands over at random points.
///
/// One run for each seed gives four results, each its own test:
/// - `order`: the strip's tab list and its selected tab are the oracle's at once after each key, after the key's turn
///   and after each delivery; at the end the daemon's list and the store's list are the oracle's too. A seed does not
///   stop at a difference. It records it, the oracle takes the strip's list and selection, and the seed goes on:
///   each later difference is checked from what the app had after the one before it, so one fault does not hide the
///   next. The first difference is the failure text; the others follow it, with their count.
/// - `shown`: after each turn the pane shows the selected tab (the test makes the frame's own call).
/// - `focus`: after each turn the key focus is on that tab, where it is a tab the keys made.
/// - `typed` (the seeds with letter keys): a letter key directly after a New Tab key is for the new tab. The window's
///   key hold must take it. When the hold ends, the check says where the letter went: to the field of a page that
///   reported ready, to no view (lost), to a view, or away with its own tab when that tab closed. A letter that is
///   lost and a letter that went to a view of another tab are differences. The seed goes on after one, and the
///   failure text has the counts of the whole seed.
///
/// The whole tree. The daemon sends a `tree-changed` for each close and for each move, and the app answers each one
/// with a read of the whole tree. This store has no driver, so the test makes the steps of `DaemonStore.resync()`
/// itself: while the tree is owed the store gets no event (the driver holds its inbox), a reply can still arrive, and
/// the tree that arrives is the daemon's of that moment. The events that reached the inbox meanwhile apply in the same
/// turn as the tree: 3 of 4 times each waiting event, else a count the seed picks, so that the tree can hold a tab
/// whose event the store did not get yet. The failure text says for each tree which events the store had.
///
/// Limits. A turn is a fixed count of yields and of round trips through the connection and the thread pool, not a
/// proof that each task ended. The test copies the driver's steps; it does not run the driver, and a tree that the
/// app asks for with no `tree-changed` is not served. The model makes no selection events. The placement overlay's
/// wall-clock limits are not controlled. The store's list is compared at the end only: between a create and its move
/// the store holds the tab at the end of the pane. Close Tab is pressed only on a tab the keys made.
///
/// Limits of the keys. The test makes each key event: none comes from the system's event queue, and no menu sees
/// one. Close Tab never empties the pane here, so the rule for a held Close Tab key after a pane's last tab does
/// not run.
///
/// Limits of `typed`. No page reports its field ready here (the inert address), so no letter can go to a field: the
/// check sees only a hold that ends with no field ready. Each key with Command ends the hold (the keys typed before
/// it go on first), so a letter waits only until the next key of the seed. A letter after the last key of a seed
/// stays in the hold, and the check does not say where it went. Such a hold gives no key to what had the
/// keyboard at its opening. The check counts that letter as lost, with that rule in its text: the letter was typed
/// for the new tab. For a letter that the hold gave on, the check reads the view that had the keyboard before the
/// key or the delivery in which the hold ended; it does not assert that the view took the key. When the key router
/// took the letter again at the hold's end, the check does not see where it went, and says so as a difference of
/// the letters' setup. The hold's time limit never passes in these seeds (its clock stands still). The letter comes
/// directly after the key's call, before the app's next turn. The seeds with no letter keys have no probe view and
/// the hold's own clock.
///
/// Limits of a seed that goes on. The next key of a seed depends on what is selected, so after a difference the keys
/// of one seed can differ between two versions of the code. The oracle keeps each opener that the keys made; the
/// app's own openers after a fault are not read, so a later difference can be an effect of an earlier one. A fault
/// that the app mends by itself at a later delivery counts two times: when it comes and when it goes. So the count
/// of a seed is a count of differences, not of faults.
///
/// The `typed` check has a test of its own (`theLetterKeyCheckReportsAHoldThatEndsWithNoFieldReady`): a run that ends
/// the hold itself must make the check report a difference.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(10)))
struct TabKeysOrderFuzzTests {
    /// One key list and its deliveries: all of it follows from `value`.
    nonisolated struct Seed: Sendable, CustomTestStringConvertible {
        let value: UInt64
        let keys: Int
        /// Close Tab at each `closeEvery`-th key of a held New Tab; nil: the two keys mixed at random.
        let closeEvery: Int?
        /// A letter key directly after about half of the New Tab keys.
        var letters = false
        /// A fault that the run makes itself, for the test of the `typed` check: it ends the window's hold directly
        /// after the first letter key that the hold took.
        var endsHoldEarly = false
        var testDescription: String {
            "seed \(value): \(keys) keys, \(closeEvery.map { "held, a close at each \($0)th" } ?? "mixed")\(letters ? ", letter keys" : "")"
                + (endsHoldEarly ? ", the run ends the hold" : "")
        }
    }

    nonisolated static let seeds: [Seed] = [
        Seed(value: 1, keys: 6, closeEvery: 3), Seed(value: 2, keys: 10, closeEvery: nil),
        Seed(value: 3, keys: 16, closeEvery: 4, letters: true), Seed(value: 4, keys: 24, closeEvery: nil, letters: true),
        Seed(value: 5, keys: 32, closeEvery: 8), Seed(value: 6, keys: 48, closeEvery: nil),
        Seed(value: 7, keys: 64, closeEvery: 16, letters: true), Seed(value: 8, keys: 100, closeEvery: nil, letters: true),
    ]

    /// The keys of seed 3 in a run that ends the window's hold itself: the test of the `typed` check.
    nonisolated static let holdEndsEarly = Seed(value: 3, keys: 16, closeEvery: 4, letters: true, endsHoldEarly: true)

    /// What one seed's run found: the first difference of each class, nil for none.
    nonisolated struct Outcome: Sendable {
        /// The run could not test the order: a cause of the fixture, of the model or of the turn.
        var setup: String?
        var order: String?
        var shown: String?
        var focus: String?
        var typed: String?
        /// The run could not test the letter keys: a cause of the fixture, not of the product.
        var typedSetup: String?
        /// The keys that the run pressed, and the differences of the order that it recorded.
        var keys = 0
        var differences = 0
        /// The run ended the window's hold itself (`Seed.endsHoldEarly`).
        var holdEnded = false
        /// The letter keys of the run: all of them, those that went to no view, and those that went to a view of
        /// another tab than their own.
        var letters = 0
        var lettersLost = 0
        var lettersElsewhere = 0
        var lettersText: String { "\(letters) letter keys, \(lettersLost) lost, \(lettersElsewhere) to a view of another tab" }
    }

    /// One run for each seed, shared by its tests.
    private static var outcomes: [String: Outcome] = [:]

    static func outcome(_ seed: Seed) async throws -> Outcome {
        if let outcome = outcomes[seed.testDescription] { return outcome }
        // An inert address for each New Tab page, as the other agent tab suites use: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let outcome = try await LargeSessionWindowFixture.withController(.large, agentPaneEnvironment: environment) { store, controller in
            let run = try TabKeysOrderRun(seed, store: store, controller: controller)
            return await run.outcome()
        }
        outcomes[seed.testDescription] = outcome
        return outcome
    }

    @Test(arguments: seeds)
    func eachKeyActsOnTheTabsOfTheKeysBeforeIt(seed: Seed) async throws {
        let outcome = try await Self.outcome(seed)
        #expect(outcome.setup == nil, "\(seed.testDescription): \(outcome.setup ?? "")")
        #expect(outcome.order == nil, "\(seed.testDescription): \(outcome.differences) differences in \(outcome.keys) keys. \(outcome.order ?? "")")
    }

    @Test(arguments: seeds)
    func thePaneShowsTheSelectedTabAfterEachKey(seed: Seed) async throws {
        let outcome = try await Self.outcome(seed)
        #expect(outcome.setup == nil, "\(seed.testDescription): \(outcome.setup ?? "")")
        #expect(outcome.shown == nil, "\(seed.testDescription): \(outcome.shown ?? "")")
    }

    @Test(arguments: seeds)
    func theKeyFocusIsOnTheSelectedTabAfterEachKey(seed: Seed) async throws {
        let outcome = try await Self.outcome(seed)
        #expect(outcome.setup == nil, "\(seed.testDescription): \(outcome.setup ?? "")")
        #expect(outcome.focus == nil, "\(seed.testDescription): \(outcome.focus ?? "")")
    }

    @Test(arguments: seeds.filter(\.letters))
    func aLetterKeyAfterNewTabWaitsInTheKeyHoldForTheNewTab(seed: Seed) async throws {
        let outcome = try await Self.outcome(seed)
        #expect(outcome.setup == nil, "\(seed.testDescription): \(outcome.setup ?? "")")
        #expect(outcome.typedSetup == nil, "\(seed.testDescription): \(outcome.typedSetup ?? "")")
        #expect(outcome.typed == nil, "\(seed.testDescription): \(outcome.lettersText). \(outcome.typed ?? "")")
    }

    /// A test of the `typed` check itself. The run ends the window's hold as a failed opening does, directly after the
    /// first letter key that the hold took. No field is ready then, so the check must report a difference.
    @Test func theLetterKeyCheckReportsAHoldThatEndsWithNoFieldReady() async throws {
        let seed = Self.holdEndsEarly
        let outcome = try await Self.outcome(seed)
        #expect(outcome.setup == nil, "\(seed.testDescription): \(outcome.setup ?? "")")
        #expect(outcome.typedSetup == nil, "\(seed.testDescription): \(outcome.typedSetup ?? "")")
        try #require(outcome.holdEnded, "setup: the hold took no letter key in this run, so the run ended no hold")
        let typed = try #require(outcome.typed, "the check found no difference in a run whose hold ended with no field ready")
        #expect(typed.contains("ended with no field ready") || typed.contains("got "), "the check reported another difference: \(typed)")
    }
}

/// Stands for the view that had the keyboard before the first New Tab key: it counts each key it gets.
final class TabKeysKeyProbe: NSView {
    var keys = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys += 1 }
}

/// One seed's run in one window: the keys, the deliveries and the comparisons.
@MainActor final class TabKeysOrderRun {
    private let seed: TabKeysOrderFuzzTests.Seed
    private let store: DaemonStore
    private let controller: WindowController
    private let pane: PaneController
    private let model: TabKeysModelDaemon
    private let connection: DaemonConnection
    private var oracle: TabKeysOracle
    private var random: TabKeysRandom
    /// The name of each strip tab id: `s0`, `s1`, ... for the pane's tabs at the start, `t1`, `t2`, ... for the tab of
    /// the first, second, ... New Tab key (its stand-in id first, then also the daemon's id).
    private var names: [String: String]
    private var opened = 0
    private var found = TabKeysOrderFuzzTests.Outcome()
    /// Each difference of the order after the first one, without the keys before it.
    private var later: [String] = []
    private var trace: [String] = []
    /// The tree the session started from: the model's tree is this one with the pane's tabs replaced.
    private let base: DaemonTree
    /// The store asked for the whole tree, and the tree did not arrive yet.
    private var treeOwed = false
    /// The newest event sequence the store got: what the driver's inbox calls taken.
    private var handed: UInt64 = 0
    private let input: NewTabInputCoordinator
    private var keyboard: TabKeysKeyboard
    private var probe: TabKeysKeyProbe?
    /// The letter key that waits in the window's hold: its event, the tab that it is for, and the probe's count at
    /// the key.
    private var letter: (key: NSEvent, tab: String, probeKeys: Int)?

    init(_ seed: TabKeysOrderFuzzTests.Seed, store: DaemonStore, controller: WindowController) throws {
        let services = controller.services
        let tabs = services.agentTabs
        try #require(tabs.canHostChat, "this build has no New Tab page")
        let pane = try #require(controller.focusedPane, "fixture: the window has no focused pane")
        let handle = pane.pane.handle
        let shown = UInt64(LargeSessionWindowFixture.workspaces)
        try #require(handle == PaneID(rawValue: shown), "fixture: the focused pane is \(handle.rawValue), not the shown workspace's")
        let held = try #require(store.pane(handle)?.tabs, "fixture: the store has no such pane")
        let start = pane.orderedIDs.map(\.rawValue)
        try #require(start == held.map(\.id), "fixture: the strip \(start) is not the store's list \(held.map(\.id))")
        let selected = try #require(pane.stripModel.selectedID?.rawValue, "fixture: the pane selects no tab")
        let selectedIndex = try #require(start.firstIndex(of: selected), "fixture: the selected tab is not in the strip")
        let window = try #require(pane.view.window, "fixture: the pane's view is in no window")
        keyboard = TabKeysKeyboard(router: services.keyRouter, window: window, seed: seed.value, held: seed.closeEvery != nil)
        self.seed = seed
        self.store = store
        self.controller = controller
        self.pane = pane
        input = services.keyRouter.newTabInputCoordinator
        base = LargeSessionWindowFixture.tree(.large)
        names = Dictionary(uniqueKeysWithValues: start.enumerated().map { ($0.element, "s\($0.offset)") })
        oracle = TabKeysOracle(tabs: start.indices.map { "s\($0)" }, selected: "s\(selectedIndex)")
        random = TabKeysRandom(seed: seed.value)
        let model = TabKeysModelDaemon(workspace: WorkspaceHandle(rawValue: shown), screen: ScreenID(rawValue: shown), pane: handle,
                                       tabs: held.map(\.surface))
        self.model = model
        // The daemon side: the create is the app's own seam; the close and the move go through a connection that
        // never started and that the model answers.
        tabs.localHost = AgentSessionRef.host(installID: "tab-keys-order-fuzz")
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabs.create = { _, _, record, _, transaction, _ in try await model.create(record: record, transaction: transaction) }
        var configuration = DaemonConnection.Configuration()
        configuration.answers.answerer = TabKeysModelDaemon.Answerer(model)
        connection = DaemonConnection(configuration: configuration, endpointProvider: { throw DaemonError.notConnected })
        pane.daemon.connection = connection
        if seed.letters {
            // The hold's limit is a time on the clock: it never passes in this run.
            let began = input.now()
            input.now = { began }
            input.scheduleDeadline = { _, _ in Task {} }
            let probe = TabKeysKeyProbe(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            pane.view.addSubview(probe)
            if window.makeFirstResponder(probe), window.firstResponder === probe {
                self.probe = probe
            } else {
                found.typedSetup = "fixture: the probe view did not get the keyboard before the first key, so no letter key was typed"
            }
        }
        trace.append("start: \(oracle.tabs.joined(separator: " ")) [\(oracle.selected ?? "-")], shows \(pane.currentTabKey.map { name($0) } ?? "-"), "
            + "focus \(controller.focus.currentState().resolved.tab.map { name($0) } ?? "-")")
    }

    /// Presses the seed's keys, hands the daemon's events and replies over at the seed's points, and compares.
    func outcome() async -> TabKeysOrderFuzzTests.Outcome {
        for number in 1...seed.keys where found.setup == nil {
            await press(number)
            found.keys = number
            // Up to 5: a key makes about 5 deliveries (a create's event and reply; a move's 2 events, reply and tree).
            for _ in 0..<random.next(in: 0...5) where found.setup == nil {
                guard let what = await deliver() else { break }
                compare("after \(what) (key \(number) was the last key)")
            }
        }
        // Each reply goes back, also after a difference: no request stays open when the window closes.
        var rounds = 0
        while owed, rounds < seed.keys * 20 + 50 {
            guard let what = await deliver() else { break }
            rounds += 1
            if found.setup == nil { compare("after \(what) (all keys pressed)") }
        }
        if owed { fail(\.setup, "the daemon still had events, replies or a tree to give after \(rounds) deliveries") }
        if found.setup == nil { compareEnd() }
        if let first = found.order, !later.isEmpty {
            found.order = first + " THEN \(later.count) more differences, each one checked from the app's state after the one before it: "
                + later.prefix(6).map { String($0.prefix(400)) }.joined(separator: " || ")
        }
        return found
    }

    /// The daemon has an event, a reply or the tree to hand over.
    private var owed: Bool { model.pendingEvents + model.pendingReplies > 0 || treeOwed }

    // MARK: Keys

    private func press(_ number: Int) async {
        let selectedIsMade = oracle.selected?.hasPrefix("t") == true
        let closes = selectedIsMade && (seed.closeEvery.map { number % $0 == 0 } ?? (random.next(in: 0...9) < 4))
        let point: String
        var letterTab: String?
        if closes, let target = oracle.selected {
            point = "key \(number) (Close Tab on \(target))"
            trace.append(point)
            let refusal = chord("w", code: 13, action: "closeTab")
            settleLetter(point, atChord: true, closed: target)
            oracle.close(target)
            if let refusal { differs("\(point): \(refusal)") } else { compare("\(point), at once", frame: false) }
        } else {
            opened += 1
            let tab = "t\(opened)"
            point = "key \(number) (New Tab, \(tab))"
            trace.append(point)
            let before = Set(pane.orderedIDs.map(\.rawValue)), held = Set(pane.pane.tabs.map(\.id))
            let refusal = chord("t", code: 17, action: "newTab.default")
            settleLetter(point, atChord: true)
            let ran = refusal == nil
            letterTab = tab
            let made = pane.orderedIDs.map(\.rawValue).filter { !before.contains($0) }
            // The store's new record names the tab also when the strip does not list exactly one new tab.
            let recorded = pane.pane.tabs.map(\.id).filter { !held.contains($0) }
            oracle.open(tab)
            if recorded.count == 1 { names[recorded[0]] = tab } else if made.count == 1 { names[made[0]] = tab }
            if let first = recorded.first ?? made.first, opened == 1, !controller.services.agentTabs.isNewTabPage(first, machine: pane.daemon.machineID) {
                return fail(\.setup, "\(point): the tab is not a New Tab page, so the keys take another path than the model's")
            }
            // A refused key makes no tab: the next New Tab key gets this name.
            if !ran { opened -= 1 }
            if ran, made.count == 1 {
                compare("\(point), at once", frame: false)
            } else {
                differs("\(point): \(refusal ?? "the action ran") and the strip has \(made.count) new tabs at once")
            }
        }
        if let letterTab { typeLetter(point, tab: letterTab) }
        await turn()
        if model.creates.count != opened {
            return fail(\.setup, "\(point): \(model.creates.count) create requests arrived for \(opened) New Tab keys in the keys' turns")
        }
        compare("\(point), after its turn")
    }

    /// One key-down with Command (``TabKeysKeyboard``). Nil: the router took the key and ran `action` in the key's own
    /// call. Else what it did.
    private func chord(_ characters: String, code: UInt16, action: ActionID) -> String? {
        let key = keyboard.chord(characters, code: code, action: action)
        if key.repeats { trace.append("(the key repeats)") }
        return key.refusal
    }

    /// The seeds with letter keys: one letter key through the key router, directly after about half of the New Tab
    /// keys and before the app's next turn. The window's key hold must take it.
    private func typeLetter(_ point: String, tab: String) {
        guard seed.letters, random.next(in: 0...1) == 0, found.typedSetup == nil else { return }
        guard let (key, taken) = keyboard.letter() else { return fail(\.typedSetup, "fixture: \(point): no key event could be made") }
        trace.append("a letter key for \(tab)")
        found.letters += 1
        guard taken, input.log.last?.hasPrefix("hold key #") == true else {
            return fail(\.typed, "\(point): the window's key hold did not take the letter key for \(tab), typed directly after the key "
                + "(the key router \(taken ? "took the key in another way" : "passed the key on")). \(holdLog)")
        }
        letter = (key, tab, probe?.keys ?? 0)
        if seed.endsHoldEarly, !found.holdEnded {
            // The fault of the test of the check: the hold ends as a failed opening ends it.
            trace.append("the run ends the hold")
            input.cancel(in: keyboard.window)
            found.holdEnded = true
            settleLetter("\(point), the run ended the hold")
        }
    }

    /// The end of the hold's own log. It holds no text of a key.
    private var holdLog: String { "The hold's log ends: \(input.log.suffix(6).joined(separator: " | "))" }

    /// Where the letter key that waited in the window's hold went, when that hold ended: read from the hold's own log
    /// after the entry of that key. `atChord`: a key with Command came, which ends the hold. `closed`: the tab that
    /// this key closes.
    private func settleLetter(_ point: String, atChord: Bool = false, closed: String? = nil) {
        guard let waits = letter else { return }
        let log = input.log
        guard let held = log.lastIndex(where: { $0.hasPrefix("hold key #") }) else {
            letter = nil
            return fail(\.typedSetup, "\(point): the hold's log has no entry of the letter key for \(waits.tab). \(holdLog)")
        }
        let after = log[(held + 1)...]
        guard let end = after.first(where: { $0.hasPrefix("release") || $0.hasPrefix("drained to field") }) else {
            guard atChord else { return }
            letter = nil
            found.lettersLost += 1
            return fail(\.typed, "\(point): the hold with the letter key for \(waits.tab) did not end at a key with Command, "
                + "so that key ran before the letter typed ahead of it. \(holdLog)")
        }
        letter = nil
        // A page reported its field ready, and the hold gave it each key.
        if end.hasPrefix("drained to field") { return }
        if let probe, probe.keys > waits.probeKeys {
            found.lettersElsewhere += 1
            return fail(\.typed, "\(point): the view that had the keyboard before the first New Tab key got the letter key for \(waits.tab) "
                + "(it got \(probe.keys) keys in this run). \(holdLog)")
        }
        // The letter's own tab closed: the letter goes with it.
        if closed == waits.tab || !oracle.tabs.contains(waits.tab) { return }
        if after.contains(where: { $0.hasPrefix("dropped ") }) {
            found.lettersLost += 1
            return fail(\.typed, "\(point): the letter key for \(waits.tab) is lost. The hold ended with no field ready (\(end)) and gave the key "
                + "to no view, by the product's rule that such a hold gives no key to what had the keyboard at its opening. \(holdLog)")
        }
        // The hold gave the key on, and the key router took it again (its queue for a page that is not ready, or a
        // primary input): a key with Command ends that queue, and the check does not read it.
        if !keyboard.router.menuMayClaim(waits.key) {
            return fail(\.typedSetup, "\(point): the hold ended with no field ready (\(end)) and the key router took the letter key for "
                + "\(waits.tab) again: the check does not see where it went. \(holdLog)")
        }
        // The hold gave the key on. The view that had the keyboard before the key or the delivery in which it ended:
        var view = keyboard.before as? NSView
        while let current = view, !(current is AgentPaneView) { view = current.superview }
        let tabs = controller.services.agentTabs
        let own = names.filter { $0.value == waits.tab }.keys.contains { tabs.existingView($0, machine: pane.daemon.machineID) === view }
        if view != nil, own { return }
        let responder = keyboard.before.map { String(describing: type(of: $0)) } ?? "no view"
        found.lettersElsewhere += 1
        fail(\.typed, "\(point): the hold ended with no field ready (\(end)) and gave the letter key for \(waits.tab) on while \(responder), "
            + "not a view of that tab, had the keyboard: it got the key or the key is lost. \(holdLog)")
    }

    /// The letter keys against their rule, at each comparison.
    private func compareLetters(_ point: String) { settleLetter(point) }

    // MARK: Deliveries

    /// Hands over the daemon's next events (1 to 3, as one batch), one of its waiting replies or the tree the store
    /// asked for, and gives the app a turn. Nil: the daemon has nothing to hand over.
    private func deliver() async -> String? {
        let events = model.pendingEvents, replies = model.pendingReplies
        guard owed else { return nil }
        keyboard.before = keyboard.window.firstResponder
        let what: String
        if treeOwed, let first = model.createReplyBeforeTree {
            // The daemon wrote this reply before the tree that holds its tab: the app gets it, and a turn, first.
            what = "the reply of " + model.deliverReply(first) + " (before the tree that holds its tab)"
        } else if treeOwed {
            // The driver holds its inbox until the tree arrives: only the tree or a reply comes now.
            what = replies == 0 || random.next(in: 0...1) == 0 ? serveTree() : "the reply of " + model.deliverReply(random.next(in: 0...(replies - 1)))
        } else if replies == 0 || (events > 0 && random.next(in: 0...1) == 0) {
            what = apply(model.takeEvents(random.next(in: 1...3)))
        } else {
            what = "the reply of " + model.deliverReply(random.next(in: 0...(replies - 1)))
        }
        trace.append(what)
        await turn()
        return what
    }

    /// Gives a batch to the store as the driver's drain does: a batch that needs the whole tree makes the tree owed.
    private func apply(_ batch: [DaemonEventEnvelope]) -> String {
        let what = "events \(batch.map { String($0.sequence) }.joined(separator: ","))"
        handed = max(handed, batch.map(\.sequence).max() ?? 0)
        switch store.apply(batch: batch) {
        case .none:
            return what
        case .resync:
            treeOwed = true
            return what + " (the store asks for the tree)"
        case .personal:
            fail(\.setup, "\(what): the store asked for the personal state, which the model does not serve")
            return what
        }
    }

    /// The tree arrives: the steps of `DaemonStore.resync()` after its snapshot request. The tree and its barrier are
    /// the daemon's of this moment; the store may acknowledge only the events it got; then the events that reached the
    /// held inbox (the seed picks how many of the waiting ones) apply in the same turn. The reply of each create whose
    /// tab the tree holds came before it (``deliver()`` hands those over first): the daemon answers the requests of
    /// one connection in the order of their arrival, and the tree's request is the last of them. The model still hands
    /// the replies of the closes and the moves over in any order, also after the tree: more orders than the daemon gives.
    private func serveTree() -> String {
        treeOwed = false
        guard let snapshot = model.snapshot(of: base) else {
            fail(\.setup, "the model daemon holds a tab with no entity, so it has no tree to give")
            return "no tree"
        }
        // 3 of 4 times all of them: the daemon wrote each one before the tree, so only the app's own pump can hold one back.
        let inbox = random.next(in: 0...3) == 0 ? random.next(in: 0...model.pendingEvents) : model.pendingEvents
        store.apply(snapshot: snapshot.tree)
        store.snapshotBarrier = max(store.snapshotBarrier, snapshot.barrier)
        let consumed = min(snapshot.barrier, handed)
        store.snapshotCoveredPersonal(through: consumed)
        store.advanceAppliedSequence(to: consumed)
        let what = "the tree to \(snapshot.barrier) (the store had the events to \(handed))"
        return inbox > 0 ? what + ", then " + apply(model.takeEvents(inbox)) : what
    }

    /// Lets the app's tasks run: the main actor's queue, one round trip through the connection, one through the
    /// thread pool; no wait for time to pass.
    private func turn() async {
        for _ in 0..<5 {
            await LargeSessionWindowFixture.drainMain()
            _ = await connection.eventSequence()
            await Self.threadPoolRoundTrip()
        }
        await LargeSessionWindowFixture.drainMain()
    }

    @concurrent nonisolated private static func threadPoolRoundTrip() async {}

    // MARK: Comparisons

    private func name(_ id: String) -> String { names[id] ?? "?\(id)" }

    /// The daemon's ids of the tabs the keys made, as soon as the daemon has them.
    private func learnNames() {
        for (index, surface) in model.creates.enumerated() {
            names["tab_\(surface.rawValue)"] = "t\(index + 1)"
            if let id = store.tab(surface: surface)?.id { names[id] = "t\(index + 1)" }
        }
    }

    /// The strip against the oracle; with `frame`, also the shown tab and the key focus after the frame's call.
    private func compare(_ point: String, frame: Bool = true) {
        learnNames()
        compareLetters(point)
        let strip = pane.orderedIDs.map { name($0.rawValue) }
        let selected = pane.stripModel.selectedID.map { name($0.rawValue) }
        let want = "\(oracle.tabs.joined(separator: " ")) [\(oracle.selected ?? "-")]"
        if strip != oracle.tabs || selected != oracle.selected {
            return differs("\(point): the strip is \(strip.joined(separator: " ")) [\(selected ?? "-")], the oracle says \(want)")
        }
        guard frame else { return }
        // What the frame drain of the content presentation calls for a pane that waits for its frame.
        pane.showSelected()
        let shown = pane.currentTabKey.map { name($0) }
        if found.shown == nil, shown != oracle.selected {
            fail(\.shown, "\(point): the pane shows \(shown ?? "-"), the oracle says \(oracle.selected ?? "-")")
        }
        if found.focus == nil, let wanted = oracle.selected, wanted.hasPrefix("t") {
            let focus = controller.focus.currentState().resolved.tab.map { name($0) }
            if focus != wanted { fail(\.focus, "\(point): the key focus is on \(focus ?? "-"), the oracle says \(wanted)") }
        }
    }

    /// All delivered: the daemon's list and the store's list are the oracle's, and no stand-in tab is left.
    private func compareEnd() {
        learnNames()
        let daemon = model.tabs.map { model.name($0) }
        if daemon != oracle.tabs {
            differs("at the end the daemon holds \(daemon.joined(separator: " ")), the oracle says \(oracle.tabs.joined(separator: " "))", resync: false)
        }
        let held = store.pane(pane.pane.handle)?.tabs.map(\.id) ?? []
        let stored = held.map { name($0) }
        if stored != oracle.tabs {
            differs("at the end the store holds \(stored.joined(separator: " ")), the oracle says \(oracle.tabs.joined(separator: " "))", resync: false)
        }
        let standIns = (held + pane.orderedIDs.map(\.rawValue)).filter { ProvisionalTab.isProvisional($0) }
        if !standIns.isEmpty { differs("at the end \(standIns.count) stand-in tabs are left: \(standIns.map { name($0) })", resync: false) }
        if !model.faults.isEmpty { differs("the daemon got \(model.faults)", resync: false) }
    }

    /// Records a difference of the order. The first one is the failure text, with the keys and deliveries before it.
    /// With `resync` the oracle then takes the strip's list and selection, so the seed goes on from what the app has.
    private func differs(_ text: String, resync: Bool = true) {
        if found.order == nil { fail(\.order, text) } else { later.append(text) }
        found.differences += 1
        guard resync else { return }
        oracle.take(tabs: pane.orderedIDs.map { name($0.rawValue) }, selected: pane.stripModel.selectedID.map { name($0.rawValue) })
        trace.append("the oracle takes the strip: \(oracle.tabs.joined(separator: " ")) [\(oracle.selected ?? "-")]")
    }

    /// Keeps the first difference of a class, with the keys and deliveries before it.
    private func fail(_ kind: WritableKeyPath<TabKeysOrderFuzzTests.Outcome, String?>, _ text: String) {
        guard found[keyPath: kind] == nil else { return }
        let refused = model.refused.isEmpty ? "" : "; other requests, refused by the model: \(Set(model.refused).sorted())"
        let stale = model.stale.isEmpty ? "" : "; requests for a tab the daemon closed before: \(model.stale)"
        found[keyPath: kind] = "\(text). Before it: \(trace.suffix(24).joined(separator: " | "))\(refused)\(stale)"
    }
}
