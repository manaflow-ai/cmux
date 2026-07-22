import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator command palette")
struct ControlCommandCoordinatorCommandPaletteTests {
    @Test func listReturnsLiveActionMetadataAndForwardsRouting() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let workspaceID = UUID()
        let command = ControlCommandPaletteItem(
            id: "palette.demo",
            title: "Demo",
            subtitle: "Workspace",
            shortcutHint: "⌘D",
            keywords: ["sample"],
            dismissOnRun: true
        )
        context.listResolution = .listed(windowID: windowID, commands: [command])
        let coordinator = ControlCommandCoordinator(context: context)

        let result = try #require(coordinator.handle(request(
            method: "palette.list",
            params: ["workspace_id": .string(workspaceID.uuidString)]
        )))

        #expect(context.listRouting?.workspaceID == workspaceID)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected palette.list payload")
            return
        }
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["count"] == .int(1))
        #expect(payload["commands"] == .array([.object([
            "id": .string("palette.demo"),
            "title": .string("Demo"),
            "subtitle": .string("Workspace"),
            "shortcut_hint": .string("⌘D"),
            "keywords": .array([.string("sample")]),
            "dismiss_on_run": .bool(true),
        ])]))
    }

    @Test func runInvokesTheRequestedLiveAction() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let command = ControlCommandPaletteItem(
            id: "palette.demo",
            title: "Demo",
            subtitle: "Workspace",
            shortcutHint: nil,
            keywords: [],
            dismissOnRun: false
        )
        context.runResolution = .ran(windowID: windowID, command: command)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = try #require(coordinator.handle(request(
            method: "palette.run",
            params: ["command_id": .string("palette.demo")]
        )))

        #expect(context.runCall?.commandID == "palette.demo")
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected palette.run payload")
            return
        }
        #expect(payload["window_id"] == .string(windowID.uuidString))
        guard case .object(let encodedCommand)? = payload["command"] else {
            Issue.record("expected encoded command")
            return
        }
        #expect(encodedCommand["id"] == .string("palette.demo"))
        #expect(encodedCommand["dismiss_on_run"] == .bool(false))
    }

    @Test func runRejectsMissingAndUnavailableActionIDs() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let missing = try #require(coordinator.handle(request(method: "palette.run")))
        guard case .err(let missingCode, _, _) = missing else {
            Issue.record("expected missing-id error")
            return
        }
        #expect(missingCode == "invalid_params")
        #expect(context.runCall == nil)

        context.runResolution = .commandNotFound
        let unavailable = try #require(coordinator.handle(request(
            method: "palette.run",
            params: ["command_id": .string("palette.hidden")]
        )))
        guard case .err(let unavailableCode, _, let data) = unavailable else {
            Issue.record("expected unavailable-action error")
            return
        }
        #expect(unavailableCode == "not_found")
        #expect(data == .object(["command_id": .string("palette.hidden")]))
    }

    private func request(
        method: String,
        params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
