import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// cmux-ad m23 (STATUS 15571): a sidebar row insert (Cmd-N) or remove (Close Workspace) misses refreshes at 120 Hz, more
/// with more rows. One O(rows) part is the list's apply: it computed `frame(for:)` for every listed row (each reads the
/// row tokens), only to test it against the realization rect, though it draws only the rows there and the rows that
/// already have views. One change must compute frames for those rows only: as many at 200 rows as at 50.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowFrameCostTests {
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

    /// Row frames one change makes the list's apply compute.
    private static func frames(_ body: () -> Void) -> Int {
        let before = SidebarPerfCounters.count(.rowFrames)
        body()
        return SidebarPerfCounters.count(.rowFrames) - before
    }

    /// Cmd-N at the top, selected: the apply computes frames for the realized rows, the new one and the rows the
    /// realization rect holds, at most a dozen past the realized ones, whatever the list's length.
    @Test(arguments: [50, 200])
    func oneInsertComputesFramesOnlyForTheRowsItCanDraw(_ count: Int) throws {
        let ids = Array(1...count)
        let (model, list, close) = try Self.sidebar(ids)
        defer { close() }
        let realized = list.rowViews.count
        let next = Self.sections([10_000] + ids)
        let made = Self.frames {
            model.sections = next
            if let id = next.first?.workspaces.first?.id { model.activeWorkspaceID = id }
            list.reload(animated: true)
        }
        #expect(made <= realized + 12, "one insert at \(count) rows computed \(made) row frames (\(realized) realized): O(rows), not O(drawn rows)")
        #expect(list.rowViews[.workspace(try #require(next.first?.workspaces.first?.id))] != nil, "the new row has no view")
    }

    /// Close Workspace on the top, selected row: the same bound.
    @Test(arguments: [50, 200])
    func oneRemoveComputesFramesOnlyForTheRowsItCanDraw(_ count: Int) throws {
        let ids = Array(1...count)
        let (model, list, close) = try Self.sidebar(ids)
        defer { close() }
        let realized = list.rowViews.count
        let next = Self.sections(Array(ids.dropFirst()))
        let made = Self.frames {
            model.sections = next
            if let id = next.first?.workspaces.first?.id { model.activeWorkspaceID = id }
            list.reload(animated: true)
        }
        #expect(made <= realized + 12, "one remove at \(count) rows computed \(made) row frames (\(realized) realized): O(rows), not O(drawn rows)")
    }

    /// The rows the apply leaves out are the ones it would not draw: after an insert far below the realized rows,
    /// the realized rows are the same views at their slots, and the far row has no view.
    @Test
    func anInsertBelowTheDrawnRowsKeepsTheDrawnRowsAndMakesNoViewForIt() throws {
        let ids = Array(1...200)
        let (model, list, close) = try Self.sidebar(ids)
        defer { close() }
        let shown = list.rowViews
        let next = Self.sections(ids + [10_000])
        model.sections = next
        list.reload(animated: false)
        let far = try #require(next.first?.workspaces.last?.id)
        #expect(list.rowViews[.workspace(far)] == nil, "a row far below the realization rect got a view")
        for (key, view) in shown {
            #expect(list.rowViews[key] === view, "the drawn row \(key) lost its view")
            if let row = list.displayed.row(for: key) { #expect(view.frame == list.frame(for: row), "the drawn row \(key) is not at its slot") }
        }
    }
}
