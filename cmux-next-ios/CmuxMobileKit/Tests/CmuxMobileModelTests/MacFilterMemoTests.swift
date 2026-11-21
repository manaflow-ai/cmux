import Foundation
import Testing
@testable import CmuxMobileModel

/// verify/perf-latency.md: the Workspaces toolbar's Mac names and Filter rows
/// are computed once per change, not on every body pass.
@MainActor @Suite struct MacFilterMemoTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let macs = [
        MacDevice(id: "aaaa-1111", name: "Aziz's MacBook Pro", isOnline: false, lastSeenAt: now.addingTimeInterval(-4 * 60)),
        MacDevice(id: "bbbb-2222", name: "Aziz's MacBook Pro", isOnline: true),
        MacDevice(id: "cccc-3333", name: "Studio", isOnline: true),
    ]

    func input(_ macs: [MacDevice] = macs, link: [String: String] = ["bbbb-2222": "Connected"],
               connection: [String: MacConnection] = ["bbbb-2222": .connected], now: Date = now) -> MacFilterMemo.Input {
        MacFilterMemo.Input(macs: macs, connection: connection, linkStatus: link, live: true, now: now)
    }

    @Test func namesAreComputedOnceUntilAnIdOrNameChanges() {
        let memo = MacFilterMemo()
        for _ in 0..<50 { _ = memo.names(Self.macs) }
        #expect(memo.nameComputations == 1)
        #expect(memo.names(Self.macs).displayName(Self.macs[1]) == "Aziz's MacBook Pro 2222")
        var renamed = Self.macs
        renamed[0].name = "Old MacBook"
        #expect(memo.names(renamed).displayName(renamed[1]) == "Aziz's MacBook Pro")
        #expect(memo.nameComputations == 2)
        // Presence alone does not change names.
        var online = renamed
        online[0].isOnline = true
        _ = memo.names(online)
        #expect(memo.nameComputations == 2)
    }

    @Test func filterRowsMatchTheMenuTextOnlineFirst() {
        let entries = MacFilterMemo().entries(input())
        #expect(entries.map(\.id) == ["bbbb-2222", "cccc-3333", "aaaa-1111"])
        #expect(entries[0] == .init(id: "bbbb-2222", title: "Aziz's MacBook Pro 2222", detail: "Connected"))
        #expect(entries[1].detail == "Online · Not connected")
        #expect(entries[2] == .init(id: "aaaa-1111", title: "Aziz's MacBook Pro 1111", detail: "Last seen 4m ago"))
    }

    @Test func filterRowsRecomputeOnlyWhenTheirInputsChange() {
        let memo = MacFilterMemo()
        for _ in 0..<20 { _ = memo.entries(input()) }
        #expect(memo.entryComputations == 1)
        _ = memo.entries(input(link: ["bbbb-2222": "Connected · WebRTC TURN"]))
        #expect(memo.entryComputations == 2)
        _ = memo.entries(input(link: ["bbbb-2222": "Connected · WebRTC TURN"], now: Self.now.addingTimeInterval(20)))
        #expect(memo.entryComputations == 2)
        let later = memo.entries(input(link: ["bbbb-2222": "Connected · WebRTC TURN"], now: Self.now.addingTimeInterval(120)))
        #expect(memo.entryComputations == 3)
        #expect(later.last?.detail.hasPrefix("Last seen 6m ago") == true)
    }
}
