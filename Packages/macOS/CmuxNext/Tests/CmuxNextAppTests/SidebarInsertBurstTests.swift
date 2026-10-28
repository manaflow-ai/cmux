import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Cmd-N held (Lawrence 2026-10-28: "when i hold down cmd n ... i see empty space where workspaces should be, and only
/// after i stop cmd n, do the workspaces show up"; handoff/sidebar-burst-motion.md). Under key repeat each new
/// workspace lands at the top while the ones before it still open their slot. A row still opening that the next insert
/// moves must keep its view, its content and its opening progress: it moves on with the rows (an additive retarget
/// from what shows), it never starts again from an empty slot. Decided in `SidebarListView.apply`, before any frame
/// draws, so these tests need no awake display.
@MainActor @Suite(.serialized)
struct SidebarInsertBurstTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    private static func key(_ id: Int) throws -> SidebarRowKey {
        .workspace(try #require(sections([id]).first?.workspaces.first?.id))
    }

    /// A sidebar of workspaces `ids` with new workspace rows opening and Reduce Motion off. Returns the restore.
    private static func sidebar(_ ids: [Int]) throws -> (SidebarModel, SidebarListView, restore: () -> Void) {
        let start = sections(ids)
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = false
        return (model, sidebar.list, {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = kinds
        })
    }

    /// Two quick Cmd-N at the top: the first new row, still opening when the second lands, keeps its view (no new view,
    /// no reset to an empty, transparent slot) and shows its title.
    @Test func aRowStillOpeningKeepsItsViewWhenTheNextInsertMovesIt() throws {
        let (model, list, restore) = try Self.sidebar(Array(1...10))
        defer { restore() }
        model.sections = Self.sections([100] + Array(1...10))
        list.reload(animated: true)
        let first = try Self.key(100)
        let view = try #require(list.rowViews[first], "the new row has no view")
        #expect(list.openingRows[first] != nil, "the new row did not open (animations off here?)")
        let opens = view.opens
        model.sections = Self.sections([101, 100] + Array(1...10))
        list.reload(animated: true)
        #expect(list.rowViews[first] === view, "the next insert threw the opening row's view away")
        #expect(view.opens == opens, "the next insert started the row's open again from an empty slot")
        let title = (view as? WorkspaceRowView)?.title.stringValue
        #expect(title == "w100", "the moved row shows no title: \(String(describing: title))")
    }

    /// Thirty Cmd-N at the top, one per frame (key repeat): every row made so far keeps one view and opens once, and
    /// no apply makes more than the one new row's view.
    @Test func thirtyQuickInsertsOpenEachRowOnce() throws {
        var ids = Array(1...5)
        let (model, list, restore) = try Self.sidebar(ids)
        defer { restore() }
        var views: [SidebarRowKey: SidebarRowView] = [:]
        for burst in 0..<30 {
            ids.insert(1_000 + burst, at: 0)
            model.sections = Self.sections(ids)
            list.reload(animated: true)
            let key = try Self.key(1_000 + burst)
            views[key] = try #require(list.rowViews[key], "insert \(burst) has no view")
            for (key, view) in views where list.rowViews[key] != nil {
                #expect(list.rowViews[key] === view, "insert \(burst) rebuilt \(key)'s view")
                #expect(view.opens == 1, "\(key) opened \(view.opens) times")
            }
        }
    }
}
