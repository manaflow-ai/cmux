import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Three New Tab keys that each make a New Tab page: do the three creation requests reach the daemon in the order of
/// the keys?
///
/// The app starts a task of its own for the creation of each New Tab page, and nothing chains the tasks. So the order
/// in which the three requests reach the daemon is the order in which the three tasks run, and no rule of the app makes
/// that the order of the keys. This suite counts how often the order is another one. It has no mend: a count above 0
/// is the fault, shown by a run.
///
/// The app on a fresh same-tree daemon, with the real creation path to that daemon. Each key is a key-down event with
/// Command through the key router (`KeyRouter.interceptKeyDown` inside `dispatchingSynthetic`, then the window when the
/// router does not take it). The first key is a press and the next two are repeats, as a held key gives them.
///
/// The daemon gives each new tab a surface id from one counter, in the handler of the tab's request, and it handles the
/// requests of one connection one after the other. So the order of the surface ids of the three replies is the order
/// in which the daemon took the three requests.
///
/// One round: three keys; a wait for the reply or the error of each creation that the keys started (the creation path
/// is wrapped, not replaced); the checks; then three closes at the daemon and a wait until the store applied the events
/// of the closes. The checks of a round, in this order:
/// 1. each key started exactly one creation of a page in its own call, each of the three creations has a reply, and the
///    three surface ids are three different ids. A round where this does not hold is a failed round: it is counted and
///    said, and it is in neither of the two counts below;
/// 2. the surface ids rise in the order of the keys;
/// 3. the tasks of the creations started in the order of the keys (a count only, no check: it says where an order went
///    wrong, if one did).
///
/// Two forms, each a test of its own with its own app:
/// - `one turn`: the three keys run in one turn of the main actor, with no suspension between them;
/// - `a turn for each key`: one `Task.yield()` between two keys, so the tasks that wait can run between the keys.
///
/// Each test prints a line each 20 rounds and one line at its end: the two counts, the failed rounds, the wall time,
/// and the highest count of page views that the app held (after the replies of a round, and after its closes).
///
/// Limits:
/// - No HID event, no `nextEvent`, no event monitor: the keys start at the key router.
/// - In the `one turn` form the keys have no time between them. That is harder than a person's held key, whose repeats
///   are 30 ms or more apart.
/// - The pages load nothing (an inert address), and the daemon is on the same machine with no load.
/// - A count of 0 does not prove that the order holds: it says that these rounds did not show another order.
/// - The checks read the replies' surface ids, not the tab strip and not the pixels.
/// - The set-up of the terminal pane and the key press are copied from `ACloseTabKeyAfterKeptNewTabKeysTests.swift`, a
///   test file of the branch `fix/a-close-tab-key-waits-behind-kept-new-tab-keys`.
/// - A failure of a line that starts with `setup:` is no result.
@MainActor @Suite(.serialized, .timeLimit(.minutes(10)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabPagesArriveInKeyOrderTests {
    /// The rounds of each form.
    private static let rounds = 200

    /// The creations of one round, as the wrapped creation path saw them.
    @MainActor private final class Creations {
        /// The transactions in the order in which the creations' tasks started.
        private(set) var started: [ClientTransactionID] = []
        /// The surface that the daemon's reply named, for each creation with a reply.
        private(set) var surfaces: [ClientTransactionID: SurfaceID] = [:]
        /// The error's text, for each creation whose request ended with an error.
        private(set) var errors: [ClientTransactionID: String] = [:]
        private var wanted = 0
        private var waiter: CheckedContinuation<Void, Never>?

        func reset() {
            started = []
            surfaces = [:]
            errors = [:]
            wanted = 0
        }

        func start(_ transaction: ClientTransactionID) { started.append(transaction) }

        func reply(_ transaction: ClientTransactionID, _ surface: SurfaceID) {
            surfaces[transaction] = surface
            ended()
        }

        func error(_ transaction: ClientTransactionID, _ error: any Error) {
            errors[transaction] = "\(error)"
            ended()
        }

        private func ended() {
            guard let waiter, surfaces.count + errors.count >= wanted else { return }
            self.waiter = nil
            waiter.resume()
        }

        /// Returns when `count` creations of this round have a reply or an error. The signal is the end of each
        /// request; a request that never ends stops the test at the suite's time limit.
        func all(_ count: Int) async {
            wanted = count
            if surfaces.count + errors.count >= count { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    /// The transactions of the creations of a page that wait in the store, in the order in which the app added them.
    private static func pageCreations(_ store: DaemonStore) -> [ClientTransactionID] {
        store.intentLog.entries.compactMap { entry in
            if case .createTab(_, let provisional) = entry.kind, provisional.kind == .conversation { return entry.transaction }
            return nil
        }
    }

    /// One New Tab key (Cmd-T) as a key-down with Command through the app's key path. True when the key router ran an
    /// action in this call.
    private static func pressNewTab(_ services: AppServices, _ window: NSWindow, repeats: Bool, stamp: TimeInterval) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: stamp,
                                                  windowNumber: window.windowNumber, context: nil, characters: "t",
                                                  charactersIgnoringModifiers: "t", isARepeat: repeats, keyCode: 17),
                                 "setup: no key event")
        let router = services.keyRouter
        let ranBefore = router.interceptions
        let taken = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
        if !taken { window.sendEvent(event) }
        return router.interceptions > ranBefore
    }

    /// The app with a terminal pane that a split made (the app's first pane can show a chat, where the keys mean other
    /// things): the daemon confirmed the pane, it has the focus and the keyboard, and no hold of the window's keys is
    /// open.
    private static func withTerminalPane(_ body: (AppServices, NSWindow, DaemonConnection) async throws -> Void) async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        try await PasswordManagerRouteTests.withApp(agentPaneEnvironment: environment, heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            let content = try #require(services.windows.active?.workspaceContent, "setup: the window shows no workspace")
            let window = try #require(content.layoutView.window, "setup: the workspace's view is in no window")
            let holds = services.keyRouter.creationInputCoordinator
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            try #require(services.registry.perform("splitRight", invocation: terminal), "setup: the starting split was refused")
            @MainActor func made() -> PaneController? {
                content.panes.values.first { pane in
                    !before.contains(pane.layoutPaneID) && pane.pane.handle.rawValue < ProvisionalPane.firstHandle
                        && pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
                }
            }
            try await PasswordManagerRouteTests.until({ made() != nil && !holds.isHolding(in: window) },
                                                      report: { "setup: no confirmed terminal pane after the starting split, or its hold did not end" })
            let pane = try #require(made(), "setup: no terminal pane")
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PasswordManagerRouteTests.until({
                content.focus.state.pane == pane.paneKey && (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
            }, report: { "setup: the starting terminal has no focus or no keyboard: \(content.focus.state.resolved)" })
            try await body(services, window, connection)
        }
    }

    /// The rounds of one form, its lines and its two checks.
    private static func run(_ form: String, aTurnForEachKey: Bool) async throws {
        try await withTerminalPane { services, window, connection in
            let tabs = services.agentTabs
            let store = services.daemon.store
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            if tabs.localHost == nil { tabs.localHost = AgentSessionRef.host(installID: "new-tab-pages-arrive-in-key-order") }
            try #require(tabs.canHost(on: services.daemon) && tabs.reachable(services.daemon),
                         "setup: the daemon of this tree holds no agent tabs, or the app does not reach it")
            // The real creation path, with a note of each task's start, reply and error.
            let creations = Creations()
            let create = tabs.create
            tabs.create = { pane, daemon, record, key, transaction, split in
                creations.start(transaction)
                do {
                    let made = try await create(pane, daemon, record, key, transaction, split)
                    creations.reply(transaction, made.created.surface)
                    return made
                } catch {
                    creations.error(transaction, error)
                    throw error
                }
            }
            let tabsAtStart = PasswordManagerRouteTests.tabs(services).count
            var stamp = ProcessInfo.processInfo.systemUptime
            var done = 0, failed = 0, notInKeyOrder = 0, startedInAnotherOrder = 0
            var mostViews = 0, mostViewsAfterTheCloses = 0
            var failures: [String] = [], examples: [String] = []
            var stopped: String?
            let began = ContinuousClock.now
            for round in 1...Self.rounds {
                creations.reset()
                var ofKeys: [ClientTransactionID] = []
                var started = 0
                var said: [String] = []
                for key in 0..<3 {
                    stamp += 0.03
                    let before = Self.pageCreations(store)
                    let ran = try Self.pressNewTab(services, window, repeats: key > 0, stamp: stamp)
                    let added = Self.pageCreations(store).filter { !before.contains($0) }
                    started += added.count
                    if added.count == 1 { ofKeys.append(added[0]) }
                    said.append("key \(key + 1) \(ran ? "ran an action" : "ran no action") and started \(added.count) creations in its own call")
                    if aTurnForEachKey, key < 2 { await Task.yield() }
                }
                await creations.all(started)
                let surfaces = ofKeys.compactMap { creations.surfaces[$0] }.map(\.rawValue)
                // The first check of the round: one creation for each key, a reply for each, three different surface ids.
                if ofKeys.count == 3, started == 3, surfaces.count == 3, Set(surfaces).count == 3 {
                    if !(surfaces[0] < surfaces[1] && surfaces[1] < surfaces[2]) {
                        notInKeyOrder += 1
                        if examples.count < 5 { examples.append("round \(round): the surface ids in key order are \(surfaces)") }
                    }
                    if creations.started != ofKeys { startedInAnotherOrder += 1 }
                } else {
                    failed += 1
                    let line = "round \(round): \(said.joined(separator: ", ")); \(creations.surfaces.count) replies, errors \(creations.errors.values.sorted())"
                    if failures.count < 5 { failures.append(line) }
                    Issue.record("a failed round (in no count): \(line)")
                }
                done = round
                mostViews = max(mostViews, tabs.views.count)
                // The round's tabs close at the daemon, and the store applies the events of the closes.
                do {
                    for surface in creations.surfaces.values.sorted(by: { $0.rawValue < $1.rawValue }) { try await connection.closeTab(surface) }
                } catch {
                    stopped = "setup: round \(round): a close at the daemon failed: \(error)"
                    break
                }
                guard let sequence = await connection.eventSequence() else {
                    stopped = "setup: round \(round): the connection has no event sequence after the closes"
                    break
                }
                await withCheckedContinuation { (applied: CheckedContinuation<Void, Never>) in
                    store.whenApplied(ClientTransactionID.generate(), reaching: sequence) { applied.resume() }
                }
                mostViewsAfterTheCloses = max(mostViewsAfterTheCloses, tabs.views.count)
                let tabsNow = PasswordManagerRouteTests.tabs(services).count
                if tabsNow != tabsAtStart {
                    stopped = "setup: round \(round): after the closes the store lists \(tabsNow) tabs, \(tabsAtStart) at the start"
                    break
                }
                if started != 3 {
                    stopped = "round \(round): the keys started \(started) creations in their own calls, not 3: \(said.joined(separator: ", "))"
                    break
                }
                if round % 20 == 0 {
                    let soFar = (ContinuousClock.now - began).components.seconds
                    print("PAGES-ARRIVAL \(form): after \(round) rounds: \(notInKeyOrder) not in key order, "
                        + "\(startedInAnotherOrder) with a task start in another order, \(failed) failed, \(soFar) s")
                }
            }
            let seconds = (ContinuousClock.now - began).components.seconds
            let orders = "\(notInKeyOrder) of \(done) rounds where the surface ids' order is not the keys' order"
            let starts = "\(startedInAnotherOrder) of \(done) rounds where a creation's task started in another order than its key"
            let views = "the most page views at one time: \(mostViews) after the replies, \(mostViewsAfterTheCloses) after the closes"
            print("PAGES-ARRIVAL \(form): \(orders); \(starts); \(failed) failed rounds; \(done) of \(Self.rounds) rounds done; "
                + "wall time \(seconds) s; \(views)")
            if let stopped { Issue.record("the form stopped before its last round: \(stopped)") }
            #expect(failed == 0, "\(failed) of \(done) rounds failed: \(failures)")
            #expect(notInKeyOrder == 0, "\(orders); \(starts): \(examples)")
        }
    }

    /// Three New Tab keys in one turn of the main actor.
    @Test func threeNewTabKeysInOneTurnReachTheDaemonInKeyOrder() async throws {
        try await Self.run("one turn", aTurnForEachKey: false)
    }

    /// Three New Tab keys with one yield of the main actor between two keys.
    @Test func threeNewTabKeysWithATurnForEachKeyReachTheDaemonInKeyOrder() async throws {
        try await Self.run("a turn for each key", aTurnForEachKey: true)
    }
}
