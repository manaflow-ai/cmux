import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextActions
import CmuxNextFocus
import CmuxNextTestSupport
import Foundation
import Testing

/// A menu item the person chooses with the mouse is their focus choice (R-INPUT, the source check on dogfood build
/// 7dd31211, STATUS 12884). AppKit runs a chosen item's action after its menu tracking, outside any input event's
/// dispatch, so the focus events of the run carried the CLI's or the app's source, and the count of the person's focus
/// choices (``FocusState/personMoveSeq``, #35275's reply bound) did not move: a line held for a stalled Cmd-N's terminal
/// was typed into it at the bound although the person had moved the focus from the menu.
@MainActor @Suite(.serialized, .closesItsWindows)
struct MenuPickPersonMoveTests {
    /// One workspace, two panes side by side, each with one terminal tab.
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "menu-ws"), name: "menu", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "menu-ws"), index: 0)])
        return tree
    }

    private static func withWindow(_ body: (AppServices, WindowController, [String]) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["menu-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.workspaceContent?.panes.count == 2, "the window never showed the workspace's two panes")
        let panes = try #require(store.workspaces.first?.screens.first?.panes).map(\.id)
        try #require(panes.count == 2)
        controller.focus.send(.focusPane(panes[0], source: .programmatic)) // the app's focus: no choice of the person's yet
        try await body(services, controller, panes)
    }

    /// Focus Next Pane chosen from a menu (the item's action sent as AppKit sends a chosen item's, outside an event's
    /// dispatch): the focus moves to the other pane, and the move counts as the person's.
    @Test func aFocusMoveChosenFromAMenuCountsAsThePersons() async throws {
        try await Self.withWindow { services, controller, panes in
            let before = controller.focus.state.personMoveSeq
            let item = try #require(services.registry.makeMenuItem(for: "focusNextPane"), "Focus Next Pane has no menu item")
            let action = try #require(item.action)
            let sent = NSApplication.shared.sendAction(action, to: item.target, from: item)
            #expect(sent, "the menu item's action was not sent")
            for _ in 0..<100 where controller.focus.state.pane != panes[1] { try await Task.sleep(for: .milliseconds(10)) }
            #expect(controller.focus.state.pane == panes[1], "the menu's Focus Next Pane did not move the focus")
            #expect(controller.focus.state.personMoveSeq != before, "a focus move the person chose from a menu did not count as theirs")
        }
    }

    /// A menu item run by its key equivalent is no menu pick: AppKit runs it inside the key's dispatch, which names the
    /// person, and a key's responder change is no focus choice (#35275). Its focus move, CLI-sourced here, does not count.
    @Test func aKeyEquivalentRunIsNoMenuPick() async throws {
        try await Self.withWindow { services, controller, panes in
            services.registry.isDispatchingKeyDown = { true } // the run comes from a key-down's dispatch
            let before = controller.focus.state.personMoveSeq
            let item = try #require(services.registry.makeMenuItem(for: "focusNextPane"), "Focus Next Pane has no menu item")
            let action = try #require(item.action)
            let sent = NSApplication.shared.sendAction(action, to: item.target, from: item)
            #expect(sent, "the menu item's action was not sent")
            for _ in 0..<100 where controller.focus.state.pane != panes[1] { try await Task.sleep(for: .milliseconds(10)) }
            #expect(controller.focus.state.pane == panes[1], "the key equivalent's Focus Next Pane did not move the focus")
            #expect(controller.focus.state.personMoveSeq == before, "a key equivalent's run counted as a menu pick")
        }
    }

    /// The same move run by the CLI is automation's: it never counts (the counter rule of #35275, unchanged).
    @Test func theSameMoveFromTheCLIDoesNotCount() async throws {
        try await Self.withWindow { services, controller, panes in
            let before = controller.focus.state.personMoveSeq
            var invocation = ActionInvocation(origin: .cli)
            invocation.focusRequested = true // `action.run focus: true`: the CLI may move the view
            _ = services.registry.perform("focusNextPane", invocation: invocation)
            for _ in 0..<100 where controller.focus.state.pane != panes[1] { try await Task.sleep(for: .milliseconds(10)) }
            #expect(controller.focus.state.pane == panes[1], "the CLI's Focus Next Pane did not move the focus")
            #expect(controller.focus.state.personMoveSeq == before, "a CLI move counted as the person's")
        }
    }
}
