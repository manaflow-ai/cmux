@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: the sidebar keeps the order the user made. A drag sticks and no row state
/// (unread, waiting, failed, working, done) moves a row; those show as badges, and attention order
/// lives only in the Priority view. Before, `SidebarRows` re-sorted every rebuild by attention
/// while `notifications.attention.moveToTop` was on (the default), so a drag lost to the next state change.
@MainActor @Suite(.serialized)
struct SidebarManualOrderTests {
    /// The local machine's section with the workspaces `ids`, in that order.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// Every row but the first of `sections` with a state that asks for attention.
    private static func flagged(_ sections: [CmuxNextSidebar.SidebarSection]) -> [CmuxNextSidebar.SidebarWorkspace] {
        let states: [(inout CmuxNextSidebar.SidebarWorkspace) -> Void] = [
            { $0.unread = .dot }, { $0.activity = .waiting(kind: nil) }, { $0.activity = .error }, { $0.activity = .working(progress: nil) },
        ]
        return sections[0].workspaces.dropFirst().enumerated().map { offset, row in
            var row = row
            states[offset % states.count](&row)
            return row
        }
    }

    private static func order(_ model: SidebarModel) -> [String] {
        model.sections.flatMap(\.workspaces).map(\.title)
    }

    @Test func aDraggedRowStaysFirstWhileTheOthersAskForAttention() {
        let design = DesignSettings.shared
        let moved = design.attention.movesToTop
        defer { design.attention.movesToTop = moved }
        design.attention.movesToTop = true

        let start = Self.sections([1, 2, 3, 4, 5])
        let model = SidebarModel(sections: [])
        let rows = SidebarRows(model: model, document: { nil })
        rows.show(start)
        #expect(Self.order(model) == ["w1", "w2", "w3", "w4", "w5"])

        // The drag: row 5 to row 1, shown before the daemon replies.
        let five = start[0].workspaces[4].id
        let drag = rows.edits.add(.reorder([five], to: DropPosition(section: start[0].id, index: 0)))
        let dragged = ["w5", "w1", "w2", "w3", "w4"]
        #expect(Self.order(model) == dragged)

        // Every other row turns unread, waiting, failed or working, written in place.
        rows.patch(Self.flagged(start))
        #expect(Self.order(model) == dragged, "a row state moved a row during the drag")

        // The daemon holds the drag; its rows arrive with the states, and the edit settles.
        let held = Self.sections([5, 1, 2, 3, 4])
        rows.show(CmuxNextSidebar.SidebarSection.patching(Self.flagged(held), in: held))
        rows.edits.settle(drag)
        #expect(Self.order(model) == dragged, "a row state moved a row after the drag")

        rows.patch(Self.flagged(held).map { var row = $0; row.activity = .success; return row })
        #expect(Self.order(model) == dragged, "a finished agent moved its row")
    }
}
