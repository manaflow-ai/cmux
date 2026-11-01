import Foundation
import Testing
@testable import CmuxMobileHost

@Suite("Agent chat background tasks")
struct AgentChatBackgroundTaskTests {
    @Test("A missing key leaves the caller's list alone")
    func missingKeyDecodesNil() {
        #expect(AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: nil) == nil)
        #expect(AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: #"{"stop_hook_active":false}"#) == nil)
        #expect(AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: "not json") == nil)
        #expect(AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: #"{"background_tasks":"x"}"#) == nil)
    }

    @Test("An empty array means nothing is in flight")
    func emptyArrayDecodesEmpty() {
        #expect(AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: #"{"background_tasks":[]}"#) == [])
    }

    @Test("Task fields decode, including type-specific ones")
    func fieldsDecode() throws {
        let json = #"""
        {"background_tasks":[
          {"id":"task-001","type":"shell","status":"running","description":"tail logs","command":"tail -f /var/log/syslog"},
          {"id":"task-002","type":"subagent","status":"running","description":"Audit tests","agent_type":"Explore"},
          {"id":"task-003","type":"workflow","status":"running","name":"release"}
        ]}
        """#
        let tasks = try #require(AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: json))
        #expect(tasks.count == 3)
        #expect(tasks[0] == AgentChatBackgroundTask(
            id: "task-001",
            type: "shell",
            status: "running",
            description: "tail logs",
            command: "tail -f /var/log/syslog"
        ))
        #expect(tasks[1].agentType == "Explore")
        #expect(tasks[1].command == nil)
        #expect(tasks[2].name == "release")
        #expect(tasks[2].description == nil)
    }

    @Test("Entries without ids or types still count, and non-objects are skipped")
    func sparseEntriesDecode() throws {
        // Oversized hook payloads are compacted by the CLI to a bare
        // `{"status":"running"}` marker per list; it must still count.
        let json = #"{"background_tasks":[{"status":"running"},42,{"id":"","type":"","status":""}]}"#
        let tasks = try #require(AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: json))
        #expect(tasks.count == 2)
        #expect(tasks[0].id == "task-0")
        #expect(tasks[0].type == "task")
        #expect(tasks[0].status == "running")
        #expect(tasks[1].id == "task-2")
        #expect(tasks[1].status == "unknown")
    }

    @Test("The list is capped")
    func listIsCapped() throws {
        let entries = (0..<(AgentChatBackgroundTask.capacity + 5))
            .map { #"{"id":"t\#($0)","type":"shell","status":"running"}"# }
            .joined(separator: ",")
        let tasks = try #require(
            AgentChatBackgroundTask.decodeList(fromExtraFieldsJSON: #"{"background_tasks":[\#(entries)]}"#)
        )
        #expect(tasks.count == AgentChatBackgroundTask.capacity)
        #expect(tasks.last?.id == "t\(AgentChatBackgroundTask.capacity - 1)")
    }
}
