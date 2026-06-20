import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeHelperControlCommandContext: ControlCommandContext {
    let windowID = UUID()
    let callerWorkspaceID = UUID()
    let callerPaneID = UUID()
    let callerSurfaceID = UUID()
    let focusedWorkspaceID = UUID()
    let focusedPaneID = UUID()
    let focusedSurfaceID = UUID()
    let leftPaneID = UUID()
    let leftSurfaceID = UUID()
    let helperPaneID = UUID()
    let helperSurfaceID = UUID()
    let extraHelperSurfaceID = UUID()
    let createdPaneID = UUID()
    let createdSurfaceID = UUID()

    var includeExistingHelperPane = false
    var includeLeftPane = false
    var includeExtraHelperSurface = false
    var helperSelectedSurfaceID: UUID?
    var windowVisible = true
    var focusedSurfaceVisible = true
    var focusedSurfaceVisibleInUI: Bool?
    var existingHelperSurfaceVisible = true
    var existingHelperSurfaceVisibleInUI: Bool?
    var leftSurfaceTypeRaw = "terminal"
    var leftSurfaceVisibleInUI = true
    var helperSurfaceTypeRaw = "terminal"
    var extraHelperSurfaceTypeRaw = "terminal"
    var extraHelperSurfaceVisibleInUI = false
    var createdSurfaceVisible = true
    var createdSurfaceVisibleAfterWindowEvent: Bool?
    var createdSurfaceVisibleInUI: Bool?
    var createdSurfaceWindowEventObserved = true
    var isRemoteTmuxMirror = false
    var browserCreationDisabled = false
    var onSurfaceWindowWait: (() -> Void)?
    var surfaceSendTextFails = false
    private(set) var identifyParams: [String: JSONValue] = [:]
    private(set) var paneListRoutings: [ControlRoutingSelectors] = []
    private(set) var surfaceHealthRoutings: [ControlRoutingSelectors] = []
    private(set) var surfaceWindowWaits: [(routing: ControlRoutingSelectors, surfaceID: UUID)] = []
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
        if includeLeftPane {
            panes.append(ControlPaneSummary(
                paneID: leftPaneID,
                isFocused: false,
                surfaceIDs: [leftSurfaceID],
                selectedSurfaceID: leftSurfaceID,
                pixelFrame: ControlPanePixelFrame(x: -500, y: 0, width: 500, height: 500),
                gridSize: nil
            ))
        }
        if includeExistingHelperPane {
            var surfaceIDs = [helperSurfaceID]
            if includeExtraHelperSurface {
                surfaceIDs.insert(extraHelperSurfaceID, at: 0)
            }
            panes.append(ControlPaneSummary(
                paneID: helperPaneID,
                isFocused: false,
                surfaceIDs: surfaceIDs,
                selectedSurfaceID: helperSelectedSurfaceID ?? helperSurfaceID,
                pixelFrame: ControlPanePixelFrame(x: 500, y: 0, width: 500, height: 500),
                gridSize: nil
            ))
        }
        return ControlPaneListSnapshot(
            workspaceID: focusedWorkspaceID,
            windowID: windowID,
            panes: panes,
            isRemoteTmuxMirror: isRemoteTmuxMirror,
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
                inWindow: focusedSurfaceVisible,
                visibleInUI: focusedSurfaceVisibleInUI ?? focusedSurfaceVisible
            ),
        ]
        if includeLeftPane {
            surfaces.append(ControlSurfaceHealthEntry(
                surfaceID: leftSurfaceID,
                typeRawValue: leftSurfaceTypeRaw,
                inWindow: true,
                visibleInUI: leftSurfaceVisibleInUI
            ))
        }
        if includeExistingHelperPane {
            if includeExtraHelperSurface {
                surfaces.append(ControlSurfaceHealthEntry(
                    surfaceID: extraHelperSurfaceID,
                    typeRawValue: extraHelperSurfaceTypeRaw,
                    inWindow: true,
                    visibleInUI: extraHelperSurfaceVisibleInUI
                ))
            }
            surfaces.append(ControlSurfaceHealthEntry(
                surfaceID: helperSurfaceID,
                typeRawValue: helperSurfaceTypeRaw,
                inWindow: existingHelperSurfaceVisible,
                visibleInUI: existingHelperSurfaceVisibleInUI ?? existingHelperSurfaceVisible
            ))
        }
        if !paneCreateCalls.isEmpty || !surfaceCreateCalls.isEmpty {
            let isCreatedSurfaceVisible = createdSurfaceVisibleAfterWindowEvent ?? createdSurfaceVisible
            surfaces.append(ControlSurfaceHealthEntry(
                surfaceID: createdSurfaceID,
                typeRawValue: "terminal",
                inWindow: isCreatedSurfaceVisible,
                visibleInUI: createdSurfaceVisibleInUI ?? isCreatedSurfaceVisible
            ))
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: focusedWorkspaceID,
            windowID: windowID,
            windowVisible: windowVisible,
            surfaces: surfaces
        )
    }

    func controlSurfaceWaitForInWindow(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) async -> Bool {
        surfaceWindowWaits.append((routing, surfaceID))
        onSurfaceWindowWait?()
        guard createdSurfaceWindowEventObserved else {
            return false
        }
        if let visibleAfterWindowEvent = createdSurfaceVisibleAfterWindowEvent {
            createdSurfaceVisible = visibleAfterWindowEvent
        }
        return true
    }

    func controlPaneBrowserCreationDisabled() -> Bool {
        browserCreationDisabled
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
        if surfaceSendTextFails {
            return .surfaceUnavailable(surfaceID ?? createdSurfaceID)
        }
        return .sent(
            windowID: windowID,
            workspaceID: focusedWorkspaceID,
            surfaceID: surfaceID ?? createdSurfaceID,
            queued: false
        )
    }
}
