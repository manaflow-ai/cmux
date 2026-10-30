import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextTerminal
import Foundation
import Testing

/// The launch window opens before the `InputVerification.start` launch post (it runs after the first frame), so it
/// installs its focus observers before input verification knows the app's services. Its focus settles must still reach
/// the services that act on them (the key router's holds, notifications, the location trail, the record saver, the
/// new-work context) for the whole session, not only in windows opened after that post.
@MainActor @Suite(.serialized)
struct LaunchWindowFocusSettleTests {
    /// One workspace with one pane and one terminal tab.
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "settle-ws"), name: "settle", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "settle-ws"), index: 0)])
        return tree
    }

    /// The window record saver keeps the focused pane at a focus settle (`WindowRecordSaver.focusDidSettle`), before any
    /// other check, and nothing else writes it for a window opened without a record: it shows whether the launch window's
    /// settle reached the app's services.
    @Test func aWindowOpenedBeforeInputVerificationStartsSendsItsSettlesToTheServices() async throws {
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
        // The launch window first, then the app's InputVerification.start post, in the app's order.
        let controller = try #require(services.windows.openWindow(workspaces: ["settle-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        services.input.start(services: services)
        let paneKey = try #require(store.workspaces.first?.screens.first?.panes.first?.id)
        try await PasswordManagerRouteTests.until({ controller.workspaceContent?.paneController(key: paneKey)?.currentContent != nil },
                                                  within: .seconds(10), report: { "the pane never showed its terminal" })
        let pane = try #require(controller.workspaceContent?.paneController(key: paneKey))
        let tab = try #require(pane.currentTabKey, "the pane shows no tab")
        controller.focus.send(.focusPane(paneKey, source: .programmatic))
        try await PasswordManagerRouteTests.until({ controller.focus.state.resolved == .terminal(pane: paneKey, tab: tab) },
                                                  within: .seconds(5), report: { "focus never named the terminal" })

        // The settle the app sends after the window's focus queue drained.
        let settle = try #require(controller.focus.settledObserver, "the window has no focus settle observer")
        settle(controller.focus.state)
        try await PasswordManagerRouteTests.until({ controller.state.savedFocusedPane == paneKey }, within: .seconds(2),
                                                  report: { "the launch window's settle reached no service: saved focused pane \(String(describing: controller.state.savedFocusedPane))" })
    }
}
