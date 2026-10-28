#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextOracle
import CmuxNextSettings
import CmuxNextSidebar
import Testing

/// The oracle's sidebar facet is the window's `SidebarModel` in the snapshot schema's form:
/// sections, groups and rows in model order with their folds, pins, unread counts and selection; the filter
/// only as a hash. Run: `swift test --filter OracleSidebarFacetTests`.
@MainActor struct OracleSidebarFacetTests {
    private let pinnedRow = WorkspaceID("w_pinned"), loose = WorkspaceID("w_loose")
    private let built = WorkspaceID("w_built"), asking = WorkspaceID("w_asking")
    private let group = GroupID("grp_build")

    /// Pinned holds one workspace; the local machine a loose workspace and a collapsed group of two.
    private func makeModel() -> SidebarModel {
        var pinned = SidebarWorkspace(id: pinnedRow, title: "Pinned one", unread: .dot)
        pinned.agentChip = .done
        var waiting = SidebarWorkspace(id: asking, title: "Asking")
        waiting.agentChip = .needsYou
        let groupNode = SidebarGroup(id: group, name: "Build", isCollapsed: true,
                                     workspaces: [SidebarWorkspace(id: built, title: "Built", unread: .count(3)), waiting])
        let machine = SidebarMachine(id: .local, name: "The host's own name", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .pinned, nodes: [.workspace(pinned)]),
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: loose, title: "Loose")), .group(groupNode)]),
        ], activeWorkspaceID: loose)
        model.selection = [asking, loose]
        model.width = 250
        let pinnedID = loose
        model.workspacePin = (isPinned: { $0 == pinnedID }, toggle: { _ in })
        return model
    }

    private func value(_ model: SidebarModel, editing: Bool = false) -> OracleValue {
        SidebarSnapshot.oracleValue(of: model, window: "win_1", editing: editing, windowWidth: 1000, workspaceID: { "ws_" + $0.rawValue })
    }

    private func row(_ kind: String, workspace: String? = nil, group: String? = nil, label: String?, depth: Int = 0,
                     selected: Bool = false, collapsed: Bool = false, unread: Int = 0, needsYou: Bool = false,
                     pinned: Bool = false) -> OracleValue {
        [
            "kind": .string(kind), "workspace": workspace.map { .string("ws_" + $0) } ?? .null,
            "group": group.map(OracleValue.string) ?? .null, "label": label.map(OracleValue.string) ?? .null,
            "depth": OracleValue(depth), "selected": .bool(selected), "collapsed": .bool(collapsed),
            "unread": OracleValue(unread), "needsYou": .bool(needsYou), "pinned": .bool(pinned),
        ]
    }

    @Test func theModelIsTheSchemaObjectInModelOrder() {
        let model = makeModel()
        let expected: OracleValue = [
            "window": "win_1",
            "hidden": false,
            "editing": false,
            "widthFraction": .number(Double(model.width) / 1000),
            "selectedWorkspace": "ws_w_loose",
            "selection": ["ws_w_loose", "ws_w_asking"],
            "filterSha256": nil,
            "rows": [
                row("section", label: "pinned"),
                row("workspace", workspace: "w_pinned", label: "Pinned one", unread: 1, pinned: true),
                // The machine's own name differs between hosts: a section is labeled by its kind.
                row("section", label: "local"),
                row("workspace", workspace: "w_loose", label: "Loose", selected: true, pinned: true),
                // A collapsed group's header sums its members; the members stay listed one level deeper.
                row("group", group: "grp_build", label: "Build", collapsed: true, unread: 3, needsYou: true),
                row("workspace", workspace: "w_built", group: "grp_build", label: "Built", depth: 1, unread: 3),
                row("workspace", workspace: "w_asking", group: "grp_build", label: "Asking", depth: 1, selected: true, needsYou: true),
            ],
        ]
        #expect(value(model) == expected)
    }

    @Test func theFilterIsRecordedOnlyAsItsHash() {
        let model = makeModel()
        model.filterText = "secret"
        let facet = value(model)
        #expect(facet["filterSha256"] == OracleValue.string("sha256:2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b"))
        #expect(!String(describing: facet).contains("secret"))
    }

    @Test func aHiddenSidebarTakesNoWidthAndEditModeIsRead() {
        let model = makeModel()
        model.presentation = .hidden
        let facet = value(model, editing: true)
        #expect(facet["hidden"] == OracleValue.bool(true))
        #expect(facet["widthFraction"] == OracleValue.number(0))
        #expect(facet["editing"] == OracleValue.bool(true))
    }

    @Test func aFoldedSectionIsCollapsedOnItsHeader() {
        let model = makeModel()
        model.collapsedSections = [.pinned]
        guard case .array(let rows) = value(model)["rows"] else { Issue.record("no rows"); return }
        #expect(rows.first?["collapsed"] == OracleValue.bool(true))
        #expect(rows.count == 7)
    }

    /// The app's list provides the facet; with no window it answers not-comparable, never an empty sidebar.
    @Test func theAppListProvidesTheSidebarFacet() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.sidebar))
        #expect(facets.duplicates.isEmpty)
        let snapshot = try #require(try facets.beginCapture([.sidebar]).completed)
        if services.windows.controllers.isEmpty {
            #expect(snapshot["sidebar"] == OracleValue.notComparable(reason: "no window shows a sidebar", task: "p15-oracle-036"))
        } else {
            #expect(snapshot["sidebar"]?["rows"] != nil)
        }
    }
}
#endif
