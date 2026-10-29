import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A window's focus settles reach the services that act on them (the key router's holds, the record saver,
/// notifications, the location trail) from the window's first settle, also before the `InputVerification.start` launch
/// post (it runs after the first frame). Only the invariant monitor, which that post makes, waits for it.
@MainActor @Suite(.serialized)
struct SettleBeforeInputVerificationTests {
    /// One workspace with one pane and one terminal tab.
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "early-settle-ws"), name: "settle", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "early-settle-ws"), index: 0)])
        return tree
    }

    /// The record saver keeps the focused pane at a settle (`WindowRecordSaver.focusDidSettle`), and nothing else writes
    /// it for a window opened without a record: it shows whether the settle reached the app's services.
    @Test func aSettleBeforeInputVerificationStartsReachesTheServices() async throws {
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
        // No InputVerification.start: the launch window's first settles come before that post.
        let controller = try #require(services.windows.openWindow(workspaces: ["early-settle-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        #expect(services.input.monitor == nil, "the test needs input verification not started")
        let paneKey = try #require(store.workspaces.first?.screens.first?.panes.first?.id)
        try await PasswordManagerRouteTests.until({ controller.workspaceContent?.paneController(key: paneKey)?.currentContent != nil },
                                                  within: .seconds(10), report: { "the pane never showed its terminal" })
        let pane = try #require(controller.workspaceContent?.paneController(key: paneKey))
        let tab = try #require(pane.currentTabKey, "the pane shows no tab")
        controller.focus.send(.focusPane(paneKey, source: .programmatic))
        try await PasswordManagerRouteTests.until({ controller.focus.state.resolved == .terminal(pane: paneKey, tab: tab) },
                                                  within: .seconds(5), report: { "focus never named the terminal" })

        let settle = try #require(controller.focus.settledObserver, "the window has no focus settle observer")
        settle(controller.focus.state)
        try await PasswordManagerRouteTests.until({ controller.state.savedFocusedPane == paneKey }, within: .seconds(2),
                                                  report: { "a settle before InputVerification.start reached no service: saved focused pane \(String(describing: controller.state.savedFocusedPane))" })
    }
}
