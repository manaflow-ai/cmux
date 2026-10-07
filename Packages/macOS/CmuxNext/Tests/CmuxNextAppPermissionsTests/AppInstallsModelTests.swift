@testable import CmuxNextAppPermissions
import Foundation
import Testing

@MainActor
@Suite struct AppInstallsModelTests {
    @Test func changesFromOtherChannelsReachTheList() {
        let source = AppInstallsMockSource()
        let model = AppInstallsModel(source: source)
        let before = model.hidden.count
        // The CLI on another device hides Search.
        let cli = AppStateActor(client: "laptop-cli", origin: .cli)
        source.applyExternal(AppStateOp(key: "x1", app: "cmux/search", kind: .hide), actor: cli)
        #expect(model.states["cmux/search"]?.hidden == true)
        #expect(model.hidden.count == before + 1)
    }

    @Test func olderOrRepeatedEventsNeverGoBack() throws {
        let source = AppInstallsMockSource()
        let model = AppInstallsModel(source: source)
        let current = try #require(model.states["cmux/search"])
        var stale = current
        stale.hidden = !current.hidden
        model.receive([.changed(stale)])
        #expect(model.states["cmux/search"] == current)
        var newer = stale
        newer.revision = current.revision + 1
        model.receive([.changed(newer), .changed(current)])
        #expect(model.states["cmux/search"] == newer)
    }

    @Test func membersCannotRemoveTeamApps() async {
        let source = AppInstallsMockSource()
        let model = AppInstallsModel(source: source)
        let team = AppInstallsMockSource.teamSample.id
        #expect(!model.canRemove(team))
        await model.remove(team)
        #expect(model.states[team]?.installed == true)
        source.teamAdmin = true
        #expect(model.canRemove(team))
        await model.remove(team)
        #expect(model.states[team]?.installed == false)
    }

    @Test func aSendClearsOnlyItsOwnAppsConfirmation() async {
        let model = AppInstallsModel(source: AppInstallsMockSource())
        await model.remove("cmux/search")
        #expect(model.confirmingRemoval == "cmux/search")
        await model.send(.disable, app: "cmux/inbox")
        #expect(model.confirmingRemoval == "cmux/search")
        await model.send(.hide, app: "cmux/search")
        #expect(model.confirmingRemoval == nil && model.states["cmux/search"]?.hidden == true)
        #expect(model.sending.isEmpty)
    }
}
