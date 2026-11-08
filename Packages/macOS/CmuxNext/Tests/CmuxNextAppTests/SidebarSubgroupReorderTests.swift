import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// Cmd-Opt-Up/Down and Move Group Up/Down with nested groups (QA spree 2026-10-23, F8). Nested
/// groups list flat after their parent and draw inside it, but both moves counted the section's
/// rows flat: the slot before a subgroup named it as a top-level sibling (a move the document
/// refuses, so the key did nothing), a workspace below a collapsed group stepped up into a
/// subgroup hidden under it (it vanished from the list), Move Group Down on a group with a
/// subgroup moved it nowhere, and Move Group Up on the group below it went nowhere either.
@MainActor @Suite struct SidebarSubgroupReorderTests {
    static let docSection = "sec_m_s-local"
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let g = GroupID("itm_g"), s = GroupID("itm_s"), h = GroupID("itm_h")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Loose `a`; group `g` (`c`) with subgroup `s` (`d`); group `h` (`e`); loose `z`.
    static func model(gCollapsed: Bool = false) -> SidebarModel {
        var sub = SidebarGroup(id: s, name: "s", workspaces: [row("d")])
        (sub.parent, sub.depth) = (g, 1)
        return SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(row("a")),
                .group(SidebarGroup(id: g, name: "g", isCollapsed: gCollapsed, workspaces: [row("c")])),
                .group(sub),
                .group(SidebarGroup(id: h, name: "h", workspaces: [row("e")])),
                .workspace(row("z")),
            ]),
        ], activeWorkspaceID: nil)
    }

    static let drag = SidebarDocDrag(item: { key in
        switch key {
        case .workspace(let id): "itm_\(id.rawValue)"
        case .group(let group): group.rawValue
        default: nil
        }
    }, section: { _ in docSection }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })

    /// The document move Cmd-Opt-Up/Down sends for workspace `id`, or nil when the key does nothing.
    static func keyMove(_ id: String, _ direction: KeyboardReorder.Direction, gCollapsed: Bool = false) -> SidebarDocTarget? {
        let model = model(gCollapsed: gCollapsed)
        guard let position = KeyboardReorder.target(moving: [WorkspaceID(id)], direction: direction, in: model.sections) else { return nil }
        return drag.anchoredTarget(position, moving: ["itm_\(id)"], model: model)?.target
    }

    /// The document move Move Group Up/Down/Top/Bottom sends for `group`, or nil when it refuses.
    static func groupMove(_ group: GroupID, _ move: SidebarGroupMove) -> SidebarDocTarget? {
        let model = model()
        guard let index = SidebarEdits.groupIndex(group, move, in: model.sections) else { return nil }
        let section = model.sections[0].id
        return drag.anchoredTarget(DropPosition(section: section, index: index), moving: [group.rawValue], model: model)?.target
    }

    @Test func movingDownFromAGroupsLastMemberEntersItsSubgroup() {
        #expect(Self.keyMove("c", .down) == SidebarDocTarget(section: Self.docSection, parent: Self.s.rawValue, before: "itm_d"))
    }

    @Test func movingDownFromASubgroupsLastMemberLeavesTheWholeGroup() {
        #expect(Self.keyMove("d", .down) == SidebarDocTarget(section: Self.docSection, before: Self.h.rawValue))
    }

    @Test func movingUpFromAGroupsFirstMemberLeavesItAboveItsHeader() {
        #expect(Self.keyMove("e", .up) == SidebarDocTarget(section: Self.docSection, before: Self.h.rawValue))
    }

    // The slot rules themselves (a subgroup's gap is inside its parent, a hidden subgroup has none) are the shared
    // Rust rules' tests (cmux-layout-reducer `sidebar_edits::tests`); these check the document move they lead to.
    @Test func movingUpFromBelowAGroupEntersItsEnd() {
        #expect(Self.keyMove("z", .up) == SidebarDocTarget(section: Self.docSection, parent: Self.h.rawValue, after: "itm_e"))
    }

    @Test func aSubgroupUnderACollapsedGroupIsSteppedOver() {
        // Before: loose `a` moving down named hidden subgroup `s` as a top-level row (refused), then entered it.
        #expect(Self.keyMove("a", .down, gCollapsed: true) == SidebarDocTarget(section: Self.docSection, before: Self.h.rawValue))
    }

    @Test func aTopLevelSlotBeforeASubgroupAnchorsAtTheNextTopLevelRow() throws {
        let model = Self.model()
        let target = try #require(Self.drag.anchoredTarget(DropPosition(section: model.sections[0].id, index: 2), moving: ["itm_z"], model: model))
        #expect(target.target == SidebarDocTarget(section: Self.docSection, before: Self.h.rawValue))
    }

    @Test func moveGroupDownPassesTheNextGroupWhole() {
        #expect(Self.groupMove(Self.g, .down) == SidebarDocTarget(section: Self.docSection, before: "itm_z"))
    }

    @Test func moveGroupUpAnchorsAboveTheGroupNotItsSubgroup() {
        #expect(Self.groupMove(Self.h, .up) == SidebarDocTarget(section: Self.docSection, before: Self.g.rawValue))
    }

    @Test func moveGroupToBottomGoesAfterTheLastTopLevelRow() {
        #expect(Self.groupMove(Self.g, .bottom) == SidebarDocTarget(section: Self.docSection, after: "itm_z"))
        #expect(Self.groupMove(Self.g, .top) == SidebarDocTarget(section: Self.docSection, before: "itm_a"))
    }

    @Test func aSubgroupIsNotMovedOutOfItsParent() {
        #expect(Self.groupMove(Self.s, .up) == nil)
        #expect(Self.groupMove(Self.s, .down) == nil)
    }
}
