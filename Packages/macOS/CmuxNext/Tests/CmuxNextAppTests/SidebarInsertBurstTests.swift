import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Cmd-N held (Lawrence 2026-10-28: "when i hold down cmd n ... i see empty space where workspaces should be, and only
/// after i stop cmd n, do the workspaces show up"; handoff/sidebar-burst-motion.md). Under key repeat each new
/// workspace lands at the top while the ones before it may still open. A row still opening that the next insert only
/// pushes down must keep its view, its content and its open: it must never start again from an empty, transparent
/// slot in a new view. Checked for every new row motion (`sidebar.insertMotion`), with `ui.animations.newWorkspace`
/// on (new workspace rows do not animate at all with it off, the default), in a window on an awake display: an apply
/// opens rows only where it can animate (`SidebarListView.apply`, `opensRows`).
@MainActor @Suite(.serialized, .closesItsWindows)
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

    /// Workspaces `ids` in a window on screen, the first selected, with new workspace rows opening on `motion` and
    /// Reduce Motion off. Returns the restore.
    private static func sidebar(_ ids: [Int], motion: SidebarInsertMotion) throws -> (SidebarModel, SidebarListView, restore: () -> Void) {
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
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarInsertMotion.tunable.key, .choice(motion.rawValue))
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = false
        return (model, sidebar.list, {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = kinds
            TunableStore.shared.set(SidebarInsertMotion.tunable.key, nil)
            window.close()
        })
    }

    /// Two quick Cmd-N at the top: the first new row, maybe still opening when the second lands, keeps its view (no
    /// new view, no reset to an empty, transparent slot) and shows its title.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() },
          arguments: SidebarInsertMotion.allCases)
    func aRowStillOpeningKeepsItsViewWhenTheNextInsertMovesIt(_ motion: SidebarInsertMotion) throws {
        let (model, list, restore) = try Self.sidebar(Array(1...10), motion: motion)
        defer { restore() }
        model.sections = Self.sections([100] + Array(1...10))
        list.reload(animated: true)
        let first = try Self.key(100)
        let view = try #require(list.rowViews[first], "the new row has no view")
        let opens = view.opens
        model.sections = Self.sections([101, 100] + Array(1...10))
        list.reload(animated: true)
        #expect(list.rowViews[first] === view, "\(motion): the next insert threw the opening row's view away")
        #expect(view.opens == opens, "\(motion): the next insert started the row's open again from an empty slot")
        let title = (view as? WorkspaceRowView)?.title.stringValue
        #expect(title == "w100", "\(motion): the moved row shows no title: \(String(describing: title))")
    }

    /// Thirty Cmd-N at the top, one per apply (key repeat), each selecting its new workspace as Cmd-N does: every row
    /// made so far that still shows keeps its one view and opened at most once.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() },
          arguments: SidebarInsertMotion.allCases)
    func thirtyQuickInsertsOpenEachRowOnce(_ motion: SidebarInsertMotion) throws {
        var ids = Array(1...5)
        let (model, list, restore) = try Self.sidebar(ids, motion: motion)
        defer { restore() }
        var views: [SidebarRowKey: SidebarRowView] = [:]
        var rebuilt = 0, reopened = 0
        for burst in 0..<30 {
            ids.insert(1_000 + burst, at: 0)
            let sections = Self.sections(ids)
            model.sections = sections
            if let id = sections.first?.workspaces.first?.id { model.activeWorkspaceID = id }
            list.reload(animated: true)
            let key = try Self.key(1_000 + burst)
            let made: SidebarRowView = try #require(list.rowViews[key], "\(motion): insert \(burst) has no view")
            views[key] = made
            for (key, view) in views where list.rowViews[key] != nil {
                if list.rowViews[key] !== view { rebuilt += 1 }
                if view.opens > 1 { reopened += 1 }
            }
        }
        #expect(rebuilt == 0, "\(motion): \(rebuilt) times an insert rebuilt a shown row's view")
        #expect(reopened == 0, "\(motion): \(reopened) times a shown row had opened more than once")
    }

    /// A row still opening that moves by itself (shown at the daemon's slot first, then placed below another row) opens
    /// again at its new slot in a new view, so it never crosses the list half open (cx-ai79); a row an insert above
    /// only pushes keeps its view (the burst case above).
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aRowStillOpeningThatMovesByItselfOpensAgainThere() throws {
        let (model, list, restore) = try Self.sidebar(Array(1...10), motion: .spring)
        defer { restore() }
        model.sections = Self.sections(Array(1...10) + [100])
        list.reload(animated: true)
        let moved = try Self.key(100)
        let view = try #require(list.rowViews[moved])
        let opened = try #require(list.openingRows[moved], "the appended row did not open")
        model.sections = Self.sections([1, 100] + Array(2...10))
        list.reload(animated: true)
        let again = try #require(list.rowViews[moved])
        #expect(again !== view, "a row that moved by itself flew across the list half open")
        #expect(again.opens == 1, "it did not open again at its new slot")
        #expect((list.openingRows[moved]?.until ?? 0) >= opened.until, "its open did not start again")
    }

    /// Cmd-N with the list scrolled away from its top: the reveal jumps to the new row at the top, so its gap is open in
    /// that frame. The row is in its slot, whole, in that frame (it does not grow from nothing in the open gap).
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() },
          arguments: [SidebarInsertMotion.nudge, .quick, .spring])
    func aCmdNTheRevealJumpsToShowsTheNewRowWhole(_ motion: SidebarInsertMotion) throws {
        let ids = Array(1...40)
        let (model, list, restore) = try Self.sidebar(ids, motion: motion)
        defer { restore() }
        let clip = try #require(list.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 900))
        list.enclosingScrollView?.reflectScrolledClipView(clip)
        try #require(clip.bounds.minY > 400, "the list did not scroll")
        let sections = Self.sections([500] + ids)
        model.sections = sections
        model.activeWorkspaceID = try #require(sections.first?.workspaces.first?.id)
        list.reload(animated: true)
        #expect(clip.bounds.minY < 1, "\(motion): the reveal did not show the new row")
        let key = try Self.key(500)
        let view = try #require(list.rowViews[key], "\(motion): the new row has no view")
        #expect(view.opens == 0 && view.alphaValue == 1,
                "\(motion): the new row grows from an empty slot (opens \(view.opens), alpha \(view.alphaValue))")
        #expect(list.openingRows[key] == nil, "\(motion): the new row is still opening")
        #expect(view.frame == list.frame(for: try #require(list.displayed.row(for: key))), "\(motion): the new row is not in its slot")
    }

    /// A new row inserted just below the viewport (a new workspace after the current one near the bottom): the reveal
    /// scrolls a little, and the row, drawn in this apply, opens with its gap, so the row below it, which springs down
    /// from the new row's slot, never draws over a whole row.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func aNewRowJustBelowTheViewportOpensWithItsGap() throws {
        var ids = Array(1...40)
        let (model, list, restore) = try Self.sidebar(ids, motion: .spring)
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

    /// The rule for a row still opening: it moved by itself only when both rows beside it changed. An insert at the top
    /// pushes the rows (no neighbour change for any row both layouts list); a row whose neighbour moved away keeps the
    /// other one; a row taken out and put elsewhere changes both.
    @Test func aRowMovesByItselfOnlyWhenBothNeighboursChange() throws {
        func layout(_ ids: [Int]) -> SidebarLayout {
            SidebarLayout.make(sections: Self.sections(ids), metrics: .standard, options: SidebarLayoutOptions())
        }
        let keys = try (1...12).map(Self.key) + [try Self.key(100), try Self.key(101)]
        #expect(SidebarListView.movedByThemselves(keys, from: layout(Array(1...10)), to: layout([11] + Array(1...10))).isEmpty,
                "an insert at the top moved rows by themselves")
        let appended = layout(Array(1...10) + [100, 101])
        #expect(SidebarListView.movedByThemselves(keys, from: appended, to: layout([1, 100] + Array(2...10) + [101])) == [try Self.key(100)],
                "only the row moved below 1 moved by itself")
        #expect(SidebarListView.movedByThemselves(keys, from: appended, to: layout(Array(1...10) + [101])).isEmpty,
                "a removal moved its neighbour by itself")
    }
}
