import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Review of #28044 at a4ae195d: while a lower split's move was under way, placement named a stand-in
/// for the pane still moving in. A folder link looked it up, found no pane and opened its terminal in
/// the source, over the chat; DurableTabLink's fallback lost its destination the same way. Placement
/// hands out real panes only now: the stand-in becomes the right pane that holds the moving tab.
@MainActor struct RightColumnPendingTargetTests {
    private static func tree() -> DaemonTree {
        let chat = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "chat")])
        let right = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "diff")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(chat.id), b: .leaf(right.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [chat, right])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    @Test func aFolderOpenedDuringALowerSplitTargetsTheRealRightPane() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self,
            from: Data(#"{"app":"cmux-tui","protocol":1,"session":"pending-target-test","generation":"g1"}"#.utf8))
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1600, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        window.contentView = content.contentView
        window.orderFrontRegardless()
        content.applyCurrent()
        content.contentView.layoutSubtreeIfNeeded()
        let panes = try #require(content.layoutModel.screens.first?.layout.panes)
        try #require(panes.count == 2)
        let chat = try #require(content.panes[panes[0]]), right = panes[1]
        services.linkOpener.placement = { .splitRight }

        // Fixture: with nothing pending, the chat's one right pane gets a split below it.
        try #require(services.linkOpener.target(from: chat, mainPane: false) == .splitBelow(of: right))

        let release = RightColumn.reserveBelow(right)
        defer { release() }
        let target = services.linkOpener.target(from: chat, mainPane: false)
        #expect(target == .pane(right), "a pending split's stand-in leaked out of placement: \(target)")
        #expect(LinkOpener.existingPane(of: target) == right, "DurableTabLink's fallback lost its destination")
        #expect(RightColumn.panes(beside: chat.layoutPaneID, in: content).allSatisfy { content.panes[$0] != nil },
                "the right column named a pane the workspace has none of")
        #expect(RightColumn.measure(beside: chat).panes.allSatisfy { content.panes[LayoutPaneID($0)] != nil })
        withExtendedLifetime(state) {}
    }
}
