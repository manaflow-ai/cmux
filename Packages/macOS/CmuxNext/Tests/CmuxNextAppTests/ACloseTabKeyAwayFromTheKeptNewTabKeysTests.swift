import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import Foundation
import Testing

/// A Close Tab key that the person presses in another place than the New Tab keys that a hold of the window's keys
/// keeps: in another pane of the window, or in a panel of the window.
///
/// Decision of 2026-11-16: an act never runs before the act of a key that the person pressed before it. A hold's end
/// lets a kept Close Tab key and the kept New Tab key before it go together, because the Close Tab key closes the tab
/// of that New Tab key (`ACloseTabKeyAfterKeptNewTabKeysTests`). That is true only when the two keys are for one pane.
/// A Close Tab key in another pane is for the tab that the other pane shows, and a Close Tab key in a panel is the
/// panel's key. So such a key is not kept behind the New Tab keys and makes no pair with one of them: the hold ends,
/// each kept New Tab key makes its tab, and the Close Tab key acts where the person pressed it.
///
/// Decision of 2026-11-17: a pane that changes with no focus move of the person is not another place. The window shows
/// the person's new workspace while a hold keeps New Tab keys: the pane of the keys' press is the old workspace's, and
/// the Close Tab key after them comes in the new workspace's pane. The person made no move between those keys, so they
/// are keys of one place, and the decision of 2026-11-16 is for them: Cmd-N, Cmd-T, Cmd-T, Cmd-W leaves 1 new tab of
/// the New Tab keys and closes no other tab. The two last rows expect that result and not a form (`checkOneNewTab`).
/// The two rows are the two times where the Close Tab key can come: before the hold of the new workspace ends, and
/// after it. The keys that a hold keeps for a new workspace's terminal are keys of that terminal's pane
/// (`CreationInputBuffer.bindNewWorkspaceKeys`), and while the window shows that workspace the Close Tab key waits
/// behind them (`CreationInputBuffer.closeKeyActsNow`): the hold's end lets it go together with the newest kept New Tab
/// key before it.
///
/// The app on a fresh same-tree daemon, with the keys and the helpers of `ACloseTabKeyAfterKeptNewTabKeysTests`. A New
/// Tab key makes a terminal here (the pane's daemon holds no agent tabs).
///
/// Limits:
/// - The limits of `ACloseTabKeyAfterKeptNewTabKeysTests`: no HID event, the keys of a test in one turn of the main
///   actor, the store's tab lists, not the pixels.
/// - The focus goes to the other pane by the app's pane-focus call (`PaneHandlers.focus`), in the turn of the keys. No
///   row has a mouse event: a click on a pane is not run here.
/// - The panel is a child window that the test makes (an `NSPanel` with no view). The test gives the key router the
///   key for that window, and reads if the router takes it. What AppKit then does with the key in a panel is not run.
/// - The two rows of the new workspace have their limits in their own comments. The other case of the same rule is
///   not run: a split that the daemon makes with no stand-in pane (the same-tree daemon makes each split with a
///   stand-in).
/// - A failure of a line that starts with `setup:` is no result.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ACloseTabKeyAwayFromTheKeptNewTabKeysTests {
    private typealias Rows = ACloseTabKeyAfterKeptNewTabKeysTests
    private typealias Counts = AHoldsEndCountsItsTabKeyPairsAndLostCloseKeysTests

    /// One more terminal pane, split from the focused one by the set-up of `withTerminalPane`: the daemon confirmed it,
    /// it has the focus and the keyboard, and no hold of the window's keys is open.
    private static func oneMoreTerminalPane(_ services: AppServices, _ content: WorkspaceContentController, _ window: NSWindow) async throws -> PaneController {
        let holds = services.keyRouter.creationInputCoordinator
        var terminal = ActionInvocation(origin: .user)
        terminal.opensTerminal = true
        let before = Set(content.panes.keys)
        try #require(services.registry.perform("splitRight", invocation: terminal), "setup: the second split was refused")
        @MainActor func made() -> PaneController? {
            content.panes.values.first { pane in
                !before.contains(pane.layoutPaneID) && pane.pane.handle.rawValue < ProvisionalPane.firstHandle
                    && pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
            }
        }
        try await PasswordManagerRouteTests.until({ made() != nil && !holds.isHolding(in: window) },
                                                  report: { "setup: no confirmed second terminal pane after the second split, or its hold did not end" })
        let pane = try #require(made(), "setup: no second terminal pane")
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        try await PasswordManagerRouteTests.until({
            content.focus.state.pane == pane.paneKey && (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
        }, report: { "setup: the second terminal pane has no focus or no keyboard: \(content.focus.state.resolved)" })
        return pane
    }

    /// Two terminal panes. In the first: Cmd-T (it makes a terminal and opens the hold), Cmd-T (the hold keeps it).
    /// Then the focus goes to the second pane (the app's pane-focus call, no mouse event), and Cmd-W there. All in one
    /// turn, before the daemon's answer to the first New Tab key. At the end: the first pane has the tabs of the two
    /// New Tab keys, the tab of the second pane is closed, and the hold's end counts no pair and no lost key. In its
    /// own call the Close Tab key ran its action: the hold did not keep it behind a New Tab key of another pane.
    @Test func aCloseTabKeyInAnotherPaneThanAKeptNewTabKeyClosesTheTabOfItsOwnPaneWithNoMouseEvent() async throws {
        try await Rows.withTerminalPane { services, window, log in
            let content = try #require(services.windows.active?.workspaceContent, "setup: the window shows no workspace")
            let closePane = try #require(content.panes.values.first { $0.paneKey == content.focus.state.pane }, "setup: the focused pane has no controller")
            let newTabPane = try await Self.oneMoreTerminalPane(services, content, window)
            services.agentTabs.holdsTabs = { _ in false }
            let holds = services.keyRouter.creationInputCoordinator
            let closing = closePane.orderedIDs.map(\.rawValue)
            try #require(closing.count == 1 && newTabPane.orderedIDs.count == 1,
                         "setup: the two terminal panes have \(newTabPane.orderedIDs.count) and \(closing.count) tabs (want 1 and 1)")
            let keys = Rows.Keys(services: services, window: window, log: log)
            try #require(Counts.counts(services) == [0, 0], "setup: the counts are \(Counts.counts(services)) before the keys (want 0 and 0)")
            var failure: (any Error)?, close: Rows.Keys.Outcome?
            do {
                // One turn of the main actor: the daemon's answer to the first creation cannot come between the keys.
                let first = try keys.newTab()
                try #require(first == .ran && holds.isHolding(in: window), "setup: the first New Tab key did not run, or it opened no hold; \(keys.said)")
                let second = try keys.newTab()
                try #require(second == .kept, "setup: the hold did not keep the second New Tab key; \(keys.said)")
                PaneHandlers.focus(closePane.layoutPaneID, in: content)
                log.add("the focus goes to the second pane (the app's pane-focus call, no mouse event)")
                try #require(content.focus.state.pane == closePane.paneKey,
                             "setup: the focus did not go to the second pane in the turn of the keys: \(content.focus.state.resolved); \(keys.said)")
                close = try keys.press("Cmd-W", "w", code: 13, repeats: false).outcome
                try await Rows.settle(keys, in: window, services: services)
            } catch { failure = error }
            let new = keys.newTabs, gone = keys.oldTabsGone
            let inNewTabPane = services.daemon.store.pane(newTabPane.pane.handle)?.tabs.map(\.id) ?? []
            let newThere = new.filter { inNewTabPane.contains($0) }
            let counted = Counts.counts(services)
            print("KEYS-IN-ORDER 2 panes, Cmd-T Cmd-T in the first, Cmd-W in the second: \(keys.count) keys, \(keys.keptNewTabKeys) New Tab keys kept by a hold, \(new.count) new tabs at the end (\(newThere.count) in the first pane), closed old tabs \(gone), counts \(counted)")
            #expect(close == .ran, "in its own call the Close Tab key of the second pane did not run its action (\(close.map { "\($0)" } ?? "no call")): a hold kept it behind a New Tab key of another pane; \(keys.said)")
            #expect(gone == closing, "at the end the closed old tabs are \(gone) (want the tab of the second pane only: \(closing)); \(keys.said)")
            #expect(new.count == 2 && newThere.count == 2,
                    "at the end \(new.count) new tabs, \(newThere.count) of them in the first pane (want 2 and 2: the tabs of the two New Tab keys): new \(new), the first pane's tabs \(inNewTabPane); \(keys.said)")
            #expect(counted == [0, 0], "the debug read counts \(counted) (want 0 cancelled pairs, then 0 lost Close Tab keys: the keys of two panes make no pair); \(keys.said)")
            if let failure { throw failure }
        }
    }

    /// A panel of the window. The test opens a hold with a creation that never answers, and the hold keeps two New Tab
    /// keys. Then Cmd-W for a panel that is a child window of the test's window, in the same turn. The key router does
    /// not take that Cmd-W (it is the panel's key), and no hold keeps it. At the end: the tabs of the two New Tab keys,
    /// no closed tab, no pair and no lost key.
    @Test func aCloseTabKeyInAPanelOfTheWindowIsNotKeptBehindKeptNewTabKeys() async throws {
        try await Rows.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let holds = services.keyRouter.creationInputCoordinator
            let controller = try #require(services.windows.active, "setup: the app has no window")
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            window.addChildWindow(panel, ordered: .above)
            defer {
                window.removeChildWindow(panel)
                panel.close()
            }
            let place = services.keyRouter.focus(for: panel)
            try #require(place.0 === controller && place.1 == .textPanel, "setup: the key router does not read the test's panel as a panel of the window")
            let ticket = try #require(holds.begin(in: window, generation: controller.focus.beginIntent(), tab: "pending_tab_that_never_answers"),
                                      "setup: no hold opened for the creation that never answers")
            let keys = Rows.Keys(services: services, window: window, log: log)
            try #require(Counts.counts(services) == [0, 0], "setup: the counts are \(Counts.counts(services)) before the keys (want 0 and 0)")
            var failure: (any Error)?, close: (outcome: Rows.Keys.Outcome, gone: [String])?
            do {
                // One turn of the main actor, inside the hold.
                let first = try keys.newTab(), second = try keys.newTab()
                try #require(first == .kept && second == .kept, "setup: the hold did not keep the two New Tab keys; \(keys.said)")
                close = try keys.press("Cmd-W", "w", code: 13, repeats: false, in: panel)
                try await Rows.settle(keys, in: window, services: services)
            } catch { failure = error }
            let new = keys.newTabs, gone = keys.oldTabsGone
            let counted = Counts.counts(services)
            print("KEYS-IN-ORDER a panel, 2 kept Cmd-T, Cmd-W in the panel: \(keys.count) keys, \(keys.keptNewTabKeys) New Tab keys kept by a hold, \(new.count) new tabs at the end, closed old tabs \(gone), counts \(counted)")
            #expect(close?.outcome == .passedOn, "the key router took the Close Tab key of the panel (\(close.map { "\($0.outcome)" } ?? "no call"); want: not taken, it is the panel's key); \(keys.said)")
            #expect(gone.isEmpty && close?.gone.isEmpty != false, "the keys closed \(gone), tabs that were there before the first key; \(keys.said)")
            #expect(new.count == 2, "at the end \(new.count) new tabs (want 2, the tabs of the two New Tab keys): \(new); \(keys.said)")
            #expect(counted == [0, 0], "the debug read counts \(counted) (want 0 cancelled pairs, then 0 lost Close Tab keys: the panel's key makes no pair); \(keys.said)")
            holds.resolve(ticket, landed: false, in: window)
            if let failure { throw failure }
        }
    }

    /// What the row of the second case reads in the turn where the hold of the new workspace ends: the new tabs that
    /// the store lists then. They are the tabs of the new workspace itself: no kept key ran again yet.
    @MainActor private final class AtTheEndOfTheWorkspacesHold {
        var newTabs: [String]?
    }

    /// The runs of the New Tab action and of the Close Tab action in their order, from `start()` on. The app's action
    /// registry tells each run of an action before it runs (`willRunObservers`), also a run that does not come through
    /// the key path: a kept key of a terminal that is not the focused one runs its action with that terminal's tab as
    /// the target.
    @MainActor private final class TabActs {
        private(set) var ids: [String] = []
        private var on = false

        func start() { on = true }
        func note(_ id: String) { if on, id == "newTab.default" || id == "closeTab" { ids.append(id) } }
        /// How many New Tab actions ran before the first Close Tab action.
        var newTabsBeforeTheClose: Int { ids.prefix { $0 != "closeTab" }.count }
    }

    /// The work that the New Workspace key started (the create of the workspace): if each task of it ended, and the
    /// failures that the tasks gave. The create tells the hold of its workspace before its task ends.
    @MainActor private final class TheNewWorkspacesWork {
        var ended = false
        var failures: [String] = []
    }

    /// The result that the two rows of the person's new workspace expect (decision of 2026-11-16: an act never runs
    /// before the act of a key that the person pressed before it), with the row's counts in one line:
    /// - 1 new tab of the New Tab keys at the end (two New Tab keys and one Close Tab key);
    /// - no tab of the start and no tab of the new workspace itself is closed;
    /// - the Close Tab key did not act before a New Tab key that the person pressed before it. One of three facts says
    ///   so: a hold kept the Close Tab key in its own call (it then goes with the kept keys, in their order); or 2 kept
    ///   keys ran again on the key path before the call of the Close Tab key returned; or the registry saw 2 runs of
    ///   the New Tab action before the first run of the Close Tab action.
    ///
    /// `close`: what the key router did with the Close Tab key in its own call. `replaysAtTheClose`: how many kept keys
    /// ran again on the key path when that call returned. `workspaceTabs`: the new tabs before a New Tab key acted
    /// (the tabs of the new workspace itself).
    private static func checkOneNewTab(_ label: String, keys: Rows.Keys, log: Rows.KeyLog, acts: TabActs, close: Rows.Keys.Outcome,
                                       replaysAtTheClose: Int, workspaceTabs: [String], services: AppServices) {
        let tabsNow = keys.tabs
        let made = keys.newTabs.filter { !workspaceTabs.contains($0) }, gone = keys.oldTabsGone
        let workspaceTabsGone = workspaceTabs.filter { !tabsNow.contains($0) }
        print("KEYS-IN-ORDER a new workspace, \(label): \(keys.count) keys, \(keys.keptNewTabKeys) New Tab keys kept by a hold, the Close Tab key in its own call: \(close), \(replaysAtTheClose) kept keys that ran again at its return and \(log.replays) at the end, the tab actions in their order \(acts.ids), \(made.count) new tabs of the New Tab keys at the end, closed old tabs \(gone), closed tabs of the new workspace itself \(workspaceTabsGone), counts \(Counts.counts(services))")
        #expect(made.count == 1, "at the end \(made.count) new tabs of the New Tab keys (want 1: two New Tab keys and one Close Tab key): \(made); the tab actions in their order \(acts.ids); \(keys.said)")
        #expect(gone.isEmpty && keys.oldTabsClosedAfterANewTabKey.isEmpty && workspaceTabsGone.isEmpty,
                "the keys closed a tab that they did not make: tabs of the start \(gone), tabs of the new workspace itself \(workspaceTabsGone); \(keys.said)")
        #expect(close == .kept || replaysAtTheClose == 2 || acts.newTabsBeforeTheClose == 2,
                "the Close Tab key acted before the act of a New Tab key that the person pressed before it: in its own call the key router's answer was \(close), \(replaysAtTheClose) kept keys ran again before its return, and \(acts.newTabsBeforeTheClose) New Tab actions ran before the first Close Tab action (want: kept, or 2, or 2); the tab actions in their order \(acts.ids); \(keys.said)")
    }

    /// The person's new workspace, the second case: the Close Tab key after the hold of the new workspace ended.
    /// Cmd-N (the workspace gets a terminal, so a hold of the window's keys opens and waits until the window shows the
    /// workspace), Cmd-T, Cmd-T, in one turn: the hold keeps the two New Tab keys, and the pane that has the focus at
    /// their press is the pane of the old workspace. Then the window shows the new workspace: the hold ends, the first
    /// New Tab key runs again in the new workspace's pane and opens a hold of its own, and that hold keeps the second
    /// New Tab key. Then Cmd-W while that hold is open (the row keeps the creation of the first New Tab key from the
    /// daemon until the Close Tab key was pressed): the focus is on the pane of the new workspace then.
    ///
    /// The person made no focus move between the keys, so they are keys of one place. The row expects the result and
    /// not a form (`checkOneNewTab`). The form when this row was made: the hold does not keep the Close Tab key; the
    /// key ends the hold, the second New Tab key runs again first and makes its tab, and then the Close Tab key closes
    /// one new tab. The form after the mend of the first case (2026-11-17): the second New Tab key has the pane of
    /// the new workspace's terminal, so the hold of the first New Tab key keeps the Close Tab key behind it, and its
    /// end lets the two go together.
    ///
    /// Limits of this row:
    /// - It is the second case only. The first case (the Close Tab key before the hold of the new workspace ends) is
    ///   the next row.
    /// - The creation of the first New Tab key waits before its send, at the app's own order of a workspace's
    ///   creations (`WorkspaceContentController.pendingCreate`) behind a task of the test. A creation that waits after
    ///   its send, at a slow daemon, is not run.
    /// - New Tab keys that make pages in the new workspace are not run: here each makes a terminal.
    /// - The row does not tell which of the two new tabs the Close Tab key closed.
    @Test func aCloseTabKeyAfterTheEndOfThePersonsNewWorkspacesHoldLeavesOneNewTab() async throws {
        try await Rows.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let holds = services.keyRouter.creationInputCoordinator
            let controller = try #require(services.windows.active, "setup: the app has no window")
            let oldPane = try #require(controller.focus.state.pane, "setup: no pane has the focus")
            let oldWorkspace = try #require(controller.workspaceContent?.workspace.id, "setup: the window shows no workspace")
            let keys = Rows.Keys(services: services, window: window, log: log)
            try #require(Counts.counts(services) == [0, 0], "setup: the counts are \(Counts.counts(services)) before the keys (want 0 and 0)")
            let acts = TabActs()
            services.registry.willRunObservers.append { id, _ in acts.note(id.rawValue) }
            // The creation of the first New Tab key waits behind this task, from the turn where the key runs again
            // until the row lets it go.
            let (gate, letGo) = AsyncStream<Void>.makeStream()
            defer { letGo.finish() }
            let seen = AtTheEndOfTheWorkspacesHold()
            log.beforeFirstReplay = {
                seen.newTabs = keys.newTabs
                services.windows.active?.workspaceContent?.pendingCreate = Task { () -> ActionWorkFailure? in
                    for await _ in gate {}
                    return nil
                }
            }
            var failure: (any Error)?, close: (outcome: Rows.Keys.Outcome, replays: Int)?
            do {
                // One turn of the main actor: the daemon's answer to the new workspace cannot come between the keys.
                let workspace = try keys.press("Cmd-N", "n", code: 45, repeats: false).outcome
                try #require(workspace == .ran && holds.isHolding(in: window),
                             "setup: the New Workspace key did not run, or it opened no hold of the window's keys; \(keys.said)")
                try #require(controller.focus.state.pane == oldPane,
                             "setup: the focus left the old workspace's pane in the turn of the New Workspace key: \(controller.focus.state.resolved); \(keys.said)")
                let first = try keys.newTab(), second = try keys.newTab()
                try #require(first == .kept && second == .kept, "setup: the hold of the new workspace did not keep the two New Tab keys; \(keys.said)")
                acts.start()
                // The window shows the new workspace, its hold ends, and the first New Tab key runs again.
                try await PasswordManagerRouteTests.until({ log.replays >= 1 },
                                                          report: { "setup: no kept New Tab key ran again on the key path after the New Workspace key; \(keys.said)" })
                let workspaceTabs = try #require(seen.newTabs, "setup: the row did not read the tabs of the new workspace")
                let shown = controller.workspaceContent?.workspace.id
                try #require(shown != nil && shown != oldWorkspace, "setup: the window does not show the new workspace; \(keys.said)")
                let newPane = controller.focus.state.pane
                try #require(newPane != nil && newPane != oldPane,
                             "setup: the focus is not on a pane of the new workspace: \(controller.focus.state.resolved); \(keys.said)")
                let pendingTabs = keys.newTabs.filter { !workspaceTabs.contains($0) }
                try #require(log.replays == 1 && holds.isHolding(in: window) && pendingTabs.count == 1,
                             "setup: before the Close Tab key \(log.replays) kept keys ran again (want 1), a hold of the window's keys is \(holds.isHolding(in: window) ? "open" : "not open") (want open: the hold of the first New Tab key, which keeps the second), and the New Tab keys made \(pendingTabs.count) tabs (want 1); \(keys.said)")
                let outcome = try keys.closeTab()
                close = (outcome, log.replays)
                letGo.finish()
                try await Rows.settle(keys, in: window, services: services)
            } catch { failure = error }
            if let close {
                Self.checkOneNewTab("Cmd-N Cmd-T Cmd-T, then Cmd-W after the end of the workspace's hold", keys: keys, log: log, acts: acts, close: close.outcome,
                                    replaysAtTheClose: close.replays, workspaceTabs: seen.newTabs ?? [], services: services)
            }
            if let failure { throw failure }
        }
    }

    /// The person's new workspace, the first case: the Close Tab key before the hold of the new workspace ends.
    /// Cmd-N, Cmd-T, Cmd-T, in one turn: the hold of the new workspace keeps the two New Tab keys. Then the window
    /// shows the new workspace and the create of the workspace has its answer, and the hold is still open. In the app
    /// the hold is open then until the new terminal has the keyboard. The row keeps it open with one more creation,
    /// which is the test's and never answers (`CreationInputCoordinator.begin`, in the turn of the keys and under the
    /// intent of the New Workspace key). Then Cmd-W: the focus is on the pane of the new workspace, and the hold still
    /// keeps the two New Tab keys.
    ///
    /// The row expects the same result as the row before it (`checkOneNewTab`): 1 new tab of the New Tab keys, no
    /// other tab closed, and no act of the Close Tab key before the act of a New Tab key that the person pressed
    /// before it. It also counts the New Tab keys: each of the two ran its action or went in a pair with the Close
    /// Tab key. Before the mend of 2026-11-17 the second one did neither: the Close Tab key ended the hold, the
    /// first New Tab key ran again and opened a hold of its own, the second went into that hold as a key of the first
    /// one's creation, and the Close Tab key cancelled that creation, which took the second key with it.
    ///
    /// Limits of this row:
    /// - The hold has one more creation than the app's hold: the test's, which never answers. The keys were kept
    ///   before it, for the new workspace. It has the app's bound for an answer (10 seconds): the row's set-up fails
    ///   when the Close Tab key does not come in that time.
    /// - The test takes the work of the New Workspace key (`ActionRegistry.capturingWork`) to know when the create
    ///   has its answer. A failure of that work then comes to the test and is not shown as a notice.
    /// - The row does not read if the new terminal has the keyboard at the Close Tab key.
    /// - New Tab keys that make pages in the new workspace are not run, and the row does not tell which new tab the
    ///   Close Tab key closed.
    @Test func aCloseTabKeyBeforeTheEndOfThePersonsNewWorkspacesHoldLeavesOneNewTab() async throws {
        try await Rows.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let holds = services.keyRouter.creationInputCoordinator
            let controller = try #require(services.windows.active, "setup: the app has no window")
            let oldPane = try #require(controller.focus.state.pane, "setup: no pane has the focus")
            let oldWorkspace = try #require(controller.workspaceContent?.workspace.id, "setup: the window shows no workspace")
            let keys = Rows.Keys(services: services, window: window, log: log)
            try #require(Counts.counts(services) == [0, 0], "setup: the counts are \(Counts.counts(services)) before the keys (want 0 and 0)")
            let acts = TabActs()
            services.registry.willRunObservers.append { id, _ in acts.note(id.rawValue) }
            let work = TheNewWorkspacesWork()
            // The workspace that the window shows, when it is not the old one and the store lists a terminal of it.
            @MainActor func shownNewWorkspace() -> String? {
                guard let content = controller.workspaceContent?.workspace.id, content != oldWorkspace,
                      let shown = controller.focus.currentState().topology.workspace,
                      services.daemon.store.firstTerminalTab(ofWorkspace: shown) != nil else { return nil }
                return shown
            }
            var failure: (any Error)?, close: (outcome: Rows.Keys.Outcome, replays: Int)?, workspaceTabs: [String] = []
            var ticket: CreationInputBuffer.Ticket?
            do {
                // One turn of the main actor: the daemon's answer to the new workspace cannot come between the keys.
                var workspace: Rows.Keys.Outcome?, pressFailure: (any Error)?
                let tasks = services.registry.capturingWork {
                    do { workspace = try keys.press("Cmd-N", "n", code: 45, repeats: false).outcome } catch { pressFailure = error }
                }
                if let pressFailure { throw pressFailure }
                try #require(workspace == .ran && holds.isHolding(in: window),
                             "setup: the New Workspace key did not run, or it opened no hold of the window's keys; \(keys.said)")
                try #require(!tasks.isEmpty, "setup: the New Workspace key started no work that the registry tells; \(keys.said)")
                try #require(controller.focus.state.pane == oldPane,
                             "setup: the focus left the old workspace's pane in the turn of the New Workspace key: \(controller.focus.state.resolved); \(keys.said)")
                let first = try keys.newTab(), second = try keys.newTab()
                try #require(first == .kept && second == .kept, "setup: the hold of the new workspace did not keep the two New Tab keys; \(keys.said)")
                acts.start()
                // The hold stays open after the answer of the workspace's create: one more creation, which never answers.
                ticket = try #require(holds.begin(in: window, generation: controller.focus.state.generation, tab: "pending_tab_that_never_answers"),
                                      "setup: the hold took no creation that never answers; \(keys.said)")
                Task { @MainActor in
                    for task in tasks { if let failed = await task.value { work.failures.append("\(failed)") } }
                    work.ended = true
                }
                try await PasswordManagerRouteTests.until({
                    work.ended && shownNewWorkspace() != nil && controller.focus.state.pane.map { $0 != oldPane } == true
                }, report: { "setup: the work of the New Workspace key \(work.ended ? "ended" : "did not end"), the window \(shownNewWorkspace() == nil ? "does not show the new workspace with a terminal" : "shows the new workspace with a terminal"), and the focus is \(controller.focus.state.resolved); \(keys.said)" })
                try #require(work.failures.isEmpty, "setup: the work of the New Workspace key failed: \(work.failures); \(keys.said)")
                try #require(holds.isHolding(in: window) && log.replays == 0 && acts.ids.isEmpty,
                             "setup: before the Close Tab key a hold of the window's keys is \(holds.isHolding(in: window) ? "open" : "not open") (want open: the hold of the new workspace), \(log.replays) kept keys ran again (want 0), and the tab actions that ran are \(acts.ids) (want none); \(keys.said)")
                workspaceTabs = keys.newTabs
                let outcome = try keys.closeTab()
                close = (outcome, log.replays)
                // A Close Tab key that the hold kept acts at the hold's end: the test's creation ends, with no tab, so
                // that the hold can end before the check. A Close Tab key that ran left no hold for the test to end.
                if outcome == .kept {
                    holds.resolve(ticket, landed: false, in: window)
                    ticket = nil
                }
                try await Rows.settle(keys, in: window, services: services)
            } catch { failure = error }
            if let close {
                Self.checkOneNewTab("Cmd-N Cmd-T Cmd-T, then Cmd-W before the end of the workspace's hold", keys: keys, log: log, acts: acts, close: close.outcome,
                                    replaysAtTheClose: close.replays, workspaceTabs: workspaceTabs, services: services)
                let newTabActs = acts.ids.filter { $0 == "newTab.default" }.count
                let pairs = Counts.counts(services)[0].map { Int($0) }
                #expect(pairs.map { newTabActs + $0 } == 2,
                        "a New Tab key is lost: \(newTabActs) New Tab actions ran and the holds' ends counted \(pairs.map { "\($0)" } ?? "no") pairs (want 2 together: each of the two New Tab keys ran its action or went in a pair with the Close Tab key); the tab actions in their order \(acts.ids); \(keys.said)")
            }
            holds.resolve(ticket, landed: false, in: window)
            if let failure { throw failure }
        }
    }
}
