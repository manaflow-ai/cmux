import Foundation
import Testing
@testable import CMUXWorkstream

@Suite("WorkstreamItem")
struct WorkstreamItemTests {
    @Test("Actionable kinds default to pending, telemetry kinds to telemetry")
    func defaultStatusByKind() {
        let perm = WorkstreamItem(
            workstreamId: "claude-1",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(requestId: "r1", toolName: "Write", toolInputJSON: "{}", pattern: nil)
        )
        #expect(perm.status.isPending)

        let tool = WorkstreamItem(
            workstreamId: "claude-1",
            source: .claude,
            kind: .toolUse,
            payload: .toolUse(toolName: "Read", toolInputJSON: "{}")
        )
        if case .telemetry = tool.status {
            // ok
        } else {
            Issue.record("telemetry kind should default to .telemetry status")
        }
    }

    @Test("Codable round-trip preserves payload associated values")
    func codableRoundTrip() throws {
        let original = WorkstreamItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            workstreamId: "codex-42",
            source: .codex,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "req-7",
                toolName: "shell",
                toolInputJSON: "{\"cmd\":\"rm -rf /\"}",
                pattern: "dangerous"
            ),
            context: WorkstreamContext(lastUserMessage: "please clean up")
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkstreamItem.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Question payload decodes legacy flat question shape")
    func legacyQuestionPayloadDecode() throws {
        let json = """
        {
          "question": {
            "requestId": "req-q",
            "prompt": "Pick one",
            "multiSelect": false,
            "options": [
              {"id": "a", "label": "A"}
            ]
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkstreamPayload.self, from: json)
        guard case .question(let requestId, let questions) = decoded else {
            Issue.record("expected question payload")
            return
        }
        #expect(requestId == "req-q")
        #expect(questions.count == 1)
        #expect(questions.first?.prompt == "Pick one")
        #expect(questions.first?.options.first?.label == "A")
    }

    @Test("Non-actionable kinds normalize explicit actionable statuses")
    func nonActionableStatusNormalizesToTelemetry() {
        let item = WorkstreamItem(
            workstreamId: "s",
            source: .claude,
            kind: .sessionStart,
            status: .pending,
            payload: .sessionStart
        )
        if case .telemetry = item.status {
            // ok
        } else {
            Issue.record("non-actionable item should normalize to telemetry")
        }
    }

    @Test("WorkstreamKind.isActionable is correct")
    func isActionable() {
        #expect(WorkstreamKind.permissionRequest.isActionable)
        #expect(WorkstreamKind.exitPlan.isActionable)
        #expect(WorkstreamKind.question.isActionable)
        #expect(!WorkstreamKind.toolUse.isActionable)
        #expect(!WorkstreamKind.sessionStart.isActionable)
        #expect(!WorkstreamKind.todos.isActionable)
    }
}
