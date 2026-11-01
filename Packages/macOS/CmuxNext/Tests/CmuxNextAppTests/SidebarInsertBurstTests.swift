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
            views[key] = try #require(list.rowViews[key], "\(motion): insert \(burst) has no view")
            for (key, view) in views where list.rowViews[key] != nil {
                if list.rowViews[key] !== view { rebuilt += 1 }
                if view.opens > 1 { reopened += 1 }
            }
        }
        #expect(rebuilt == 0, "\(motion): \(rebuilt) times an insert rebuilt a shown row's view")
        #expect(reopened == 0, "\(motion): \(reopened) times a shown row had opened more than once")
    }
}
