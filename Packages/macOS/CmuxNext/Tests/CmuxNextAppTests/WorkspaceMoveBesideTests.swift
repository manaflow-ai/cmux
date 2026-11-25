import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// `cmux workspace move-above|move-below --target ws --anchor ws` (cmux#29907): the CLI
/// can drop a workspace next to any row, as a drag does, so a script reaches every
/// place a person can put a workspace in the personal sidebar order, including a
/// place inside a group and out of one.
@Suite struct WorkspaceMoveBesideTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let group = GroupID("g")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Loose `a`, `b`, `c`, then group `g` (`x`, `y`); a custom section "Work" lists `w`.
    static func sections() -> [SidebarSection] {
        [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(row("a")), .workspace(row("b")), .workspace(row("c")),
                .group(SidebarGroup(id: group, name: "g", workspaces: [row("x"), row("y")])),
            ]),
            SidebarSection(kind: .custom(SidebarCustomSection(id: "sec_work", title: "Work", showsTitle: true)), nodes: [
                .workspace(row("w")),
            ]),
        ]
    }

    static func apply(_ moving: String, _ position: DropPosition) -> [SidebarSection] {
        var sections = Self.sections()
        #expect(SidebarEdits.apply(.reorder([WorkspaceID(moving)], to: position), to: &sections))
        return sections
    }

    static func loose(_ sections: [SidebarSection]) -> [String] {
        sections[0].nodes.compactMap { if case let .workspace(ws) = $0 { ws.id.rawValue } else { nil } }
    }

    static func grouped(_ sections: [SidebarSection]) -> [String] {
        for case let .group(group) in sections[0].nodes { return group.workspaces.map(\.id.rawValue) }
        return []
    }

    @Test func aboveALooseRowReordersTheLooseRows() throws {
        let position = try WorkspaceSlot.beside("a", below: false, moving: "c", in: Self.sections(), onDocument: false).get()
        #expect(position == DropPosition(section: .machine(.local), index: 0))
        #expect(Self.loose(Self.apply("c", position)) == ["c", "a", "b"])
    }

    @Test func belowALooseRowCountsWithoutTheMovingRow() throws {
        let position = try WorkspaceSlot.beside("b", below: true, moving: "a", in: Self.sections(), onDocument: false).get()
        #expect(Self.loose(Self.apply("a", position)) == ["b", "a", "c"])
    }

    @Test func nextToAGroupedRowMovesIntoTheGroupThere() throws {
        let position = try WorkspaceSlot.beside("y", below: false, moving: "b", in: Self.sections(), onDocument: false).get()
        #expect(position == DropPosition(section: .machine(.local), group: Self.group, index: 1))
        let after = Self.apply("b", position)
        #expect(Self.grouped(after) == ["x", "b", "y"])
        #expect(Self.loose(after) == ["a", "c"])
    }

    @Test func nextToALooseRowTakesAGroupedRowOutOfItsGroup() throws {
        let position = try WorkspaceSlot.beside("a", below: true, moving: "x", in: Self.sections(), onDocument: false).get()
        let after = Self.apply("x", position)
        #expect(Self.loose(after) == ["a", "x", "b", "c"])
        #expect(Self.grouped(after) == ["y"])
    }

    @Test func aCustomSectionReordersOnlyOnTheSidebarDocument() {
        var sections = Self.sections()
        sections[1].nodes.append(.workspace(Self.row("v")))
        #expect(WorkspaceSlot.beside("w", below: false, moving: "v", in: sections, onDocument: false) == .failure(.needsDocument))
        #expect(WorkspaceSlot.beside("w", below: false, moving: "v", in: sections, onDocument: true)
            == .success(DropPosition(section: .custom("sec_work"), index: 0)))
    }

    @Test func refusesItselfAnotherSectionAndUnlistedRows() {
        #expect(WorkspaceSlot.beside("a", below: false, moving: "a", in: Self.sections(), onDocument: false) == .failure(.elsewhere))
        #expect(WorkspaceSlot.beside("w", below: false, moving: "a", in: Self.sections(), onDocument: false) == .failure(.elsewhere))
        #expect(WorkspaceSlot.beside("a", below: false, moving: "gone", in: Self.sections(), onDocument: false) == .failure(.elsewhere))
        #expect(WorkspaceSlot.beside("gone", below: false, moving: "a", in: Self.sections(), onDocument: false) == .failure(.elsewhere))
    }
}
