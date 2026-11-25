@testable import CmuxNextPalette
import Testing

/// The palette v2 look's groups (`PaletteV2Grouping`): Workspaces, Sessions, Commands and Agents in the order of
/// their best row, rank order kept inside each, and the rail's counts and filter.
@MainActor
@Suite(.paletteRanker)
struct PaletteV2GroupingTests {
    private func item(_ id: String, section: String, brand: String? = nil) -> PaletteItem {
        PaletteItem(id: id, title: id, brand: brand, section: PaletteSection(id: section, title: section, order: 0),
                    primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))
    }

    private func row(_ id: String, section: String, brand: String? = nil) -> PaletteRow {
        PaletteRow(item: item(id, section: section, brand: brand), highlights: [], score: 0)
    }

    private func block(_ id: String, _ rows: [PaletteRow]) -> PaletteResultSection {
        PaletteResultSection(section: PaletteSection(id: id, title: id, order: 0), rows: rows)
    }

    private func ids(_ sections: [PaletteResultSection]) -> [String] { sections.map(\.id) }
    private func rowIDs(_ sections: [PaletteResultSection]) -> [String] { sections.flatMap(\.rows).map(\.id) }

    @Test func groupsComeInTheOrderOfTheirBestRow() {
        let grouped = PaletteV2Grouping.regroup([
            block("general", [row("c1", section: "general")]),
            block("workspaces", [row("w1", section: "workspaces")]),
            block("tabs", [row("t1", section: "tabs")]),
            block("layout", [row("c2", section: "layout")]),
        ])
        #expect(ids(grouped) == ["v2.commands", "v2.workspaces", "v2.sessions"])
        #expect(rowIDs(grouped) == ["c1", "c2", "w1", "t1"])
        #expect(grouped.map(\.title) == [PaletteStrings.commandsTitle, PaletteStrings.sectionWorkspaces, PaletteStrings.v2GroupSessions])
    }

    @Test func theTopMatchStaysTheFirstRow() {
        let grouped = PaletteV2Grouping.regroup([
            block("tabs", [row("t1", section: "tabs")]),
            block("general", [row("c1", section: "general")]),
            block("tabs2", [row("t2", section: "tabs")]),
        ])
        #expect(grouped.first?.rows.first?.id == "t1")
        #expect(rowIDs(grouped) == ["t1", "t2", "c1"])
    }

    @Test func emptyGroupsDoNotShow() {
        let grouped = PaletteV2Grouping.regroup([
            block("empty", []),
            block("workspaces", [row("w1", section: "workspaces"), row("w2", section: "workspaces")]),
        ])
        #expect(ids(grouped) == ["v2.workspaces"])
        #expect(PaletteV2Grouping.regroup([]).isEmpty)
        #expect(PaletteV2Grouping.regroup([block("empty", [])]).isEmpty)
    }

    @Test func rankOrderIsKeptInsideAGroupAndRepeatsShowOnce() {
        // Recent rows keep their own section: a recent workspace joins Workspaces, ahead of the other workspaces.
        let grouped = PaletteV2Grouping.regroup([
            block("recent", [row("w2", section: "workspaces"), row("c1", section: "general")]),
            block("workspaces", [row("w1", section: "workspaces"), row("w2", section: "workspaces"), row("w3", section: "workspaces")]),
        ])
        #expect(ids(grouped) == ["v2.workspaces", "v2.commands"])
        #expect(grouped[0].rows.map(\.id) == ["w2", "w1", "w3"])
    }

    @Test func eachKindFindsItsGroup() {
        let grouped = PaletteV2Grouping.regroup([
            block("search.agentChats", [row("chat", section: "results")]),
            block("search.history.agents", [row("agentRun", section: "search.history.agents")]),
            block("tabs", [row("claudeTab", section: "tabs", brand: "claude")]),
            block("search.history.closed", [row("closedTab", section: "search.history.closed")]),
            block("panes", [row("pane", section: "panes")]),
            block("groups", [row("group", section: "groups")]),
            block("findWork.workspaces", [row("found", section: "findWork.workspaces")]),
            block("search.commands", [row("cmd", section: "search.commands")]),
            block("settings", [row("setting", section: "settings")]),
            block("goTo", [row("goTo", section: "goTo")]),
        ])
        #expect(ids(grouped) == ["v2.agents", "v2.sessions", "v2.workspaces", "v2.commands"])
        #expect(grouped[0].rows.map(\.id) == ["chat", "agentRun", "claudeTab"])
        #expect(grouped[1].rows.map(\.id) == ["closedTab", "pane"])
        #expect(grouped[2].rows.map(\.id) == ["group", "found"])
        #expect(grouped[3].rows.map(\.id) == ["cmd", "setting", "goTo"])
    }

    @Test func railCountsEveryGroupInItsFixedOrderAndFilters() {
        let grouped = PaletteV2Grouping.regroup([
            block("general", [row("c1", section: "general"), row("c2", section: "general")]),
            block("tabs", [row("t1", section: "tabs")]),
            block("workspaces", [row("w1", section: "workspaces")]),
        ])
        let rail = PaletteV2Grouping.railEntries(grouped)
        #expect(rail == [
            PaletteV2RailEntry(group: nil, count: 4),
            PaletteV2RailEntry(group: .workspaces, count: 1),
            PaletteV2RailEntry(group: .sessions, count: 1),
            PaletteV2RailEntry(group: .commands, count: 2),
        ])
        #expect(rail.first?.title == PaletteStrings.v2RailAll)
        #expect(rowIDs(PaletteV2Grouping.filter(grouped, to: .commands)) == ["c1", "c2"])
        #expect(rowIDs(PaletteV2Grouping.filter(grouped, to: nil)) == rowIDs(grouped))
        #expect(PaletteV2Grouping.filter(grouped, to: .agents).isEmpty)
    }

    // MARK: The model

    private func rootPage() -> PalettePageSpec {
        PalettePageSpec(id: "root", title: "Commands", placeholder: "Search", providers: [
            StaticPaletteProvider(id: "rows", items: [
                item("alpha command", section: "general"),
                item("alpha workspace", section: "workspaces"),
                item("alpha tab", section: "tabs"),
            ]),
        ], scope: .root)
    }

    private func openModel(_ look: PaletteV2Look, query: String = "alpha") async -> PaletteModel {
        let model = PaletteModel(persistence: nil)
        model.experiments = PaletteExperiments(look: look)
        model.reset(to: rootPage())
        await model.settle()
        model.query = query
        await model.settle()
        return model
    }

    @Test func lookOffKeepsTodaysSections() async {
        let model = await openModel(.off)
        #expect(!model.sections.contains { $0.id.hasPrefix("v2.") })
        #expect(model.railEntries.isEmpty)
    }

    @Test func lookOnGroupsAndSelectsTheTopMatch() async {
        let model = await openModel(.flat)
        #expect(!model.sections.isEmpty)
        #expect(model.sections.allSatisfy { $0.id.hasPrefix("v2.") })
        #expect(model.selectedRowID == model.rows.first?.id)
        // A flat look has no rail.
        #expect(model.railEntries.isEmpty)
        model.query = "alpha t"
        await model.settle()
        #expect(model.selectedRowID == model.rows.first?.id)
    }

    @Test func railFiltersTheListAndKeepsTheCounts() async {
        let model = await openModel(.rail)
        let all = [
            PaletteV2RailEntry(group: nil, count: 3),
            PaletteV2RailEntry(group: .workspaces, count: 1),
            PaletteV2RailEntry(group: .sessions, count: 1),
            PaletteV2RailEntry(group: .commands, count: 1),
        ]
        #expect(model.railEntries == all)
        model.chooseRail(.workspaces)
        #expect(model.railFilter == .workspaces)
        #expect(model.rows.map(\.id) == ["alpha workspace"])
        #expect(model.selectedRowID == "alpha workspace")
        #expect(model.railEntries == all)
        // Arrow-key navigation walks only the chosen group.
        model.handle(.moveDown)
        #expect(model.selectedRowID == "alpha workspace")
        #expect(model.moveRail(by: 1))
        #expect(model.railFilter == .sessions)
        #expect(model.rows.map(\.id) == ["alpha tab"])
        model.chooseRail(nil)
        #expect(model.rows.count == 3)
        #expect(model.selectedRowID == model.rows.first?.id)
    }
}
