import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// "there is so many weird animations in the sidebar where i create a new workspace or close and the sidebar items
/// just keep moving around" (2026-10-20). With attention ordering on (the default), a row's status change (unread,
/// waiting, working, done) was written in place and its re-sort waited for the next rebuild: the user's next create or
/// close, which then slid every row whose attention changed since. Now the re-sort shows when the status changes, in
/// one step, and a create moves only its own row.
@MainActor @Suite(.serialized)
struct SidebarAttentionResortTests {
    /// The local machine's section with the workspaces `ids`, in that order.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// Row `index` of `sections` with an agent waiting on the user.
    private static func waiting(_ sections: [CmuxNextSidebar.SidebarSection], _ index: Int) -> CmuxNextSidebar.SidebarWorkspace {
        var row = sections[0].workspaces[index]
        row.activity = .waiting(kind: nil)
        return row
    }

    private static func order(_ model: SidebarModel) -> [String] {
        model.sections.flatMap(\.workspaces).map(\.name)
    }

    /// The workspace rows not yet at their slots (on a spring), other than `except`.
    private static func rowMotion(in list: SidebarListView, except: Set<CmuxNextSidebar.WorkspaceID>) -> [String] {
        list.displayed.rows.compactMap { row -> String? in
            guard case let .workspace(id) = row.key, !except.contains(id), let view = list.rowViews[row.key] else { return nil }
            let target = list.frame(for: row)
            return abs(view.frame.minY - target.minY) > 0.5 || view.alphaValue < 0.99 ? "\(row.key) at \(view.frame.minY), slot \(target.minY)" : nil
        }
    }

    @Test func anAttentionChangeReordersWhenItArrivesNotAtTheNextCreate() throws {
        try #require(DesignSettings.shared.attention.movesToTop, "attention ordering is off by default now: this test is moot")
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: [])
        let rows = SidebarRows(model: model)
        rows.show(start)
        #expect(Self.order(model) == ["w1", "w2", "w3", "w4"])

        // An agent in w4 asks for input: the row goes up now, not when the user next makes or closes a workspace.
        rows.patch([Self.waiting(start, 3)])
        #expect(Self.order(model) == ["w4", "w1", "w2", "w3"], "the attention change waited for the next rebuild")

        // The user's create: only the new row is added; the others keep the order they show.
        var created = Self.sections([1, 2, 3, 4, 5])
        created = CmuxNextSidebar.SidebarSection.patching([Self.waiting(created, 3)], in: created)
        rows.show(created)
        #expect(Self.order(model) == ["w4", "w1", "w2", "w3", "w5"])
    }

    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aCreateAfterAnAttentionChangeSlidesNoOtherRow() throws {
        try #require(DesignSettings.shared.attention.movesToTop)
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: [])
        let rows = SidebarRows(model: model)
        rows.show(start)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try #require(window.screen != nil)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false, fromModel: true)
        sidebar.list.pointerIsOverList = { _ in false }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        // The user clicked a moment ago; then an agent in w4 asks for input. Its re-sort is nobody's request: no spring.
        model.noteUserIntent()
        rows.patch([Self.waiting(start, 3)])
        sidebar.renderNow()
        #expect(Self.rowMotion(in: sidebar.list, except: []).isEmpty, "an attention re-sort slid rows: \(Self.rowMotion(in: sidebar.list, except: []))")

        // Cmd-N: the new row may open, and no other row moves.
        var created = Self.sections([1, 2, 3, 4, 5])
        created = CmuxNextSidebar.SidebarSection.patching([Self.waiting(created, 3)], in: created)
        let new = try #require(created[0].workspaces.last?.id)
        model.noteUserIntent()
        rows.show(created)
        sidebar.renderNow()
        #expect(Self.rowMotion(in: sidebar.list, except: [new]).isEmpty,
                "the create slid other rows: \(Self.rowMotion(in: sidebar.list, except: [new]))")
    }
}
