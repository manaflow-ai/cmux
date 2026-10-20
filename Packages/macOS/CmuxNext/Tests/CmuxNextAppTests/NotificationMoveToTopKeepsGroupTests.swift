import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// A notification moves its workspace to the top of its container (`notifications.attention.moveToTop`)
/// through `WorkspaceVerbHandlers.place` (Austin 2026-10-20: "when my notification hits, sometimes my
/// workspaces just leave the group that it is in"). The verb resolved `WorkspaceSlot.top` against the
/// workspace's machine section only. A workspace listed in another section (a custom sidebar section),
/// or not listed in that window's sidebar at all, had no group there, so the slot became the top of the
/// machine's loose rows and the move took the workspace out of its group.
@Suite struct NotificationMoveToTopKeepsGroupTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let group = GroupID("g")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// The machine section with loose `a`, and a custom section "Work" with loose `b` and group `g` (`c`, `n`).
    static func sections() -> [SidebarSection] {
        [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(row("a"))]),
            SidebarSection(kind: .custom(SidebarCustomSection(id: "sec_work", title: "Work", showsTitle: true)), nodes: [
                .workspace(row("b")),
                .group(SidebarGroup(id: group, name: "g", workspaces: [row("c"), row("n")])),
            ]),
        ]
    }

    @Test func topOfAGroupInACustomSectionStaysInTheGroup() throws {
        var sections = Self.sections()
        let position = try #require(WorkspaceSlot.top(anchor: "n").position(moving: ["n"], besides: "n", in: sections))
        #expect(position == DropPosition(section: .custom("sec_work"), group: Self.group, index: 0))
        #expect(SidebarEdits.apply(.reorder([WorkspaceID("n")], to: position), to: &sections))
        guard case let .group(group) = sections[1].nodes[1] else { Issue.record("the group is gone"); return }
        #expect(group.workspaces.map(\.id.rawValue) == ["n", "c"])
        #expect(sections[0].nodes.count == 1, "nothing lands in the machine section")
    }

    @Test func topOfAGroupInTheMachineSectionStaysInTheGroup() throws {
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.row("a")),
            .group(SidebarGroup(id: Self.group, name: "g", isCollapsed: true, workspaces: [Self.row("c"), Self.row("n")])),
        ])]
        let position = try #require(WorkspaceSlot.top(anchor: "n").position(moving: ["n"], besides: "n", in: sections))
        #expect(position == DropPosition(section: .machine(.local), group: Self.group, index: 0))
    }

    @Test func aWorkspaceTheSidebarDoesNotListHasNoSlot() {
        #expect(WorkspaceSlot.top(anchor: "gone").position(moving: ["gone"], besides: "gone", in: Self.sections()) == nil)
    }
}
