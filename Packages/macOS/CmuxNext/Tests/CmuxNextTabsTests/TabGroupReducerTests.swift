import Foundation
import Testing
@testable import CmuxNextTabs

@MainActor
@Suite("Group reducer")
struct GroupReducerTests {
    /// a | [g: b c] | d, with b selected.
    private func model() -> TabStripModel {
        let tabs = [
            TabItem(id: "a", title: "a"),
            TabItem(id: "b", title: "b", groupID: "g"),
            TabItem(id: "c", title: "c", groupID: "g"),
            TabItem(id: "d", title: "d"),
        ]
        return TabStripModel(tabs: tabs, groups: [TabGroupItem(id: "g", name: "work", colorToken: .green)], selectedID: "b")
    }

    private var fresh: TabItem { TabItem(id: "n", title: "n") }
    private func ids(_ model: TabStripModel) -> [String] { model.orderedTabs.map(\.id.rawValue) }
    private func members(_ model: TabStripModel) -> [String] { model.members(of: "g").map(\.id.rawValue) }

    @Test func collapsingMovesSelectionOutOfTheGroup() {
        let model = model()
        #expect(model.apply(.toggleGroupCollapsed("g"), makeTab: { fresh }))
        #expect(model.group("g")?.isCollapsed == true)
        #expect(model.selectedID == "d")
        #expect(model.apply(.toggleGroupCollapsed("g"), makeTab: { fresh }))
        #expect(model.group("g")?.isCollapsed == false)
    }

    @Test func collapsingTheOnlyVisibleTabsOpensANewTab() {
        let model = TabStripModel(tabs: [TabItem(id: "b", title: "b", groupID: "g")], groups: [TabGroupItem(id: "g")], selectedID: "b")
        model.apply(.toggleGroupCollapsed("g"), makeTab: { fresh })
        #expect(ids(model) == ["b", "n"])
        #expect(model.selectedID == "n")
    }

    @Test func selectingACollapsedMemberExpandsTheGroup() {
        let model = model()
        model.apply(.toggleGroupCollapsed("g"), makeTab: { fresh })
        model.apply(.select("c"), makeTab: { fresh })
        #expect(model.group("g")?.isCollapsed == false)
    }

    @Test func newTabFromAGroupedTabJoinsTheGroup() {
        let model = model()
        model.apply(.newTab(after: "b"), makeTab: { fresh })
        #expect(ids(model) == ["a", "b", "n", "c", "d"])
        #expect(members(model) == ["b", "n", "c"])
        model.apply(.newTab(after: nil), makeTab: { TabItem(id: "m", title: "m") })
        #expect(model.tab("m")?.groupID == nil)
    }

    @Test func duplicateStaysInTheGroup() {
        let model = model()
        model.apply(.duplicate("c"), makeTab: { fresh })
        #expect(members(model) == ["b", "c", "n"])
    }

    @Test func pinningLeavesTheGroup() {
        let model = model()
        model.apply(.pin("c"), makeTab: { fresh })
        #expect(ids(model) == ["c", "a", "b", "d"])
        #expect(members(model) == ["b"])
    }

    @Test func moveGroupMovesTheBlockAfterPinnedTabs() {
        let model = model()
        model.apply(.moveGroup("g", to: 2), makeTab: { fresh })
        #expect(ids(model) == ["a", "d", "b", "c"])
        model.apply(.pin("d"), makeTab: { fresh })
        model.apply(.moveGroup("g", to: 0), makeTab: { fresh })
        #expect(ids(model) == ["d", "b", "c", "a"])
    }

    @Test func addToGroupAtIndexOrAppended() {
        let model = model()
        model.apply(.addToGroup("d", "g", index: 1), makeTab: { fresh })
        #expect(ids(model) == ["a", "d", "b", "c"])
        #expect(members(model) == ["d", "b", "c"])
        model.apply(.addToGroup("a", "g", index: nil), makeTab: { fresh })
        #expect(ids(model) == ["d", "b", "c", "a"])
        #expect(members(model) == ["d", "b", "c", "a"])
    }

    @Test func pinnedTabsCannotJoinAGroup() {
        let model = model()
        model.apply(.pin("a"), makeTab: { fresh })
        #expect(!model.apply(.addToGroup("a", "g", index: nil), makeTab: { fresh }))
    }

    @Test func removeFromGroupPlacesTheTabAfterTheGroup() {
        let model = model()
        model.apply(.removeFromGroup("b", index: nil), makeTab: { fresh })
        #expect(ids(model) == ["a", "c", "b", "d"])
        #expect(members(model) == ["c"])
        model.apply(.removeFromGroup("c", index: 0), makeTab: { fresh })
        #expect(ids(model) == ["c", "a", "b", "d"])
        #expect(model.groups.isEmpty, "empty groups are dropped")
    }

    @Test func createGroupSkipsPinnedTabsAndGathersMembers() {
        let model = model()
        model.apply(.pin("a"), makeTab: { fresh })
        model.apply(.createGroup(TabGroupItem(id: "h", colorToken: .orange), tabs: ["a", "d"]), makeTab: { fresh })
        #expect(model.members(of: "h").map(\.id.rawValue) == ["d"])
        #expect(model.tab("a")?.groupID == nil)
    }

    @Test func closingTheLastMemberDropsTheGroup() {
        let model = model()
        model.apply(.close("b", source: .mouse), makeTab: { fresh })
        model.apply(.close("c", source: .mouse), makeTab: { fresh })
        #expect(model.groups.isEmpty)
    }

    @Test func groupCommands() {
        let model = model()
        model.apply(.group(.rename("g", name: "infra")), makeTab: { fresh })
        model.apply(.group(.setColor("g", .cyan)), makeTab: { fresh })
        model.apply(.group(.save("g")), makeTab: { fresh })
        #expect(model.group("g") == TabGroupItem(id: "g", name: "infra", colorToken: .cyan, isSaved: true))
        model.apply(.group(.newTab("g")), makeTab: { fresh })
        #expect(members(model) == ["b", "c", "n"])
        #expect(model.selectedID == "n")
        #expect(!model.apply(.group(.moveToNewWindow("g")), makeTab: { fresh }))
        model.apply(.group(.close("g")), makeTab: { fresh })
        #expect(ids(model) == ["a", "d"])
        #expect(model.selectedID == "d")
        #expect(model.groups.isEmpty)
    }

    @Test func ungroupKeepsTabsInPlace() {
        let model = model()
        model.apply(.group(.ungroup("g")), makeTab: { fresh })
        #expect(ids(model) == ["a", "b", "c", "d"])
        #expect(model.groups.isEmpty)
    }

    @Test func commandsCarryRegistryActionIDs() {
        #expect(TabGroupCommand.setColor("g", .pink).actionID == "tabGroup.setColor")
        #expect(TabGroupCommand.setColor("g", .pink).arguments == ["group": "g", "color": "pink"])
        #expect(TabGroupCommand.rename("g", name: "x").arguments == ["group": "g", "name": "x"])
        #expect(TabGroupCommand.moveToNewWindow("g").actionID == "tabGroup.moveToNewWindow")
    }

    @Test func groupIntentsForwardToTheHandler() {
        let model = model()
        var received: [TabStripIntent] = []
        model.intentHandler = { received.append($0) }
        model.send(.toggleGroupCollapsed("g"))
        #expect(received == [.toggleGroupCollapsed("g")])
        #expect(model.group("g")?.isCollapsed == false)
    }
}
