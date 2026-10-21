import Foundation
import Testing
@testable import CmuxMobileModel

/// Settings round 3 note: setup's "Personal" left the previous team (Manaflow)
/// active when no live coordinator selected it (mock mode). Setup now selects
/// the personal space in the store itself.
@MainActor @Suite(.serialized) struct PersonalSpaceSelectionTests {
    #if DEBUG
    @Test func pickingPersonalInMockLeavesPersonalActive() {
        let remembered = UserDefaults.standard.string(forKey: AppStore.lastTeamKey)
        defer { UserDefaults.standard.set(remembered, forKey: AppStore.lastTeamKey) }
        let store = AppStore.mock(tabMemory: .inMemory())
        #expect(store.activeTeamID != "personal-mock")
        #expect(store.selectPersonalSpace())
        #expect(store.activeTeamID == "personal-mock")
        #expect(store.activeTeam?.isPersonalSpace == true)
    }
    #endif

    @Test func liveShapedListKeepsPersonalAfterTheAccountReloads() {
        let remembered = UserDefaults.standard.string(forKey: AppStore.lastTeamKey)
        defer { UserDefaults.standard.set(remembered, forKey: AppStore.lastTeamKey) }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let list = [AppStore.AccountTeam(id: "t1", name: "Manaflow"), AppStore.AccountTeam(id: "personal-u", name: "Personal")]
        store.applyLiveTeams(list, selectedID: "t1")
        #expect(store.activeTeamID == "t1")
        #expect(store.selectPersonalSpace())
        // The coordinator's reload keeps the active space when listed.
        store.applyLiveTeams(list, selectedID: store.activeTeamID)
        #expect(store.activeTeamID == "personal-u")
    }

    @Test func withNoPersonalSpaceListedNothingChanges() {
        let store = AppStore(teams: [Team(id: "t1", name: "One")], activeTeamID: "t1", workspaces: [], feed: [],
                             tabMemory: .inMemory())
        #expect(!store.selectPersonalSpace())
        #expect(store.activeTeamID == "t1")
    }
}
