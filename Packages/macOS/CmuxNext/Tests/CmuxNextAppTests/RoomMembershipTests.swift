import CmuxNextDaemon
@testable import CmuxNextApp
import Testing

/// Room rules (plans/cmux-next/data-model.md 3.2): pins beat follows, a
/// workspace is pinned to at most one room, and a workspace in no room
/// shows in `default`.
@Suite struct RoomMembershipTests {
    private let work: ProfileID = "prof_work", play: ProfileID = "prof_play"
    private let mac = "mac-uuid", box = "box-uuid"

    private func ws(_ session: String, _ key: String) -> RoomMembership.Workspace { .init(session: session, key: key) }

    @Test func followersShowUnpinnedWorkspacesOfTheirSessions() {
        let rules = RoomMembership(follows: [.defaultProfile: [mac, box], work: [box]])
        #expect(rules.rooms(of: ws(box, "w1")) == [.defaultProfile, work])
        #expect(rules.rooms(of: ws(mac, "w2")) == [.defaultProfile])
    }

    @Test func aPinShowsTheWorkspaceOnlyInItsRoom() {
        var rules = RoomMembership(follows: [.defaultProfile: [mac, box], work: [box]])
        rules.pin(ws(box, "w1"), to: play)
        #expect(rules.rooms(of: ws(box, "w1")) == [play])
        #expect(!rules.contains(ws(box, "w1"), in: work))
        rules.pin(ws(box, "w1"), to: work)
        #expect(rules.rooms(of: ws(box, "w1")) == [work])
    }

    @Test func unfollowedWorkspacesFallBackToDefault() {
        let rules = RoomMembership(follows: [work: [box]])
        #expect(rules.rooms(of: ws("offline-uuid", "w9")) == [.defaultProfile])
    }

    @Test func deletingARoomMovesOrDropsItsPins() {
        var rules = RoomMembership(follows: [.defaultProfile: [mac], work: [mac]])
        rules.pin(ws(mac, "w1"), to: work)
        rules.pin(ws(mac, "w2"), to: work)
        var moved = rules
        moved.removeRoom(work, movingPinsTo: play)
        #expect(moved.rooms(of: ws(mac, "w1")) == [play])
        rules.removeRoom(work, movingPinsTo: nil)
        #expect(rules.rooms(of: ws(mac, "w1")) == [.defaultProfile])
    }

    @Test func followingAllIsTheFallbackForOlderHomes() {
        let rules = RoomMembership.followingAll([mac, box])
        #expect(rules.rooms(of: ws(box, "w1")) == [.defaultProfile])
    }
}
