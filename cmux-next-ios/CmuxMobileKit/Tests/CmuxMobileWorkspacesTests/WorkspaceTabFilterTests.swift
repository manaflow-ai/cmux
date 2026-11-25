import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

@Suite struct WorkspaceTabFilterTests {
    let tabs = [
        WorkspaceTab(id: "a", kind: .agent, title: "Claude"),
        WorkspaceTab(id: "t", kind: .terminal, title: "zsh"),
        WorkspaceTab(id: "b", kind: .browser, title: "Docs"),
        WorkspaceTab(id: "s", kind: .simulator, title: "iPhone"),
    ]

    private func ids(_ filter: WorkspaceTabFilter, keeping kept: Set<String> = []) -> [String] {
        filter.listed(tabs, keeping: kept).map(\.id)
    }

    @Test func allListsEveryTabInOrder() {
        #expect(ids(.all) == ["a", "t", "b", "s"])
        #expect(WorkspaceTabFilter.all.hiddenCount(tabs, keeping: []) == 0)
    }

    @Test func eachFilterListsItsKinds() {
        #expect(ids(.agents) == ["a"])
        #expect(ids(.agentsAndTerminals) == ["a", "t"])
        #expect(ids(.browsers) == ["b", "s"])
        #expect(WorkspaceTabFilter.agents.hiddenCount(tabs, keeping: []) == 3)
    }

    @Test func theTabOnScreenIsAlwaysListed() {
        #expect(ids(.agents, keeping: ["b"]) == ["a", "b"])
        #expect(ids(.browsers, keeping: ["t"]) == ["t", "b", "s"])
    }

    @Test func choiceSurvivesRelaunchAndDefaultsToAll() throws {
        let suite = "cmuxMobile.tests.tabfilter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WorkspaceTabFilter.saved(defaults) == .all)
        WorkspaceTabFilter.browsers.save(defaults)
        #expect(WorkspaceTabFilter.saved(defaults) == .browsers)
        defaults.set("bogus", forKey: WorkspaceTabFilter.defaultsKey)
        #expect(WorkspaceTabFilter.saved(defaults) == .all)
    }
}
