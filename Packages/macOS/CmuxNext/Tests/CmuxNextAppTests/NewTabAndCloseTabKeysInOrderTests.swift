import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// A held New Tab key and Close Tab keys, as key events through the key router: each Close Tab key closes the newest
/// new tab, and the pane then selects the new tab that was made directly before it (at the end, the tab that was
/// selected before the first key).
///
/// Decision of 2026-11-16: the order of a person's New Tab and Close Tab keys is tested with key events through the
/// key router, repeats included, and not by a call of the action. The tests that were there call the action, click, or
/// test one rule alone.
///
/// A whole window of the `large` session with no daemon. Each key is a new key-down event with Command, the window's
/// number and a rising time; each key-down of a held key after its first is a repeat. It goes to
/// `KeyRouter.interceptKeyDown` inside `dispatchingSynthetic`, as the application's `sendEvent` gives it. The New Tab
/// key makes a New Tab page, and the daemon's side of its creation waits, so the test gives each answer by hand: the
/// daemon's `tab-added` event with the creation's transaction, and the daemon's `tab-closed` event of a close. Each
/// row runs in one turn of the main actor. After each key and each answer the row checks the strip and the selected
/// tab against a model: the new tabs are a stack after the tab that was selected at the start (the rule of
/// `close_selection.rs` for a new tab directly after the selected tab). Each row prints its counts at its end.
///
/// Limits:
/// - No HID event, no `nextEvent`, no event monitor, no `sendEvent`: the keys start at the key router.
/// - No daemon and no real time: an answer comes only at a named point of a row, never between two lines of the app.
/// - No frame is drawn: the row reads the strip's list and its selected tab, not the pixels.
/// - No close of a terminal: that close first asks the daemon what runs there, and this window has no daemon. Each
///   tab that a row closes is a New Tab page.
/// - The model holds only while each New Tab key comes from the selected tab and `tabs.newTabPosition` is its
///   default.
/// - In the last test the New Tab key after the Close Tab key is sent as a repeat. The key router has no rule of its
///   own for a repeat.
/// - A key that a hold keeps is in `ACloseTabKeyAfterKeptNewTabKeysTests`: no hold begins in a window with no daemon.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NewTabAndCloseTabKeysInOrderTests {
    /// When the daemon answers the creations of the three New Tab keys (keys 1 to 3), and the close of key 4.
    enum Answers: String, CaseIterable, Sendable {
        /// No answer before the row's end: each close is the close of a tab that has no answer.
        case none
        /// Each creation's answer directly after its key.
        case eachAtOnce
        /// The three answers in one update, before the first Close Tab key.
        case togetherBeforeTheCloses
        /// The three answers in three updates, the newest creation first, before the first Close Tab key.
        case newestFirstBeforeTheCloses
        /// The first Close Tab key closes a tab with no answer; then the two other answers in one update.
        case betweenTheCloses
        /// Key 3's answer, the first Close Tab key (it closes the daemon's tab), then the two other answers, and only
        /// then the daemon's answer to the close.
        case aCreationsAnswerBeforeTheClosesAnswer
        /// The same, with the daemon's answer to the close before the two other answers.
        case theClosesAnswerBeforeACreationsAnswer
    }

    /// The creations of one row: each waits here, so the daemon's side answers nothing by itself.
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

    /// The tab of one New Tab key.
    private struct Made {
        /// The strip's id of the tab now: the stand-in's, then the id of the daemon's tab.
        var tab: String
        /// The daemon's tab, once the row gave the creation's answer.
        var surface: SurfaceID?
        /// The daemon's `tab-added` event of the creation, for a surface.
        let added: (SurfaceID) -> DaemonEvent
    }

    /// One row: its keys, its answers, and the model of the strip.
    @MainActor private final class Row {
        private let pane: PaneController
        private let controller: WindowController
        private let window: NSWindow
        private let store: DaemonStore
        /// The strip at the start, and the index of the tab that was selected then.
        private let start: [String]
        private let anchor: Int
        /// The tab of each New Tab key, by the key's number.
        private var made: [Int: Made] = [:]
        /// The keys whose new tabs are open, oldest first.
        private var openKeys: [Int] = []
        private var stamp = ProcessInfo.processInfo.systemUptime
        private var surfaces = 0
        private(set) var keys = 0
        private(set) var repeats = 0
        private(set) var answers = 0
        private(set) var lateAnswers = 0
        private(set) var closeAnswers = 0

        init(pane: PaneController, controller: WindowController, window: NSWindow) throws {
            let listed = pane.orderedIDs.map(\.rawValue)
            let records = pane.pane.tabs.map(\.id)
            try #require(listed == records, "setup: the strip \(listed) is not the store's list \(records)")
            let chosen = try #require(pane.stripModel.selectedID?.rawValue, "setup: the pane selects no tab")
            let index = try #require(listed.firstIndex(of: chosen), "setup: the selected tab is not in the strip")
            self.pane = pane
            self.controller = controller
            self.window = window
            self.store = pane.daemon.store
            self.start = listed
            self.anchor = index
        }

        private var strip: [String] { pane.orderedIDs.map(\.rawValue) }
        private var selected: String { pane.stripModel.selectedID?.rawValue ?? "no tab" }

        /// The strip that the keys so far make: the open new tabs, oldest first, directly after the start's selected tab.
        private var wantStrip: [String] {
            var want = start
            want.insert(contentsOf: openKeys.compactMap { made[$0]?.tab }, at: anchor + 1)
            return want
        }

        /// The tab of the newest New Tab key whose tab is open, else the tab that was selected at the start.
        private var wantSelected: String { openKeys.last.flatMap { made[$0]?.tab } ?? start[anchor] }

        /// A tab's id with its name in the row: `s3` for the fourth tab of the start, `N2` for the tab of key 2.
        private func name(_ id: String) -> String {
            if let key = made.first(where: { $0.value.tab == id })?.key { return "N\(key)=\(id)" }
            if let index = start.firstIndex(of: id) { return "s\(index)=\(id)" }
            return "?=\(id)"
        }

        private func names(_ ids: [String]) -> String { "[" + ids.map(name).joined(separator: " ") + "]" }

        /// The strip and the selected tab are the model's.
        private func check(_ after: String) throws {
            let now = strip, want = wantStrip
            try #require(now == want, "\(after): the strip lists \(names(now)), want \(names(want))")
            try #require(selected == wantSelected, "\(after): the pane selects \(name(selected)), want \(name(wantSelected))")
        }

        /// One key-down with Command through the key router. `ran`: the action that the router ran in the key's own
        /// call (nil: none, so a key that it took is kept by a hold).
        private func send(_ characters: String, code: UInt16, repeats: Bool) throws -> (taken: Bool, ran: ActionID?) {
            stamp += 0.03
            keys += 1
            if repeats { self.repeats += 1 }
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: stamp,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: repeats, keyCode: code),
                                     "setup: no key event")
            let router = controller.services.keyRouter
            let ranBefore = router.interceptions
            let taken = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
            return (taken, router.interceptions > ranBefore ? router.lastInterception?.action : nil)
        }

        /// The New Tab key. Its tab shows in the key's own call, directly after the tab that was selected, selected.
        func newTab(repeats: Bool = false) throws {
            let before = strip
            let sent = try send("t", code: 17, repeats: repeats)
            // A first key that makes no tab is a fault of the test's window, not a result.
            let key = keys, what = "\(keys == 1 ? "setup: " : "")key \(keys) (Cmd-T\(repeats ? ", a repeat" : ""))"
            try #require(sent.taken && sent.ran != nil,
                         "\(what): the key router ran no action in the key's own call (it \(sent.taken ? "took the key: a hold keeps it" : "passed the key on"))")
            let added = strip.filter { !before.contains($0) }
            try #require(added.count == 1 && strip.count == before.count + 1,
                         "\(what) ran \(sent.ran?.rawValue ?? "no action") and added \(added.count) tabs to the strip in its own call, want 1: the strip lists \(names(strip))")
            let standIn = added[0]
            let created = store.intentLog.entries.last { entry in
                if case .createTab(_, let provisional) = entry.kind { return provisional.tabResourceID?.rawValue == standIn }
                return false
            }
            let entry = try #require(created, "setup: the store has no creation intent for the tab of \(what)")
            guard case .createTab(let paneHandle, let provisional) = entry.kind else { return }
            let screen = try #require(store.workspaces.flatMap(\.screens).first { screen in screen.panes.contains { $0 === pane.pane } },
                                      "setup: no screen of the store holds the pane")
            let workspace = try #require(store.workspaces.first { workspace in workspace.screens.contains { $0 === screen } },
                                         "setup: no workspace of the store holds the pane's screen")
            let (workspaceHandle, screenHandle, transaction) = (workspace.handle, screen.handle, entry.transaction)
            made[key] = Made(tab: standIn, surface: nil, added: { surface in
                var entity = TabSnapshot(surface: surface, kind: .conversation, title: "chat", browserRenderer: "frontend")
                entity.conversation = provisional.conversation
                return .tabAdded(TabDelta(workspace: workspaceHandle, screen: screenHandle, pane: paneHandle, surface: surface, index: nil,
                                          entity: entity, clientTransactionID: transaction))
            })
            openKeys.append(key)
            try check("after \(what)")
        }

        /// The Close Tab key. It closes one tab, the tab of the newest New Tab key whose tab is open.
        func closeTab(repeats: Bool = false) throws {
            let before = strip, selectedBefore = selected
            let sent = try send("w", code: 13, repeats: repeats)
            let what = "key \(keys) (Cmd-W\(repeats ? ", a repeat" : ""))"
            try #require(sent.taken && sent.ran != nil,
                         "\(what): the key router ran no action in the key's own call (it \(sent.taken ? "took the key: a hold keeps it" : "passed the key on"))")
            let newest = try #require(openKeys.last, "setup: \(what) comes when no new tab is open")
            let want = try #require(made[newest]?.tab, "setup: key \(newest) has no tab")
            let now = strip
            let gone = before.filter { !now.contains($0) }, came = now.filter { !before.contains($0) }
            try #require(gone == [want] && came.isEmpty,
                         "\(what) ran \(sent.ran?.rawValue ?? "no action") and closed \(names(gone)), want \(name(want)), the tab of key \(newest), the newest New Tab key whose tab is open; the pane selected \(name(selectedBefore)) before the key\(came.isEmpty ? "" : "; new in the strip: \(names(came))")")
            openKeys.removeLast()
            try check("after \(what)")
        }

        /// The daemon's answers to the creations of `answered` (New Tab keys by number), in that order, in one update.
        func answer(_ answered: [Int]) throws {
            var batch: [DaemonEventEnvelope] = []
            var sequence = max(store.appliedSequence, store.snapshotBarrier)
            for key in answered {
                let one = try #require(made[key], "setup: key \(key) made no tab")
                // A surface past each tab of the session.
                let surface = LargeSessionWindowFixture.surface(workspace: SessionFixtureSize.large.workspaces + 1, index: surfaces)
                surfaces += 1
                try #require(store.tab(surface: surface) == nil, "setup: the session has a tab with the surface of key \(key)'s answer")
                sequence += 1
                batch.append(DaemonEventEnvelope(sequence: sequence, event: one.added(surface)))
                made[key]?.surface = surface
            }
            _ = store.apply(batch: batch)
            answers += answered.count
            // Late: 1 or more keys came between the creation's key and its answer.
            lateAnswers += answered.filter { $0 < keys }.count
            for key in answered {
                let surface = try #require(made[key]?.surface, "setup: key \(key) has no surface")
                let tab = try #require(store.tab(surface: surface), "setup: the store did not take the daemon's tab of key \(key)")
                made[key]?.tab = tab.id
            }
            try check("after the daemon's answer to the creation of key \(answered.map { "\($0)" }.joined(separator: ", "))")
        }

        /// The daemon's answer to the close of the tab of New Tab key `key`: its `tab-closed` event.
        func daemonCloses(_ key: Int) throws {
            let surface = try #require(made[key]?.surface, "setup: the tab of key \(key) has no answer, so the daemon has no tab to close")
            let screen = try #require(store.workspaces.flatMap(\.screens).first { screen in screen.panes.contains { $0 === pane.pane } },
                                      "setup: no screen of the store holds the pane")
            let workspace = try #require(store.workspaces.first { workspace in workspace.screens.contains { $0 === screen } },
                                         "setup: no workspace of the store holds the pane's screen")
            let delta = TabDelta(workspace: workspace.handle, screen: screen.handle, pane: pane.pane.handle, surface: surface, index: nil,
                                 entity: TabSnapshot(surface: surface))
            let sequence = max(store.appliedSequence, store.snapshotBarrier) + 1
            _ = store.apply(batch: [DaemonEventEnvelope(sequence: sequence, event: .tabClosed(delta))])
            closeAnswers += 1
            try check("after the daemon's answer to the close of key \(key)'s tab")
        }
    }

    /// Runs `body`, in one turn of the main actor, on the focused pane of a whole window. The New Tab key makes a New
    /// Tab page there, and the daemon's side of each creation waits until `body` ends. Prints the row's counts.
    private static func withRow(_ label: String, _ body: @MainActor (Row) throws -> Void) async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        try await LargeSessionWindowFixture.withController(.large, agentPaneEnvironment: environment) { _, controller in
            let tabs = controller.services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let window = try #require(controller.window, "setup: the window's controller has no window")
            let held = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "new-tab-and-close-tab-keys-in-order")
            tabs.holdsTabs = { _ in true }
            tabs.reachable = { _ in true }
            tabs.create = { _, _, _, _, _, _ in
                await held.wait()
                throw CancellationError()
            }
            let row = try Row(pane: pane, controller: controller, window: window)
            var failure: (any Error)?
            do { try body(row) } catch { failure = error }
            print("KEYS-IN-ORDER \(label): \(row.keys) keys, \(row.repeats) repeats, \(row.lateAnswers) answers given late (of \(row.answers) answers to a creation), \(row.closeAnswers) answers to a close\(failure == nil ? "" : "; the row ended at its first failure")")
            // Each creation ends before the window closes.
            held.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }

    /// The New Tab key held for three tabs (keys 1 to 3), then the Close Tab key two times (keys 4 and 5): key 4 closes
    /// the tab of key 3 and the pane selects the tab of key 2, key 5 closes the tab of key 2 and the pane selects the
    /// tab of key 1. One row for each order of the daemon's answers.
    @Test(arguments: Answers.allCases)
    func aHeldNewTabKeyThenTwoCloseTabKeysCloseTheTwoNewestNewTabs(_ answers: Answers) async throws {
        try await Self.withRow("a held New Tab key, then 2 Close Tab keys; answers: \(answers.rawValue)") { row in
            try row.newTab()
            if answers == .eachAtOnce { try row.answer([1]) }
            try row.newTab(repeats: true)
            if answers == .eachAtOnce { try row.answer([2]) }
            try row.newTab(repeats: true)
            switch answers {
            case .eachAtOnce, .aCreationsAnswerBeforeTheClosesAnswer, .theClosesAnswerBeforeACreationsAnswer:
                try row.answer([3])
            case .togetherBeforeTheCloses:
                try row.answer([1, 2, 3])
            case .newestFirstBeforeTheCloses:
                try row.answer([3])
                try row.answer([2])
                try row.answer([1])
            case .none, .betweenTheCloses:
                break
            }
            try row.closeTab()
            switch answers {
            case .betweenTheCloses:
                try row.answer([1, 2])
            case .aCreationsAnswerBeforeTheClosesAnswer:
                try row.answer([1, 2])
                try row.daemonCloses(3)
            case .theClosesAnswerBeforeACreationsAnswer:
                try row.daemonCloses(3)
                try row.answer([1, 2])
            case .none, .eachAtOnce, .togetherBeforeTheCloses, .newestFirstBeforeTheCloses:
                break
            }
            try row.closeTab()
        }
    }

    /// The New Tab key held for four tabs, the first two answers in one update, then the Close Tab key held for three
    /// closes: the tabs of keys 4, 3 and 2 close, newest first, and the pane selects the tab of key 1.
    @Test func aHeldCloseTabKeyClosesTheNewTabsNewestFirst() async throws {
        try await Self.withRow("a held New Tab key, then a held Close Tab key") { row in
            try row.newTab()
            try row.newTab(repeats: true)
            try row.newTab(repeats: true)
            try row.newTab(repeats: true)
            try row.answer([1, 2])
            try row.closeTab()
            try row.closeTab(repeats: true)
            try row.closeTab(repeats: true)
        }
    }

    /// Which of the two answers comes first after a Close Tab key and a New Tab key: the app takes them in two tasks,
    /// and no code forces their order.
    enum AfterTheClose: String, CaseIterable, Sendable { case theClosesAnswerFirst, theNewTabsAnswerFirst }

    /// The Close Tab key on an answered new tab (key 3 closes the tab of key 2), then the New Tab key (key 4) before the
    /// daemon answered the close: the new tab goes directly after the tab that the close selected, and the closed tab
    /// stays out of the strip. Then the two answers, in each order, and one more Close Tab key.
    @Test(arguments: AfterTheClose.allCases)
    func aNewTabKeyBeforeTheAnswerToACloseTabKeyGoesAfterTheTabThatTheCloseSelected(_ order: AfterTheClose) async throws {
        try await Self.withRow("Close Tab, then New Tab before the close's answer; \(order.rawValue)") { row in
            try row.newTab()
            try row.answer([1])
            try row.newTab(repeats: true)
            try row.answer([2])
            try row.closeTab()
            try row.newTab(repeats: true)
            switch order {
            case .theClosesAnswerFirst:
                try row.daemonCloses(2)
                try row.answer([4])
            case .theNewTabsAnswerFirst:
                try row.answer([4])
                try row.daemonCloses(2)
            }
            try row.closeTab()
        }
    }
}
