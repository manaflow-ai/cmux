import Foundation
import Testing
@testable import CmuxMobileModel

/// The build a phone picked (``Team/pickedMacID``, #46718) is the one
/// every screen lists for its computer, not only the focus: on Aziz's 2026-11-18 phone the `cu-all` dev
/// build (`0ae8a0d4…`) sorts before the tag's own Mac (`e7673bc3…`), and the Workspaces Mac filter,
/// Home, Settings → Devices and Terminal Size When Shared listed cu-all while the phone was on v3.
@MainActor
@Suite struct PickedBuildSurfacesTests {
    let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    let cuAll = "0ae8a0d4-d8d9-4872-b541-a48f3dc6cc50"
    let v3 = "e7673bc3-6fc4-4184-ba29-d80ad6743844"

    func mac(_ id: String, machine: String? = nil) -> MacDevice {
        MacDevice(id: id, name: "Aziz’s MacBook Pro", isOnline: true, ownerUserID: "me", machineID: machine ?? self.machine)
    }

    func team(_ id: String = "t", pick: String?) -> Team {
        var team = Team(id: id, name: "Personal", macs: [mac(cuAll), mac(v3)])
        team.pickedMacID = pick
        return team
    }

    /// Workspaces' and Home's Mac list (MacFilterMemo): the pick, and again when only the pick changes.
    @Test func theMacFilterListsThePickedBuild() {
        let memo = MacFilterMemo()
        #expect(memo.roster(team(pick: nil)).visible.map(\.id) == [cuAll])
        #expect(memo.roster(team(pick: v3)).visible.map(\.id) == [v3])
        #expect(memo.roster(team(pick: cuAll)).visible.map(\.id) == [cuAll])
        #expect(memo.roster(nil).visible.isEmpty)
    }

    /// The account's Macs (the same-name tags' scope) list each team's pick, as its screens do.
    @Test func theAccountsMacsListEachTeamsPick() {
        #expect(MacRoster.accountMacs([team(pick: v3)]).map(\.id) == [v3])
        #expect(MacRoster.accountMacs([team(pick: nil)]).map(\.id) == [cuAll])
    }

    /// Terminal Size When Shared lists one build per computer across the teams: the active team's pick.
    @Test func terminalSizingListsTheActiveTeamsPick() {
        let other = Team(id: "o", name: "Team", macs: [mac("mini", machine: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2")])
        #expect(MacRoster.acrossTeams([team(pick: v3), other], activeTeamID: "t").map(\.id) == [v3, "mini"])
        #expect(MacRoster.acrossTeams([team(pick: v3), other], activeTeamID: "o").map(\.id) == [cuAll, "mini"])
    }

    /// Settings → Devices calls the build Workspaces hides "another build": with the pick, that is cu-all.
    @Test func settingsMarksTheUnpickedBuildAsTheOtherBuild() {
        func row(_ id: String) -> SettingsDevice {
            SettingsDevice(ids: [id], kind: .mac, name: "Aziz’s MacBook Pro", online: true, lastSeenAt: nil, isThisDevice: false,
                           receivesNotifications: false, machineID: machine, teamID: "t")
        }
        let rows = [row(cuAll), row(v3)]
        #expect(SettingsDeviceRows.otherBuilds(rows) == [v3])
        #expect(SettingsDeviceRows.otherBuilds(rows, picked: SettingsDeviceRows.picks([team(pick: v3)])) == [cuAll])
        #expect(SettingsDeviceRows.otherBuilds(rows, picked: ["other-team": v3]) == [v3])
    }
}
