@testable import CmuxNextSidebar
import Testing

/// Shift+Up/Down selects the range from where it started to the new row, as
/// in Finder: going back shrinks it. Before, Shift+Down three times then
/// Shift+Up left all four rows selected, and a row still being created
/// stopped Shift+Down short of the rows after it (QA spree 2026-10-21).
@MainActor struct SidebarShiftArrowRangeTests {
    static let ids = ["a", "b", "c", "d", "e"].map(WorkspaceID.init)

    static func model(creating: Set<String> = []) -> SidebarModel {
        let rows = ids.map { SidebarWorkspace(id: $0, title: $0.rawValue, rowState: creating.contains($0.rawValue) ? .creating : .live) }
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: rows.map { .workspace($0) })
        let model = SidebarModel(sections: [section], activeWorkspaceID: ids[0])
        model.click(ids[0])
        return model
    }

    static func selected(_ model: SidebarModel) -> [String] { model.selection.map(\.rawValue).sorted() }

    @Test func goingBackShrinksTheRange() {
        let model = Self.model()
        for _ in 0..<3 { model.moveActive(by: 1, extending: true, visibleOrder: Self.ids) }
        #expect(Self.selected(model) == ["a", "b", "c", "d"])
        model.moveActive(by: -1, extending: true, visibleOrder: Self.ids)
        #expect(Self.selected(model) == ["a", "b", "c"])
        #expect(model.activeWorkspaceID == WorkspaceID("c"))
    }

    @Test func crossingTheAnchorFlipsTheRange() {
        let model = Self.model()
        model.click(Self.ids[2])
        model.moveActive(by: 1, extending: true, visibleOrder: Self.ids)
        model.moveActive(by: -1, extending: true, visibleOrder: Self.ids)
        model.moveActive(by: -1, extending: true, visibleOrder: Self.ids)
        #expect(Self.selected(model) == ["b", "c"])
    }

    @Test func aRowBeingCreatedIsSteppedOver() {
        let model = Self.model(creating: ["b"])
        model.moveActive(by: 1, extending: true, visibleOrder: Self.ids)
        #expect(Self.selected(model) == ["a", "c"])
        #expect(!model.selection.contains(WorkspaceID("b")))
    }

    @Test func aPlainArrowStartsANewRange() {
        let model = Self.model()
        model.moveActive(by: 1, extending: true, visibleOrder: Self.ids)
        model.moveActive(by: 1, extending: false, visibleOrder: Self.ids)
        model.moveActive(by: 1, extending: true, visibleOrder: Self.ids)
        #expect(Self.selected(model) == ["c", "d"])
    }

    /// Shift-click selects a..c; Shift+Down continues from c, as in Finder.
    @Test func shiftArrowAfterShiftClickExtendsFromTheClickedEnd() {
        let model = Self.model()
        model.extendSelection(to: Self.ids[2], visibleOrder: Self.ids)
        #expect(Self.selected(model) == ["a", "b", "c"])
        model.moveActive(by: 1, extending: true, visibleOrder: Self.ids)
        #expect(Self.selected(model) == ["a", "b", "c", "d"])
    }

    @Test func shiftArrowKeepsItsRangeAfterTheActivationEcho() {
        let model = Self.model()
        model.onIntent = { model.apply($0) }
        model.moveActive(by: 1, extending: true, visibleOrder: Self.ids)
        #expect(Self.selected(model) == ["a", "b"])
        #expect(model.activeWorkspaceID == WorkspaceID("b"))
    }
}
