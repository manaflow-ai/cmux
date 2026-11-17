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
/// the Close Tab key after them comes in the new workspace's pane. The person made no move between those keys, so the
/// Close Tab key waits behind the kept New Tab key and goes with it (the last row).
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
/// - In the row of the new workspace, the creation of the first New Tab key waits at the app's own order of a
///   workspace's creations (`WorkspaceContentController.pendingCreate`) behind a task of the test, not at a slow
///   daemon. The other case of the same rule is not run: a split that the daemon makes with no stand-in pane (the
///   same-tree daemon makes each split with a stand-in).
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

    /// What the row of the new workspace reads in the turn where the hold of the new workspace ends: the new tabs that
    /// the store lists then. They are the tabs of the new workspace itself: no kept key ran again yet.
    @MainActor private final class AtTheEndOfTheWorkspacesHold {
        var newTabs: [String]?
    }

    /// The person's new workspace. Cmd-N (the workspace gets a terminal, so a hold of the window's keys opens and waits
    /// until the window shows the workspace), Cmd-T, Cmd-T, in one turn: the hold keeps the two New Tab keys, and the
    /// pane that has the focus at their press is the pane of the old workspace. Then the window shows the new
    /// workspace: the hold ends, the first New Tab key runs again in the new workspace's pane and opens a hold of its
    /// own, and that hold keeps the second New Tab key. Then Cmd-W while that hold is open (the row keeps the creation
    /// of the first New Tab key from the daemon until the Close Tab key was pressed): the focus is on the pane of the
    /// new workspace then.
    ///
    /// The person made no focus move between the three keys, so they are keys of one place: the hold keeps the Close
    /// Tab key behind the second New Tab key, and the two go together. At the end: 1 new tab of the New Tab keys, the
    /// tabs of the new workspace itself are open, no tab of the start is closed, and the hold's end counts 1 pair and
    /// no lost key.
    @Test func aCloseTabKeyAfterNewTabKeysKeptWhileThePersonsNewWorkspaceOpensGoesWithTheNewestNewTabKey() async throws {
        try await Rows.withTerminalPane { services, window, log in
            services.agentTabs.holdsTabs = { _ in false }
            let holds = services.keyRouter.creationInputCoordinator
            let controller = try #require(services.windows.active, "setup: the app has no window")
            let oldPane = try #require(controller.focus.state.pane, "setup: no pane has the focus")
            let oldWorkspace = try #require(controller.workspaceContent?.workspace.id, "setup: the window shows no workspace")
            let keys = Rows.Keys(services: services, window: window, log: log)
            try #require(Counts.counts(services) == [0, 0], "setup: the counts are \(Counts.counts(services)) before the keys (want 0 and 0)")
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
            var failure: (any Error)?, close: Rows.Keys.Outcome?
            do {
                // One turn of the main actor: the daemon's answer to the new workspace cannot come between the keys.
                let workspace = try keys.press("Cmd-N", "n", code: 45, repeats: false).outcome
                try #require(workspace == .ran && holds.isHolding(in: window),
                             "setup: the New Workspace key did not run, or it opened no hold of the window's keys; \(keys.said)")
                try #require(controller.focus.state.pane == oldPane,
                             "setup: the focus left the old workspace's pane in the turn of the New Workspace key: \(controller.focus.state.resolved); \(keys.said)")
                let first = try keys.newTab(), second = try keys.newTab()
                try #require(first == .kept && second == .kept, "setup: the hold of the new workspace did not keep the two New Tab keys; \(keys.said)")
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
                close = try keys.closeTab()
                letGo.finish()
                try await Rows.settle(keys, in: window, services: services)
            } catch { failure = error }
            let workspaceTabs = seen.newTabs ?? []
            let tabsNow = keys.tabs
            let made = keys.newTabs.filter { !workspaceTabs.contains($0) }, gone = keys.oldTabsGone
            let workspaceTabsGone = workspaceTabs.filter { !tabsNow.contains($0) }
            let counted = Counts.counts(services)
            print("KEYS-IN-ORDER a new workspace, Cmd-N Cmd-T Cmd-T, then Cmd-W when the window shows the workspace: \(keys.count) keys, \(keys.keptNewTabKeys) New Tab keys kept by a hold, \(log.replays) kept keys that ran again, \(made.count) new tabs of the New Tab keys at the end, closed old tabs \(gone), counts \(counted)")
            #expect(close == .kept, "in its own call the Close Tab key was not kept by a hold (\(close.map { "\($0)" } ?? "no call")): it did not wait behind the kept New Tab key of its place; \(keys.said)")
            #expect(made.count == 1, "at the end \(made.count) new tabs of the New Tab keys (want 1: two New Tab keys and one Close Tab key): \(made); \(keys.said)")
            #expect(gone.isEmpty && keys.oldTabsClosedAfterANewTabKey.isEmpty && workspaceTabsGone.isEmpty,
                    "the keys closed a tab that they did not make: tabs of the start \(gone), tabs of the new workspace itself \(workspaceTabsGone); \(keys.said)")
            #expect(counted == [1, 0], "the debug read counts \(counted) (want 1 cancelled pair, then 0 lost Close Tab keys); \(keys.said)")
            if let failure { throw failure }
        }
    }
}
