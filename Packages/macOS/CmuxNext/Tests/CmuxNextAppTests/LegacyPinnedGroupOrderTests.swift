@testable import CmuxNextSidebar
import Testing

/// Pinned groups list first on daemons without the sidebar document too (a219's report, 2026-10-20: there,
/// a group's pin was only "keep it when its workspaces close" and the group stayed where it was). The legacy
/// projection (`SidebarSection.pinnedFirst`) lifts each pinned group to the top of its own section, in
/// their order, as the document lists pinned groups first (plans/cmux-next/pinning-DESIGN.md).
@Suite struct LegacyPinnedGroupOrderTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func group(_ id: String, pinned: Bool) -> SidebarNode {
        .group(SidebarGroup(id: GroupID(id), name: id, isPinned: pinned, workspaces: [row("\(id)-member")]))
    }

    static func order(_ sections: [SidebarSection]) -> [String] {
        sections.flatMap(\.nodes).map { node in
            switch node {
            case .workspace(let workspace): workspace.id.rawValue
            case .group(let group): group.id.rawValue
            case .item(let item): item.id
            }
        }
    }

    @Test func pinnedGroupsListFirstInTheirSection() {
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.row("a")), Self.group("g1", pinned: false), Self.group("g2", pinned: true),
            .workspace(Self.row("b")), Self.group("g3", pinned: true),
        ])]
        let shown = SidebarSection.pinnedFirst(sections, pinned: [])
        #expect(Self.order(shown) == ["g2", "g3", "a", "g1", "b"])
    }

    @Test func withNoPinnedGroupNothingMoves() {
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.row("a")), Self.group("g1", pinned: false)])]
        #expect(Self.order(SidebarSection.pinnedFirst(sections, pinned: [])) == ["a", "g1"])
    }
}
