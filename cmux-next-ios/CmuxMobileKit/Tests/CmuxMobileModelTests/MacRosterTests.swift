import Foundation
import Testing
@testable import CmuxMobileModel

/// One computer registered twice (the user's report: "Abdulaziz's MacBook Pro
/// (2) 3EB7", online, and "… 39C6", the same Mac's old test install, offline):
/// the pickers and lists show the Mac once. Settings → Devices still lists both.
@Suite struct MacRosterTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func anOfflineInstallOfAnOnlineMacIsRetired() {
        let current = MacDevice(id: "3eb7", name: "Abdulaziz's MacBook Pro (2)", isOnline: true, lastSeenAt: now)
        let old = MacDevice(id: "39c6", name: "Abdulaziz's MacBook Pro (2)", isOnline: false, lastSeenAt: now - 4 * 3600)
        let other = MacDevice(id: "aaaa", name: "Aziz's MacBook Pro", isOnline: true, lastSeenAt: now)
        let roster = MacRoster([current, old, other], now: now)
        #expect(roster.visible.map(\.id) == ["3eb7", "aaaa"])
        #expect(roster.retired.map(\.id) == ["39c6"])
        // With the old record gone, the remaining Mac needs no "3EB7" tag.
        #expect(MacNameDisambiguation(roster.visible).tag(for: "3eb7") == nil)
    }

    /// Names compare without case or surrounding spaces.
    @Test func namesMatchLoosely() {
        let current = MacDevice(id: "a", name: "Studio", isOnline: true)
        let old = MacDevice(id: "b", name: " studio ", isOnline: false, lastSeenAt: now - 60)
        #expect(MacRoster([current, old], now: now).retired.map(\.id) == ["b"])
    }

    /// A teammate's offline Mac with the same name is another computer: it stays.
    @Test func aTeammatesSameNamedMacStays() {
        let mine = MacDevice(id: "a", name: "MacBook Pro", isOnline: true, ownerUserID: "me")
        let theirs = MacDevice(id: "b", name: "MacBook Pro", isOnline: false, lastSeenAt: now - 60, ownerUserID: "them")
        #expect(MacRoster([mine, theirs], now: now).visible.count == 2)
    }

    /// Both offline: the one seen last stays.
    @Test func ofTwoOfflineInstallsTheNewerStays() {
        let newer = MacDevice(id: "a", name: "Mini", isOnline: false, lastSeenAt: now - 60)
        let older = MacDevice(id: "b", name: "Mini", isOnline: false, lastSeenAt: now - 7200)
        let roster = MacRoster([older, newer], now: now)
        #expect(roster.visible.map(\.id) == ["a"])
        #expect(roster.retired.map(\.id) == ["b"])
    }

    /// Two online Macs with one name are two computers: both stay (tagged).
    @Test func twoOnlineMacsWithOneNameBothStay() {
        let macs = [MacDevice(id: "a", name: "MacBook Pro", isOnline: true), MacDevice(id: "b", name: "MacBook Pro", isOnline: true)]
        #expect(MacRoster(macs, now: now).visible.count == 2)
    }

    /// No last-seen time on either: nothing tells them apart, both stay.
    @Test func unknownTimesKeepBoth() {
        let macs = [MacDevice(id: "a", name: "Mini", isOnline: false), MacDevice(id: "b", name: "Mini", isOnline: false)]
        #expect(MacRoster(macs, now: now).visible.count == 2)
    }

    /// A Mac not seen for 30 days leaves the lists while another Mac remains.
    @Test func aMacGoneForAMonthIsRetired() {
        let gone = MacDevice(id: "a", name: "Old iMac", isOnline: false, lastSeenAt: now - 31 * 24 * 3600)
        let recent = MacDevice(id: "b", name: "MacBook", isOnline: false, lastSeenAt: now - 24 * 3600)
        #expect(MacRoster([gone, recent], now: now).visible.map(\.id) == ["b"])
        // The only Mac stays, however old: the lists never empty out on their own.
        #expect(MacRoster([gone], now: now).visible.map(\.id) == ["a"])
    }

    /// A retired record that comes back online shows again.
    @Test func aRetiredMacBackOnlineShows() {
        let current = MacDevice(id: "a", name: "Mini", isOnline: true)
        var old = MacDevice(id: "b", name: "Mini", isOnline: false, lastSeenAt: now - 3600)
        #expect(MacRoster([current, old], now: now).retired.map(\.id) == ["b"])
        old.isOnline = true
        #expect(MacRoster([current, old], now: now).visible.map(\.id) == ["a", "b"])
    }

    /// The month rule never retires an online Mac, however old its last-seen time.
    @Test func anOnlineMacIsNeverStale() {
        let online = MacDevice(id: "a", name: "Old iMac", isOnline: true, lastSeenAt: now - 90 * 24 * 3600)
        let other = MacDevice(id: "b", name: "MacBook", isOnline: true)
        #expect(MacRoster([online, other], now: now).visible.count == 2)
    }
}
