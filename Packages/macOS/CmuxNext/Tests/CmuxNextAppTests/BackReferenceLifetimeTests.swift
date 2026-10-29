import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTabs
import Foundation
import Testing

/// back-references whose owner can be freed first are no longer `unowned` (an
/// `unowned` read after the owner's deinit traps). A workspace content reads its window state after
/// the window let go of it (a create's task or a `ScreenRef` still holds the content), and a screen
/// hover card's thumbnail task asks its preview source after the workspace content was freed.
@MainActor struct BackReferenceLifetimeTests {
    private static var key: WorkspaceKey { WorkspaceKey(rawValue: "w1") }

    private static var tree: DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"back-reference-lifetime-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Lets the torn-down content's cancelled observation tasks end: a fixed number of yields.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private static func services() throws -> (AppServices, WorkspaceModel) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try connected())
        store.apply(snapshot: tree)
        return (services, try #require(store.workspaces.first))
    }

    @Test(.timeLimit(.minutes(1)))
    func aContentKeepsItsWindowStateAfterTheWindowLetsGo() async throws {
        let (services, workspace) = try Self.services()
        defer { withExtendedLifetime(services) {} }
        weak var released: WindowState?
        let content: WorkspaceContentController = autoreleasepool {
            let state = WindowState(id: "window-1", workspaceID: workspace.id)
            released = state
            return WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        }
        try #require(released != nil, "the content holds its window state; an unowned reference would trap on the next read")
        #expect(content.state.id == "window-1")
        content.teardown()
    }

    @Test(.timeLimit(.minutes(1)))
    func aScreenPreviewAnswersAfterItsContentIsFreed() async throws {
        let (services, workspace) = try Self.services()
        defer { withExtendedLifetime(services) {} }
        let state = WindowState(id: "window-1", workspaceID: workspace.id)
        weak var freed: WorkspaceContentController?
        let preview: ScreenPreviewSource = autoreleasepool {
            let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            freed = content
            let preview = ScreenPreviewSource(content: content)
            content.teardown()
            return preview
        }
        await Self.drainMain()
        try #require(freed == nil, "the content is gone; the hover card's task still holds its preview source")
        let screen = try #require(workspace.screens.first)
        // A terminal with no surface has no picture: nil, not a trap on a freed content.
        let image = await preview.previewImage(for: StripTabID(screen.id), maxPixelSize: CGSize(width: 320, height: 200))
        #expect(image == nil)
    }
}
