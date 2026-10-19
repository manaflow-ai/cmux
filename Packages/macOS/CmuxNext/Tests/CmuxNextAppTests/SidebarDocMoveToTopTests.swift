import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// Move Workspace to Top on the sidebar document (Lawrence 2026-10-18: "I
/// did Move to Top but it didn't move all the way to the top"). The verb
/// resolves `WorkspaceSlot.top` to slot 0 of the machine section and the
/// document drag turns that slot into an anchor (`SidebarDocDrag.target`).
/// When this client held no document item for the loose rows above the
/// groups (they list, but `item` answers nil), those rows fell out of the
/// count: slot 0 became the first group, and the workspace landed right above
/// it, below every loose row. A row with no item counts with the item id its
/// adopt gives it, so slot 0 is the first row the person sees.
@MainActor @Suite struct SidebarDocMoveToTopTests {
    static let session = "s-local"
    static let docSection = "sec_m_s-local"
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// Loose `first` and `second`, group `g` (member `c`), loose `moved`, in that order.
    static func model() -> SidebarModel {
        let row = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        return SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(row("first")), .workspace(row("second")),
                .group(SidebarGroup(id: GroupID("itm_g_g"), name: "g", workspaces: [row("c")])),
                .workspace(row("moved")),
            ]),
        ], activeWorkspaceID: nil)
    }

    static func ref(_ id: WorkspaceID) -> [String: String] {
        ["session_id": session, "workspace_id": id.rawValue, "workspace_key": id.rawValue]
    }

    /// A drag where `placed` rows have document items and every row has an adopt ref.
    static func drag(placed: Set<String>) -> SidebarDocDrag {
        SidebarDocDrag(item: { key in
            switch key {
            case .workspace(let id): placed.contains(id.rawValue) ? "itm_\(id.rawValue)" : nil
            case .group(let group): group.rawValue
            default: nil
            }
        }, section: { _ in docSection }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { ref($0) })
    }

    /// Where Move to Top sends `moved`, as `WorkspaceVerbHandlers.place` resolves it.
    static func moveToTop(_ drag: SidebarDocDrag) throws -> SidebarDocTarget {
        let model = model()
        let position = try #require(WorkspaceSlot.top(anchor: "moved").position(moving: ["moved"], section: .machine(.local), in: model.sections))
        #expect(position.index == 0 && position.group == nil, "Move to Top is slot 0 of the loose rows")
        return try #require(drag.target(position, moving: [drag.item(.workspace(WorkspaceID("moved"))) ?? "itm_moved"], model: model))
    }

    @Test func moveToTopAnchorsBeforeTheFirstRowWhenEveryRowHasAnItem() throws {
        let target = try Self.moveToTop(Self.drag(placed: ["first", "second", "c", "moved"]))
        #expect(target == SidebarDocTarget(section: Self.docSection, before: "itm_first"))
    }

    @Test func moveToTopAnchorsBeforeTheFirstRowEvenWithoutItsItemHere() throws {
        // The client has items for the group and the moved row only: the two loose rows above the group list,
        // but `item` answers nil for them.
        let target = try Self.moveToTop(Self.drag(placed: ["c", "moved"]))
        let first = SidebarDocStore.adoptedID(SidebarDocWorkspaceRef(sessionID: Self.session, workspaceID: "first"))
        #expect(target.before == first, "Move to Top went before \(target.before ?? target.after ?? "nothing"), not the first row")
    }

    @Test func anAnchorWithoutItsItemHereIsAdoptedWithTheMove() throws {
        let drag = Self.drag(placed: ["c", "moved"])
        let model = Self.model()
        let position = try #require(WorkspaceSlot.top(anchor: "moved").position(moving: ["moved"], section: .machine(.local), in: model.sections))
        let anchored = try #require(drag.anchoredTarget(position, moving: ["itm_moved"], model: model))
        #expect(anchored.adopt == [Self.ref(WorkspaceID("first"))], "the anchor the client has no item for is not adopted first")
        // An anchor the client has an item for needs no adopt.
        let placed = try #require(Self.drag(placed: ["first", "second", "c", "moved"]).anchoredTarget(position, moving: ["itm_moved"], model: model))
        #expect(placed.adopt.isEmpty)
    }
}
