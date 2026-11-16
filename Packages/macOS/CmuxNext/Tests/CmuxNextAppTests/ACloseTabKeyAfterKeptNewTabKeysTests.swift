import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import CmuxNextTabs
import Foundation
import Testing

/// A Close Tab key that comes after New Tab keys while a hold of the window's keys is open: the order of a person's
/// keys.
///
/// Decision of 2026-11-16: an act never runs before the act of a key that the person pressed before it. So a Close Tab
/// key that comes after New Tab keys closes the tab of the newest New Tab key: it waits in the hold behind the kept
/// New Tab keys. It never closes a tab that was there before the keys, and it takes no other New Tab key's tab.
///
/// The app on a fresh same-tree daemon. Each key is a key-down event with Command through the key router
/// (`KeyRouter.interceptKeyDown` inside `dispatchingSynthetic`, then the window when the router does not take it). A
/// key that a hold keeps runs again on the same path (`heldKeyReplay`). The tests, by the thing that opens the hold:
/// - a split key: the new pane's stand-in shows at once, and the keys wait for the daemon's answer. One test with New
///   Tab keys that make New Tab pages, one with New Tab keys that make terminals;
/// - the New Tab key itself, where it makes a terminal (the pane's daemon holds no agent tabs). One test with terminals
///   only, and two tests of the mix: the first New Tab key makes a terminal and the second makes a New Tab page, with
///   the focus on the new terminal and with the focus moved to another pane before the daemon's answer;
/// - a Close Tab key on a terminal: the tab leaves at once, and the keys wait while the app reads from the daemon what
///   runs in the terminal;
/// - a creation that never answers: the hold ends at its reply bound, by force (the last test, with its own rule).
///
/// Each test but the last checks two things. In the key's own call, a Close Tab key that comes after a New Tab key
/// closes no tab that was there before the first key. At the end (no hold, and the store's tab list did not change for
/// one second), the count of the new tabs and of the closed old tabs is the count that the keys make in their order.
/// Each test prints its counts at its end. A failure names each act in its order: each key with what it did in its own
/// call, and each kept key with what it did when it ran again and how its hold ended.
///
/// Limits:
/// - No HID event, no `nextEvent`, no event monitor: the keys start at the key router.
/// - The keys of one test run in one turn of the main actor, so the daemon's answer cannot come between them. That is
///   harder than a person, whose keys are 30 ms or more apart. The suite does not say how long the answer of a
///   person's daemon takes.
/// - In the close test the read is held by the debug hold of the close read (`DaemonService.closeReadHold`), not by a
///   slow daemon, and the terminal is idle.
/// - In the forced-end test the test opens the hold itself, with a creation that has no request at the daemon. The
///   bound is the hold's own reply bound, with a value of 1 second in place of the product's value.
/// - The creation of each New Tab page waits until its test ends: a page's tab is its stand-in.
/// - The checks read the store's tab lists, not the pixels.
/// - A failure of a line that starts with `setup:` is no result.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ACloseTabKeyAfterKeptNewTabKeysTests {
    /// The creations of the New Tab pages of one test: each waits here until the test ends.
    @MainActor private final class HeldCreations {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            released = true
            for one in waiting { one.resume() }
            waiting = []
        }
    }

    /// The acts of one test in their order: one line for each key in its own call, and one line for each kept key
    /// when it runs again.
    @MainActor final class KeyLog {
        private(set) var lines: [String] = []
        /// How many kept keys ran again, and how many notes of an action the key router made for them.
        private(set) var replays = 0
        private(set) var replayNotes = 0
        /// The keys of the test in the order of the presses (kept here, so each event stays one object).
        private var pressed: [NSEvent] = []

        var said: String { lines.joined(separator: "; ") }

        func add(_ line: String) { lines.append(line) }

        /// Notes a key before the key router gets it; its number is its place in the order of the presses.
        func press(_ event: NSEvent) { pressed.append(event) }

        private func number(of event: NSEvent) -> String {
            pressed.firstIndex { $0 === event }.map { "key \($0 + 1)" } ?? "a key that the test did not press"
        }

        /// Where a kept key runs again: the app's key path, with one line for what the key router did with the key.
        var replay: HeldKeyReplay {
            { [self] event, window, router in
                let before = router.interceptions
                let taken = router.interceptKeyDown(event, in: window)
                if !taken { window.sendEvent(event) }
                let ran = router.interceptions > before ? router.lastInterception?.action.rawValue : nil
                replays += 1
                replayNotes += router.interceptions - before
                // The hold's log has the end of the hold that gave the key out before the key runs again.
                let end = router.creationInputCoordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "not known"
                add("\(number(of: event)) runs again (its hold's end: \(end)): " + (ran.map { "ran \($0)" } ?? (taken ? "taken with no action" : "not taken by the key router")))
            }
        }
    }

    /// The keys of one test, what each did in its own call, and the counts that the keys make in their order.
    @MainActor final class Keys {
        /// What the key router did with a key in the key's own call.
        enum Outcome: Equatable { case ran, kept, passedOn }

        private let services: AppServices
        private let window: NSWindow
        private let log: KeyLog
        /// The store's tabs before the first key.
        private let start: Set<String>
        private var stamp = ProcessInfo.processInfo.systemUptime
        private(set) var count = 0
        private(set) var repeats = 0
        /// The New Tab keys that the key router took and did not run in their own call.
        private(set) var keptNewTabKeys = 0
        private var newTabKeys = 0
        /// The new tabs that are open by the keys' order, and the two counts that the keys make.
        private var openNewTabs = 0
        private(set) var wantNewTabs = 0
        private(set) var wantOldTabsGone = 0
        /// The tabs of the start that a Close Tab key closed in its own call after 1 or more New Tab keys.
        private(set) var oldTabsClosedAfterANewTabKey: [String] = []

        init(services: AppServices, window: NSWindow, log: KeyLog) {
            self.services = services
            self.window = window
            self.log = log
            self.start = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
        }

        /// The store's tabs now, each pane's in its order.
        var tabs: [String] { PasswordManagerRouteTests.tabs(services).map(\.id) }
        var newTabs: [String] { tabs.filter { !start.contains($0) } }
        /// The new tabs by their kind, in the store's order: `terminal`, or `page` for each other kind.
        var newTabKinds: [String] {
            PasswordManagerRouteTests.tabs(services).filter { !start.contains($0.id) }.map { $0.kind == .pty ? "terminal" : "page" }
        }
        var oldTabsGone: [String] {
            let now = Set(tabs)
            return start.filter { !now.contains($0) }.sorted()
        }

        var said: String { log.said }

        private func label(_ id: String) -> String { (start.contains(id) ? "old tab " : "new tab ") + id }

        /// One key-down through the app's key path, with Command when `flags` does not say another thing.
        func press(_ name: String, _ characters: String, code: UInt16, repeats: Bool, flags: NSEvent.ModifierFlags = [.command]) throws -> (outcome: Outcome, gone: [String]) {
            stamp += 0.03
            count += 1
            if repeats { self.repeats += 1 }
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: stamp,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: repeats, keyCode: code),
                                     "setup: no key event")
            log.press(event)
            let router = services.keyRouter
            let before = tabs
            let notesBefore = router.interceptions
            let replaysBefore = log.replays, replayNotesBefore = log.replayNotes
            let taken = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
            if !taken { window.sendEvent(event) }
            // The router notes each action that it runs; a key that a hold keeps leaves no note. A kept key that ran
            // again in this call left a note of its own, before this key's: those notes are not this key's.
            let ranAgain = log.replays - replaysBefore
            let ownNotes = (router.interceptions - notesBefore) - (log.replayNotes - replayNotesBefore)
            let ran = ownNotes > 0 ? router.lastInterception?.action : nil
            let after = tabs
            let gone = before.filter { !after.contains($0) }
            let came = after.filter { !before.contains($0) }
            let outcome: Outcome = ran != nil ? .ran : (taken ? .kept : .passedOn)
            var line = "key \(count) (\(name)\(repeats ? ", a repeat" : "")): "
            switch outcome {
            case .ran: line += "ran \(ran?.rawValue ?? "an action")"
            case .kept: line += "kept by a hold"
            case .passedOn: line += "not taken by the key router"
            }
            if ranAgain > 0 { line += ", after \(ranAgain) kept keys that ran again in its call" }
            if !gone.isEmpty { line += ", closed \(gone.map(label).joined(separator: ", "))" }
            if !came.isEmpty { line += ", made \(came.map(label).joined(separator: ", "))" }
            log.add(line)
            return (outcome, gone)
        }

        /// The split key (Cmd-D): one new pane with one tab.
        @discardableResult
        func split() throws -> Outcome {
            let pressed = try press("Cmd-D", "d", code: 2, repeats: false)
            wantNewTabs += 1
            return pressed.outcome
        }

        /// The New Tab key (Cmd-T): one new tab.
        @discardableResult
        func newTab(repeats: Bool = false) throws -> Outcome {
            let pressed = try press("Cmd-T", "t", code: 17, repeats: repeats)
            newTabKeys += 1
            openNewTabs += 1
            wantNewTabs += 1
            if pressed.outcome == .kept { keptNewTabKeys += 1 }
            return pressed.outcome
        }

        /// The Close Tab key (Cmd-W): it closes the tab of the newest New Tab key whose tab is open, else the selected
        /// tab of the start.
        @discardableResult
        func closeTab(repeats: Bool = false) throws -> Outcome {
            let pressed = try press("Cmd-W", "w", code: 13, repeats: repeats)
            if openNewTabs > 0 {
                openNewTabs -= 1
                wantNewTabs -= 1
            } else {
                wantOldTabsGone += 1
            }
            if newTabKeys > 0 { oldTabsClosedAfterANewTabKey += pressed.gone.filter { start.contains($0) } }
            return pressed.outcome
        }
    }

    /// The end of the keys' work: no hold of the window's keys, and the store's tab list did not change for one second
    /// (a bound of the test, not a time of the product).
    static func settle(_ keys: Keys, in window: NSWindow, services: AppServices) async throws {
        let holds = services.keyRouter.creationInputCoordinator
        var last = keys.tabs
        var since = ContinuousClock.now
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let now = keys.tabs
            if now != last || holds.isHolding(in: window) {
                last = now
                since = ContinuousClock.now
            } else if ContinuousClock.now - since >= .seconds(1) {
                return
            }
        }
        Issue.record("setup: the window's keys did not come to rest in 30 seconds (a hold: \(holds.isHolding(in: window))); \(keys.said)")
    }

    /// The two checks of each test, and the test's counts.
    static func check(_ keys: Keys, _ label: String, lateAnswers: Int) {
        print("KEYS-IN-ORDER \(label): \(keys.count) keys, \(keys.repeats) repeats, \(lateAnswers) answers given late, \(keys.keptNewTabKeys) New Tab keys kept by a hold")
        #expect(keys.oldTabsClosedAfterANewTabKey.isEmpty,
                "a Close Tab key that came after a New Tab key closed \(keys.oldTabsClosedAfterANewTabKey), tabs that were there before the first key; \(keys.keptNewTabKeys) New Tab keys were kept by a hold; \(keys.said)")
        let new = keys.newTabs, gone = keys.oldTabsGone
        #expect(new.count == keys.wantNewTabs && gone.count == keys.wantOldTabsGone,
                "at the end \(new.count) new tabs (want \(keys.wantNewTabs)) and \(gone.count) old tabs closed (want \(keys.wantOldTabsGone)): new \(new), closed \(gone); \(keys.keptNewTabKeys) New Tab keys were kept by a hold; \(keys.said)")
    }

    /// The app with a terminal pane that a split made (the app's first pane can show a chat, where the keys mean other
    /// things): the daemon confirmed the pane, it has the focus and the keyboard, and no hold of the window's keys is
    /// open.
    static func withTerminalPane(_ body: (AppServices, NSWindow, KeyLog) async throws -> Void) async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let log = KeyLog()
        try await PasswordManagerRouteTests.withApp(agentPaneEnvironment: environment, heldKeyReplay: log.replay) { services, _ in
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
            try await body(services, window, log)
        }
    }

    /// New Tab pages whose creation waits until the test ends: from the call on, a New Tab key makes a New Tab page.
    private static func makeNewTabPages(_ services: AppServices, held: HeldCreations) throws {
        let tabs = services.agentTabs
        try #require(tabs.canHostChat, "setup: this build has no New Tab page")
        tabs.localHost = AgentSessionRef.host(installID: "a-close-tab-key-after-kept-new-tab-keys")
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabs.create = { _, _, _, _, _, _ in
            await held.wait()
            throw CancellationError()
        }
    }

    /// A split key opens the hold: Cmd-D, Cmd-T, Cmd-T as a repeat, Cmd-W, in one turn. The New Tab key makes a New
    /// Tab page here. At the end: the split's pane with its tab, and one of the two new tabs.
    @Test func aCloseTabKeyAfterNewTabKeysBehindASplitClosesTheNewestNewTab() async throws {
        try await Self.withTerminalPane { services, window, log in
            let held = HeldCreations()
            try Self.makeNewTabPages(services, held: held)
            let keys = Keys(services: services, window: window, log: log)
            var failure: (any Error)?
            do {
                // One turn of the main actor: the daemon's answer to the split cannot come between the keys.
                let split = try keys.split()
                try #require(split == .ran && services.keyRouter.creationInputCoordinator.isHolding(in: window),
                             "setup: the split key did not run, or it opened no hold; \(keys.said)")
                try keys.newTab()
                try keys.newTab(repeats: true)
                try keys.closeTab()
                try await Self.settle(keys, in: window, services: services)
            } catch { failure = error }
            Self.check(keys, "a split key, 2 New Tab keys that make pages, a Close Tab key", lateAnswers: 1)
            // Each creation of a New Tab page ends before the window closes.
            held.release()
            if let failure { throw failure }
        }
    }

    /// The same keys behind a split key, where each New Tab key makes a terminal (the pane's daemon holds no agent
    /// tabs): Cmd-D, Cmd-T, Cmd-T as a repeat, Cmd-W, in one turn. At the end: the split's pane with its tab, and one
    /// of the two new terminals.
    @Test func aCloseTabKeyAfterNewTabKeysThatMakeTerminalsBehindASplitClosesTheNewestNewTab() async throws {
        try await Self.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let keys = Keys(services: services, window: window, log: log)
            var failure: (any Error)?
            do {
                // One turn of the main actor: the daemon's answer to the split cannot come between the keys.
                let split = try keys.split()
                try #require(split == .ran && services.keyRouter.creationInputCoordinator.isHolding(in: window),
                             "setup: the split key did not run, or it opened no hold; \(keys.said)")
                try keys.newTab()
                try keys.newTab(repeats: true)
                try keys.closeTab()
                try await Self.settle(keys, in: window, services: services)
            } catch { failure = error }
            Self.check(keys, "a split key, 2 New Tab keys that make terminals, a Close Tab key", lateAnswers: 1)
            if let failure { throw failure }
        }
    }

    /// The New Tab key opens the hold itself (it makes a terminal: the pane's daemon holds no agent tabs): Cmd-T, Cmd-T
    /// as a repeat two times, Cmd-W, in one turn. At the end: two of the three new tabs.
    @Test func aCloseTabKeyAfterAHeldNewTabKeyThatMakesTerminalsClosesTheNewestNewTab() async throws {
        try await Self.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let keys = Keys(services: services, window: window, log: log)
            var failure: (any Error)?
            do {
                // One turn of the main actor: the daemon's answer to the first creation cannot come between the keys.
                let first = try keys.newTab()
                try #require(first == .ran && services.keyRouter.creationInputCoordinator.isHolding(in: window),
                             "setup: the first New Tab key did not run, or it opened no hold; \(keys.said)")
                try keys.newTab(repeats: true)
                try keys.newTab(repeats: true)
                try keys.closeTab()
                try await Self.settle(keys, in: window, services: services)
            } catch { failure = error }
            Self.check(keys, "a held New Tab key that makes terminals, a Close Tab key", lateAnswers: 1)
            if let failure { throw failure }
        }
    }

    /// The mix. The first New Tab key makes a terminal and opens the hold; from the second key on, a New Tab key makes
    /// a New Tab page: Cmd-T, Cmd-T, Cmd-W, in one turn. With `focusLeaves`, the focus then goes to the window's other
    /// pane in the same turn, before the daemon's answer to the terminal. At the end: one new tab, and it is the
    /// terminal of the first key (the Close Tab key closed the page of the second key).
    @Test(arguments: [false, true])
    func aCloseTabKeyAfterATerminalAndAPageNewTabKeyClosesThePage(focusLeaves: Bool) async throws {
        try await Self.withTerminalPane { services, window, log in
            let content = try #require(services.windows.active?.workspaceContent, "setup: the window shows no workspace")
            let other = try #require(content.panes.values.first { $0.paneKey != content.focus.state.pane }, "setup: the window has no second pane")
            let held = HeldCreations()
            services.agentTabs.holdsTabs = { _ in false }
            let keys = Keys(services: services, window: window, log: log)
            var failure: (any Error)?
            do {
                // One turn of the main actor: the daemon's answer to the terminal cannot come between the keys.
                let first = try keys.newTab()
                try #require(first == .ran && services.keyRouter.creationInputCoordinator.isHolding(in: window),
                             "setup: the first New Tab key did not run, or it opened no hold; \(keys.said)")
                try Self.makeNewTabPages(services, held: held)
                try keys.newTab()
                try keys.closeTab()
                if focusLeaves { PaneHandlers.focus(other.layoutPaneID, in: content) }
                try await Self.settle(keys, in: window, services: services)
            } catch { failure = error }
            Self.check(keys, "a New Tab key that makes a terminal, a New Tab key that makes a page, a Close Tab key\(focusLeaves ? ", then the focus leaves the pane" : "")", lateAnswers: 1)
            let kinds = keys.newTabKinds
            #expect(kinds == ["terminal"],
                    "at the end the new tabs are \(kinds) (want the terminal of the first key only: the Close Tab key closes the page of the second key); \(keys.said)")
            held.release()
            if let failure { throw failure }
        }
    }

    /// A Close Tab key on a terminal opens the hold (its read of the daemon is held): Cmd-W, then Cmd-T, Cmd-T as a
    /// repeat and Cmd-W in one turn. At the end: the first terminal is closed, and one of the two new tabs is open. The
    /// terminal has a terminal tab before it in its pane: the tab that the pane shows while the close reads.
    @Test func aCloseTabKeyAfterNewTabKeysBehindAClosesReadClosesTheNewestNewTab() async throws {
        let log = KeyLog()
        try await PinnedPageTests.withApp(heldKeyReplay: log.replay) { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first, "setup: the store has no pane")
            try await PinnedPageTests.until({ services.paneController(for: paneModel) != nil }, report: { "setup: the first pane has no controller" })
            let pane = try #require(services.paneController(for: paneModel), "setup: the first pane has no controller")
            services.agentTabs.holdsTabs = { _ in false }
            // Two terminal tabs at the end of the pane: the neighbour, then the terminal that the first Cmd-W closes.
            var made: [TabModel] = []
            for _ in 0..<2 {
                let surface = try await connection.newTab(in: paneModel.handle).surface
                try await PinnedPageTests.until({ store.tab(surface: surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true },
                                                report: { "setup: the pane's strip does not list a new terminal tab" })
                let tab = try #require(store.tab(surface: surface), "setup: the store has no tab for a new terminal")
                made.append(tab)
                pane.select(CmuxNextTabs.TabID(tab.id))
            }
            let neighbour = made[0], terminal = made[1]
            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == terminal.id }, report: { "setup: the pane does not select the terminal" })
            try #require(services.windows.active?.focusedPane === pane, "setup: the terminal's pane is not the focused one")
            try #require(TabCloseGuard.asks([terminal], services: services), "setup: a close of the terminal reads nothing from the daemon")
            // The terminal's shell runs, with no program in front.
            var idle = false
            for _ in 0..<100 where !idle {
                if let answer = await connection.readProcessInfo(terminal.surface, timeout: .seconds(1)), answer.runningProgram == nil { idle = true }
                else { try await Task.sleep(for: .milliseconds(100)) }
            }
            try #require(idle, "setup: the terminal's shell did not start")
            let window = try #require(pane.view.window, "setup: the pane's view is in no window")
            let hold = services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            let keys = Keys(services: services, window: window, log: log)
            var failure: (any Error)?
            do {
                let first = try keys.closeTab()
                try #require(first == .ran && TabCloseGuard.reading.contains(terminal.id),
                             "setup: the first Cmd-W did not run, or it did not wait for the close's read; \(keys.said)")
                // The pane shows the neighbour and the focus is on it (a bound of the test).
                try await Task.sleep(for: .milliseconds(300))
                try #require(pane.stripModel.selectedID?.rawValue == neighbour.id, "setup: the pane does not show the neighbour while the close reads; \(keys.said)")
                // One turn of the main actor, inside the read.
                try keys.newTab()
                try keys.newTab(repeats: true)
                try keys.closeTab()
                let resumed = hold.release()
                try #require(resumed >= 1, "setup: the close's read was not held (no read waited); \(keys.said)")
                try await Self.settle(keys, in: window, services: services)
            } catch { failure = error }
            Self.check(keys, "a Close Tab key on a terminal whose close reads, 2 New Tab keys, a Close Tab key", lateAnswers: 1)
            if let failure { throw failure }
        }
    }

    /// The forced end. The test opens a hold with a creation that never answers, so the hold can end only by force: at
    /// its reply bound (1 second here). The keys of a row come in one turn, and the hold keeps each. A hold that ends by
    /// force runs its kept keys at the thing that has the focus then, which can be a tab that was there before the
    /// keys. So the kept keys are first reduced by their own meaning: a kept Close Tab key cancels the newest kept New
    /// Tab key before it that is not cancelled yet (the two keys asked for no change and make none); a kept Close Tab
    /// key with no such key before it is dropped; each New Tab key that is left runs. A dropped key is a lost key: the
    /// person pressed it and the app did nothing for it. The test waits for the forced end by its event: the hold's
    /// log names the reply bound as the hold's end, or a kept key ran again (only the end of a hold runs one).
    @Test(arguments: zip(["Cmd-T Cmd-T Cmd-W", "Cmd-T Cmd-W", "Cmd-T Cmd-W Cmd-W"], [1, 0, 0]))
    func keptCloseTabKeysCloseNoOldTabWhenTheHoldEndsByForce(typed: String, wantNewTabs: Int) async throws {
        try await Self.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let holds = services.keyRouter.creationInputCoordinator
            holds.replyWaitLimit = .seconds(1)
            let controller = try #require(services.windows.active, "setup: the app has no window")
            let ticket = try #require(holds.begin(in: window, generation: controller.focus.beginIntent(), tab: "pending_tab_that_never_answers"),
                                      "setup: no hold opened for the creation that never answers")
            let keys = Keys(services: services, window: window, log: log)
            var failure: (any Error)?, closes: [Keys.Outcome] = []
            do {
                // One turn of the main actor, inside the hold.
                for key in typed.split(separator: " ") {
                    if key == "Cmd-W" { try closes.append(keys.closeTab()); continue }
                    let newTab = try keys.newTab()
                    try #require(newTab == .kept, "setup: the hold did not keep a New Tab key; \(keys.said)")
                }
                if closes.allSatisfy({ $0 == .kept }) {
                    try await PasswordManagerRouteTests.until({ holds.lastHoldEnd(in: window) == .replyBoundReached || log.replays > 0 },
                                                              report: { "setup: the hold did not end at its reply bound; \(keys.said)" })
                }
                try await Self.settle(keys, in: window, services: services)
            } catch { failure = error }
            let new = keys.newTabs, gone = keys.oldTabsGone
            print("KEYS-IN-ORDER a hold that ends by force, \(typed): \(keys.count) keys, \(keys.keptNewTabKeys) New Tab keys kept by a hold, \(new.count) new tabs at the end")
            #expect(closes.allSatisfy { $0 == .kept }, "a Close Tab key that came after a kept New Tab key was not kept by the hold; \(keys.said)")
            #expect(gone.isEmpty && keys.oldTabsClosedAfterANewTabKey.isEmpty, "the keys closed \(gone), tabs that were there before the first key; \(keys.said)")
            #expect(new.count == wantNewTabs, "at the end \(new.count) new tabs (want \(wantNewTabs)): \(new); \(keys.said)")
            holds.resolve(ticket, landed: false, in: window)
            if let failure { throw failure }
        }
    }
}
