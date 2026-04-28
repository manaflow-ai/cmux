import Foundation
import Testing
@testable import CMUXWorkstream

@Suite("WorkstreamEvent")
struct WorkstreamEventTests {
    @Test("Decodes a Vibe-Island-shaped hook payload with tool_input object")
    func decodesHookPayload() throws {
        let json = """
        {
          "session_id": "claude-abc",
          "hook_event_name": "PermissionRequest",
          "_source": "claude",
          "cwd": "/tmp/proj",
          "tool_name": "Write",
          "tool_input": {"file_path": "/etc/passwd", "content": "x"},
          "context": {"lastUserMessage": "write a file", "permissionMode": "plan"},
          "_opencode_request_id": "req-1",
          "_ppid": 1234
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: json)
        #expect(event.sessionId == "claude-abc")
        #expect(event.hookEventName == .permissionRequest)
        #expect(event.source == "claude")
        #expect(event.toolName == "Write")
        #expect(event.context?.lastUserMessage == "write a file")
        #expect(event.context?.permissionMode == "plan")
        #expect(event.requestId == "req-1")
        #expect(event.ppid == 1234)
        // `toolInputJSON` round-trips through JSONSerialization which may
        // escape forward slashes; parse it back rather than substring-match.
        let raw = try #require(event.toolInputJSON?.data(using: .utf8))
        let dict = try #require(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        #expect(dict["file_path"] as? String == "/etc/passwd")
        #expect(dict["content"] as? String == "x")
    }

    @Test("Re-encodes and re-decodes preserving all fields")
    func roundTrip() throws {
        let event = WorkstreamEvent(
            sessionId: "opencode-xyz",
            hookEventName: .exitPlanMode,
            source: "opencode",
            cwd: "/work",
            toolName: "ExitPlanMode",
            toolInputJSON: "{\"plan\":\"step1\\nstep2\"}",
            context: WorkstreamContext(
                lastUserMessage: "make a plan",
                assistantPreamble: "I will make a short plan.",
                allowedPrompts: [
                    WorkstreamAllowedPrompt(tool: "Bash", prompt: "run tests")
                ],
                permissionMode: "plan"
            ),
            requestId: "plan-1",
            ppid: 999
        )
        let data = try JSONEncoder().encode(event)
        let back = try JSONDecoder().decode(WorkstreamEvent.self, from: data)
        #expect(back.sessionId == event.sessionId)
        #expect(back.hookEventName == event.hookEventName)
        #expect(back.requestId == event.requestId)
        let rawPlan = try #require(back.toolInputJSON?.data(using: .utf8))
        let planDict = try #require(
            try JSONSerialization.jsonObject(with: rawPlan) as? [String: Any]
        )
        #expect((planDict["plan"] as? String)?.contains("step1") == true)
        #expect(back.context?.lastUserMessage == "make a plan")
        #expect(back.context?.assistantPreamble == "I will make a short plan.")
        #expect(back.context?.allowedPrompts.first?.prompt == "run tests")
        #expect(back.context?.permissionMode == "plan")
    }

    @Test("Missing optional fields decode as nil")
    func missingOptionals() throws {
        let json = """
        {"session_id": "s", "hook_event_name": "SessionStart", "_source": "claude"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: json)
        #expect(event.cwd == nil)
        #expect(event.toolName == nil)
        #expect(event.toolInputJSON == nil)
        #expect(event.context == nil)
        #expect(event.requestId == nil)
        #expect(event.ppid == nil)
    }

    @Test("Unknown event fields round-trip for forward compatibility")
    func unknownFieldsRoundTrip() throws {
        let json = """
        {
          "session_id": "s",
          "hook_event_name": "SessionStart",
          "_source": "claude",
          "future_field": {"enabled": true, "count": 2}
        }
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: json)
        let extraData = try #require(event.extraFieldsJSON?.data(using: .utf8))
        let extra = try #require(
            try JSONSerialization.jsonObject(with: extraData) as? [String: Any]
        )
        let future = try #require(extra["future_field"] as? [String: Any])
        #expect(future["enabled"] as? Bool == true)
        #expect(future["count"] as? Int == 2)

        let encoded = try JSONEncoder().encode(event)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let encodedFuture = try #require(object["future_field"] as? [String: Any])
        #expect(encodedFuture["enabled"] as? Bool == true)
        #expect(encodedFuture["count"] as? Int == 2)
    }

    @Test("Non-JSON tool input re-encodes as a string")
    func encodesRawToolInputString() throws {
        let event = WorkstreamEvent(
            sessionId: "s",
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: "plain text"
        )
        let data = try JSONEncoder().encode(event)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["tool_input"] as? String == "plain text")
    }
}
