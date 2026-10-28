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

    /// A row still opening that moves by itself (shown at the daemon's slot first, then placed below another row) opens
    /// again at its new slot in a new view, so it never crosses the list half open (cx-ai79); a row an insert above
    /// only pushes keeps its view (the burst case above).
    @Test func aRowStillOpeningThatMovesByItselfOpensAgainThere() throws {
        let (model, list, restore) = try Self.sidebar(Array(1...10))
        defer { restore() }
        model.sections = Self.sections(Array(1...10) + [100])
        list.reload(animated: true)
        let moved = try Self.key(100)
        let view = try #require(list.rowViews[moved])
        model.sections = Self.sections([1, 100] + Array(2...10))
        list.reload(animated: true)
        let again = try #require(list.rowViews[moved])
        #expect(again !== view, "a row that moved by itself flew across the list half open")
        #expect(again.opens == 1 && again.alphaValue == 0, "it did not open again at its new slot")
    }

    /// Cmd-W held on the top workspace, one close per frame (a guard, not red on the base: no row is opening): each
    /// closing row collapses in the view it had, never upward, and the rows still shown keep their views.
    @Test func quickClosesCollapseEachRowInItsOwnView() throws {
        var ids = Array(1...12)
        let (model, list, restore) = try Self.sidebar(ids)
        defer { restore() }
        let stay = try Self.key(8)
        let kept = try #require(list.rowViews[stay])
        for _ in 0..<6 {
            let closing = try Self.key(ids.removeFirst())
            let view = try #require(list.rowViews[closing], "the closing row has no view")
            let shown = view.frame
            model.sections = Self.sections(ids)
            list.reload(animated: true)
            #expect(list.rowViews[closing] == nil, "the closed row is still listed")
            #expect(view.closingEnd != nil || view.superview == nil, "the closing row neither collapses nor left")
            // Its end frame (the model frame now): the top of its slot at zero height, not above where it showed.
            if let end = view.closingEnd { #expect(end.minY >= shown.minY - 0.5 && end.height <= shown.height, "the close ends at \(end)") }
            #expect(list.rowViews[stay] === kept, "a close rebuilt a row that stays")
        }
    }

    /// Thirty Cmd-N at the top, one per frame (key repeat), each selecting its new workspace as Cmd-N does: every row
    /// made so far that still shows keeps its one view and opens once.
    @Test func thirtyQuickInsertsOpenEachRowOnce() throws {
        var ids = Array(1...5)
        let (model, list, restore) = try Self.sidebar(ids)
        defer { restore() }
        var views: [SidebarRowKey: SidebarRowView] = [:]
        for burst in 0..<30 {
            ids.insert(1_000 + burst, at: 0)
            let sections = Self.sections(ids)
            model.sections = sections
            if let id = sections.first?.workspaces.first?.id { model.activeWorkspaceID = id }
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
