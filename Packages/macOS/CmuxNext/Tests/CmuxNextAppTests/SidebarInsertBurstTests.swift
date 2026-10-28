import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
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
    /// `onScreen`: the window is ordered in, so springs run on the render server (the caller checks a display draws).
    private static func sidebar(_ ids: [Int], onScreen: Bool = false) throws -> (SidebarModel, SidebarListView, restore: () -> Void) {
        let start = sections(ids)
        let model = SidebarModel(sections: start, activeWorkspaceID: try #require(start.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: !onScreen)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        if onScreen { window.orderFrontRegardless() }
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = false
        return (model, sidebar.list, {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = kinds
            window.orderOut(nil)
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
        let opened = try #require(list.openingRows[moved])
        model.sections = Self.sections([1, 100] + Array(2...10))
        list.reload(animated: true)
        let again = try #require(list.rowViews[moved])
        #expect(again !== view, "a row that moved by itself flew across the list half open")
        #expect(again.opens == 1, "it did not open again at its new slot")
        #expect((list.openingRows[moved] ?? 0) > opened, "its open did not start again")
    }

    /// Cmd-N with the list scrolled away from its top: the reveal jumps to the new row at the top, so its gap is open in
    /// that frame. The row is in its slot, whole, in that frame (it does not grow from nothing in the open gap).
    @Test func aCmdNTheRevealJumpsToShowsTheNewRowWhole() throws {
        let ids = Array(1...40)
        let (model, list, restore) = try Self.sidebar(ids)
        defer { restore() }
        let clip = try #require(list.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 900))
        list.enclosingScrollView?.reflectScrolledClipView(clip)
        try #require(clip.bounds.minY > 400, "the list did not scroll")
        let sections = Self.sections([500] + ids)
        model.sections = sections
        model.activeWorkspaceID = try #require(sections.first?.workspaces.first?.id)
        list.reload(animated: true)
        #expect(clip.bounds.minY < 1, "the reveal did not show the new row")
        let key = try Self.key(500)
        let view = try #require(list.rowViews[key], "the new row has no view")
        #expect(view.opens == 0 && view.alphaValue == 1, "the new row grows from an empty slot (opens \(view.opens), alpha \(view.alphaValue))")
        #expect(list.openingRows[key] == nil)
        #expect(view.frame == list.frame(for: try #require(list.displayed.row(for: key))))
    }

    /// A new row inserted just below the viewport (a new workspace after the current one near the bottom): the reveal
    /// scrolls a little, and the row, drawn in this apply, opens with its gap, so the row below it, which springs down
    /// from the new row's slot, never draws over a whole row (review of df204f50462).
    @Test func aNewRowJustBelowTheViewportOpensWithItsGap() throws {
        var ids = Array(1...40)
        let (model, list, restore) = try Self.sidebar(ids)
        defer { restore() }
        let clip = try #require(list.enclosingScrollView?.contentView)
        let height = clip.bounds.height
        // The first row whose bottom is past the viewport: insert after the row before it.
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        let index = try #require(rows.firstIndex { list.frame(for: $0).maxY > height }, "the list fits the viewport")
        ids.insert(500, at: index)
        let sections = Self.sections(ids)
        model.sections = sections
        model.activeWorkspaceID = try #require(sections.first?.workspaces.first { $0.title == "w500" }?.id)
        list.reload(animated: true)
        let key = try Self.key(500)
        #expect(list.rowViews[key] != nil, "the new row has no view")
        #expect(list.openingRows[key] != nil, "the new row was shown whole while the row below sprang over it")
    }

    /// Cmd-N with the list at its top and taller than the viewport: no scroll at all, so the rows below are pushed down
    /// on their springs while the new row opens (its gap and its content together). The anchor shift moved the rows
    /// and the offset down at once and the reveal jumped back, so the rows stood in their new slots with no motion and
    /// the new row grew from nothing in a gap already open.
    @Test(.enabled("needs an awake display and animations on") { await SidebarInsertWhileDisplayAsleepTests.animatesHere() })
    func aCmdNAtTheTopOfALongListPushesTheRowsOnTheirSprings() throws {
        let ids = Array(1...40)
        let (model, list, restore) = try Self.sidebar(ids, onScreen: true)
        defer { restore() }
        let clip = try #require(list.enclosingScrollView?.contentView)
        try #require(clip.bounds.minY < 1)
        let pushed = try #require(list.rowViews[try Self.key(1)])
        let sections = Self.sections([500] + ids)
        model.sections = sections
        model.activeWorkspaceID = try #require(sections.first?.workspaces.first?.id)
        list.reload(animated: true)
        #expect(clip.bounds.minY < 1, "the list scrolled")
        let springs = (pushed.layer?.animationKeys() ?? []).filter {
            (pushed.layer?.animation(forKey: $0) as? CASpringAnimation)?.keyPath == "position"
        }
        #expect(!springs.isEmpty, "the row below the new one did not move on a spring: the gap opened at once")
        #expect(list.openingRows[try Self.key(500)] != nil, "the new row did not open")
    }

    /// The rule for a row still opening: it moved by itself only when both rows beside it changed. An insert at the top
    /// pushes the rows (no neighbour change for any row both layouts list); a row whose neighbour moved away keeps the
    /// other one; a row taken out and put elsewhere changes both.
    @Test func aRowMovesByItselfOnlyWhenBothNeighboursChange() throws {
        func layout(_ ids: [Int]) -> SidebarLayout { SidebarLayout.make(sections: Self.sections(ids), metrics: .standard, options: SidebarLayoutOptions()) }
        let keys = try (1...12).map(Self.key) + [try Self.key(100), try Self.key(101)]
        #expect(SidebarListView.movedByThemselves(keys, from: layout(Array(1...10)), to: layout([11] + Array(1...10))).isEmpty,
                "an insert at the top moved rows by themselves")
        let appended = layout(Array(1...10) + [100, 101])
        #expect(SidebarListView.movedByThemselves(keys, from: appended, to: layout([1, 100] + Array(2...10) + [101])) == [try Self.key(100)],
                "only the row moved below 1 moved by itself")
        #expect(SidebarListView.movedByThemselves(keys, from: appended, to: layout(Array(1...10) + [101])).isEmpty,
                "a removal moved its neighbour by itself")
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
