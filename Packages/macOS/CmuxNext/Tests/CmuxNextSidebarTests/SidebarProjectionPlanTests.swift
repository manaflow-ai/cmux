@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// CMUX-383 slice 2's projection invariants through the real model and the
/// pinned Rust planner: a hidden row comes back for its selection only, a
/// click on a drawn row never plans again, a malformed value keeps the last
/// good view, and the request does not grow with the rows.
@MainActor @Suite(.serialized) struct SidebarProjectionPlanTests {
    private static func workspace(_ id: String) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: "Workspace \(id)", directory: "~/cmux", branch: "main",
                         rowKind: .terminal, kind: .terminal, activity: .idle)
    }

    private static func sections(rows: Int) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let group = SidebarGroup(id: GroupID("grp"), name: "Work", workspaces: [workspace("member")])
        let loose = (0..<rows).map { SidebarNode.workspace(workspace("ws-\($0)")) }
        return [
            SidebarSection(kind: .machine(machine), nodes: loose + [.group(group)]),
            SidebarSection(kind: .custom(.init(id: "recents", title: "Recents", showsTitle: true, region: .bottom)),
                           nodes: [.workspace(workspace("recent"))]),
        ]
    }

    private static func ids(_ model: SidebarModel) -> [String] {
        model.sections.flatMap { $0.nodes.flatMap(\.workspaces) }.map(\.id.rawValue)
    }

    @Test func aHiddenWorkspaceShowsWhileSelectedAndHidesAgainAfter() {
        let model = SidebarModel(sections: Self.sections(rows: 3))
        model.sectionCustomization = .init(workspaces: ["ws-1": .init(hidden: true)])
        model.setSections(Self.sections(rows: 3))
        #expect(!Self.ids(model).contains("ws-1"))
        #expect(model.projectionPlan.restorable.map(\.id) == ["ws-1"])

        model.activeWorkspaceID = WorkspaceID("ws-1")
        #expect(Self.ids(model).contains("ws-1"), "the selection is made visible before it opens")
        #expect(model.projectionPlan.selectionOverridesHide)

        model.activeWorkspaceID = WorkspaceID("ws-2")
        #expect(!Self.ids(model).contains("ws-1"))
        #expect(!model.projectionPlan.selectionOverridesHide)
    }

    @Test func aClickOnADrawnRowDoesNotPlanAgain() {
        for rows in [30, 3_000] {
            let model = SidebarModel(sections: Self.sections(rows: rows))
            model.sectionCustomization = .init(hiddenSections: ["recents"], workspaces: ["ws-1": .init(hidden: true)])
            model.setSections(Self.sections(rows: rows))
            _ = SidebarPerfCounters.report(reset: true)
            model.activeWorkspaceID = WorkspaceID("ws-2")
            model.activeWorkspaceID = WorkspaceID("ws-0")
            let counts = SidebarPerfCounters.report(reset: true)
            #expect(counts["ffi_calls", default: 0] == 0, "\(rows) rows")
            #expect(counts["section_sets", default: 0] == 0, "\(rows) rows")
        }
    }

    @Test func aMalformedValueKeepsTheLastGoodProjection() {
        let model = SidebarModel(sections: Self.sections(rows: 3))
        model.sectionCustomization = .init(hiddenSections: ["recents"])
        model.setSections(Self.sections(rows: 3))
        #expect(!Self.ids(model).contains("recent"))
        model.sectionCustomization = .init(isComplete: false)
        #expect(model.sectionCustomization.hiddenSections == ["recents"])
        #expect(!Self.ids(model).contains("recent"), "the last good view stays")
        model.sectionCustomization = .defaults
        #expect(Self.ids(model).contains("recent"), "the saved fix applies")
    }

    @Test func aGroupOverrideMovesTheRowAndOrderNeverRewritesTheDocument() {
        let base = Self.sections(rows: 3)
        let model = SidebarModel(sections: base)
        model.sectionCustomization = .init(workspaces: ["ws-2": .init(group: "Work", order: 0), "member": .init(order: 5)])
        model.setSections(base)
        let group = model.sections.first?.nodes.compactMap { node -> SidebarGroup? in
            if case let .group(group) = node { return group }
            return nil
        }.first
        #expect(group?.workspaces.map(\.id.rawValue) == ["ws-2", "member"])
        model.sectionCustomization = .defaults
        #expect(Self.ids(model) == base.flatMap { $0.nodes.flatMap(\.workspaces) }.map(\.id.rawValue))
    }

    @Test func theRequestOnlyListsTheNamedWorkspaces() {
        let small = SidebarCustomizationPlanner.locations(of: ["ws-1", "member"], in: Self.sections(rows: 30))
        let large = SidebarCustomizationPlanner.locations(of: ["ws-1", "member"], in: Self.sections(rows: 3_000))
        #expect(small == large)
        #expect(small.count == 2)
    }
}
