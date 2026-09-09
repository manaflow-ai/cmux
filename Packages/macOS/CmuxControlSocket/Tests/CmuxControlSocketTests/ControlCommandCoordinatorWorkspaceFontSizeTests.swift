import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator workspace.font_size")
struct ControlCommandCoordinatorWorkspaceFontSizeTests {
    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "workspace.font_size", params: params)
    }

    @Test(arguments: ControlWorkspaceFontSizeAction.allCases)
    func routesEveryActionAndReportsAdmission(_ action: ControlWorkspaceFontSizeAction) {
        let context = FakeWorkspaceControlCommandContext()
        let workspaceID = UUID()
        context.fontSizeResolution = .accepted(workspaceID: workspaceID)
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .ok(.object(let payload)) = coordinator.handle(request([
            "action": .string(action.rawValue),
        ])) else {
            Issue.record("expected accepted workspace.font_size result")
            return
        }

        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["workspace_ref"] == .string("workspace:1"))
        #expect(payload["action"] == .string(action.rawValue))
        #expect(payload["accepted"] == .bool(true))
        #expect(context.fontSizeCall?.action == action)
        #expect(context.fontSizeCall?.routing.windowID == nil)
        #expect(!context.fontSizeCall!.routing.hasWindowIDParam)
        #expect(ControlCommandExecutionPolicy(forMethod: "workspace.font_size") == .mainActor)
    }

    @Test func routesUUIDAndTypedSelectors() {
        let context = FakeWorkspaceControlCommandContext()
        context.fontSizeResolution = .accepted(workspaceID: UUID())
        let coordinator = ControlCommandCoordinator(context: context)
        let windowID = UUID()
        let workspaceID = UUID()
        let windowRef = coordinator.ensureRef(kind: .window, uuid: windowID)
        let workspaceRef = coordinator.ensureRef(kind: .workspace, uuid: workspaceID)

        let result = coordinator.handle(request([
            "action": .string("increase"),
            "window_id": .string(windowRef),
            "workspace_id": .string(workspaceID.uuidString),
        ]))

        #expect(result != nil)
        #expect(context.fontSizeCall?.routing.hasWindowIDParam == true)
        #expect(context.fontSizeCall?.routing.windowID == windowID)
        #expect(context.fontSizeCall?.routing.workspaceID == workspaceID)
        #expect(workspaceRef == "workspace:1")
    }

    @Test func absentSelectorsAreAllowedAndDoNotInventRouting() {
        let context = FakeWorkspaceControlCommandContext()
        context.fontSizeResolution = .accepted(workspaceID: UUID())
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(request(["action": .string("reset")]))

        #expect(context.fontSizeCall?.routing.windowID == nil)
        #expect(context.fontSizeCall?.routing.workspaceID == nil)
        #expect(!context.fontSizeCall!.routing.hasWindowIDParam)
    }

    @Test func malformedInputNeverReachesMutation() {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let workspaceRef = coordinator.ensureRef(kind: .workspace, uuid: workspaceID)

        let invalidRequests: [[String: JSONValue]] = [
            ["action": .string("zoom")],
            ["action": .int(1)],
            ["action": .string("increase"), "window_id": .null],
            ["action": .string("increase"), "window_id": .string("window:999")],
            ["action": .string("increase"), "window_id": .string(workspaceRef)],
            ["action": .string("increase"), "workspace_id": .string("window:999")],
        ]

        for params in invalidRequests {
            guard case .err(code: "invalid_params", _, _) = coordinator.handle(request(params)) else {
                Issue.record("expected invalid_params for \(params)")
                continue
            }
        }
        #expect(context.fontSizeCall == nil)
    }

    @Test func unknownKeysNeverReachMutation() {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request([
            "action": .string("increase"),
            "unknown": .string("ignored"),
        ]))

        guard case .err(code: "invalid_params", message: "font size invalid", data: nil) = result else {
            Issue.record("expected localized invalid_params result")
            return
        }
        #expect(context.fontSizeCall == nil)
    }

    @Test func reportsSeamFailuresWithProtocolErrorsAndFallback() {
        let workspaceID = UUID()
        for (resolution, code, message) in [
            (ControlWorkspaceFontSizeResolution.unavailable, "unavailable", "font size unavailable"),
            (.notFound, "not_found", "font size not found"),
            (.rejected, "invalid_state", "font size rejected"),
        ] as [(ControlWorkspaceFontSizeResolution, String, String)] {
            let context = FakeWorkspaceControlCommandContext()
            context.fontSizeResolution = resolution
            let coordinator = ControlCommandCoordinator(context: context)
            guard case .err(code: code, message: message, data: nil) = coordinator.handle(request([
                "action": .string("increase"),
            ])) else {
                Issue.record("expected \(code) result")
                continue
            }
        }

        let coordinator = ControlCommandCoordinator()
        guard case .err(code: "unavailable", message: "Workspace font-size unavailable", data: nil) = coordinator.handle(
            request(["action": .string("increase")])
        ) else {
            Issue.record("expected English unavailable fallback without context")
            return
        }
        _ = workspaceID
    }
}
