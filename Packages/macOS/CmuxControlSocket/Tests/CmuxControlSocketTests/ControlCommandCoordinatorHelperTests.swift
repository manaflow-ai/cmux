import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeHelperControlCommandContext: ControlCommandContext {
    let windowID = UUID()
    let callerWorkspaceID = UUID()
    let callerPaneID = UUID()
    let callerSurfaceID = UUID()
    let focusedWorkspaceID = UUID()
    let focusedPaneID = UUID()
    let focusedSurfaceID = UUID()
    let helperPaneID = UUID()
    let helperSurfaceID = UUID()
    let extraHelperSurfaceID = UUID()
    let createdPaneID = UUID()
    let createdSurfaceID = UUID()

    var includeExistingHelperPane = false
    var includeExtraHelperSurface = false
    var existingHelperSurfaceVisible = true
    var createdSurfaceVisible = true
    var createdSurfaceVisibleAfterHealthSample: Int?
    private(set) var identifyParams: [String: JSONValue] = [:]
    private(set) var paneListRoutings: [ControlRoutingSelectors] = []
    private(set) var surfaceHealthRoutings: [ControlRoutingSelectors] = []
    private(set) var paneCreateCalls: [(routing: ControlRoutingSelectors, inputs: ControlPaneCreateInputs)] = []
    private(set) var surfaceCreateCalls: [(routing: ControlRoutingSelectors, inputs: ControlSurfaceCreateInputs)] = []
    private(set) var surfaceSendTextCalls: [(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        text: String
    )] = []

    func controlSystemIdentify(params: [String: JSONValue]) -> JSONValue {
        identifyParams = params
        return .object([
            "focused": .object([
                "window_id": .string(windowID.uuidString),
                "workspace_id": .string(focusedWorkspaceID.uuidString),
                "pane_id": .string(focusedPaneID.uuidString),
                "surface_id": .string(focusedSurfaceID.uuidString),
            ]),
            "caller": .object([
                "window_id": .string(windowID.uuidString),
                "workspace_id": .string(callerWorkspaceID.uuidString),
                "pane_id": .string(callerPaneID.uuidString),
                "surface_id": .string(callerSurfaceID.uuidString),
            ]),
        ])
    }

    func controlPaneRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        routing.workspaceID == focusedWorkspaceID
    }

    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        routing.workspaceID == focusedWorkspaceID
    }

    func controlPaneList(routing: ControlRoutingSelectors) -> ControlPaneListSnapshot? {
        paneListRoutings.append(routing)
        var panes = [
            ControlPaneSummary(
                paneID: focusedPaneID,
                isFocused: true,
                surfaceIDs: [focusedSurfaceID],
                selectedSurfaceID: focusedSurfaceID,
                pixelFrame: ControlPanePixelFrame(x: 0, y: 0, width: 500, height: 500),
                gridSize: nil
            ),
        ]
        if includeExistingHelperPane {
            var surfaceIDs = [helperSurfaceID]
            if includeExtraHelperSurface {
                surfaceIDs.insert(extraHelperSurfaceID, at: 0)
            }
            panes.append(ControlPaneSummary(
                paneID: helperPaneID,
                isFocused: false,
                surfaceIDs: surfaceIDs,
                selectedSurfaceID: helperSurfaceID,
                pixelFrame: ControlPanePixelFrame(x: 500, y: 0, width: 500, height: 500),
                gridSize: nil
            ))
        }
        return ControlPaneListSnapshot(
            workspaceID: focusedWorkspaceID,
            windowID: windowID,
            panes: panes,
            containerWidth: 1_000,
            containerHeight: 500
        )
    }

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        surfaceHealthRoutings.append(routing)
        var surfaces = [
            ControlSurfaceHealthEntry(
                surfaceID: focusedSurfaceID,
                typeRawValue: "terminal",
                inWindow: true
            ),
        ]
        if includeExistingHelperPane {
            if includeExtraHelperSurface {
                surfaces.append(ControlSurfaceHealthEntry(
                    surfaceID: extraHelperSurfaceID,
                    typeRawValue: "terminal",
                    inWindow: true
                ))
            }
            surfaces.append(ControlSurfaceHealthEntry(
                surfaceID: helperSurfaceID,
                typeRawValue: "terminal",
                inWindow: existingHelperSurfaceVisible
            ))
        }
        if !paneCreateCalls.isEmpty || !surfaceCreateCalls.isEmpty {
            let sampleNumber = surfaceHealthRoutings.count
            let isCreatedSurfaceVisible = createdSurfaceVisibleAfterHealthSample.map {
                sampleNumber >= $0
            } ?? createdSurfaceVisible
            surfaces.append(ControlSurfaceHealthEntry(
                surfaceID: createdSurfaceID,
                typeRawValue: "terminal",
                inWindow: isCreatedSurfaceVisible
            ))
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: focusedWorkspaceID,
            windowID: windowID,
            surfaces: surfaces
        )
    }

    func controlPaneCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        paneCreateCalls.append((routing, inputs))
        return .created(
            windowID: windowID,
            workspaceID: focusedWorkspaceID,
            paneID: createdPaneID,
            surfaceID: createdSurfaceID,
            typeRawValue: inputs.typeRaw ?? "terminal"
        )
    }

    func controlSurfaceCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution {
        surfaceCreateCalls.append((routing, inputs))
        return .created(
            windowID: windowID,
            workspaceID: focusedWorkspaceID,
            paneID: inputs.requestedPaneID ?? helperPaneID,
            surfaceID: createdSurfaceID,
            typeRawValue: inputs.typeRaw ?? "terminal"
        )
    }

    func controlSurfaceSendText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        text: String
    ) -> ControlSurfaceSendResolution {
        surfaceSendTextCalls.append((routing, surfaceID, hasSurfaceIDParam, text))
        return .sent(
            windowID: windowID,
            workspaceID: focusedWorkspaceID,
            surfaceID: surfaceID ?? createdSurfaceID,
            queued: false
        )
    }
}

@MainActor
@Suite("ControlCommandCoordinator helper domain")
struct ControlCommandCoordinatorHelperTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeHelperControlCommandContext) {
        let context = FakeHelperControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "helper.visible", params: params)
    }

    @Test func visibleHelperTargetsFocusedWorkspaceWhenCallerDiffers() throws {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request([
            "caller": .object(["workspace_id": .string(context.callerWorkspaceID.uuidString)]),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.createdPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["target_workspace_source"] == .string("focused"))
        #expect(payload["caller_focused_diverged"] == .bool(true))
        #expect(payload["placement_strategy"] == .string("created_right_pane"))
        #expect(payload["reused_pane"] == .bool(false))
        #expect(payload["created_pane"] == .bool(true))
        #expect(payload["created_surface"] == .bool(true))
        #expect(payload["sent_command"] == .bool(false))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(payload["surface_health_attempts"] == .int(1))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 2)
        #expect(context.paneCreateCalls.first?.routing.workspaceID == context.focusedWorkspaceID)
        #expect(context.paneCreateCalls.first?.inputs.directionRaw == "right")
        #expect(context.paneCreateCalls.first?.inputs.requestedFocus == false)
    }

    @Test func visibleHelperCreatesVisiblePaneBeforeSendingCommand() throws {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request([
            "initial_command": .string("echo created"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.createdPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["created_pane"] == .bool(true))
        #expect(payload["created_surface"] == .bool(true))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["sent_command"] == .bool(true))
        #expect(payload["command_queued"] == .bool(false))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.paneCreateCalls.first?.inputs.initialCommand == nil)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.createdSurfaceID)
        #expect(context.surfaceSendTextCalls.first?.text == "echo created\n")
    }

    @Test func visibleHelperRetriesUntilNewlyCreatedSurfaceIsInWindow() throws {
        let (coordinator, context) = makeCoordinator()
        context.createdSurfaceVisibleAfterHealthSample = 3

        let result = coordinator.handle(request([
            "initial_command": .string("echo delayed"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(payload["surface_health_attempts"] == .int(2))
        #expect(payload["sent_command"] == .bool(true))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceHealthRoutings.count == 3)
    }

    @Test func visibleHelperReusesExistingRightPaneWithoutDuplicatingPanes() throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true

        let result = coordinator.handle(request())

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("reused_right_pane"))
        #expect(payload["reused_pane"] == .bool(true))
        #expect(payload["created_pane"] == .bool(false))
        #expect(payload["created_surface"] == .bool(false))
        #expect(payload["sent_command"] == .bool(false))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 2)
    }

    @Test func visibleHelperSendsCommandToExistingVisibleTerminalWithoutDuplicatingPanes() throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true

        let result = coordinator.handle(request([
            "initial_command": .string("echo helper"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("reused_right_pane"))
        #expect(payload["reused_pane"] == .bool(true))
        #expect(payload["created_pane"] == .bool(false))
        #expect(payload["created_surface"] == .bool(false))
        #expect(payload["sent_command"] == .bool(true))
        #expect(payload["command_queued"] == .bool(false))
        #expect(payload["surface_visible"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(true))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.routing.workspaceID == context.focusedWorkspaceID)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.helperSurfaceID)
        #expect(context.surfaceSendTextCalls.first?.text == "echo helper\n")
        #expect(context.surfaceHealthRoutings.count == 2)
    }

    @Test func visibleHelperSendsCommandToSelectedHelperSurfaceWhenPaneHasMultipleSurfaces() throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.includeExtraHelperSurface = true

        let result = coordinator.handle(request([
            "initial_command": .string("echo selected"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }

        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["surface_id"] == .string(context.helperSurfaceID.uuidString))
        #expect(payload["sent_command"] == .bool(true))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.count == 1)
        #expect(context.surfaceSendTextCalls.first?.surfaceID == context.helperSurfaceID)
        #expect(context.surfaceSendTextCalls.first?.surfaceID != context.extraHelperSurfaceID)
    }

    @Test func visibleHelperRejectsStructuralHelperPaneThatIsNotVisible() throws {
        let (coordinator, context) = makeCoordinator()
        context.includeExistingHelperPane = true
        context.existingHelperSurfaceVisible = false

        let result = coordinator.handle(request())

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "not_visible")
        #expect(message.contains("structural helper pane"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["pane_id"] == .string(context.helperPaneID.uuidString))
        #expect(payload["target_workspace_source"] == .string("focused"))
        #expect(context.paneCreateCalls.isEmpty)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 1)
    }

    @Test func visibleHelperFailsWhenCreatedSurfaceIsNotInWindow() throws {
        let (coordinator, context) = makeCoordinator()
        context.createdSurfaceVisible = false

        let result = coordinator.handle(request())

        guard case .err(let code, let message, let data) = result else {
            Issue.record("unexpected helper.visible result: \(String(describing: result))")
            return
        }
        guard case .object(let payload)? = data else {
            Issue.record("unexpected helper.visible error data: \(String(describing: data))")
            return
        }

        #expect(code == "not_visible")
        #expect(message.contains("in_window=true"))
        #expect(payload["workspace_id"] == .string(context.focusedWorkspaceID.uuidString))
        #expect(payload["surface_id"] == .string(context.createdSurfaceID.uuidString))
        #expect(payload["placement_strategy"] == .string("created_right_pane"))
        #expect(payload["surface_visible"] == .bool(false))
        #expect(payload["surface_health_found"] == .bool(true))
        #expect(payload["surface_health_in_window"] == .bool(false))
        #expect(payload["surface_health_attempts"] == .int(6))
        #expect(context.paneCreateCalls.count == 1)
        #expect(context.surfaceCreateCalls.isEmpty)
        #expect(context.surfaceSendTextCalls.isEmpty)
        #expect(context.surfaceHealthRoutings.count == 7)
    }
}
