import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// A new tab (the New Tab key, or an app page opened as a tab), then a close of another tab of the pane before the
/// daemon answered the creation: the closed tab stays out of the strip while the daemon's tab arrives.
///
/// Decision of 2026-11-16: a closed tab that shows again for one frame is a fault (a frame with a state that never
/// was), not a known issue. `NewTabCloseInterleaveOrderTests` samples the strip against a real daemon, so it sees
/// that frame only when a sample falls in it. This suite records the strip at the two points where it can change, so
/// each run sees it.
///
/// A whole window of the `large` session with no daemon. The test makes the new tab, closes the other tab and gives
/// the store the daemon's `tab-added` event of the creation in one turn of the main actor: no wait, no sample loop.
/// The strip is recorded right after the app's own report of the created tab (`AgentTabs.moveSelection` for the New
/// Tab key, the store's `onPageTabCreated` for a page tab) and when the store's apply returns.
///
/// Limits: the close is the pane's own close (`PaneController.close`), which hides the tab by a close intent of the
/// store at once. A person's close of a terminal hides it by the same intent while it asks the daemon what runs
/// there, and that question has no answer in a window with no daemon. The order in which the daemon's reply comes
/// before its event is not in this suite.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct ACloseInTheTurnOfANewTabStaysClosedTests {
    /// Which of the three tabs `a b c` (b selected, so the new tab goes between b and c) closes: the right neighbor
    /// of the selected tab, its left one, or the selected tab itself.
    enum Closed: String, CaseIterable, Sendable { case right, left, anchor }

    /// What makes the new tab: the New Tab key (an agent tab's creation), or an app page opened as a tab (a page
    /// tab's creation, which the store reports to the app on another path). The page rows do not check the place of
    /// the new tab.
    enum Made: String, CaseIterable, Sendable { case newTab, page }

    /// An app page with an empty view: the page of the `page` rows.
    private final class EmptyPage: InternalPageProvider {
        let page = InternalPageID.settings
        var title = "Settings"
        var symbol = "gear"
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// The creation of one test: it waits here, so the daemon's side answers nothing before `release()`.
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

    /// The strip as letters, one entry per record: a letter for each tab of the start in its order, `N` for the new
    /// tab (the stand-in or the daemon's).
    @MainActor private final class Frames {
        private let pane: PaneController
        private let letters: [String: String]
        private(set) var all: [String] = []
        /// How many times the app's report of a created tab ran.
        private(set) var moves = 0

        init(pane: PaneController, letters: [String: String]) {
            self.pane = pane
            self.letters = letters
        }

        func record() { all.append(pane.orderedIDs.map { letters[$0.rawValue] ?? "N" }.joined()) }

        func recordMove() {
            moves += 1
            record()
        }
    }

    @Test(arguments: Made.allCases, Closed.allCases)
    func aTabClosedBeforeTheNewTabsAnswerStaysOutOfTheStrip(made: Made, closed: Closed) async throws {
        // An inert address for the New Tab page: the page loads nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        try await LargeSessionWindowFixture.withController(.large, agentPaneEnvironment: environment) { store, controller in
            let services = controller.services
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let held = HeldCreations()
            switch made {
            case .newTab:
                let tabs = services.agentTabs
                try #require(tabs.canHostChat, "setup: this build has no New Tab page")
                tabs.localHost = AgentSessionRef.host(installID: "a-close-in-the-turn-of-a-new-tab")
                tabs.holdsTabs = { _ in true }
                tabs.reachable = { _ in true }
                tabs.create = { _, _, _, _, _, _ in
                    await held.wait()
                    throw CancellationError()
                }
            case .page:
                // The fixture's daemon with the capability that lets it hold page tabs.
                let capabilities = [DaemonCapability.conversationTabs, .pageTabs].map { "\"\($0.rawValue)\"" }.joined(separator: ",")
                let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["# + capabilities + "]}"
                let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
                store.noteHandshake(identity)
                services.pages.register(EmptyPage())
                services.pages.createStoreTab = { _, _, _, _, _, _ in
                    await held.wait()
                    throw CancellationError()
                }
            }
            var failure: (any Error)?
            do { try Self.makeCloseAndAnswer(made, closed, pane: pane, controller: controller) } catch { failure = error }
            // The creation ends before the window closes.
            held.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }

    /// The whole test in one turn of the main actor: the new tab, the close, the daemon's event, the checks.
    private static func makeCloseAndAnswer(_ made: Made, _ closed: Closed, pane: PaneController, controller: WindowController) throws {
        let store = pane.daemon.store
        let services = controller.services
        let start = pane.orderedIDs.map(\.rawValue)
        let records = pane.pane.tabs.map(\.id)
        try #require(start == records, "setup: the strip \(start) is not the store's list \(records)")
        try #require((3...26).contains(start.count), "setup: the pane has \(start.count) tabs, the test needs 3 to 26")
        let letters = Dictionary(uniqueKeysWithValues: zip(start, "abcdefghijklmnopqrstuvwxyz".map { String($0) }))
        let frames = Frames(pane: pane, letters: letters)

        // b, the middle one of the pane's first three tabs, is selected: the new tab goes directly after it.
        let anchor = start[1]
        pane.select(CmuxNextTabs.TabID(anchor))
        try #require(pane.stripModel.selectedID?.rawValue == anchor, "setup: the pane does not select its second tab")

        switch made {
        case .newTab:
            try #require(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)),
                         "setup: the New Tab key was refused")
        case .page:
            try #require(services.pages.openStoreTab(.settings, in: pane, window: controller, focus: true) != nil,
                         "setup: the page did not open as a tab of the store")
        }
        let added = pane.orderedIDs.map(\.rawValue).filter { !start.contains($0) }
        try #require(added.count == 1, "setup: the creation added \(added.count) tabs to the strip in its own call, want 1")
        let standIn = added[0]
        if made == .newTab {
            var withNew = start
            withNew.insert(standIn, at: 2)
            try #require(pane.orderedIDs.map(\.rawValue) == withNew, "setup: the new tab is not directly after the selected tab")
        }
        try #require(pane.stripModel.selectedID?.rawValue == standIn, "setup: the new tab is not selected")
        let created = store.intentLog.entries.last { entry in
            if case .createTab(_, let provisional) = entry.kind { return provisional.tabResourceID?.rawValue == standIn }
            return false
        }
        let entry = try #require(created, "setup: the store has no creation intent for the new tab")
        guard case .createTab(let paneHandle, let provisional) = entry.kind else { return }
        frames.record()

        let victim: String
        switch closed {
        case .right: victim = start[2]
        case .left: victim = start[0]
        case .anchor: victim = anchor
        }
        pane.close([CmuxNextTabs.TabID(victim)])
        frames.record()
        try #require(!pane.orderedIDs.contains { $0.rawValue == victim }, "setup: the closed tab is still in the strip")
        try #require(store.closingTabIDs.contains(victim), "setup: no close intent of the store hides the closed tab")
        try #require(pane.stripModel.selectedID?.rawValue == standIn, "setup: the new tab is not selected after the close")

        // The app's report of the created tab, as the app set it: the strip is recorded right after each call.
        switch made {
        case .newTab:
            let tabs = services.agentTabs
            let move = tabs.moveSelection
            tabs.moveSelection = { provisional, surface in
                move(provisional, surface)
                frames.recordMove()
            }
        case .page:
            let report = store.onPageTabCreated
            store.onPageTabCreated = { provisional, tab in
                report?(provisional, tab)
                frames.recordMove()
            }
        }

        // The daemon's event of the creation: its tab, last in the pane, with the creation's transaction.
        let screen = try #require(store.workspaces.flatMap(\.screens).first { screen in screen.panes.contains { $0 === pane.pane } },
                                  "setup: no screen of the store holds the pane")
        let workspace = try #require(store.workspaces.first { workspace in workspace.screens.contains { $0 === screen } },
                                     "setup: no workspace of the store holds the pane's screen")
        // A surface past each tab of the session.
        let surface = LargeSessionWindowFixture.surface(workspace: SessionFixtureSize.large.workspaces + 1, index: 0)
        try #require(store.tab(surface: surface) == nil, "setup: the session has a tab with the new tab's surface")
        var entity = TabSnapshot(surface: surface, kind: .conversation, title: "chat", browserRenderer: "frontend")
        entity.conversation = provisional.conversation
        let delta = TabDelta(workspace: workspace.handle, screen: screen.handle, pane: paneHandle, surface: surface, index: nil,
                             entity: entity, clientTransactionID: entry.transaction)
        let sequence = max(store.appliedSequence, store.snapshotBarrier) + 1
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: sequence, event: .tabAdded(delta))])
        frames.record()

        let seen = frames.all.joined(separator: ", ")
        try #require(store.tab(surface: surface) != nil, "setup: the store did not take the daemon's tab: \(seen)")
        try #require(frames.moves == 1,
                     "setup: the app's report of the created tab ran \(frames.moves) times, want 1: the test no longer reaches the step (\(seen))")
        let victimLetter = letters[victim] ?? "?"
        // The first record is the strip before the close.
        #expect(!frames.all.dropFirst().contains { $0.contains(victimLetter) },
                "the closed tab \(victimLetter) came back: \(seen)")
    }
}
