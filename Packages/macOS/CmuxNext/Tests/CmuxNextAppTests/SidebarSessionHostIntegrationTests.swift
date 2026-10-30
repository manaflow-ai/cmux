import AppKit
@testable import CmuxNextAgentLanes
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Exercise the feed-to-view boundary: pure SidebarLayout tests cannot catch a list option
/// dropping the session tree during a drag, or a default-off feed publishing it anyway.
@MainActor @Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty, "needs a GUI display host"))
struct SidebarSessionHostIntegrationTests {
    private static let coordinator = WorkspaceID("host-integration-coordinator")
    private static let plain = WorkspaceID("host-integration-plain")
    private static let dragged = WorkspaceID("host-integration-dragged")
    private static let workers = (0..<12).map { WorkspaceID("host-integration-worker-\($0)") }
    private static let host = "registry:host-integration"

    private static func pass(enabled: Bool) -> SidebarSessionTreeFeed.Pass {
        let refs = [(coordinator, [AgentSessionRef(host: host, hostName: "Build machine", session: "coordinator")])]
            + workers.enumerated().map { index, workspace in
                (workspace, [AgentSessionRef(host: host, session: "worker-\(index)")])
            }
        let parents = Dictionary(uniqueKeysWithValues: workers.indices.map { ("worker-\($0)", "coordinator") })
        var pass = SidebarSessionTreeFeed.pass(refs, lanes: [:], remoteParentsByHost: [host: parents],
                                              localHost: "install:host-integration-local", pullRequests: [:])
        pass.showsTree = enabled
        return pass
    }

    private static func withList(_ body: (SidebarListView) throws -> Void) rethrows {
        _ = NSApplication.shared
        let tree = SidebarSessionTree.shared
        let savedState = tree.state
        let savedBadges = tree.pullRequests
        let savedHistory = SidebarChatHistory.shared.state
        defer {
            tree.state = savedState
            tree.pullRequests = savedBadges
            SidebarChatHistory.shared.state = savedHistory
        }
        tree.state = nil
        tree.pullRequests = [:]
        SidebarChatHistory.shared.state = nil
        let workspace = { (id: WorkspaceID) in SidebarNode.workspace(SidebarWorkspace(id: id, title: id.rawValue)) }
        let nodes = [workspace(coordinator), workspace(plain)] + workers.map(workspace) + [workspace(dragged)]
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: nodes)
        let model = SidebarModel(sections: [section], activeWorkspaceID: dragged)
        model.showWorkspaceTabs = false
        model.groupsByComputer = false
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            list.cancelDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 1000))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        try body(list)
    }

    @Test func defaultOffPublishLeavesTheProductionListFlatAndCanDisableAnEnabledTree() throws {
        try Self.withList { list in
            let defaults = SidebarSectionsPreferences.defaults
            #expect(!defaults.sessionTree)
            SidebarSessionTreeFeed.publish(Self.pass(enabled: defaults.sessionTree), to: .shared)
            list.reload(animated: false)
            #expect(list.options(includeGap: false).sessionTree == nil)
            #expect(list.displayed.row(for: .sessionHost(Self.host)) == nil)
            let originalOrder = [Self.coordinator, Self.plain] + Self.workers + [Self.dragged]
            #expect(list.displayed.rows.map(\.key) == originalOrder.map(SidebarRowKey.workspace))

            SidebarSessionTreeFeed.publish(Self.pass(enabled: true), to: .shared)
            list.reload(animated: false)
            let header = try #require(list.displayed.row(for: .sessionHost(Self.host)))
            #expect(header.childCount == Self.workers.count + 1)
            #expect(list.options(includeGap: false).sessionTree?.parents[Self.workers[0]] == Self.coordinator)
            #expect(list.displayed.rows.map(\.key) == [.sessionHost(Self.host), .workspace(Self.coordinator)]
                    + Self.workers.map(SidebarRowKey.workspace) + [.workspace(Self.plain), .workspace(Self.dragged)])

            SidebarSessionTreeFeed.publish(Self.pass(enabled: defaults.sessionTree), to: .shared)
            list.reload(animated: false)
            #expect(SidebarSessionTree.shared.state == nil)
            #expect(list.options(includeGap: true).sessionTree == nil)
            #expect(list.displayed.rows.map(\.key) == originalOrder.map(SidebarRowKey.workspace))
        }
    }

    @Test func draggingAnUnrelatedWorkspaceKeepsEnabledCoordinatorLanesAndTheirDropIdentity() throws {
        try Self.withList { list in
            SidebarSessionTreeFeed.publish(Self.pass(enabled: true), to: .shared)
            list.reload(animated: false)
            let hostKey = SidebarRowKey.sessionHost(Self.host)
            let before = try #require(list.displayed.row(for: hostKey))
            let key = SidebarRowKey.workspace(Self.dragged)
            let row = try #require(list.displayed.row(for: key))
            let press = SidebarPress(key: key, point: NSPoint(x: 80, y: row.y + row.height / 2))
            list.press = press
            list.beginDrag(press)
            let drag = try #require(list.drag)

            let baseOptions = list.options(includeGap: false)
            let gapOptions = list.options(includeGap: true)
            #expect(baseOptions.sessionTree?.hosts[Self.coordinator] == Self.host)
            #expect(gapOptions.sessionTree == baseOptions.sessionTree)
            #expect(baseOptions.excludedWorkspaces == [Self.dragged])
            #expect(baseOptions.gap == nil)
            #expect(gapOptions.gap == DropPosition(section: .machine(.local), index: Self.workers.count + 2))
            #expect(gapOptions.gapHeight == drag.gapHeight)
            // Both the drop resolver's base and the actual in-place drag layout retain the host.
            let base = SidebarLayout.make(sections: list.listSections, metrics: list.metrics, options: baseOptions)
            let gap = SidebarLayout.make(sections: list.listSections, metrics: list.metrics, options: gapOptions)
            for layout in [base, gap, list.displayed] {
                let header = try #require(layout.row(for: hostKey))
                #expect(header.childCount == before.childCount)
                for (index, worker) in Self.workers.enumerated() {
                    let child = try #require(layout.row(for: .workspace(worker)))
                    #expect(child.section == .machine(.local))
                    #expect(child.group == nil)
                    #expect(child.siblingIndex == index + 2)
                    #expect(child.content?.treeDepth == 2)
                    #expect(layout.rows.filter { $0.key == child.key }.count == 1)
                }
            }
            #expect(base.row(for: key) == nil)
            #expect(gap.gapY != nil)
            #expect(list.displayed.gapY == list.displayed.row(for: key)?.y)
            #expect(list.model.sections[0].workspaces.map(\.id) == [Self.coordinator, Self.plain] + Self.workers + [Self.dragged])
        }
    }
}
