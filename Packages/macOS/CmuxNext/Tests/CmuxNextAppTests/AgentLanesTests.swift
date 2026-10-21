import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-v9k2f: acpmux decides each session's lane (the summary's `lane`): working, waiting on a
/// person, idle, failed (with why, e.g. "Credit balance too low") or lost. The app's watch feed
/// mirrors it into ``AgentLaneStore`` for the Priority view, the Chief item and the session tree.
@MainActor
@Suite(.serialized)
struct AgentLanesTests {
    /// One session summary as acpmux sends it, with its lane.
    static func summary(_ id: String, _ state: String, since: Double = 1_760_000_000_000, error: String? = nil,
                        parent: String? = nil, peer: String? = nil, workspaceID: String? = nil) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": id, "name": id, "status": "idle",
                                      "lane": ["state": state, "since": since, "error": error as Any]]
        if let parent { summary["tags"] = [AgentActivityLane.parentTag: parent] }
        if let peer { summary["peer"] = peer; summary["name"] = "\(peer)/\(id)" }
        if let workspaceID { summary["workspaceId"] = workspaceID }
        return summary
    }

    /// One session in each lane state, on this Mac and an acpmux peer, under a coordinator.
    static let sessions: [[String: Any]] = [
        summary("chief", "working"),
        summary("op-busy", "working", parent: "chief"),
        summary("op-idle", "idle", parent: "chief"),
        summary("op-broke", "failed", error: "Credit balance too low", parent: "chief"),
        summary("op-asks", "input", parent: "chief"),
        summary("op-gone", "lost", peer: "mini"),
    ]

    @Test func theWatchFeedMirrorsEverySessionsLane() async throws {
        let acpmux = try StandInAcpmux(sessions: Self.sessions)
        let lanes = AgentLaneStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: AgentTurnStateStore(), lanes: lanes)
        feed.start(localHost: "install:lanes")
        try await until { lanes.lanes.count == Self.sessions.count }

        #expect(lanes.lanes["op-broke"]?.state == .failed)
        #expect(lanes.lanes["op-broke"]?.error == "Credit balance too low")
        #expect(lanes.lanes["op-broke"]?.parent == "chief")
        #expect(lanes.lanes["op-asks"]?.state == .input)
        #expect(lanes.lanes["op-idle"]?.state == .idle)
        #expect(lanes.lanes["op-idle"]?.since == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(lanes.lanes["op-gone"]?.peer == "mini")

        // The idle lane dies on its next turn: the store follows the push, no poll.
        acpmux.push(Self.summary("op-idle", "failed", error: "Credit balance too low", parent: "chief"))
        try await until { lanes.lanes["op-idle"]?.state == .failed }
        #expect(lanes.lanes["op-idle"]?.error == "Credit balance too low")

        // A person answered the permission; the lane works again.
        acpmux.push(Self.summary("op-asks", "working", parent: "chief"))
        try await until { lanes.lanes["op-asks"]?.state == .working }
        #expect(lanes.lanes["op-asks"]?.state == .working)

        // A closed session has no lane and leaves the store.
        acpmux.push(["sessionId": "op-busy", "name": "op-busy", "status": "closed", "lane": NSNull()])
        try await until { lanes.lanes["op-busy"] == nil }
        #expect(lanes.lanes["op-busy"] == nil)
        withExtendedLifetime((acpmux, feed)) {}
    }

    @Test func aLanePreservesTheExistingSessionWorkspaceBinding() {
        let summary = Self.summary("codex-1", "working", workspaceID: "workspace-7")
        let lane = AgentActivityLane.of(summary: summary)
        #expect(lane?.workspaceID == "workspace-7")
    }

    /// hq#2509: a lane row says which harness owns it and what it is doing now. acpmux masks
    /// secrets in `lane.step` before the summary leaves it; the raw prompt beside it still holds
    /// the token, so the app reads only `lane.step` and never falls back to the prompt.
    @Test func aLaneShowsTheDaemonsMaskedStepNeverTheRawPrompt() {
        let token = "gh" + "p_" + "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"
        var summary = Self.summary("op-busy", "working")
        summary["harness"] = "codex"
        summary["turn"] = ["prompt": "push with \(token)", "startedAt": 1_760_000_500_000.0]
        summary["lastMessage"] = ["role": "agent", "text": token]
        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull(), "step": "push with [github token]"]
        let lane = AgentActivityLane.of(summary: summary)
        #expect(lane?.harness == "codex")
        #expect(lane?.step == "push with [github token]")

        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull()]
        #expect(AgentActivityLane.of(summary: summary)?.step == nil, "an acpmux from before lane.step shows no step")
    }

    /// hq#2509: a lane's title is acpmux's masked `lane.title`, never the summary's raw title or
    /// latest prompt; an acpmux from before it shows the session's name.
    @Test func aLanesTitleIsTheDaemonsMaskedTitle() {
        let token = "gh" + "p_" + "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"
        var summary = Self.summary("op-busy", "working")
        summary["title"] = "push \(token)"
        summary["lastPrompt"] = "push \(token)"
        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull(), "title": "push [github token]"]
        #expect(AgentActivityLane.of(summary: summary)?.title == "push [github token]")
        summary["lane"] = ["state": "working", "since": 1_760_000_500_000.0, "error": NSNull()]
        #expect(AgentActivityLane.of(summary: summary)?.title == "op-busy")
    }

    /// Waits up to five seconds for `done`.
    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
