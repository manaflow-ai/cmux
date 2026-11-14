import CmuxNextApps
import Foundation
import Testing

/// `agent_chat.list`: a customize script reads the agent chats the sidebar shows (title, state,
/// folder, times), so a section of its own can list them as threads.
@MainActor
struct AgentChatAppOpsTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static let chats = [
        AgentChatSummary(id: "s1", title: "Fix the flaky upload test", harness: "claude", state: "working", unread: false,
                         project: "cmux", cwd: "/Users/me/src/cmux", workspace: "ws_1", machine: nil, step: "Running the tests",
                         error: nil, since: start, updatedAt: start.addingTimeInterval(30), createdAt: start.addingTimeInterval(-600),
                         pullRequests: ["https://github.com/o/r/pull/7"]),
        AgentChatSummary(id: "s2", title: "Docs pass", harness: nil, state: "idle", unread: true, project: nil, cwd: nil,
                         workspace: nil, machine: "mini", step: nil, error: nil, since: nil, updatedAt: nil, createdAt: nil, pullRequests: []),
    ]

    private func request(_ params: AppJSON = [:], op: String = "agent_chat.list") -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "local/customize", op: op, params: params, origin: "script")
    }

    @Test func listAnswersEveryChatInTheScriptShape() async throws {
        let ops = AgentChatAppOps { Self.chats }
        #expect(ops.families == ["agent_chat"])
        let value = try await ops.handle(request())
        let chats = try #require(value["chats"]?.arrayValue)
        #expect(chats.count == 2)
        let first = try #require(chats.first)
        #expect(first == [
            "id": "s1", "title": "Fix the flaky upload test", "harness": "claude", "state": "working", "unread": false,
            "project": "cmux", "cwd": "/Users/me/src/cmux", "workspace": "ws_1", "machine": .null, "step": "Running the tests",
            "error": .null, "since_ms": 1_800_000_000_000, "updated_ms": 1_800_000_030_000, "created_ms": 1_799_999_400_000,
            "pull_requests": ["https://github.com/o/r/pull/7"],
        ])
        let second = try #require(chats.last)
        #expect(second["project"] == .null, "no folder: the script groups it apart")
        #expect(second["machine"] == "mini")
        #expect(second["unread"] == true)
        #expect(second["since_ms"] == .null)
    }

    @Test func noParamsIsTheSameAsEmptyParams() async throws {
        let ops = AgentChatAppOps { Self.chats }
        #expect(try await ops.handle(request(.null)) == ops.handle(request([:])))
    }

    @Test func unknownParamsAndOtherOpsAreRefused() async {
        let ops = AgentChatAppOps { Self.chats }
        await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(request(["limit": 3])) }
        do {
            _ = try await ops.handle(request(op: "agent_chat.delete"))
            Issue.record("expected a refusal")
        } catch {
            #expect(error.code == "operation.unsupported")
        }
    }

    @Test func theRouterSendsTheAgentChatFamilyToIt() {
        let router = AppHostCapabilities([AgentChatAppOps { [] }])
        #expect(router.handles("agent_chat.list"))
        #expect(!router.handles("agent.list"), "the daemon's agent family stays the daemon's")
    }
}
