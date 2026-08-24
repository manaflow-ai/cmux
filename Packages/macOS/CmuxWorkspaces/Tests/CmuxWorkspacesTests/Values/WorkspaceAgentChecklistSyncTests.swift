import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Workspace agent checklist sync")
struct WorkspaceAgentChecklistSyncTests {
    @Test("agent reports replace only their own rows")
    func preservesUserAndOtherAgentRows() throws {
        let user = WorkspaceChecklistItem(text: "User note")
        let otherRef = WorkspaceAgentTaskRef(workstreamId: "other", taskId: "1")
        let other = WorkspaceChecklistItem(text: "Other task", origin: .agent, agentTaskRef: otherRef)
        let existing = [user, other]
        let current = WorkspaceAgentChecklistTask(
            id: UUID(),
            ref: WorkspaceAgentTaskRef(workstreamId: "current", taskId: "2"),
            text: "Current task",
            state: .inProgress,
            lastActivityAt: Date(timeIntervalSince1970: 42),
            agentName: "claude"
        )
        let replacements = try #require(WorkspaceAgentChecklistSync().replacement(
            existing: existing,
            agentTasks: [current],
            workstreamId: "current"
        ))
        #expect(replacements.map(\.text) == ["User note", "Other task", "Current task"])
        #expect(replacements.last?.agentTaskRef == current.ref)
        #expect(replacements.last?.lastActivityAt == Date(timeIntervalSince1970: 42))
    }

    @Test("an empty report retires only the reporting agent")
    func emptyReportRetiresRows() throws {
        let currentRef = WorkspaceAgentTaskRef(workstreamId: "current", taskId: "1")
        let otherRef = WorkspaceAgentTaskRef(workstreamId: "other", taskId: "1")
        let existing = [
            WorkspaceChecklistItem(text: "current", origin: .agent, agentTaskRef: currentRef),
            WorkspaceChecklistItem(text: "other", origin: .agent, agentTaskRef: otherRef),
        ]
        let replacements = try #require(WorkspaceAgentChecklistSync().replacement(
            existing: existing,
            agentTasks: [],
            workstreamId: "current"
        ))
        #expect(replacements.map(\.text) == ["other"])
    }

    @Test("dispatch metadata survives Codable round trip")
    func dispatchMetadataRoundTrips() throws {
        let item = WorkspaceChecklistItem(
            text: "Run tests",
            dispatchTarget: WorkspaceTaskDispatchTarget(
                workingDirectory: "/tmp/project",
                agentCommand: "claude --continue",
                agentName: "claude"
            ),
            boundWorkspaceID: UUID(),
            boundAgent: "claude",
            lastActivityAt: Date(timeIntervalSince1970: 7)
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WorkspaceChecklistItem.self, from: data)
        #expect(decoded.dispatchTarget == item.dispatchTarget)
        #expect(decoded.boundWorkspaceID == item.boundWorkspaceID)
        #expect(decoded.boundAgent == "claude")
        #expect(decoded.lastActivityAt == item.lastActivityAt)
    }
}
