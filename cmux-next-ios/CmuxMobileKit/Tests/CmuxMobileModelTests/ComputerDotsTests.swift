import Foundation
import Testing
@testable import CmuxMobileModel

/// Leo, 2026-11-24 (item 4): "x of x macs online is... hm. idk if we need to show that on the top
/// per se. it feels like we csn go more implied like... red dot green dot when you switch between
/// your computers' stuff. cuz it wont just be macs. like afaik this was only [one Mac]'s so i
/// dont need to see the others".
@MainActor @Suite struct ComputerDotsTests {
    static let macs = [
        MacDevice(id: "mac-studio", name: "Studio", isOnline: true),
        MacDevice(id: "mac-office", name: "Office Mac", isOnline: true),
        // A Cloud VM: its daemon registers as a Mac-kind device, so the service lists it with the Macs.
        MacDevice(id: "vm-cloud", name: "Cloud VM", isOnline: false),
    ]

    static func listed(_ mac: MacDevice) -> MacReachability { ComputerDots.listed(mac) }

    @Test func headerShowsOneDotForTheWorkspacesComputerNotACount() {
        let header = ComputerDots.header(macs: Self.macs, scopedMacID: nil, workspaceMacID: "mac-office", linkedMacID: "mac-studio",
                                         needsYou: 0, reach: Self.listed)
        #expect(header.dot == ComputerDot(id: "mac-office", name: "Office Mac", isUp: true))
        #expect(header.text == "Office Mac")
        #expect(!header.text.contains("of"))
        #expect(!header.text.contains("online"))
    }

    @Test func aCloudVMIsAComputerWithARedDotWhenUnreachable() {
        let header = ComputerDots.header(macs: Self.macs, scopedMacID: nil, workspaceMacID: "vm-cloud", linkedMacID: nil,
                                         needsYou: 2, reach: Self.listed)
        #expect(header.dot == ComputerDot(id: "vm-cloud", name: "Cloud VM", isUp: false))
        #expect(header.text == "Cloud VM · 2 need you")
    }

    @Test func greenWhileReachableOrOnItsWayRedWhenNot() {
        #expect(ComputerDots.isUp(.connected, listedOnline: true))
        #expect(ComputerDots.isUp(.connecting, listedOnline: true))
        #expect(ComputerDots.isUp(.notConnected, listedOnline: true))
        #expect(!ComputerDots.isUp(.offline(lastSeenAt: nil), listedOnline: false))
        #expect(!ComputerDots.isUp(.noAnswer(listedOnline: true, lastSeenAt: nil), listedOnline: true))
        #expect(!ComputerDots.isUp(.slow(quietSeconds: 40), listedOnline: true))
        #expect(!ComputerDots.isUp(.serviceDown, listedOnline: true))
        // The phone offline knows nothing new: the last-known presence stays.
        #expect(ComputerDots.isUp(.phoneOffline, listedOnline: true))
        #expect(!ComputerDots.isUp(.phoneOffline, listedOnline: false))
    }

    @Test func aDialThatNeverAnsweredTurnsTheDotRed() {
        let header = ComputerDots.header(macs: Self.macs, scopedMacID: nil, workspaceMacID: "mac-office", linkedMacID: nil, needsYou: 0) { _ in
            .noAnswer(listedOnline: true, lastSeenAt: nil)
        }
        #expect(header.dot?.isUp == false)
    }

    @Test func filteredToAComputerShowsItsDotAndPresence() {
        let header = ComputerDots.header(macs: Self.macs, scopedMacID: "mac-studio", workspaceMacID: "mac-office", linkedMacID: nil,
                                         needsYou: 3, scopedLine: "Online", reach: Self.listed)
        #expect(header.dot?.id == "mac-studio")
        #expect(header.text == "Studio · Online")
    }

    @Test func withNoWorkspaceTheLinkedThenFirstOnlineComputerShows() {
        #expect(ComputerDots.current(macs: Self.macs, linkedMacID: "mac-office")?.id == "mac-office")
        #expect(ComputerDots.current(macs: Self.macs, workspaceMacID: "gone", linkedMacID: nil)?.id == "mac-studio")
        let allOff = Self.macs.map { MacDevice(id: $0.id, name: $0.name, isOnline: false) }
        #expect(ComputerDots.current(macs: allOff)?.id == "mac-studio")
        #expect(ComputerDots.current(macs: []) == nil)
    }

    @Test func oneComputerAloneSaysNothingAsBefore() {
        let header = ComputerDots.header(macs: [Self.macs[0]], scopedMacID: nil, workspaceMacID: nil, linkedMacID: nil,
                                         needsYou: 0, reach: Self.listed)
        #expect(header == ComputerDots.Header(dot: nil, text: ""))
        let waiting = ComputerDots.header(macs: [Self.macs[0]], scopedMacID: nil, workspaceMacID: nil, linkedMacID: nil,
                                          needsYou: 1, reach: Self.listed)
        #expect(waiting.text == "1 needs you")
    }

    @Test func aTeamRowShowsItsCurrentComputerNotEveryComputer() {
        var team = Team(id: "t", name: "T", macs: Self.macs)
        #expect(ComputerDots.team(team, workspaceMacID: "vm-cloud") == ComputerDot(id: "vm-cloud", name: "Cloud VM", isUp: false))
        team.pickedMacID = "mac-office"
        #expect(ComputerDots.team(team)?.id == "mac-office")
        #expect(ComputerDots.team(Team(id: "e", name: "E")) == nil)
    }

    @Test func filterMenuRowsCarryAGreenOrRedDot() {
        let entries = MacFilterMemo().entries(MacFilterMemo.Input(
            macs: Self.macs, connection: ["mac-office": .connected], linkStatus: [:], live: true,
            failure: ["mac-studio": .hostUnreachable]))
        let dots = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.isOnline) })
        #expect(dots == ["mac-office": true, "mac-studio": false, "vm-cloud": false])
    }
}
