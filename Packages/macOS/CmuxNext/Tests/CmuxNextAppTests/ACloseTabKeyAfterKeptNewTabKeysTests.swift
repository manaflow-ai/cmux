import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// A Close Tab key that comes after New Tab keys while a hold of the window's keys is open: the order of a person's
/// keys.
///
/// Decision of 2026-11-16: an act never runs before the act of a key that the person pressed before it. So a Close Tab
/// key that comes after New Tab keys closes the tab of the newest New Tab key (it waits behind the keys that a hold
/// keeps, or those keys run first). It never closes a tab that was there before the keys, and no New Tab key is lost.
///
/// The app on a fresh same-tree daemon. Each key is a key-down event with Command through the key router
/// (`KeyRouter.interceptKeyDown` inside `dispatchingSynthetic`, then the window when the router does not take it). A
/// key that a hold keeps runs again on the same path (`heldKeyReplay`). One test for each thing that opens a hold:
/// - a split key: the new pane's stand-in shows at once, and the keys wait for the daemon's answer;
/// - the New Tab key itself, where it makes a terminal (the pane's daemon holds no agent tabs);
/// - a Close Tab key on a terminal: the tab leaves at once, and the keys wait while the app reads from the daemon what
///   runs in the terminal.
///
/// Each test checks two things. In the key's own call, a Close Tab key that comes after a New Tab key closes no tab
/// that was there before the first key. At the end (no hold, and the store's tab list did not change for one second),
/// the count of the new tabs and of the closed old tabs is the count that the keys make in their order. Each test
/// prints its counts at its end, and a failure names each key with what it did in its own call.
///
/// Limits:
/// - No HID event, no `nextEvent`, no event monitor: the keys start at the key router.
/// - In the two creation tests the keys run in one turn of the main actor, so the daemon's answer cannot come between
///   them. That is harder than a person, whose keys are 30 ms or more apart. The suite does not say how long the answer
///   of a person's daemon takes.
/// - In the close test the read is held by the debug hold of the close read (`DaemonService.closeReadHold`), not by a
///   slow daemon, and the terminal is idle.
/// - In the test of the New Tab key's own hold and in the close test the New Tab key makes a terminal.
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

    /// The keys of one test, what each did in its own call, and the counts that the keys make in their order.
    @MainActor private final class Keys {
        /// What the key router did with a key in the key's own call.
        enum Outcome: Equatable { case ran, kept, passedOn }

        private let services: AppServices
        private let window: NSWindow
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
        /// One line for each key.
        private(set) var trace: [String] = []
        /// The tabs of the start that a Close Tab key closed in its own call after 1 or more New Tab keys.
        private(set) var oldTabsClosedAfterANewTabKey: [String] = []

        init(services: AppServices, window: NSWindow) {
            self.services = services
            self.window = window
            self.start = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
        }

        /// The store's tabs now, each pane's in its order.
        var tabs: [String] { PasswordManagerRouteTests.tabs(services).map(\.id) }
        var newTabs: [String] { tabs.filter { !start.contains($0) } }
        var oldTabsGone: [String] {
            let now = Set(tabs)
            return start.filter { !now.contains($0) }.sorted()
        }

        var said: String { trace.joined(separator: "; ") }

        private func label(_ id: String) -> String { (start.contains(id) ? "old tab " : "new tab ") + id }

        /// One key-down with Command through the app's key path.
        private func press(_ name: String, _ characters: String, code: UInt16, repeats: Bool) throws -> (outcome: Outcome, gone: [String]) {
            stamp += 0.03
            count += 1
            if repeats { self.repeats += 1 }
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: stamp,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: repeats, keyCode: code),
                                     "setup: no key event")
            let router = services.keyRouter
            let before = tabs
            let ranBefore = router.interceptions
            let taken = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
            if !taken { window.sendEvent(event) }
            // The router notes each action that it runs; a key that a hold keeps leaves no note.
            let ran = router.interceptions > ranBefore ? router.lastInterception?.action : nil
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
            if !gone.isEmpty { line += ", closed \(gone.map(label).joined(separator: ", "))" }
            if !came.isEmpty { line += ", made \(came.map(label).joined(separator: ", "))" }
            trace.append(line)
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
    private static func settle(_ keys: Keys, in window: NSWindow, services: AppServices) async throws {
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
    private static func check(_ keys: Keys, _ label: String, lateAnswers: Int) {
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
    private static func withTerminalPane(_ body: (AppServices, NSWindow) async throws -> Void) async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        try await PasswordManagerRouteTests.withApp(agentPaneEnvironment: environment, heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, _ in
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
            try await body(services, window)
        }
    }

    /// A split key opens the hold: Cmd-D, Cmd-T, Cmd-T as a repeat, Cmd-W, in one turn. The New Tab key makes a New
    /// Tab page here. At the end: the split's pane with its tab, and one of the two new tabs.
    @Test func aCloseTabKeyAfterNewTabKeysBehindASplitClosesTheNewestNewTab() async throws {
        try await Self.withTerminalPane { services, window in
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let held = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "a-close-tab-key-after-kept-new-tab-keys")
            tabs.holdsTabs = { _ in true }
            tabs.reachable = { _ in true }
            tabs.create = { _, _, _, _, _, _ in
                await held.wait()
                throw CancellationError()
            }
            let keys = Keys(services: services, window: window)
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
            Self.check(keys, "a split key, 2 New Tab keys, a Close Tab key", lateAnswers: 1)
            // Each creation of a New Tab page ends before the window closes.
            held.release()
            if let failure { throw failure }
        }
    }

    /// The New Tab key opens the hold itself (it makes a terminal: the pane's daemon holds no agent tabs): Cmd-T, Cmd-T
    /// as a repeat two times, Cmd-W, in one turn. At the end: two of the three new tabs.
    @Test func aCloseTabKeyAfterAHeldNewTabKeyThatMakesTerminalsClosesTheNewestNewTab() async throws {
        try await Self.withTerminalPane { services, window in
            services.agentTabs.holdsTabs = { _ in false }
            let keys = Keys(services: services, window: window)
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

    /// A Close Tab key on a terminal opens the hold (its read of the daemon is held): Cmd-W, then Cmd-T, Cmd-T as a
    /// repeat and Cmd-W in one turn. At the end: the first terminal is closed, and one of the two new tabs is open. The
    /// terminal has a terminal tab before it in its pane: the tab that the pane shows while the close reads.
    @Test func aCloseTabKeyAfterNewTabKeysBehindAClosesReadClosesTheNewestNewTab() async throws {
        try await PinnedPageTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
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
            let keys = Keys(services: services, window: window)
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
}
