import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrTabPaneIndexTests {
    @Test func removeLeafClearsInverseTabPaneEntry() {
        var index = RemoteHerdrTabPaneIndex<String>()
        index.bind(paneID: "p1", tabID: "tab-a")
        index.bind(paneID: "p2", tabID: "tab-b")
        let removed = index.removeLeaf(paneID: "p1")
        #expect(removed == "tab-a")
        #expect(index.tabIdByPaneId["p1"] == nil)
        #expect(index.paneIdByTabId["tab-a"] == nil)
        #expect(index.tabIdByPaneId["p2"] == "tab-b")
        #expect(index.paneIdByTabId["tab-b"] == "p2")
    }

    @Test func removeLeafIgnoresUnknownPane() {
        var index = RemoteHerdrTabPaneIndex<String>()
        index.bind(paneID: "p1", tabID: "tab-a")
        #expect(index.removeLeaf(paneID: "missing") == nil)
        #expect(index.tabIdByPaneId["p1"] == "tab-a")
        #expect(index.paneIdByTabId["tab-a"] == "p1")
    }
}
