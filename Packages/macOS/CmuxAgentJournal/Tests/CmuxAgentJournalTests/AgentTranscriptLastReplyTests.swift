import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Agent transcript last reply")
struct AgentTranscriptLastReplyTests {
    private static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)
    }

    @Test("a Claude text reply followed by tool calls and results keeps the text's time")
    func claudeTextThenTools() {
        let lines = [
            #"{"type":"user","timestamp":"2026-09-28T14:40:00.000Z","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-28T14:41:03.250Z","message":{"role":"assistant","content":[{"type":"text","text":"Starting the build."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-28T14:41:04.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-28T14:43:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-28T14:43:01.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
        ]
        #expect(AgentTranscriptLastReply().lastReplyDate(inJSONLLines: lines) == Self.date("2026-09-28T14:41:03.250Z"))
    }

    @Test("sidechain, blank, synthetic and API-error text do not count as a reply")
    func sidechainAndBlankIgnored() {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-28T09:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Launched a background agent."}]}}"#,
            #"{"type":"assistant","isSidechain":true,"timestamp":"2026-09-28T09:05:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"subagent says hi"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-28T09:06:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"  \n"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-28T09:07:00.000Z","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-09-28T09:08:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"API Error: overloaded"}]}}"#,
        ]
        #expect(AgentTranscriptLastReply().lastReplyDate(inJSONLLines: lines) == Self.date("2026-09-28T09:00:00.000Z"))
    }

    @Test("a Codex rollout assistant message counts; reasoning and function calls do not")
    func codexRollout() {
        let lines = [
            #"{"timestamp":"2026-09-28T10:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Looking now."}]}}"#,
            #"{"timestamp":"2026-09-28T10:00:02.000Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
            #"{"timestamp":"2026-09-28T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"role\":\"assistant\"}"}}"#,
        ]
        #expect(AgentTranscriptLastReply().lastReplyDate(inJSONLLines: lines) == Self.date("2026-09-28T10:00:00.000Z"))
    }

    @Test("no reply, malformed lines and whole-second timestamps")
    func edgeCases() {
        #expect(AgentTranscriptLastReply().lastReplyDate(inJSONLLines: []) == nil)
        #expect(AgentTranscriptLastReply().lastReplyDate(inJSONLLines: ["{\"assistant\"", "not json"]) == nil)
        let whole = [#"{"type":"assistant","timestamp":"2026-09-28T10:00:00Z","message":{"role":"assistant","content":"plain string reply"}}"#]
        #expect(AgentTranscriptLastReply().lastReplyDate(inJSONLLines: whole) == Self.date("2026-09-28T10:00:00.000Z"))
    }
}
