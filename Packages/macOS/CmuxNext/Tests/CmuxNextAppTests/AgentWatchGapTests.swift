import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import Foundation
import Testing
@testable import CmuxNextApp

/// A daemon handover (an update, `cmux app try`, `cmux live --rust`) closes the sidebar's watch and
/// the next acpmux answers on the same socket a moment later with the same chats. Leo, 2026-11-22:
/// "no shift, no anything, just... ok now it changed." The sidebar's working dots and lanes stay on
/// screen through that gap; only a watch still closed past its hold clears them.
@MainActor
@Suite(.serialized)
struct AgentWatchGapTests {
    static let sessions: [[String: Any]] = [
        AgentLanesTests.summary("chief", "working"),
        AgentLanesTests.summary("op-asks", "input", parent: "chief"),
    ]

    @Test func aDaemonHandoverLeavesTheSidebarAsItWas() async throws {
        var old: StandInAcpmux? = try StandInAcpmux(sessions: Self.sessions)
        let path = try #require(old?.path)
        let turns = AgentTurnStateStore()
        let lanes = AgentLaneStore()
        let feed = AgentTurnStateFeed(socketPath: path, turns: turns, lanes: lanes)
        feed.start(localHost: "install:gap")
        try await until { lanes.lanes.count == Self.sessions.count }
        let shown = lanes.lanes

        // The old daemon goes; the next one serves the same socket 800 ms later.
        old = nil
        var changedFrames = 0
        let gapEnds = ContinuousClock.now + .milliseconds(800)
        while ContinuousClock.now < gapEnds {
            if lanes.lanes != shown { changedFrames += 1 }
            try await Task.sleep(for: .milliseconds(8))
        }
        let next = try StandInAcpmux(sessions: Self.sessions, at: path)
        let settles = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < settles {
            if lanes.lanes != shown { changedFrames += 1 }
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(changedFrames == 0, "the sidebar's lanes changed in \(changedFrames) frames of the handover")
        #expect(lanes.lanes == shown)

        // The new daemon's pushes still land: the watch reconnected.
        next.push(AgentLanesTests.summary("op-asks", "working", parent: "chief"))
        try await until { lanes.lanes["op-asks"]?.state == .working }
        #expect(lanes.lanes["op-asks"]?.state == .working)
        withExtendedLifetime((next, feed)) {}
    }

    @Test func aWatchClosedPastItsHoldClearsItsLanes() async throws {
        var old: StandInAcpmux? = try StandInAcpmux(sessions: Self.sessions)
        let lanes = AgentLaneStore()
        let feed = AgentTurnStateFeed(socketPath: try #require(old?.path), turns: AgentTurnStateStore(), lanes: lanes,
                                      gapHold: .milliseconds(300))
        feed.start(localHost: "install:gap")
        try await until { lanes.lanes.count == Self.sessions.count }

        old = nil // no daemon answers again
        try await until { lanes.lanes.isEmpty }
        #expect(lanes.lanes.isEmpty, "a daemon that stays gone leaves no stale working lanes")
        #expect(!lanes.live)
        withExtendedLifetime(feed) {}
    }

    /// Waits up to five seconds for `done`.
    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
