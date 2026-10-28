import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Keys typed into a terminal the person just opened go to it as soon as it has the keyboard, not at the creation's
/// reply or at the next key (first-seconds-evidence.md, Lawrence's optimized v2.2.3: 30 of 226 terminal keys waited
/// 250-1600 ms in `CreationInputCoordinator` and were sent again late). The new terminal's view sends them to the
/// daemon by the terminal id its create chose (cx-wb5.78), so nothing waits for the daemon. Chrome routes input to the
/// focused frame at once and never replays it late.
@MainActor @Suite(.serialized)
struct EarlyTerminalKeysTests {
    /// One workspace with one pane and one terminal tab.
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "early-ws"), name: "early", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "early-ws"), index: 0)])
        return tree
    }

    private static func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let paneKey: String
        let tab: String
        let entry: TerminalEntry
    }

    /// A window showing one terminal that has the focus; `body` runs with it.
    private static func withTerminal(_ body: (Harness) async throws -> Void) async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["early-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let window = try #require(controller.window)
        let paneKey = try #require(store.workspaces.first?.screens.first?.panes.first?.id)
        try await PasswordManagerRouteTests.until({ controller.workspaceContent?.paneController(key: paneKey)?.currentContent != nil },
                                                  within: .seconds(10), report: { "the pane never showed its terminal" })
        let pane = try #require(controller.workspaceContent?.paneController(key: paneKey))
        guard case .terminal(let entry)? = pane.currentContent, let tab = pane.currentTabKey else {
            Issue.record("the pane shows no terminal")
            return
        }
        controller.focus.send(.focusPane(paneKey, source: .programmatic))
        try await PasswordManagerRouteTests.until({ controller.focus.state.resolved == .terminal(pane: paneKey, tab: tab) },
                                                  within: .seconds(5), report: { "focus never named the terminal" })

        try await body(Harness(services: services, controller: controller, window: window, paneKey: paneKey, tab: tab, entry: entry))
    }

    /// The early view of a pending creation (here the pane's terminal stands in for it) gets the keyboard after a key
    /// was held: the held key goes to it in that settle, with no later key and no reply. Before, it waited for the
    /// next key or for the reply, and was sent again then with its old OS time.
    @Test func heldKeysGoToTheEarlyTerminalWhenItGetsTheKeyboard() async throws {
        try await Self.withTerminal { h in
            let (controller, window, paneKey, tab, entry) = (h.controller, h.window, h.paneKey, h.tab, h.entry)
            let router = h.services.keyRouter
            // The creation is pending and its view does not have the keyboard yet (it is being mounted).
            window.makeFirstResponder(nil)
            let coordinator = router.creationInputCoordinator
            _ = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation, earlyTab: tab, tab: tab),
                             "the creation opened no key hold")
            let typed = try Self.key("a", keyCode: 0, in: window)
            let held = router.interceptKeyDown(typed, in: window)
            #expect(held, "the key was not held while the new terminal did not have the keyboard")
            #expect(coordinator.heldCount(in: window) == 1)

            // The view gets the keyboard (its content is presented): the held key goes to it now.
            window.makeFirstResponder(entry.session.surfaceView)
            controller.focus.send(.contentPresented(pane: paneKey))
            try await PasswordManagerRouteTests.until({ coordinator.heldCount(in: window) == 0 }, within: .milliseconds(500),
                                                      report: { "the held key still waits (\(coordinator.heldCount(in: window))) after the new terminal got the keyboard" })
            #expect(coordinator.isHolding(in: window), "the hold ended before its creation resolved")
        }
    }

    /// The early tab is focused, but another view (an agent's composer, Home's message box) has the keyboard: the held
    /// key stays held. Terminal input never goes anywhere but the new terminal (review of 107f5da1ac6: the early check
    /// let any non-terminal first responder take the held keys).
    @Test func heldKeysNeverGoToAnotherViewThatHasTheKeyboard() async throws {
        try await Self.withTerminal { h in
            let (controller, window, paneKey, tab) = (h.controller, h.window, h.paneKey, h.tab)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            window.contentView?.addSubview(composer)
            defer { composer.removeFromSuperview() }
            window.makeFirstResponder(nil)
            _ = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation, earlyTab: tab, tab: tab))
            let typed = try Self.key("a", keyCode: 0, in: window)
            let held = router.interceptKeyDown(typed, in: window)
            #expect(held, "the key was not held while the new terminal did not have the keyboard")
            window.makeFirstResponder(composer)
            controller.focus.send(.contentPresented(pane: paneKey))
            try await Task.sleep(for: .milliseconds(200))
            #expect(coordinator.heldCount(in: window) == 1, "the held key left the hold while another view had the keyboard")
            #expect(composer.string.isEmpty, "a key typed for the new terminal reached another text input")
        }
    }
}
