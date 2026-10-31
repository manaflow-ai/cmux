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

    @MainActor private static func withList(_ body: (SidebarListView) throws -> Void) rethrows {
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
        let section = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: nodes)
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
            #expect(list.displayed.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local)))) == nil)
            let originalOrder = [Self.coordinator, Self.plain] + Self.workers + [Self.dragged]
            #expect(list.displayed.rows.map(\.key) == originalOrder.map(SidebarRowKey.workspace))

            SidebarSessionTreeFeed.publish(Self.pass(enabled: true), to: .shared)
            list.reload(animated: false)
            let header = try #require(list.displayed.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local)))))
            #expect(header.childCount == Self.workers.count + 1)
            #expect(list.options(includeGap: false).sessionTree?.parents[Self.workers[0]] == Self.coordinator)
            #expect(list.displayed.rows.map(\.key) == [.sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))), .workspace(Self.coordinator)]
                    + Self.workers.map(SidebarRowKey.workspace) + [.workspace(Self.plain), .workspace(Self.dragged)])

            SidebarSessionTreeFeed.publish(Self.pass(enabled: defaults.sessionTree), to: .shared)
            list.reload(animated: false)
            #expect(SidebarSessionTree.shared.state == nil)
            #expect(list.options(includeGap: true).sessionTree == nil)
            #expect(list.displayed.rows.map(\.key) == originalOrder.map(SidebarRowKey.workspace))
        }
    }

    @Test func draggingAnUnrelatedWorkspaceIsRefusedWhileHostGroupsShow() throws {
        try Self.withList { list in
            SidebarSessionTreeFeed.publish(Self.pass(enabled: true), to: .shared)
            list.reload(animated: false)
            let key = SidebarRowKey.workspace(Self.dragged)
            let row = try #require(list.displayed.row(for: key))
            let press = SidebarPress(key: key, point: NSPoint(x: 80, y: row.y + row.height / 2))
            list.press = press
            list.beginDrag(press)
            let drag = try #require(list.drag)

            #expect(list.displayed.hostHeadersShowing)
            #expect(drag.target == nil)
            #expect(list.displayed.gapY == nil)
            let familyRow = try #require(list.displayed.row(for: .workspace(Self.workers[0])))
            let beforeCardY = drag.lift.frame.minY
            list.updateDrag(windowPoint: list.convert(NSPoint(x: 80, y: familyRow.y + familyRow.height / 2), to: nil))
            #expect(drag.lift.frame.minY != beforeCardY)
            #expect(list.displayed.gapY == nil)
            list.finishDrag()
            #expect(list.model.sections[0].workspaces.map(\.id) == [Self.coordinator, Self.plain] + Self.workers + [Self.dragged])
        }
    }

    /// GUI matrix for the host-group refusal: every in-sidebar target must keep
    /// the card moving while showing no gap and must leave the document intact.
    @Test func hostGroupRefusalMatrixRunsLegacyAndDocumentPaths() throws {
        try Self.withList { list in
            SidebarSessionTreeFeed.publish(Self.pass(enabled: true), to: .shared)
            list.reload(animated: false)
            let original = list.model.sections[0].workspaces.map(\.id)
            let source = SidebarRowKey.workspace(Self.dragged)

            // Targets are list points (the list is flipped); the drag and drop entry points take window points.
            @MainActor func exercise(_ point: NSPoint, document: Bool) throws {
                if document {
                    list.model.docDrag = SidebarDocDrag(
                        item: { key in if case let .workspace(id) = key { "workspace-\(id.rawValue)" } else { nil } },
                        section: { _ in "machine-local" },
                        begin: { ids in Dictionary(uniqueKeysWithValues: ids.map { ($0, SidebarDocAcceptance.none) }) },
                        drop: { _, _ in }
                    )
                }
                defer { list.model.docDrag = nil }
                let row = try #require(list.displayed.row(for: source))
                let press = SidebarPress(key: source, point: NSPoint(x: 80, y: row.y + row.height / 2))
                list.press = press
                list.beginDrag(press)
                let drag = try #require(list.drag)
                let beforeY = drag.lift.frame.minY
                list.updateDrag(windowPoint: list.convert(point, to: nil))
                #expect(drag.lift.frame.minY != beforeY)
                #expect(list.displayed.gapY == nil)
                #expect(drag.target == nil)
                list.finishDrag()
                #expect(list.model.sections[0].workspaces.map(\.id) == original)
            }

            let header = try #require(list.displayed.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local)))))
            let family = try #require(list.displayed.row(for: .workspace(Self.workers[0])))
            let plain = try #require(list.displayed.row(for: .workspace(Self.plain)))
            let targets = [
                NSPoint(x: 80, y: header.y + header.height / 2),
                NSPoint(x: 80, y: family.y + family.height / 2),
                NSPoint(x: 80, y: plain.y + plain.height / 2),
                NSPoint(x: 80, y: list.displayed.totalHeight - 4),
                NSPoint(x: 80, y: 1)
            ]
            for point in targets { try exercise(point, document: false) }
            for point in targets { try exercise(point, document: true) }

            // External tab drops use the same host-header gate only for
            // structural reorders; taking a tab into an existing workspace is
            // still accepted.
            let workspacePoint = NSPoint(x: 80, y: plain.y + plain.height / 2)
            #expect(list.externalDragMoved(windowPoint: list.convert(workspacePoint, to: nil), sourceMachine: nil) != nil)
            list.externalDragExited()
            let endPoint = NSPoint(x: 80, y: list.displayed.totalHeight - 4)
            #expect(list.externalDragMoved(windowPoint: list.convert(endPoint, to: nil), sourceMachine: nil) == nil)
            #expect(list.externalDragEnded() == nil)

            // Control: with no host header, the ordinary resolver still opens a gap.
            SidebarSessionTreeFeed.publish(Self.pass(enabled: false), to: .shared)
            list.reload(animated: false)
            let row = try #require(list.displayed.row(for: source))
            let press = SidebarPress(key: source, point: NSPoint(x: 80, y: row.y + row.height / 2))
            list.press = press
            list.beginDrag(press)
            let plainControl = try #require(list.displayed.row(for: .workspace(Self.plain)))
            list.updateDrag(windowPoint: list.convert(NSPoint(x: 80, y: plainControl.y + plainControl.height / 2), to: nil))
            #expect(list.displayed.gapY != nil)
            list.cancelDrag()
        }
    }
}
