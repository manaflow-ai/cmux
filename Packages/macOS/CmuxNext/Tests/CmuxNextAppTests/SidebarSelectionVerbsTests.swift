import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// Workspace verbs on a multi-selection and the group-only sort (plans/cmux-next/sidebar-ordering-AUDIT.md,
/// follow-up to u2418). A row's menu verb (Move Up/Down, Pin, Duplicate, Close) acts on every
/// selected row when the right-clicked row is one of two or more selected rows
/// (`SidebarModel.actionTargets`); Move Up/Down moves that block one slot, as Cmd-Opt-Up/Down does.
/// Sort Group sorts only that group's members (`WorkspaceSortKey.containers`).
@MainActor @Suite struct SidebarSelectionVerbsTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let g1 = GroupID("g1"), g2 = GroupID("g2")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func loose(_ ids: [String]) -> SidebarModel {
        SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: ids.map { .workspace(row($0)) })], activeWorkspaceID: nil)
    }

    static func order(_ model: SidebarModel) -> [String] { model.allWorkspaces.map(\.id.rawValue) }

    @Test func singularActivationReplacesAStaleMultiSelection() {
        let model = Self.loose(["a", "b", "c"])
        model.activeWorkspaceID = WorkspaceID("a")
        model.selection = [WorkspaceID("a"), WorkspaceID("b")]

        model.apply(.select(WorkspaceID("a")))
        #expect(model.activeWorkspaceID == WorkspaceID("a"))
        #expect(model.selection == [WorkspaceID("a")])

        model.selection = [WorkspaceID("a"), WorkspaceID("b")]
        model.apply(.select(WorkspaceID("c")))
        #expect(model.activeWorkspaceID == WorkspaceID("c"))
        #expect(model.selection == [WorkspaceID("c")])
    }

    @Test func deselectingTheActiveWorkspaceKeepsTheRemainingSelection() {
        let model = Self.loose(["a", "b", "c"])
        model.activeWorkspaceID = WorkspaceID("a")
        model.selection = [WorkspaceID("a"), WorkspaceID("b"), WorkspaceID("c")]
        model.onIntent = { model.apply($0) }

        model.toggleSelection(WorkspaceID("a"))
        #expect(model.activeWorkspaceID == WorkspaceID("b"))
        #expect(model.selection == [WorkspaceID("b"), WorkspaceID("c")])
    }

    @Test func aSelectedRowsVerbTargetsTheWholeSelectionInRowOrder() {
        let model = Self.loose(["a", "b", "c", "d"])
        model.selection = [WorkspaceID("c"), WorkspaceID("a")]
        #expect(model.actionTargets(for: WorkspaceID("c")).map(\.rawValue) == ["a", "c"])
        // A row outside the selection, or a selection of one, acts alone.
        #expect(model.actionTargets(for: WorkspaceID("b")).map(\.rawValue) == ["b"])
        model.selection = [WorkspaceID("a")]
        #expect(model.actionTargets(for: WorkspaceID("a")).map(\.rawValue) == ["a"])
    }

    @Test func moveUpOnASelectedRowMovesTheBlockOneSlot() {
        let model = Self.loose(["a", "b", "c", "d"])
        model.selection = [WorkspaceID("b"), WorkspaceID("c")]
        #expect(model.moveActionTargets(of: WorkspaceID("c"), .up))
        #expect(Self.order(model) == ["b", "c", "a", "d"])
        #expect(!model.moveActionTargets(of: WorkspaceID("b"), .up), "the block is at the top")
    }

    @Test func moveDownOnASelectedRowMovesTheBlockOneSlot() {
        let model = Self.loose(["a", "b", "c", "d"])
        model.selection = [WorkspaceID("b"), WorkspaceID("c")]
        #expect(model.moveActionTargets(of: WorkspaceID("b"), .down))
        #expect(Self.order(model) == ["a", "d", "b", "c"])
    }

    @Test func moveOnARowOutsideTheSelectionMovesThatRowAlone() {
        let model = Self.loose(["a", "b", "c", "d"])
        model.selection = [WorkspaceID("a"), WorkspaceID("b")]
        #expect(model.moveActionTargets(of: WorkspaceID("d"), .up))
        #expect(Self.order(model) == ["a", "b", "d", "c"])
    }

    /// Pin on a selection is one undo step: `pinOps` plans every row's tile change against the
    /// document as the earlier ones leave it, so the batch goes out (and undoes) as one change.
    /// Planned one by one against the same document, two pins with no Pinned section yet both
    /// add that section, and the second is rejected.
    @Test(arguments: [true, false])
    func pinningASelectionIsOneBatchOfOps(hasPinnedSection: Bool) throws {
        var document = SidebarLayoutDocument.defaults
        if !hasPinnedSection { document = SidebarLayoutDocument(sections: document.sections.filter { $0.id != SidebarLayoutDocument.pinnedSectionID }) }
        let refs = ["a", "b"].map(LayoutItemRef.workspace)
        let pin = document.pinOps(refs.map { ($0, nil) }, pinned: true)
        #expect(pin.count == 2)
        for op in pin { document = try SidebarLayoutReducer.reduce(document, op).get() }
        #expect(refs.allSatisfy(document.isPinned))
        #expect(document.pinOps(refs.map { ($0, nil) }, pinned: true).isEmpty, "both already pinned")
        let unpin = document.pinOps(refs.map { ($0, nil) }, pinned: false)
        #expect(unpin.count == 2)
        for op in unpin { document = try SidebarLayoutReducer.reduce(document, op).get() }
        #expect(!refs.contains(where: document.isPinned))
    }

    /// Loose `z`, `a`; group `g1` (`c`, `b`); group `g2` (`y`, `x`).
    static func sorting() -> SidebarSection {
        SidebarSection(kind: .machine(machine), nodes: [
            .workspace(row("z")), .workspace(row("a")),
            .group(SidebarGroup(id: g1, name: "one", workspaces: [row("c"), row("b")])),
            .group(SidebarGroup(id: g2, name: "two", workspaces: [row("y"), row("x")])),
        ])
    }

    @Test func sortGroupSortsOnlyThatGroupsMembers() {
        let only = WorkspaceSortKey.containers(of: Self.sorting(), only: Self.g1)
        #expect(only.count == 1)
        #expect(only.first?.group == Self.g1 && only.first?.ids == ["c", "b"])
        let names = Dictionary(uniqueKeysWithValues: ["z", "a", "c", "b", "y", "x"].map { ($0, $0) })
        let sorted = WorkspaceSortKey.name.sorted(only.first?.ids ?? [], names: names, directories: [:], recency: [])
        #expect(sorted == ["b", "c"])
    }

    @Test func sortWorkspacesSortsEveryContainer() {
        let all = WorkspaceSortKey.containers(of: Self.sorting(), only: nil)
        #expect(all.map(\.group) == [nil, Self.g1, Self.g2])
        #expect(all.map(\.ids) == [["z", "a"], ["c", "b"], ["y", "x"]])
    }
}
