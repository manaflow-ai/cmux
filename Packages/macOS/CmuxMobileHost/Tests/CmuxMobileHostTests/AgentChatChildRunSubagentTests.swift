import CmuxMobileHost
import Foundation
import Testing

/// Claude opens a child on its spawn tool's `PreToolUse`, which carries no
/// agent id, and closes it on `SubagentStop`, which carries only the agent
/// id. The child's own hook events name both, so they tie the two together.
@Suite("Agent chat child runs by agent id")
struct AgentChatChildRunSubagentTests {
    private func child(
        _ id: String, type: String? = nil, toolUseID: String? = nil, at seconds: TimeInterval
    ) -> AgentChatChildRun {
        AgentChatChildRun(
            id: id, startedAt: Date(timeIntervalSince1970: seconds), agentType: type, toolUseID: toolUseID
        )
    }

    private let stopTime = Date(timeIntervalSince1970: 100)

    @Test func stopClosesTheChildBoundToItsAgentIDNotTheOldest() {
        var children = [child("explorer", at: 1), child("oracle", at: 2)]
        children.bindSubagent(agentID: "agent-explorer", agentType: nil)
        children.bindSubagent(agentID: "agent-oracle", agentType: nil)

        children.closeSubagent(agentID: "agent-oracle", agentType: nil, requestID: "unrelated", at: stopTime)

        #expect(children[0].isRunning)
        #expect(children[1].endedAt == stopTime)
    }

    @Test func bindingPrefersTheChildOfTheSameType() {
        var children = [child("first", type: "general-purpose", at: 1), child("second", type: "Explore", at: 2)]

        children.bindSubagent(agentID: "agent-explore", agentType: "Explore")

        #expect(children[0].agentID == nil)
        #expect(children[1].agentID == "agent-explore")
    }

    @Test func bindingFallsBackToTheOldestChildWithNoTypeAndSkipsOtherTypes() {
        var children = [child("typed", type: "Explore", at: 1), child("untyped", at: 2)]

        children.bindSubagent(agentID: "agent-general", agentType: "general-purpose")

        #expect(children[0].agentID == nil)
        #expect(children[1].agentID == "agent-general")

        children.bindSubagent(agentID: "agent-other", agentType: "Plan")
        #expect(children[0].agentID == nil)
    }

    @Test func bindingIsStableAcrossLaterEventsFromTheSameAgent() {
        var children = [child("first", at: 1), child("second", at: 2)]

        children.bindSubagent(agentID: "agent-a", agentType: nil)
        children.bindSubagent(agentID: "agent-a", agentType: nil)

        #expect(children[0].agentID == "agent-a")
        #expect(children[1].agentID == nil)
    }

    @Test func settledChildrenAreNeverBound() {
        var children = [child("done", at: 1), child("running", at: 2)]
        children[0].endedAt = Date(timeIntervalSince1970: 5)

        children.bindSubagent(agentID: "agent-a", agentType: nil)

        #expect(children[0].agentID == nil)
        #expect(children[1].agentID == "agent-a")
    }

    @Test func stopForAnUnknownAgentLeavesBoundChildrenRunning() {
        var children = [child("real", at: 1)]
        children.bindSubagent(agentID: "agent-real", agentType: nil)

        children.closeSubagent(agentID: "agent-never-started", agentType: nil, requestID: nil, at: stopTime)

        #expect(children[0].isRunning)
    }

    @Test func repeatedStopForTheSameAgentClosesNothingElse() {
        var children = [child("explorer", at: 1), child("sibling", at: 2)]
        children.bindSubagent(agentID: "agent-explorer", agentType: nil)

        children.closeSubagent(agentID: "agent-explorer", agentType: nil, requestID: nil, at: stopTime)
        children.closeSubagent(agentID: "agent-explorer", agentType: nil, requestID: nil, at: stopTime.addingTimeInterval(5))

        #expect(children[0].endedAt == stopTime)
        #expect(children[1].isRunning)
    }

    /// A subagent that used no tool never bound itself; its stop names its type.
    @Test func stopForAnUnboundAgentClosesTheUnboundChildOfItsType() {
        var children = [
            child("bound", type: "oracle", at: 1), child("other", type: "explorer", at: 2),
            child("quiet", type: "oracle", at: 3),
        ]
        children.bindSubagent(agentID: "agent-bound", agentType: "oracle")

        children.closeSubagent(agentID: "agent-quiet", agentType: "oracle", requestID: nil, at: stopTime)

        #expect(children[0].isRunning)
        #expect(children[1].isRunning)
        #expect(children[2].endedAt == stopTime)
        #expect(children[2].agentID == "agent-quiet")
    }

    /// Claude sends stops for agent ids that never started, with no type.
    @Test func stopForAnUnknownAgentWithNoTypeClosesNothing() {
        var children = [child("not-bound-yet", at: 1)]

        children.closeSubagent(agentID: "agent-never-started", agentType: nil, requestID: nil, at: stopTime)

        #expect(children[0].isRunning)
        #expect(children[0].agentID == nil)
    }

    @Test func stopForAnUnknownAgentNeverTakesAChildOfAnotherType() {
        var children = [child("explorer", type: "explorer", at: 1)]

        children.closeSubagent(agentID: "agent-oracle", agentType: "oracle", requestID: nil, at: stopTime)

        #expect(children[0].isRunning)
    }

    @Test func stopWithNoAgentIDKeepsTheOldestFirstFallback() {
        var children = [child("first", at: 1), child("second", at: 2)]

        children.closeSubagent(agentID: nil, agentType: nil, requestID: nil, at: stopTime)

        #expect(children[0].endedAt == stopTime)
        #expect(children[1].isRunning)
    }

    @Test func stopStillMatchesARequestID() {
        var children = [child("first", at: 1), child("second", at: 2)]

        children.closeSubagent(agentID: nil, agentType: nil, requestID: "second", at: stopTime)

        #expect(children[0].isRunning)
        #expect(children[1].endedAt == stopTime)
    }

    @Test func taskNotificationIDsCloseOnlyTheChildrenTheyName() {
        var children = [
            child("stopped", toolUseID: "toolu_1", at: 1), child("running", toolUseID: "toolu_2", at: 2),
            child("stopped-before-any-tool", toolUseID: "toolu_3", at: 3), child("no-ids", at: 4),
        ]
        children.bindSubagent(agentID: "agent-stopped", agentType: nil)
        children.bindSubagent(agentID: "agent-running", agentType: nil)

        children.closeSubagents(finishedTaskIDs: ["agent-stopped", "toolu_3", "bash_7"], at: stopTime)

        #expect(children[0].endedAt == stopTime)
        #expect(children[1].isRunning)
        #expect(children[2].endedAt == stopTime)
        #expect(children[3].isRunning)
    }
}
