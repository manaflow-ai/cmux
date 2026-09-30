import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileHost

@Suite("Agent session attention ordering")
struct AgentSessionAttentionTests {
    /// Fixed reference instant. Ordering is compared against explicit offsets
    /// from here so no assertion depends on the wall clock.
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ offset: TimeInterval) -> Date { Self.origin.addingTimeInterval(offset) }

    private func record(
        _ sessionID: String,
        state: ChatAgentState,
        lastActivity: TimeInterval,
        kind: ChatAgentKind = .claude,
        title: String? = nil,
        lastOutput: String? = nil,
        children: [AgentChatChildRun] = [],
        hasHookLifecycleState: Bool = true,
        linkedPullRequests: [AgentSessionPullRequest] = [],
        hasFinishedTurn: Bool = true
    ) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: kind,
            state: state,
            hasHookLifecycleState: hasHookLifecycleState,
            lastActivityAt: at(lastActivity),
            children: children,
            title: title,
            lastOutput: lastOutput,
            linkedPullRequests: linkedPullRequests,
            hasFinishedTurn: hasFinishedTurn
        )
    }

    private func ids(_ records: [AgentChatSessionRecord]) -> [String] {
        records.map(\.sessionID)
    }

    // MARK: - Buckets

    @Test("Buckets rank needs-input over working over idle over ended")
    func bucketOrder() {
        let records = [
            record("ended", state: .ended, lastActivity: 400),
            record("idle", state: .idle, lastActivity: 300),
            record("working", state: .working(since: at(200)), lastActivity: 200),
            record("needs", state: .needsInput(since: at(100)), lastActivity: 100),
        ]
        #expect(ids(records.orderedByAttention()) == ["needs", "working", "idle", "ended"])
    }

    @Test("Bucket wins over recency")
    func bucketBeatsRecency() {
        // The idle session is the most recently active by a wide margin and
        // still sorts below a session that has been blocked since the epoch.
        let records = [
            record("fresh-idle", state: .idle, lastActivity: 9_000),
            record("stale-needs", state: .needsInput(since: at(1)), lastActivity: 1),
        ]
        #expect(ids(records.orderedByAttention()) == ["stale-needs", "fresh-idle"])
    }

    @Test("Rank wire names match the agent state vocabulary")
    func rankWireNames() {
        #expect(ChatAgentState.needsInput(since: at(0)).attentionRank.wireName == "needs_input")
        #expect(ChatAgentState.working(since: at(0)).attentionRank.wireName == "working")
        #expect(ChatAgentState.idle.attentionRank.wireName == "idle")
        #expect(ChatAgentState.ended.attentionRank.wireName == "ended")
    }

    // MARK: - Within-bucket tie-breaks

    @Test("Needs-input sorts longest-blocked first")
    func needsInputOldestFirst() {
        let records = [
            record("recent", state: .needsInput(since: at(500)), lastActivity: 500),
            record("oldest", state: .needsInput(since: at(10)), lastActivity: 900),
            record("middle", state: .needsInput(since: at(200)), lastActivity: 200),
        ]
        // Note `oldest` also has the newest lastActivityAt: within this bucket
        // the question's age decides, not activity.
        #expect(ids(records.orderedByAttention()) == ["oldest", "middle", "recent"])
    }

    @Test("Working sorts longest-running first")
    func workingOldestFirst() {
        let records = [
            record("just-started", state: .working(since: at(800)), lastActivity: 800),
            record("grinding", state: .working(since: at(20)), lastActivity: 850),
        ]
        #expect(ids(records.orderedByAttention()) == ["grinding", "just-started"])
    }

    @Test("Idle sorts most-recently-active first")
    func idleNewestFirst() {
        let records = [
            record("cold", state: .idle, lastActivity: 100),
            record("warm", state: .idle, lastActivity: 700),
            record("lukewarm", state: .idle, lastActivity: 400),
        ]
        #expect(ids(records.orderedByAttention()) == ["warm", "lukewarm", "cold"])
    }

    @Test("Ended sorts most-recently-active first")
    func endedNewestFirst() {
        let records = [
            record("old-finish", state: .ended, lastActivity: 100),
            record("new-finish", state: .ended, lastActivity: 600),
        ]
        #expect(ids(records.orderedByAttention()) == ["new-finish", "old-finish"])
    }

    // MARK: - Totality and stability

    @Test("Equal timestamps break on session id")
    func sessionIDTieBreak() {
        let records = [
            record("c", state: .needsInput(since: at(50)), lastActivity: 50),
            record("a", state: .needsInput(since: at(50)), lastActivity: 50),
            record("b", state: .needsInput(since: at(50)), lastActivity: 50),
        ]
        #expect(ids(records.orderedByAttention()) == ["a", "b", "c"])
    }

    @Test("Order does not depend on input order")
    func orderIsIndependentOfInputOrder() {
        // The registry hands out records from a dictionary, so input order is
        // not stable across calls. Every permutation must land identically.
        let records = [
            record("needs-old", state: .needsInput(since: at(10)), lastActivity: 10),
            record("needs-new", state: .needsInput(since: at(20)), lastActivity: 20),
            record("working", state: .working(since: at(5)), lastActivity: 30),
            record("idle-a", state: .idle, lastActivity: 60),
            record("idle-b", state: .idle, lastActivity: 60),
            record("ended", state: .ended, lastActivity: 70),
        ]
        let expected = ids(records.orderedByAttention())
        #expect(expected == ["needs-old", "needs-new", "working", "idle-a", "idle-b", "ended"])
        for _ in 0..<32 {
            #expect(ids(records.shuffled().orderedByAttention()) == expected)
        }
    }

    @Test("Empty input is empty output")
    func emptyInput() {
        let empty: [AgentChatSessionRecord] = []
        #expect(empty.orderedByAttention().isEmpty)
        #expect(empty.attentionCounts() == AgentSessionAttentionCounts())
        #expect(empty.attentionCounts().total == 0)
    }

    // MARK: - State age

    @Test("State age is measured from the state's start")
    func stateAge() {
        let age = ChatAgentState.working(since: at(100)).attentionStateAgeSeconds(now: at(175))
        #expect(age == 75)
    }

    @Test("A state stamped in the future reports zero age, not a negative one")
    func stateAgeClampsToZero() {
        // Hook timestamps come from the agent process, whose clock can read
        // slightly ahead of ours.
        let age = ChatAgentState.needsInput(since: at(200)).attentionStateAgeSeconds(now: at(190))
        #expect(age == 0)
    }

    @Test("Idle and ended have no state age")
    func settledStatesHaveNoAge() {
        #expect(ChatAgentState.idle.attentionStateAgeSeconds(now: at(0)) == nil)
        #expect(ChatAgentState.ended.attentionStateAgeSeconds(now: at(0)) == nil)
        #expect(ChatAgentState.idle.attentionStateSince == nil)
        #expect(ChatAgentState.ended.attentionStateSince == nil)
    }

    // MARK: - Counts and the needs-me filter

    @Test("Counts tally each bucket")
    func countsTally() {
        let records = [
            record("n1", state: .needsInput(since: at(1)), lastActivity: 1),
            record("n2", state: .needsInput(since: at(2)), lastActivity: 2),
            record("w1", state: .working(since: at(3)), lastActivity: 3),
            record("i1", state: .idle, lastActivity: 4),
            record("i2", state: .idle, lastActivity: 5),
            record("i3", state: .idle, lastActivity: 6),
            record("e1", state: .ended, lastActivity: 7),
        ]
        let counts = records.attentionCounts()
        #expect(counts.needsInput == 2)
        #expect(counts.working == 1)
        #expect(counts.idle == 3)
        #expect(counts.ended == 1)
        #expect(counts.total == 7)
        #expect(counts.total == records.count)
    }


    // MARK: - Wire payload

    @Test("Payload orders sessions and reports bucket counts")
    func payloadOrdersAndCounts() {
        let payload = AgentSessionListPayload().list(
            records: [
                record("idle", state: .idle, lastActivity: 500),
                record("needs", state: .needsInput(since: at(100)), lastActivity: 100),
            ],
            now: at(600)
        )
        let sessions = payload["sessions"] as? [[String: Any]]
        #expect(sessions?.compactMap { $0["session_id"] as? String } == ["needs", "idle"])
        #expect(payload["count"] as? Int == 2)
        let counts = payload["state_counts"] as? [String: Int]
        #expect(counts?["needs_input"] == 1)
        #expect(counts?["idle"] == 1)
        #expect(counts?["total"] == 2)
        #expect(payload["generated_at"] as? String != nil)
    }

    @Test("state_counts is keyed by the same names a session's state reports")
    func payloadStateCountKeysMatchWireNames() {
        let payload = AgentSessionListPayload().list(
            records: [
                record("a", state: .needsInput(since: at(10)), lastActivity: 10),
                record("b", state: .working(since: at(20)), lastActivity: 20),
                record("c", state: .idle, lastActivity: 30),
                record("d", state: .ended, lastActivity: 40),
            ],
            now: at(600)
        )
        let counts = payload["state_counts"] as? [String: Int]
        // Every bucket is present under its wire name, and nothing else is: a
        // client can read `state_counts[session["state"]]` without a mapping
        // table, and a renamed rank cannot quietly drop a key here.
        let expected = AgentSessionAttentionRank.allCases.map(\.wireName) + ["total"]
        #expect(counts?.keys.sorted() == expected.sorted())
        for rank in AgentSessionAttentionRank.allCases {
            #expect(counts?[rank.wireName] == 1)
        }
        #expect(counts?["total"] == 4)
    }

    @Test("Payload carries state age and attention for a timed state")
    func payloadTimedState() {
        let json = AgentSessionListPayload().json(
            record("s", state: .needsInput(since: at(100)), lastActivity: 120, title: "Fix the parser"),
            now: at(160)
        )
        #expect(json["state"] as? String == "needs_input")
        #expect(json["attention_rank"] as? Int == 0)
        #expect(json["needs_attention"] as? Bool == true)
        #expect(json["state_age_seconds"] as? Double == 60)
        #expect(json["state_since"] as? String != nil)
        #expect(json["title"] as? String == "Fix the parser")
        #expect(json["agent"] as? String == "claude")
        #expect(json["agent_name"] as? String == "Claude")
    }

    @Test("Payload includes cleaned last assistant output")
    func payloadLastOutput() {
        let json = AgentSessionListPayload().json(
            record("s", state: .idle, lastActivity: 10, lastOutput: "╭─ Claude ─╮\nHere is the result.\n❯"),
            now: at(20)
        )
        #expect(json["last_output"] as? String == "Here is the result.")
    }

    @Test("Settled requires a finished turn, idle threshold, and no open PR")
    func settledRules() {
        let old = at(0)
        let closed = AgentSessionPullRequest(number: 1, state: "CLOSED")
        let merged = AgentSessionPullRequest(number: 2, state: "MERGED")
        let open = AgentSessionPullRequest(number: 3, state: "OPEN")
        let settled = AgentSessionListPayload().json(
            record("settled", state: .idle, lastActivity: 0, lastOutput: "done", linkedPullRequests: [closed, merged]),
            now: old.addingTimeInterval(7_201)
        )
        #expect(settled["settled"] as? Bool == true)
        let openPR = AgentSessionListPayload().json(
            record("open", state: .idle, lastActivity: 0, linkedPullRequests: [open]),
            now: old.addingTimeInterval(7_201)
        )
        #expect(openPR["settled"] as? Bool == false)
        #expect(openPR["settled_reason"] as? String == "open_pr_3")
        let working = AgentSessionListPayload().json(
            record("working", state: .working(since: at(0)), lastActivity: 0),
            now: old.addingTimeInterval(7_201)
        )
        #expect(working["settled"] as? Bool == false)
    }

    @Test("Payload omits state age for a settled state")
    func payloadSettledState() {
        let json = AgentSessionListPayload().json(record("s", state: .idle, lastActivity: 10), now: at(99))
        #expect(json["state"] as? String == "idle")
        #expect(json["state_since"] == nil)
        #expect(json["state_age_seconds"] == nil)
        #expect(json["needs_attention"] as? Bool == false)
    }

    @Test("A long-running working session sorts high but does not need a human")
    func payloadLongWorkingSessionIsNotWaiting() {
        // It has been running for hours and sits in the second bucket, above
        // everything idle. That must not make a "needs me" filter claim it: the
        // agent is busy, not blocked.
        let json = AgentSessionListPayload().json(
            record("grinding", state: .working(since: at(0)), lastActivity: 9_000),
            now: at(9_600)
        )
        #expect(json["state"] as? String == "working")
        #expect(json["attention_rank"] as? Int == 1)
        #expect(json["needs_attention"] as? Bool == false)
        #expect(json["state_age_seconds"] as? Double == 9_600)
    }

    @Test("Payload omits absent optional fields rather than emitting null")
    func payloadOmitsMissingFields() {
        let json = AgentSessionListPayload().json(record("bare", state: .idle, lastActivity: 0), now: at(0))
        for key in ["title", "cwd", "workspace_id", "surface_id", "transcript_path", "pid", "ended_at"] {
            #expect(json[key] == nil, "expected \(key) to be omitted")
        }
        // Everything omitted above is optional on the record; these are not.
        #expect(json["session_id"] as? String == "bare")
        #expect(json["last_activity_at"] as? String != nil)
    }

    @Test("Payload counts only running children")
    func payloadChildrenRunning() {
        let children = [
            AgentChatChildRun(id: "settled", startedAt: at(1), endedAt: at(2)),
            AgentChatChildRun(id: "live-1", startedAt: at(3)),
            AgentChatChildRun(id: "live-2", startedAt: at(4)),
        ]
        let json = AgentSessionListPayload().json(
            record("parent", state: .working(since: at(1)), lastActivity: 5, children: children),
            now: at(6)
        )
        #expect(json["children_running"] as? Int == 2)
    }

    @Test("Payload reports whether the state was confirmed by a hook")
    func payloadStateConfirmed() {
        // A process-table discovery is idle-by-default and unconfirmed; only a
        // hook lifecycle event proves idleness.
        let discovered = AgentSessionListPayload().json(
            record("discovered", state: .idle, lastActivity: 0, hasHookLifecycleState: false),
            now: at(1)
        )
        #expect(discovered["state_confirmed"] as? Bool == false)
        let hooked = AgentSessionListPayload().json(
            record("hooked", state: .idle, lastActivity: 0, hasHookLifecycleState: true),
            now: at(1)
        )
        #expect(hooked["state_confirmed"] as? Bool == true)
    }

    @Test("Payload is JSON-serializable")
    func payloadSerializes() {
        // The socket encodes the reply with JSONSerialization, which throws on
        // any non-JSON value, so prove the mapping never produces one.
        let payload = AgentSessionListPayload().list(
            records: [
                record("a", state: .needsInput(since: at(1)), lastActivity: 2, title: "t"),
                record("b", state: .working(since: at(3)), lastActivity: 4, kind: .other("opencode")),
                record("c", state: .ended, lastActivity: 5),
            ],
            now: at(10)
        )
        #expect(JSONSerialization.isValidJSONObject(payload))
        #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: payload) }
    }
}
