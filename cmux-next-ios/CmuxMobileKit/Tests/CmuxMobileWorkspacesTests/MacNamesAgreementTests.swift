import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Settings round 2: Workspaces and Settings → Devices name and date a Mac
/// the same way (one tag scope and spelling, one "Last seen" formatter).
@MainActor @Suite struct MacNamesAgreementTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    // A same-name pair split across two teams, and a third pair in one team.
    static let teams = [
        Team(id: "t1", name: "Manaflow", macs: [
            MacDevice(id: "8c41e0d2-3f2a", name: "Aziz's MacBook Pro", isOnline: true),
            MacDevice(id: "mini-4", name: "mini 4", isOnline: true),
        ]),
        Team(id: "t2", name: "Personal", macs: [
            MacDevice(id: "5b97a6f1-91c7", name: "Aziz's MacBook Pro", isOnline: false, lastSeenAt: now.addingTimeInterval(-7200)),
        ]),
    ]

    @Test func workspacesAndSettingsTagEveryMacAlike() {
        let account = Self.teams.flatMap(\.macs)
        // Workspaces: the active team's filter, tagged over the account.
        let active = Self.teams[0].macs
        let entries = MacFilterMemo().entries(MacFilterMemo.Input(macs: active, accountMacs: account, connection: [:],
                                                                 linkStatus: [:], live: false, now: Self.now))
        let workspaces = MacFilterMemo().names(account)
        // Settings → Devices: the same scope (every team's Macs).
        #expect(MacNameDisambiguation.scope(Self.teams) == account)
        let settings = MacNameDisambiguation(account: Self.teams)
        for mac in account {
            #expect(workspaces.tag(for: mac.id) == settings.tag(for: mac.id))
            #expect(workspaces.displayName(mac) == settings.displayName(id: mac.id, name: mac.name))
        }
        // The other team's namesake still tags the active team's Mac.
        #expect(entries.first { $0.id == "8c41e0d2-3f2a" }?.title == "Aziz's MacBook Pro 3F2A")
        #expect(entries.first { $0.id == "mini-4" }?.title == "mini 4")
        #expect(settings.displayName(id: "5b97a6f1-91c7", name: "Aziz's MacBook Pro") == "Aziz's MacBook Pro 91C7")
    }

    @Test func aMacOnlyTheServiceListsChangesNoTag() {
        // Devices lists a Mac no team holds (a team left), named like one in a
        // team: neither surface's tags change, because both tag over the teams.
        let workspaces = MacFilterMemo().names(MacNameDisambiguation.scope(Self.teams))
        let settings = MacNameDisambiguation(account: Self.teams)
        let stray = MacDevice(id: "dead-0001", name: "mini 4", isOnline: false)
        #expect(settings.tag(for: "mini-4") == nil)
        #expect(workspaces.tag(for: "mini-4") == nil)
        #expect(settings.tag(for: stray.id) == nil)
        #expect(settings.tags == workspaces.tags)
    }

    @Test func lastSeenIsExactAgainstTheSharedMinute() {
        let clock = MinuteClock(now: Self.now, ticking: false)
        let stamp = RelativeStamp(now: clock.now)
        #expect(stamp.presence(isOnline: false, lastSeenAt: Self.now.addingTimeInterval(-59)) == "Last seen just now")
        #expect(stamp.presence(isOnline: false, lastSeenAt: Self.now.addingTimeInterval(-60)) == "Last seen 1m ago")
        #expect(stamp.presence(isOnline: false, lastSeenAt: Self.now.addingTimeInterval(-61)) == "Last seen 1m ago")
        #expect(stamp.presence(isOnline: false, lastSeenAt: Self.now.addingTimeInterval(-119)) == "Last seen 1m ago")
        #expect(stamp.presence(isOnline: false, lastSeenAt: Self.now.addingTimeInterval(-120)) == "Last seen 2m ago")
        // The filter's cache keys on the same minute, so it formats the same text.
        let mac = MacDevice(id: "m", name: "Mac", isOnline: false, lastSeenAt: Self.now.addingTimeInterval(-90))
        let entry = MacFilterMemo().entries(MacFilterMemo.Input(macs: [mac], connection: [:], linkStatus: [:], live: false,
                                                               now: clock.now))
        #expect(entry.first?.detail == stamp.presence(isOnline: false, lastSeenAt: mac.lastSeenAt))
    }
}
