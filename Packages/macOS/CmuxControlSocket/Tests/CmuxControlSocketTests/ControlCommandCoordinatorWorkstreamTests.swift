import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeWorkstreamContext: ControlCommandContext {
    // Window domain (minimal; everything else comes from the stub defaults).
    func controlWindowSummaries() -> [ControlWindowSummary] { [] }
    func controlResolveCurrentWindow(routing: ControlRoutingSelectors) -> ControlCurrentWindowResolution {
        .tabManagerUnavailable
    }
    func controlFocusWindow(id: UUID) -> Bool { false }
    func controlCreateWindowAndActivate() -> UUID? { nil }
    func controlCloseWindow(id: UUID) -> Bool { false }
    func controlAvailableDisplays() -> [ControlDisplayInfo] { [] }
    func controlWindowExists(id: UUID) -> Bool { false }
    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? { nil }
    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? { nil }

    // Programmable workstream resolutions.
    var listResolution: ControlWorkstreamListResolution = .tabManagerUnavailable
    var createResolution: ControlWorkstreamCreateResolution = .tabManagerUnavailable
    var renameResult: Bool?
    var deleteResult: Int?
    var addResult: Bool?
    var removeResult: Bool?
    var moveResult: Bool?
    var enterResult: Bool?
    var exitResult: Bool?
    private(set) var lastCreateName: String?
    private(set) var lastCreateWorkspaceIDs: [UUID] = []
    private(set) var lastRenameName: String?
    private(set) var lastRenameRouting: ControlRoutingSelectors?

    func controlWorkstreamList(routing: ControlRoutingSelectors) -> ControlWorkstreamListResolution {
        listResolution
    }
    func controlCreateWorkstream(
        routing: ControlRoutingSelectors,
        name: String,
        workspaceIDs: [UUID]
    ) -> ControlWorkstreamCreateResolution {
        lastCreateName = name
        lastCreateWorkspaceIDs = workspaceIDs
        return createResolution
    }
    func controlRenameWorkstream(routing: ControlRoutingSelectors, workstreamID: UUID, name: String) -> Bool? {
        lastRenameRouting = routing
        lastRenameName = name
        return renameResult
    }
    func controlDeleteWorkstream(routing: ControlRoutingSelectors, workstreamID: UUID) -> Int? { deleteResult }
    func controlAddWorkspaceToWorkstream(routing: ControlRoutingSelectors, workstreamID: UUID, workspaceID: UUID) -> Bool? { addResult }
    func controlRemoveWorkspaceFromWorkstream(routing: ControlRoutingSelectors, workspaceID: UUID) -> Bool? { removeResult }
    func controlMoveWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID,
        toIndex: Int?,
        beforeWorkstreamID: UUID?,
        afterWorkstreamID: UUID?
    ) -> Bool? { moveResult }
    func controlEnterWorkstream(routing: ControlRoutingSelectors, workstreamID: UUID) -> Bool? { enterResult }
    func controlExitWorkstreamDrillIn(routing: ControlRoutingSelectors) -> Bool? { exitResult }
}

@MainActor
@Suite("ControlCommandCoordinator workstream domain")
struct ControlCommandCoordinatorWorkstreamTests {
    private func coordinator() -> (ControlCommandCoordinator, FakeWorkstreamContext) {
        let context = FakeWorkstreamContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func listExposesWorkstreamsAndDrillInState() throws {
        let (coordinator, context) = coordinator()
        let wsId = UUID()
        let memberId = UUID()
        context.listResolution = .resolved(
            windowID: nil,
            workstreams: [
                ControlWorkstreamSnapshot(
                    id: wsId, name: "Checkout", customColor: nil, iconSymbol: nil,
                    memberWorkspaceIDs: [memberId]
                )
            ],
            drilledInWorkstreamID: wsId
        )
        guard case .ok(.object(let payload)) = coordinator.handle(request("workstream.list")),
              case .array(let rows) = payload["workstreams"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected workstream.list shape")
            return
        }
        #expect(row["id"] == .string(wsId.uuidString))
        #expect(row["name"] == .string("Checkout"))
        #expect(row["workspace_count"] == .int(1))
        #expect(payload["drilled_in_workstream_id"] == .string(wsId.uuidString))
    }

    @Test func createParsesWorkspaceHandlesAndReturnsPayload() throws {
        let (coordinator, context) = coordinator()
        let wsId = UUID()
        let memberId = UUID()
        context.createResolution = .created(
            ControlWorkstreamSnapshot(
                id: wsId, name: "Epic", customColor: nil, iconSymbol: nil,
                memberWorkspaceIDs: [memberId]
            )
        )
        let result = coordinator.handle(request("workstream.create", [
            "name": .string("Epic"),
            "workspace_ids": .array([.string(memberId.uuidString)]),
        ]))
        guard case .ok(.object(let payload)) = result,
              case .object(let workstream)? = payload["workstream"] else {
            Issue.record("unexpected workstream.create shape")
            return
        }
        #expect(workstream["name"] == .string("Epic"))
        #expect(context.lastCreateName == "Epic")
        #expect(context.lastCreateWorkspaceIDs == [memberId])
    }

    @Test func createRejectsMalformedWorkspaceIDs() throws {
        let (coordinator, _) = coordinator()
        let result = coordinator.handle(request("workstream.create", [
            "workspace_ids": .string("not-an-array"),
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected error")
            return
        }
        #expect(code == "invalid_params")
    }

    @Test func renameNotFoundMapsToNotFound() throws {
        let (coordinator, context) = coordinator()
        context.renameResult = false
        let result = coordinator.handle(request("workstream.rename", [
            "workstream_id": .string(UUID().uuidString),
            "name": .string("New"),
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected error")
            return
        }
        #expect(code == "not_found")
    }

    @Test func renameTrimsNameBeforeCallingContextAndReturningPayload() throws {
        let (coordinator, context) = coordinator()
        context.renameResult = true
        let id = UUID()
        let result = coordinator.handle(request("workstream.rename", [
            "workstream_id": .string(id.uuidString),
            "name": .string("  New name  "),
        ]))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastRenameName == "New name")
        #expect(payload["name"] == .string("New name"))
    }

    @Test func renameRoutesByWorkstreamHandle() throws {
        let (coordinator, context) = coordinator()
        context.renameResult = true
        let id = UUID()
        let workstreamRef = coordinator.ensureRef(kind: .workstream, uuid: id)
        _ = coordinator.handle(request("workstream.rename", [
            "workstream_id": .string(workstreamRef),
            "name": .string("New name"),
        ]))
        #expect(context.lastRenameRouting?.workstreamID == id)
    }

    @Test func renameRejectsBlankNameWithoutCallingContext() throws {
        let (coordinator, context) = coordinator()
        context.renameResult = true
        let result = coordinator.handle(request("workstream.rename", [
            "workstream_id": .string(UUID().uuidString),
            "name": .string("   "),
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected error")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastRenameName == nil)
    }

    @Test func deleteReportsReleasedCount() throws {
        let (coordinator, context) = coordinator()
        context.deleteResult = 3
        let result = coordinator.handle(request("workstream.delete", [
            "workstream_id": .string(UUID().uuidString),
        ]))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok")
            return
        }
        #expect(payload["released_workspace_count"] == .int(3))
    }

    @Test func deleteNotFoundWhenNegative() throws {
        let (coordinator, context) = coordinator()
        context.deleteResult = -1
        let result = coordinator.handle(request("workstream.delete", [
            "workstream_id": .string(UUID().uuidString),
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected error")
            return
        }
        #expect(code == "not_found")
    }

    @Test func addRemoveEnterExitRoundTrip() throws {
        let (coordinator, context) = coordinator()
        context.addResult = true
        context.removeResult = true
        context.enterResult = true
        context.exitResult = true
        let id = UUID().uuidString
        let wsId = UUID().uuidString

        if case .ok = coordinator.handle(request("workstream.add", [
            "workstream_id": .string(id), "workspace_id": .string(wsId),
        ])) {} else { Issue.record("add failed") }

        if case .ok = coordinator.handle(request("workstream.remove", [
            "workspace_id": .string(wsId),
        ])) {} else { Issue.record("remove failed") }

        guard case .ok(.object(let enterPayload)) = coordinator.handle(request("workstream.enter", [
            "workstream_id": .string(id),
        ])) else {
            Issue.record("enter failed")
            return
        }
        #expect(enterPayload["drilled_in"] == .bool(true))

        guard case .ok(.object(let exitPayload)) = coordinator.handle(request("workstream.exit")) else {
            Issue.record("exit failed")
            return
        }
        #expect(exitPayload["drilled_in"] == .bool(false))
    }

    @Test func unavailableContextSurfacesUnavailable() throws {
        let (coordinator, _) = coordinator()
        // All resolutions default to tabManagerUnavailable / nil.
        guard case .err(let code, _, _) = coordinator.handle(request("workstream.list")) else {
            Issue.record("expected error")
            return
        }
        #expect(code == "unavailable")
    }
}
