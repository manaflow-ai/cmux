import Foundation
import Testing
@testable import CmuxMobileModel

/// The App Review demo account's space: one online Mac whose workspaces open
/// terminals and pages on the phone, loaded and settled, with nothing that waits
/// for a real Mac (no spinner, no pairing step, no agent chat that needs a link).
@MainActor
@Suite struct ReviewDemoContentTests {
    private func signedOutStore() -> AppStore {
        let defaults = UserDefaults(suiteName: "review-demo-\(UUID())") ?? .standard
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: TabMemory(defaults: defaults))
        store.resetForSignOut(defaults: defaults)
        return store
    }

    @Test func loadsOneOnlineMacAndSettles() {
        let store = signedOutStore()
        #expect(store.awaitsAccountData)
        store.loadReviewDemo(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(!store.awaitsAccountData)
        #expect(store.teams.map(\.id) == [AppStore.reviewDemoTeamID])
        #expect(store.activeTeamID == AppStore.reviewDemoTeamID)
        let macs = store.teams.flatMap(\.macs)
        #expect(macs.map(\.id) == [AppStore.reviewDemoMacID])
        #expect(macs.allSatisfy { $0.isOnline })
    }

    @Test func everyWorkspaceIsOnTheDemoMacWithTerminalsAndPages() {
        let store = signedOutStore()
        store.loadReviewDemo()
        #expect(store.workspaces.count >= 3)
        #expect(store.workspaces.allSatisfy { $0.macID == AppStore.reviewDemoMacID })
        let tabs = store.workspaces.flatMap(\.tabs)
        #expect(tabs.contains { $0.kind == .terminal })
        // Pages load on the phone (no Mac stream): only public https pages.
        let pages = tabs.filter { $0.kind == .browser }
        #expect(!pages.isEmpty)
        #expect(pages.allSatisfy { $0.url?.scheme == "https" })
        // An agent chat needs a live Mac: the demo has none.
        #expect(!tabs.contains { $0.isAgent })
        #expect(Set(tabs.map(\.id)).count == tabs.count)
    }

    @Test func loadingAgainReplacesNotAppends() {
        let store = signedOutStore()
        store.loadReviewDemo()
        let first = store.workspaces.map(\.id)
        store.loadReviewDemo()
        #expect(store.workspaces.map(\.id) == first)
        #expect(store.teams.count == 1)
    }
}
