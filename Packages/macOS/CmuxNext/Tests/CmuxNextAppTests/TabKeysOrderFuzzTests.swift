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
/// delay, never change that. The keys run the two actions' own handlers in a whole window (the `large` session); the
/// daemon is a model (``TabKeysModelDaemon``) whose events and replies the seed hands over at random points.
///
/// One run for each seed gives three results, each its own test:
/// - `order`: the strip's tab list and its selected tab are the oracle's at once after each key, after the key's turn
///   and after each delivery; at the end the daemon's list and the store's list are the oracle's too.
/// - `shown`: after each turn the pane shows the selected tab (the test makes the frame's own call).
/// - `focus`: after each turn the key focus is on that tab, where it is a tab the keys made.
///
/// Limits. A turn is a fixed count of yields and of round trips through the connection and the thread pool, not a
/// proof that each task ended. The model makes no full tree refresh for a move and no selection events. The placement
/// overlay's wall-clock limits are not controlled. The store's list is compared at the end only: between a create and
/// its move the store holds the tab at the end of the pane. Close Tab is pressed only on a tab the keys made.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(10)))
struct TabKeysOrderFuzzTests {
    /// One key list and its deliveries: all of it follows from `value`.
    nonisolated struct Seed: Sendable, CustomTestStringConvertible {
        let value: UInt64
        let keys: Int
        /// Close Tab at each `closeEvery`-th key of a held New Tab; nil: the two keys mixed at random.
        let closeEvery: Int?
        var testDescription: String { "seed \(value): \(keys) keys, \(closeEvery.map { "held, a close at each \($0)th" } ?? "mixed")" }
    }

    nonisolated static let seeds: [Seed] = [
        Seed(value: 1, keys: 6, closeEvery: 3), Seed(value: 2, keys: 10, closeEvery: nil),
        Seed(value: 3, keys: 16, closeEvery: 4), Seed(value: 4, keys: 24, closeEvery: nil),
        Seed(value: 5, keys: 32, closeEvery: 8), Seed(value: 6, keys: 48, closeEvery: nil),
        Seed(value: 7, keys: 64, closeEvery: 16), Seed(value: 8, keys: 100, closeEvery: nil),
    ]

    /// What one seed's run found: the first difference of each class, nil for none.
    nonisolated struct Outcome: Sendable {
        /// The run could not test the order: a cause of the fixture, of the model or of the turn.
        var setup: String?
        var order: String?
        var shown: String?
        var focus: String?
    }

    /// One run for each seed, shared by the three tests.
    private static var outcomes: [UInt64: Outcome] = [:]

    static func outcome(_ seed: Seed) async throws -> Outcome {
        if let outcome = outcomes[seed.value] { return outcome }
        // An inert address for each New Tab page, as the other agent tab suites use: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let outcome = try await LargeSessionWindowFixture.withController(.large, agentPaneEnvironment: environment) { store, controller in
            let run = try TabKeysOrderRun(seed, store: store, controller: controller)
            return await run.outcome()
        }
        outcomes[seed.value] = outcome
        return outcome
    }

    @Test(arguments: seeds)
    func eachKeyActsOnTheTabsOfTheKeysBeforeIt(seed: Seed) async throws {
        let outcome = try await Self.outcome(seed)
        #expect(outcome.setup == nil, "\(seed.testDescription): \(outcome.setup ?? "")")
        #expect(outcome.order == nil, "\(seed.testDescription): \(outcome.order ?? "")")
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
    private var trace: [String] = []

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
        self.seed = seed
        self.store = store
        self.controller = controller
        self.pane = pane
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
        trace.append("start: \(oracle.tabs.joined(separator: " ")) [\(oracle.selected ?? "-")], shows \(pane.currentTabKey.map { name($0) } ?? "-"), "
            + "focus \(controller.focus.currentState().resolved.tab.map { name($0) } ?? "-")")
    }

    /// Presses the seed's keys, hands the daemon's events and replies over at the seed's points, and compares.
    func outcome() async -> TabKeysOrderFuzzTests.Outcome {
        for number in 1...seed.keys where found.setup == nil && found.order == nil {
            await press(number)
            for _ in 0..<random.next(in: 0...3) where found.setup == nil && found.order == nil {
                guard let what = await deliver() else { break }
                compare("after \(what) (key \(number) was the last key)")
            }
        }
        // Each reply goes back, also after a difference: no request stays open when the window closes.
        var rounds = 0
        while model.pendingEvents + model.pendingReplies > 0, rounds < seed.keys * 20 + 50 {
            guard let what = await deliver() else { break }
            rounds += 1
            if found.setup == nil, found.order == nil { compare("after \(what) (all keys pressed)") }
        }
        if model.pendingEvents + model.pendingReplies > 0 { fail(\.setup, "the daemon still had events or replies after \(rounds) deliveries") }
        if found.setup == nil, found.order == nil { compareEnd() }
        return found
    }

    // MARK: Keys

    private func press(_ number: Int) async {
        let selectedIsMade = oracle.selected?.hasPrefix("t") == true
        let closes = selectedIsMade && (seed.closeEvery.map { number % $0 == 0 } ?? (random.next(in: 0...9) < 4))
        let registry = controller.services.registry
        let point: String
        if closes, let target = oracle.selected {
            point = "key \(number) (Close Tab on \(target))"
            trace.append(point)
            let ran = registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            oracle.close(target)
            if !ran { return fail(\.order, "\(point): the action was refused") }
        } else {
            opened += 1
            let tab = "t\(opened)"
            point = "key \(number) (New Tab, \(tab))"
            trace.append(point)
            let before = Set(pane.orderedIDs.map(\.rawValue))
            let ran = registry.perform("newTab.default", invocation: ActionInvocation(origin: .user))
            let made = pane.orderedIDs.map(\.rawValue).filter { !before.contains($0) }
            oracle.open(tab)
            guard ran, made.count == 1 else {
                return fail(\.order, "\(point): the action \(ran ? "ran" : "was refused") and the strip has \(made.count) new tabs at once")
            }
            names[made[0]] = tab
            if opened == 1, !controller.services.agentTabs.isNewTabPage(made[0], machine: pane.daemon.machineID) {
                return fail(\.setup, "\(point): the tab is not a New Tab page, so the keys take another path than the model's")
            }
        }
        compare("\(point), at once", frame: false)
        await turn()
        if model.creates.count != opened {
            return fail(\.setup, "\(point): \(model.creates.count) create requests arrived for \(opened) New Tab keys in the keys' turns")
        }
        compare("\(point), after its turn")
    }

    // MARK: Deliveries

    /// Hands over the daemon's next events (1 to 3, as one batch) or one of its waiting replies, and gives the app a
    /// turn. Nil: the daemon has nothing to hand over.
    private func deliver() async -> String? {
        let events = model.pendingEvents, replies = model.pendingReplies
        guard events + replies > 0 else { return nil }
        let what: String
        if replies == 0 || (events > 0 && random.next(in: 0...1) == 0) {
            let batch = model.takeEvents(random.next(in: 1...3))
            let followup = store.apply(batch: batch)
            what = "events \(batch.map { String($0.sequence) }.joined(separator: ","))"
            if followup != .none { fail(\.setup, "\(what): the store asked for \(followup), which the model does not serve") }
        } else {
            what = "the reply of " + model.deliverReply(random.next(in: 0...(replies - 1)))
        }
        trace.append(what)
        await turn()
        return what
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
        let strip = pane.orderedIDs.map { name($0.rawValue) }
        let selected = pane.stripModel.selectedID.map { name($0.rawValue) }
        let want = "\(oracle.tabs.joined(separator: " ")) [\(oracle.selected ?? "-")]"
        if strip != oracle.tabs || selected != oracle.selected {
            return fail(\.order, "\(point): the strip is \(strip.joined(separator: " ")) [\(selected ?? "-")], the oracle says \(want)")
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
            fail(\.order, "at the end the daemon holds \(daemon.joined(separator: " ")), the oracle says \(oracle.tabs.joined(separator: " "))")
        }
        let held = store.pane(pane.pane.handle)?.tabs.map(\.id) ?? []
        let stored = held.map { name($0) }
        if stored != oracle.tabs {
            fail(\.order, "at the end the store holds \(stored.joined(separator: " ")), the oracle says \(oracle.tabs.joined(separator: " "))")
        }
        let standIns = (held + pane.orderedIDs.map(\.rawValue)).filter { ProvisionalTab.isProvisional($0) }
        if !standIns.isEmpty { fail(\.order, "at the end \(standIns.count) stand-in tabs are left: \(standIns.map { name($0) })") }
        if !model.faults.isEmpty { fail(\.order, "the daemon got \(model.faults)") }
    }

    /// Keeps the first difference of a class, with the keys and deliveries before it.
    private func fail(_ kind: WritableKeyPath<TabKeysOrderFuzzTests.Outcome, String?>, _ text: String) {
        guard found[keyPath: kind] == nil else { return }
        let refused = model.refused.isEmpty ? "" : "; other requests, refused by the model: \(Set(model.refused).sorted())"
        let stale = model.stale.isEmpty ? "" : "; requests for a tab the daemon closed before: \(model.stale)"
        found[keyPath: kind] = "\(text). Before it: \(trace.suffix(24).joined(separator: " | "))\(refused)\(stale)"
    }
}
