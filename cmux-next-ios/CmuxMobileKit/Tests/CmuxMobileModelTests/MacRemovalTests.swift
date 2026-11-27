import Foundation
import Testing
@testable import CmuxMobileModel

/// Removing a Mac: it leaves every team, list and cache at once.
@MainActor
@Suite struct ForgetMacTests {
    let now = Date(timeIntervalSince1970: 2_000)

    func workspace(_ id: String, mac: String) -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: "~", tabs: [], lastActivityAt: now)
    }

    func store() -> AppStore {
        let studio = MacDevice(id: "m1", name: "Studio", isOnline: true)
        let old = MacDevice(id: "m2", name: "cmux NEXT mobile", isOnline: false, lastSeenAt: now)
        let store = AppStore(
            teams: [Team(id: "t1", name: "One", macs: [studio, old]), Team(id: "t2", name: "Two", macs: [old])],
            activeTeamID: "t1",
            workspaces: [workspace("w1", mac: "m1"), workspace("w2", mac: "m2"), workspace("w3", mac: "m2")],
            feed: [],
            tabMemory: .inMemory(["w2": "tab-a", "w1": "tab-b"])
        )
        store.tracksMacData = true
        store.macData["m2"] = MacDataMachine()
        store.handleMacData(.restored(count: 2, savedAt: now), macID: "m2")
        store.macConnection = ["m1": .connected, "m2": .failed("timeout")]
        store.macLinkStatus = ["m2": "Reconnecting…"]
        store.macLinkDiagnostics = ["m2": "private diagnostic"]
        store.accountMacCount = 2
        return store
    }

    func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "cmuxMobile.tests.forget.\(UUID().uuidString)"))
    }

    @Test func leavesEveryTeamWithItsWorkspacesAndState() throws {
        let store = store()
        let defaults = try defaults()
        #expect(store.forgetMac("m2", defaults: defaults))
        #expect(store.teams.map { $0.macs.map(\.id) } == [["m1"], []])
        #expect(store.workspaces.map(\.id) == ["w1"])
        #expect(store.macData["m2"] == nil)
        #expect(store.macConnection == ["m1": .connected])
        #expect(store.macLinkStatus.isEmpty)
        #expect(store.macLinkDiagnostics.isEmpty)
        #expect(store.accountMacCount == 1)
        // Its workspaces' remembered tabs go too; others stay.
        #expect(store.lastTabByWorkspace == ["w1": "tab-b"])
        // The sidebar dots, the Workspaces filter and Home read these.
        #expect(store.activeWorkspaces.map(\.id) == ["w1"])
        #expect(store.macDataPhase("m2") == .idle)
    }

    @Test func dropsPreferencesThatPointedAtIt() throws {
        let store = store()
        let defaults = try defaults()
        defaults.set("m2", forKey: "cmuxMobile.live.mac.t1")
        defaults.set("m2", forKey: "cmuxMobile.workspaces.macFilter.t2")
        defaults.set("m2", forKey: "cmuxMobile.workspaces.newMac")
        defaults.set("m1", forKey: "cmuxMobile.workspaces.macFilter.t1")
        // Not an account preference: left alone even with the same value.
        defaults.set("m2", forKey: "cmuxMobile.terminal.font")
        store.forgetMac("m2", defaults: defaults)
        #expect(defaults.string(forKey: "cmuxMobile.live.mac.t1") == nil)
        #expect(defaults.string(forKey: "cmuxMobile.workspaces.macFilter.t2") == nil)
        #expect(defaults.string(forKey: "cmuxMobile.workspaces.newMac") == nil)
        #expect(defaults.string(forKey: "cmuxMobile.workspaces.macFilter.t1") == "m1")
        #expect(defaults.string(forKey: "cmuxMobile.terminal.font") == "m2")
    }

    @Test func pendingWorkspacesOfTheMacGoToo() throws {
        let store = store()
        store.insertPending(workspace("p1", mac: "m2"))
        store.forgetMac("m2", defaults: try defaults())
        #expect(!store.isPending("p1"))
        #expect(store.workspace(id: "p1") == nil)
    }

    @Test func anUnknownMacChangesNothing() throws {
        let store = store()
        let before = (store.teams, store.workspaces, store.accountMacCount)
        #expect(!store.forgetMac("nope", defaults: try defaults()))
        #expect(store.teams == before.0)
        #expect(store.workspaces == before.1)
        #expect(store.accountMacCount == before.2)
    }

    @Test func forgettingTwiceCountsOnce() throws {
        let store = store()
        let defaults = try defaults()
        store.forgetMac("m2", defaults: defaults)
        store.forgetMac("m2", defaults: defaults)
        #expect(store.accountMacCount == 1)
    }
}

@Suite struct RemovedMacsTests {
    struct Mac { var id: String }

    @Test func hidesAMacOnlyFromAnswersAskedBeforeItsRemoval() {
        var removed = RemovedMacs()
        let before = removed.mark
        removed.removed("m2")
        let list = [Mac(id: "m1"), Mac(id: "m2")]
        // A reply that was already on its way still names the removed Mac.
        #expect(removed.filter(list, askedAt: before, id: \.id).map(\.id) == ["m1"])
        // A reply asked for after the removal is the truth: the Mac signed
        // in again and registered anew.
        #expect(removed.filter(list, askedAt: removed.mark, id: \.id).map(\.id) == ["m1", "m2"])
    }

    @Test func eachRemovalHasItsOwnPoint() {
        var removed = RemovedMacs()
        removed.removed("m1")
        let between = removed.mark
        removed.removed("m2")
        #expect(!removed.removedSince(between, id: "m1"))
        #expect(removed.removedSince(between, id: "m2"))
        #expect(removed.filter([Mac(id: "m1"), Mac(id: "m2")], askedAt: between, id: \.id).map(\.id) == ["m1"])
    }

    @Test func nothingRemovedPassesEverything() {
        let removed = RemovedMacs()
        #expect(removed.filter([Mac(id: "m1")], askedAt: 0, id: \.id).count == 1)
    }
}

@Suite struct ServiceFailureMessageTests {
    @Test func quotesTheRequestIDOnItsOwnLine() {
        #expect(ServiceFailureMessage(text: "Nope.").display == "Nope.")
        #expect(ServiceFailureMessage(text: "Nope.", requestID: "8c1f").display == "Nope.\n\nRequest ID: 8c1f")
    }
}
