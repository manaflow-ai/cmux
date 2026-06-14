import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator workspace domain")
struct ControlCommandCoordinatorWorkspaceTests {
    private func coordinator() -> (ControlCommandCoordinator, FakeWorkspaceControlCommandContext) {
        let context = FakeWorkspaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func summary(id: UUID = UUID(), title: String, customTitle: String?) -> ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: id,
            title: title,
            customTitle: customTitle,
            customDescription: nil,
            isPinned: false,
            listeningPorts: [],
            remoteStatus: .object([:]),
            currentDirectory: nil,
            customColor: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil
        )
    }

    @Test func workspaceListExposesCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.listResolution = .resolved(
            windowID: nil,
            workspaces: [summary(id: workspaceID, title: "Manual name", customTitle: "Manual name")],
            selectedIndex: 0
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.list")),
              case .array(let rows) = payload["workspaces"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected workspace.list shape")
            return
        }

        #expect(row["id"] == .string(workspaceID.uuidString))
        #expect(row["title"] == .string("Manual name"))
        #expect(row["custom_title"] == .string("Manual name"))
        #expect(row["has_custom_title"] == .bool(true))
    }

    @Test func workspaceCurrentExposesMissingCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.currentResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            index: 0,
            summary: summary(id: workspaceID, title: "Terminal", customTitle: nil)
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.current")),
              case .object(let workspace) = payload["workspace"] else {
            Issue.record("unexpected workspace.current shape")
            return
        }

        #expect(workspace["title"] == .string("Terminal"))
        #expect(workspace["custom_title"] == .null)
        #expect(workspace["has_custom_title"] == .bool(false))
    }
}
