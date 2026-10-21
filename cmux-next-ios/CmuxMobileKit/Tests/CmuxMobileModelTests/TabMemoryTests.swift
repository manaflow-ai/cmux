import Foundation
import Testing
@testable import CmuxMobileModel

@MainActor @Suite struct TabMemoryTests {
    @Test func lastTabSurvivesARelaunch() throws {
        let suite = "cmuxMobile.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppStore.mock(tabMemory: TabMemory(defaults: defaults))
        let ws = first.workspaces[0]
        first.noteOpened(tabID: "t-docs", in: ws.id)

        // A new store over the same defaults is a relaunch.
        let relaunched = AppStore.mock(tabMemory: TabMemory(defaults: defaults))
        #expect(relaunched.openingTab(for: relaunched.workspaces[0])?.id == "t-docs")
    }

    @Test func forgottenTabFallsBackToFirst() {
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "gone"]))
        #expect(store.openingTab(for: store.workspaces[0])?.id == "t-claude")
    }

    @Test func closingTheRememberedTabRemembersItsNeighbor() {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.noteOpened(tabID: "t-zsh", in: "ws-cmux")
        let next = store.removeTab("t-zsh", from: "ws-cmux")
        #expect(next?.id == "t-docs")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-docs")
        store.removeTab("t-docs", from: "ws-cmux")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-claude")
        store.removeTab("t-claude", from: "ws-cmux")
        #expect(store.lastTabByWorkspace["ws-cmux"] == nil)
        #expect(store.workspace(id: "ws-cmux")?.tabs.isEmpty == true)
    }

    @Test func closingAnotherTabKeepsTheRememberedOne() {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.noteOpened(tabID: "t-docs", in: "ws-cmux")
        store.removeTab("t-zsh", from: "ws-cmux")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-docs")
    }

    @Test func appendedTabsGoLast() {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.appendTab(WorkspaceTab(id: "n", kind: .terminal, title: "zsh"), to: "ws-web")
        #expect(store.workspace(id: "ws-web")?.tabs.last?.id == "n")
    }
}
