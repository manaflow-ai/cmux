import Foundation
import Testing
@testable import CmuxMobileModel

/// Two builds on one computer are two Macs on every screen, whatever the phone picked (Aziz,
/// 2026-11-12/19: builds are separate instances, never grouped). On Aziz's 2026-11-18 phone the
/// `cu-all` dev build and the tag's own Mac (v3) were folded into one row, and the row showed
/// cu-all while the phone was on v3; listing both ends that.
@MainActor
@Suite struct PickedBuildSurfacesTests {
    let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    let cuAll = "0ae8a0d4-d8d9-4872-b541-a48f3dc6cc50"
    let v3 = "e7673bc3-6fc4-4184-ba29-d80ad6743844"

    func mac(_ id: String, name: String, machine: String? = nil) -> MacDevice {
        MacDevice(id: id, name: name, isOnline: true, ownerUserID: "me", machineID: machine ?? self.machine)
    }

    func team(_ id: String = "t", pick: String?) -> Team {
        var team = Team(id: id, name: "Personal", macs: [mac(cuAll, name: "Aziz’s MacBook Pro (DEV cu-all)"),
                                                         mac(v3, name: "Aziz’s MacBook Pro (DEV v3)")])
        team.pickedMacID = pick
        return team
    }

    /// Workspaces' and Home's Mac list (MacFilterMemo): both builds, picked or not.
    @Test func theMacFilterListsEveryBuild() {
        let memo = MacFilterMemo()
        #expect(memo.roster(team(pick: nil)).visible.map(\.id) == [cuAll, v3])
        #expect(memo.roster(team(pick: v3)).visible.map(\.id) == [cuAll, v3])
        #expect(memo.roster(nil).visible.isEmpty)
    }

    /// The account's Macs (the same-name tags' scope): both builds, and their lanes keep the names apart.
    @Test func theAccountsMacsListEveryBuild() {
        let macs = MacRoster.accountMacs([team(pick: v3)])
        #expect(macs.map(\.id) == [cuAll, v3])
        #expect(MacNameDisambiguation(macs).tags.isEmpty)
    }

    /// Terminal Size When Shared lists every build across the teams.
    @Test func terminalSizingListsEveryBuild() {
        let other = Team(id: "o", name: "Team", macs: [mac("mini", name: "mini", machine: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2")])
        #expect(MacRoster.acrossTeams([team(pick: v3), other], activeTeamID: "t").map(\.id) == [cuAll, v3, "mini"])
        #expect(MacRoster.acrossTeams([team(pick: v3), other], activeTeamID: "o").map(\.id) == [cuAll, v3, "mini"])
    }
}
