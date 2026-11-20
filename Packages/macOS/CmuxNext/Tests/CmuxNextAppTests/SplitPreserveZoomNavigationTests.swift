import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

// CmuxNextLayout has its own PaneID and ScreenID; the daemon tree takes the daemon's.
private typealias DaemonPaneID = CmuxNextDaemon.PaneID
private typealias DaemonScreenID = CmuxNextDaemon.ScreenID

/// Ghostty's `split-preserve-zoom = navigation` (cmux#47785): a pane-navigation key on a zoomed screen lands where it
/// would on the unzoomed screen, and the zoom goes with it, as Ghostty.app's `goto_split` does. Without the flag a
/// zoomed screen keeps its one pane and the key moves nothing.
///
/// The app has a daemon connection that never becomes ready: the zoom shows as a store intent in the key's turn, and
/// each check runs in that turn, before the refusal that takes it back.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct SplitPreserveZoomNavigationTests {
    private nonisolated static let left = DaemonPaneID(rawValue: 1), top = DaemonPaneID(rawValue: 2), bottom = DaemonPaneID(rawValue: 3)
    private static let workspace = "preserve-zoom-ws"

    // MARK: The config key

    @Test func theConfigKeyReadsAsGhosttyWritesIt() {
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        #expect(GhosttySplitPreserveZoom(configText: "") == [])
        #expect(GhosttySplitPreserveZoom(configText: "split-preserve-zoom = navigation\n") == .navigation)
        #expect(GhosttySplitPreserveZoom(configText: "split-preserve-zoom = navigation\nsplit-preserve-zoom = no-navigation\n") == [])
    }

    // MARK: Navigation on a zoomed screen

    @Test(arguments: [("focusRight", top), ("focusNextPane", top), ("focusPreviousPane", bottom)])
    func withNavigationTheZoomMovesWithTheFocus(action: String, lands: CmuxNextDaemon.PaneID) async throws {
        let shown = try await Self.shown(preserving: .navigation)
        defer { shown.close() }
        #expect(Self.run("toggleSplitZoom", on: Self.left, shown))
        try #require(shown.zoomedPane == Self.left && shown.order == [Self.left], "the left pane did not zoom")

        #expect(Self.run(ActionID(rawValue: action), on: Self.left, shown))
        #expect(shown.zoomedPane == lands, "\(action) did not move the zoom to the pane it lands on: \(String(describing: shown.zoomedPane))")
        #expect(shown.order == [lands], "the screen does not show the newly zoomed pane alone: \(shown.order)")
        #expect(shown.focused == lands, "\(action) did not move the focus with the zoom: \(String(describing: shown.focused))")
    }

    /// The direction reads the unzoomed layout: down from the column's top pane is the pane under it.
    @Test func aDirectionReadsTheUnzoomedLayout() async throws {
        let shown = try await Self.shown(preserving: .navigation)
        defer { shown.close() }
        #expect(Self.run("toggleSplitZoom", on: Self.top, shown))
        try #require(shown.zoomedPane == Self.top)
        PaneHandlers.focus(try #require(shown.layoutID(Self.top)), in: shown.content)

        #expect(Self.run("focusDown", on: Self.top, shown))
        #expect(shown.zoomedPane == Self.bottom && shown.focused == Self.bottom)
        #expect(Self.run("focusLeft", on: Self.bottom, shown))
        #expect(shown.zoomedPane == Self.left && shown.focused == Self.left)
    }

    @Test func withoutTheFlagTheZoomStays() async throws {
        let shown = try await Self.shown(preserving: [])
        defer { shown.close() }
        #expect(Self.run("toggleSplitZoom", on: Self.left, shown))
        try #require(shown.zoomedPane == Self.left)

        _ = Self.run("focusRight", on: Self.left, shown)
        #expect(shown.zoomedPane == Self.left, "the zoom moved without split-preserve-zoom = navigation")
        #expect(shown.focused == Self.left)
    }

    // MARK: Harness

    private struct Shown {
        let services: AppServices
        let controller: WindowController
        let content: WorkspaceContentController
        /// The runtime's config before the test's, adopted back on close.
        let restore: ghostty_config_t?

        var store: DaemonStore { services.daemon.store }
        var zoomedPane: DaemonPaneID? { store.screen(containing: SplitPreserveZoomNavigationTests.left)?.zoomedPane }
        /// The panes the layout model shows on the screen, as daemon handles.
        var order: [DaemonPaneID] {
            (content.layoutModel.screens.first?.layout.panes ?? []).compactMap { content.handles.panes[$0] }
        }
        var focused: DaemonPaneID? { content.focusedPane?.pane.handle }
        func layoutID(_ pane: DaemonPaneID) -> LayoutPaneID? { content.panes.values.first { $0.pane.handle == pane }?.layoutPaneID }

        func close() {
            if let restore { GhosttyRuntime.shared.adoptAppliedConfig(restore) }
            controller.teardown()
            controller.window?.close()
            services.daemon.shutdownConnection()
        }
    }

    /// `left` beside a column of `top` over `bottom`.
    private static func tree() -> DaemonTree {
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(left),
                                        b: .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(top), b: .leaf(bottom)))
        let panes = layout.paneIDs.map { PaneSnapshot(id: $0, tabs: [TabSnapshot(surface: SurfaceID(rawValue: $0.rawValue), title: "~")]) }
        let screen = ScreenSnapshot(id: DaemonScreenID(rawValue: 1), active: true, activePane: left, layout: layout, panes: panes)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: workspace), name: "preserve zoom", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: workspace), index: 0)])
        return tree
    }

    /// The app with one window showing the three panes, the left one focused, `flags` as the Ghostty config's.
    private static func shown(preserving flags: GhosttySplitPreserveZoom) async throws -> Shown {
        _ = NSApplication.shared
        // The flags reach the app as a person's config does: a Ghostty config the runtime applied.
        let runtime = GhosttyRuntime.shared
        let restore = runtime.config.flatMap { ghostty_config_clone($0) }
        let text = flags.contains(.navigation) ? "split-preserve-zoom = navigation\n" : ""
        let config = try #require(ghostty_config_new())
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        runtime.adoptAppliedConfig(config)
        do {
            return try await shownAfterAdopting(flags, restore: restore)
        } catch {
            // A failed setup never leaves the test's config applied for the suites after it.
            if let restore { runtime.adoptAppliedConfig(restore) }
            throw error
        }
    }

    private static func shownAfterAdopting(_ flags: GhosttySplitPreserveZoom, restore: ghostty_config_t?) async throws -> Shown {
        try #require(GhosttyRuntime.shared.splitPreserveZoom == flags, "the runtime did not take the test's config")
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-preserve-zoom-\(UUID().uuidString).sock"))
        services.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
        await services.daemon.firstConnection()
        try #require(services.daemon.connection != nil, "the service never took the connection")
        services.daemon.store.connectionState = .connected(identity)
        services.daemon.store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: [workspace], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        // test-wait: the window shows the workspace's panes once its content controller builds them.
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 3, "the window never showed the workspace's three panes")
        content.contentView.layoutSubtreeIfNeeded()
        let shown = Shown(services: services, controller: controller, content: content, restore: restore)
        PaneHandlers.focus(try #require(shown.layoutID(left)), in: content)
        try #require(shown.focused == left, "the left pane never took the focus")
        return shown
    }

    private static func run(_ id: ActionID, on pane: DaemonPaneID, _ shown: Shown) -> Bool {
        guard let controller = shown.content.panes.values.first(where: { $0.pane.handle == pane }) else { return false }
        return shown.services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: controller.paneKey), origin: .user))
    }
}
