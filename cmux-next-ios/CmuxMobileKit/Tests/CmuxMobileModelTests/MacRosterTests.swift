import Foundation
import Testing
@testable import CmuxMobileModel

/// One computer, several cmux builds (the user's report: "Abdulaziz's MacBook
/// Pro (2) 3EB7" from the nightly, online, and "… 39C6" from a deleted test
/// build, offline): the pickers and lists show the computer once, found by the
/// machine id every build on it registers. A name says nothing: "I could have
/// several Macs with the same name".
@Suite struct MacRosterTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

    @Test func twoBuildsOnOneMacAreListedOnce() {
        let nightly = MacDevice(id: "3eb7", name: "Abdulaziz's MacBook Pro (2)", isOnline: true, lastSeenAt: now,
                                ownerUserID: "me", machineID: machine)
        let old = MacDevice(id: "39c6", name: "Abdulaziz's MacBook Pro (2)", isOnline: false, lastSeenAt: now - 4 * 3600,
                            ownerUserID: "me", machineID: machine)
        let other = MacDevice(id: "aaaa", name: "Aziz's MacBook Pro", isOnline: true, lastSeenAt: now, ownerUserID: "me",
                              machineID: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2")
        let roster = MacRoster([old, nightly, other])
        #expect(roster.visible.map(\.id) == ["3eb7", "aaaa"])
        #expect(roster.otherBuilds == ["3eb7": [old]])
        #expect(roster.hiddenIDs == ["39c6"])
        // With the old record folded in, the Mac needs no "3EB7" tag.
        #expect(MacNameDisambiguation(roster.visible).tag(for: "3eb7") == nil)
    }

    /// The user's correction: same-named Macs on different computers are two Macs, tagged apart.
    @Test func sameNamedMacsOnDifferentComputersBothStay() {
        let mini1 = MacDevice(id: "a", name: "cmux mini", isOnline: true, ownerUserID: "me", machineID: machine)
        let mini2 = MacDevice(id: "b", name: "cmux mini", isOnline: false, lastSeenAt: now - 60, ownerUserID: "me",
                              machineID: "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3")
        let roster = MacRoster([mini1, mini2])
        #expect(roster.visible.map(\.id) == ["a", "b"])
        #expect(roster.otherBuilds.isEmpty)
        let names = MacNameDisambiguation(roster.visible)
        #expect(names.tag(for: "a") != nil && names.tag(for: "b") != nil)
    }

    /// A record that never said which computer it is (a host that predates machine
    /// ids) is never folded into another, whatever its name and however old.
    @Test func aMacWithoutAMachineIDIsNeverHidden() {
        let current = MacDevice(id: "a", name: "Studio", isOnline: true, ownerUserID: "me", machineID: machine)
        let unknown = MacDevice(id: "b", name: "Studio", isOnline: false, lastSeenAt: now - 90 * 24 * 3600, ownerUserID: "me")
        let alsoUnknown = MacDevice(id: "c", name: "Studio", isOnline: false, ownerUserID: "me")
        #expect(MacRoster([current, unknown, alsoUnknown]).visible.map(\.id) == ["a", "b", "c"])
    }

    /// The 30-day rule is gone: a Mac not seen for months stays listed.
    @Test func anOldOfflineMacStays() {
        let gone = MacDevice(id: "a", name: "Old iMac", isOnline: false, lastSeenAt: now - 120 * 24 * 3600, machineID: machine)
        let recent = MacDevice(id: "b", name: "MacBook", isOnline: true, machineID: "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4")
        #expect(MacRoster([gone, recent]).visible.map(\.id) == ["a", "b"])
    }

    /// Machine ids compare within one owner: a teammate's Mac is never another build of mine.
    @Test func anotherOwnersMacIsNeverABuildOfMine() {
        let mine = MacDevice(id: "a", name: "MacBook Pro", isOnline: true, ownerUserID: "me", machineID: machine)
        let theirs = MacDevice(id: "b", name: "MacBook Pro", isOnline: false, lastSeenAt: now - 60, ownerUserID: "them",
                               machineID: machine)
        #expect(MacRoster([mine, theirs]).visible.count == 2)
    }

    /// Both offline: the build seen last is listed.
    @Test func ofTwoOfflineBuildsTheNewerIsListed() {
        let newer = MacDevice(id: "a", name: "Mini", isOnline: false, lastSeenAt: now - 60, machineID: machine)
        let older = MacDevice(id: "b", name: "Mini (dev)", isOnline: false, lastSeenAt: now - 7200, machineID: machine)
        let roster = MacRoster([older, newer])
        #expect(roster.visible.map(\.id) == ["a"])
        #expect(roster.otherBuilds == ["a": [older]])
    }

    /// Both online: one stable choice, whichever reconnected last.
    @Test func ofTwoOnlineBuildsTheChoiceIsStable() {
        let first = MacDevice(id: "a", name: "Mini", isOnline: true, lastSeenAt: now - 60, machineID: machine)
        let second = MacDevice(id: "b", name: "Mini", isOnline: true, lastSeenAt: now, machineID: machine)
        #expect(MacRoster([first, second]).visible.map(\.id) == ["a"])
        let reconnected = MacDevice(id: "a", name: "Mini", isOnline: true, lastSeenAt: now + 60, machineID: machine)
        #expect(MacRoster([second, reconnected]).visible.map(\.id) == ["a"])
    }

    /// The offline build that comes back online is listed instead.
    @Test func aBuildBackOnlineIsListed() {
        let current = MacDevice(id: "a", name: "Mini", isOnline: false, lastSeenAt: now - 60, machineID: machine)
        var other = MacDevice(id: "b", name: "Mini", isOnline: false, lastSeenAt: now - 3600, machineID: machine)
        #expect(MacRoster([current, other]).visible.map(\.id) == ["a"])
        other.isOnline = true
        #expect(MacRoster([current, other]).visible.map(\.id) == ["b"])
    }

    /// The same record listed twice (two teams' lists) stays one row and no other build.
    @Test func aRepeatedRecordIsNotItsOwnOtherBuild() {
        let mac = MacDevice(id: "a", name: "Mini", isOnline: true, machineID: machine)
        let roster = MacRoster([mac, mac])
        #expect(roster.otherBuilds.isEmpty)
    }

    /// Builds of one computer registered in two teams: each team lists its own,
    /// and the account's Macs (the tags' scope) keep both, as the teams show them.
    @Test func eachTeamListsItsOwnBuild() {
        let inTeam = MacDevice(id: "a", name: "Mini", isOnline: true, ownerUserID: "me", machineID: machine)
        let inPersonal = MacDevice(id: "b", name: "Mini", isOnline: false, lastSeenAt: now, ownerUserID: "me", machineID: machine)
        let teams = [Team(id: "t", name: "Team", macs: [inTeam]), Team(id: "p", name: "Personal", macs: [inPersonal])]
        #expect(MacRoster.accountMacs(teams).map(\.id) == ["a", "b"])
        let both = Team(id: "t", name: "Team", macs: [inTeam, inPersonal])
        #expect(MacRoster.accountMacs([both]).map(\.id) == ["a"])
    }
}
