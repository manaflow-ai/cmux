import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// cmux-ad m23 (STATUS 14191, 15277): a sidebar row insert (Cmd-N) or remove (Close Workspace) at 120 Hz with 0 missed
/// refreshes. The films (cmux23/cmux24, 120 Hz) miss 9-30 refreshes per press in 3-6 long frames at the change, more with
/// more rows, and the profile puts the cost per change, not per frame. One row change must cost O(changed rows) on the
/// main thread: it configures only the rows whose content changed (the new or closed row, the rows whose selection
/// changed), never every realized row again.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowChangeCostTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// Workspaces `ids` in a 240 x 480 window on screen, the first selected, at rest.
    private static func sidebar(_ ids: [Int]) throws -> (SidebarModel, SidebarListView, close: () -> Void) {
        let start = sections(ids)
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        if window.screen == nil { window.close() }
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return (model, sidebar.list, { window.close() })
    }

    /// Row configures one reload makes.
    private static func configures(_ body: () -> Void) -> Int {
        let before = SidebarPerfCounters.count(.rowConfigures)
        body()
        return SidebarPerfCounters.count(.rowConfigures) - before
    }

    /// Cmd-N at 200 rows: the new workspace lands at the top (`workspaces.newPlacement` top, the default) and takes the
    /// selection. Only the new row and the row that loses the selection change; at most 3 row configures (the new row,
    /// the old selected row, and one for the selection's move), not one per realized row.
    @Test(arguments: [50, 200])
    func oneInsertConfiguresOnlyTheChangedRows(_ count: Int) throws {
        let ids = Array(1...count)
        let (model, list, close) = try Self.sidebar(ids)
        defer { close() }
        let realized = list.rowViews.count
        let next = Self.sections([10_000] + ids)
        let made = Self.configures {
            model.sections = next
            if let id = next.first?.workspaces.first?.id { model.activeWorkspaceID = id }
            list.reload(animated: true)
        }
        #expect(made <= 3, "one insert at \(count) rows configured \(made) row views (\(realized) realized): O(realized rows), not O(changed rows)")
    }

    /// Close Workspace at 200 rows: the selected (top) row leaves and the next row takes the selection. At most 2 row
    /// configures (the row that takes the selection, and one for the selection's move), not one per realized row.
    @Test(arguments: [50, 200])
    func oneRemoveConfiguresOnlyTheChangedRows(_ count: Int) throws {
        let ids = Array(1...count)
        let (model, list, close) = try Self.sidebar(ids)
        defer { close() }
        let realized = list.rowViews.count
        let next = Self.sections(Array(ids.dropFirst()))
        let made = Self.configures {
            model.sections = next
            if let id = next.first?.workspaces.first?.id { model.activeWorkspaceID = id }
            list.reload(animated: true)
        }
        #expect(made <= 2, "one remove at \(count) rows configured \(made) row views (\(realized) realized): O(realized rows), not O(changed rows)")
    }
}
