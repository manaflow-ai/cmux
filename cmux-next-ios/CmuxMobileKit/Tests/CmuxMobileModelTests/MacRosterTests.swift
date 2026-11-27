import Foundation
import Testing
@testable import CmuxMobileModel

/// Each cmux build on a computer is its own Mac (Aziz, 2026-11-12: builds on one computer are
/// "a single instance" each, and the phone "shouldn't group them as one computer"). The builds
/// name themselves apart (`MacBook Pro`, `MacBook Pro (NIGHTLY)`); a name still says nothing about
/// identity: same-named Macs stay apart with their tags.
@Suite struct MacRosterTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

    @Test func twoBuildsOnOneMacAreTwoMacs() {
        let stable = MacDevice(id: "3eb7", name: "Abdulaziz's MacBook Pro", isOnline: true, lastSeenAt: now,
                               ownerUserID: "me", machineID: machine)
        let nightly = MacDevice(id: "39c6", name: "Abdulaziz's MacBook Pro (NIGHTLY)", isOnline: false,
                                lastSeenAt: now - 4 * 3600, ownerUserID: "me", machineID: machine)
        let other = MacDevice(id: "aaaa", name: "Aziz's MacBook Pro", isOnline: true, lastSeenAt: now, ownerUserID: "me",
                              machineID: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2")
        let roster = MacRoster([nightly, stable, other])
        #expect(roster.visible.map(\.id) == ["39c6", "3eb7", "aaaa"])
        // The lane in the name tells them apart: no tag needed.
        let names = MacNameDisambiguation(roster.visible)
        #expect(names.tag(for: "3eb7") == nil && names.tag(for: "39c6") == nil)
    }

    /// Two builds that registered the same name (an older host that sends no lane) stay two
    /// Macs and get the same-name tag.
    @Test func sameNamedBuildsOnOneMacAreTaggedApart() {
        let first = MacDevice(id: "a", name: "Mini", isOnline: true, lastSeenAt: now - 60, machineID: machine)
        let second = MacDevice(id: "b", name: "Mini", isOnline: false, lastSeenAt: now, machineID: machine)
        let roster = MacRoster([first, second])
        #expect(roster.visible.map(\.id) == ["a", "b"])
        let names = MacNameDisambiguation(roster.visible)
        #expect(names.tag(for: "a") != nil && names.tag(for: "b") != nil)
    }

    /// Same-named Macs on different computers are two Macs, tagged apart.
    @Test func sameNamedMacsOnDifferentComputersBothStay() {
        let mini1 = MacDevice(id: "a", name: "cmux mini", isOnline: true, ownerUserID: "me", machineID: machine)
        let mini2 = MacDevice(id: "b", name: "cmux mini", isOnline: false, lastSeenAt: now - 60, ownerUserID: "me",
                              machineID: "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3")
        let roster = MacRoster([mini1, mini2])
        #expect(roster.visible.map(\.id) == ["a", "b"])
    }

    /// A Mac not seen for months stays listed.
    @Test func anOldOfflineMacStays() {
        let gone = MacDevice(id: "a", name: "Old iMac", isOnline: false, lastSeenAt: now - 120 * 24 * 3600, machineID: machine)
        let recent = MacDevice(id: "b", name: "MacBook", isOnline: true, machineID: "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4")
        #expect(MacRoster([gone, recent]).visible.map(\.id) == ["a", "b"])
    }

    /// The same record listed twice (two teams' lists merged) is one row.
    @Test func aRepeatedRecordIsListedOnce() {
        let mac = MacDevice(id: "a", name: "Mini", isOnline: true, machineID: machine)
        #expect(MacRoster([mac, mac]).visible.map(\.id) == ["a"])
    }

    /// Builds of one computer registered in two teams: each team lists its own, and the
    /// account's Macs (the tags' scope) keep both.
    @Test func eachTeamListsItsOwnBuild() {
        let inTeam = MacDevice(id: "a", name: "Mini", isOnline: true, ownerUserID: "me", machineID: machine)
        let inPersonal = MacDevice(id: "b", name: "Mini (NIGHTLY)", isOnline: false, lastSeenAt: now, ownerUserID: "me",
                                   machineID: machine)
        let teams = [Team(id: "t", name: "Team", macs: [inTeam]), Team(id: "p", name: "Personal", macs: [inPersonal])]
        #expect(MacRoster.accountMacs(teams).map(\.id) == ["a", "b"])
        let both = Team(id: "t", name: "Team", macs: [inTeam, inPersonal])
        #expect(MacRoster.accountMacs([both]).map(\.id) == ["a", "b"])
        #expect(both.listedMacs.map(\.id) == ["a", "b"])
    }
}
