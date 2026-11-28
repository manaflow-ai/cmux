import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The cursor's own rules, and what a reset, an older Mac and a stale notice do (the detector and
/// the fake Mac are in `AcpmuxListFollowTests.swift`).
@MainActor
extension AcpmuxListFollowTests {
    /// A cursor the Mac cannot follow (another daemon run) is answered with the first page marked
    /// reset: the list is read again, and the rows the Mac no longer has are let go.
    @Test func aResetReadsTheListAgainAndLetsGoOfRowsItNoLongerHas() async throws {
        let mac = Mac(chats: 250)
        let (hub, _) = await Self.hubHoldingTheList(of: mac)
        mac.epoch = "run-2"
        mac.remove("s7")
        mac.forget()
        await hub.bind(Channel(mac))
        #expect(await hub.waitUntilReady(timeout: Self.wait, clock: ContinuousClock()))
        await hub.restOfList?.value
        #expect(mac.methods.first(where: { $0 != "initialize" }) == "_acpmux/watch")
        #expect(mac.methods.contains("_acpmux/sessions"), "the rest is read after a reset")
        #expect(hub.sessions.count == 249)
        #expect(hub.sessions["s7"] == nil)
        // The new run's cursor is held: the next reconnect follows again.
        mac.forget()
        mac.change("s8")
        await hub.bind(Channel(mac))
        #expect(await hub.waitUntilReady(timeout: Self.wait, clock: ContinuousClock()))
        #expect(mac.methods == ["initialize", "_acpmux/watch"])
        #expect(hub.sessions["s8"]?.status == "running")
    }

    /// A Mac whose acpmux does not follow answers the cursor's watch as a plain first page: the
    /// phone reads the list as before, and a refresh reads it whole.
    @Test func aMacThatDoesNotFollowIsReadAsBefore() async throws {
        let mac = Mac(chats: 250)
        mac.follows = false
        let (hub, _) = await Self.hubHoldingTheList(of: mac)
        mac.forget()
        await hub.bind(Channel(mac))
        #expect(await hub.waitUntilReady(timeout: Self.wait, clock: ContinuousClock()))
        await hub.restOfList?.value
        #expect(mac.methods.filter { $0 == "_acpmux/sessions" }.count >= 1)
        #expect(hub.sessions.count == 250)
        mac.forget()
        let feed = LiveFeed(store: FeedStore(items: []), hub: hub, place: { _ in nil })
        try await feed.refresh()
        #expect(mac.rowsRead == 250, "an older Mac's refresh reads the whole list, as before")
    }

    /// A notice older than the row held (a follow built after it went out first) does not
    /// overwrite the newer row.
    @Test func aNoticeOlderThanTheRowHeldIsDropped() async throws {
        let mac = Mac(chats: 5)
        let (hub, channel) = await Self.hubHoldingTheList(of: mac)
        let stale = mac.position
        mac.change("s2", status: "running")
        _ = try await hub.followList(timeout: Self.wait)
        #expect(hub.sessions["s2"]?.status == "running")
        let newer = mac.change("s3", status: "running")
        // Notices are applied in order: once s3's is told, s2's stale one was seen first.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var resumed = false
            hub.onWatchEvent = { event in
                guard case .sessionChanged(let session, _, _) = event, session.id == "s3", !resumed else { return }
                resumed = true
                done.resume()
            }
            channel.notify("_acpmux/session_changed", ["session": Mac.row("s2", status: "idle"), "kind": "updated", "listSeq": stale])
            channel.notify("_acpmux/session_changed", ["session": Mac.row("s3", status: "running"), "kind": "updated", "listSeq": newer])
        }
        #expect(hub.sessions["s3"]?.status == "running")
        #expect(hub.sessions["s2"]?.status == "running", "the stale notice did not win")
        #expect(hub.listCursor.position?.seq == newer)
    }

    @Test func theCursorKeepsTheHighestPositionAndRewindsWhenNoticesWereDropped() {
        var cursor = AcpmuxListCursor()
        cursor.listed(seq: 10, epoch: "e")
        let newer = cursor.admits("a", listSeq: 12)
        let older = cursor.admits("a", listSeq: 11)
        let beforeReply = cursor.admits("b", listSeq: 9)
        #expect(newer)
        #expect(!older)
        #expect(!beforeReply, "older than the list reply")
        #expect(cursor.position == .init(epoch: "e", seq: 12))
        cursor.dropped()
        #expect(cursor.position == .init(epoch: "e", seq: 10), "the next follow starts at the last reply")
        cursor.followed(seq: 15, epoch: "e")
        #expect(cursor.position == .init(epoch: "e", seq: 15))
        cursor.listed(seq: nil, epoch: nil)
        #expect(cursor.position == nil, "an acpmux that stamps no position holds no cursor")
    }
}
