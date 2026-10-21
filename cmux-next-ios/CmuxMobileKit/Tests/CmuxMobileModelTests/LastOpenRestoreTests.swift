import Foundation
import Testing
@testable import CmuxMobileModel

/// Design/terminal P10: a relaunch returns to the workspace and tab that were open.
@MainActor @Suite struct LastOpenRestoreTests {
    let workspaces = AppStore.mock(tabMemory: .inMemory()).workspaces
    let live: (String) -> MacDataMachine.Phase = { _ in .live }

    @Test func nothingSavedOrAnotherRootTabOpensHome() {
        #expect(LastOpenRestore.decide(saved: nil, workspaces: workspaces, macPhase: live) == .nothing)
        let feed = LastOpenLocation(rootTab: "feed")
        #expect(LastOpenRestore.decide(saved: feed, workspaces: workspaces, macPhase: live) == .nothing)
    }

    @Test func theWorkspacesListWithNoWorkspaceOpen() {
        let list = LastOpenLocation(rootTab: "workspaces")
        #expect(LastOpenRestore.decide(saved: list, workspaces: workspaces, macPhase: live) == .showList)
    }

    @Test func reopensTheWorkspaceOnTheSavedTab() {
        let saved = LastOpenLocation(rootTab: "workspaces", workspaceID: "ws-cmux", macID: "mac-studio", tabID: "t-zsh")
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: live)
            == .open(workspaceID: "ws-cmux", tabID: "t-zsh"))
    }

    /// ws-cmux needs the user (an agent waits), but a restore keeps the
    /// saved terminal tab: the jump to the waiting tab is only for a tap.
    @Test func aNeedsYouWorkspaceKeepsTheSavedTab() throws {
        let cmux = try #require(workspaces.first { $0.id == "ws-cmux" })
        #expect(cmux.needsAttention)
        let saved = LastOpenLocation(rootTab: "workspaces", workspaceID: "ws-cmux", macID: "mac-studio", tabID: "t-docs")
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: live)
            == .open(workspaceID: "ws-cmux", tabID: "t-docs"))
    }

    @Test func aClosedTabOpensTheWorkspaceOnItsUsualTab() {
        let saved = LastOpenLocation(rootTab: "workspaces", workspaceID: "ws-cmux", macID: "mac-studio", tabID: "gone")
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: live)
            == .open(workspaceID: "ws-cmux", tabID: nil))
    }

    @Test func aWorkspaceThatIsGoneShowsTheList() {
        let saved = LastOpenLocation(rootTab: "workspaces", workspaceID: "ws-gone", macID: "mac-studio", tabID: "t-1")
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: live) == .showList)
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: { _ in .empty }) == .showList)
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: { _ in .offline }) == .showList)
        let noMac = LastOpenLocation(rootTab: "workspaces", workspaceID: "ws-gone")
        #expect(LastOpenRestore.decide(saved: noMac, workspaces: workspaces, macPhase: { _ in .loading }) == .showList)
    }

    @Test func waitsWhileTheMacHasNotAnswered() {
        let saved = LastOpenLocation(rootTab: "workspaces", workspaceID: "ws-new", macID: "mac-studio", tabID: "t-1")
        #expect(LastOpenRestore.decide(saved: saved, workspaces: [], macPhase: { _ in .loading }) == .wait)
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: { _ in .cached(.connecting) }) == .wait)
        #expect(LastOpenRestore.decide(saved: saved, workspaces: workspaces, macPhase: { _ in .idle }) == .wait)
    }

    @Test func survivesARelaunch() throws {
        let suite = "cmuxMobile.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = LastOpenLocation(rootTab: "workspaces", workspaceID: "ws-cmux", macID: "mac-studio", tabID: "t-zsh")
        LastOpenMemory(defaults: defaults).save(saved)
        #expect(LastOpenMemory(defaults: defaults).load() == saved)
        LastOpenMemory(defaults: defaults).save(nil)
        #expect(LastOpenMemory(defaults: defaults).load() == nil)
    }
}
